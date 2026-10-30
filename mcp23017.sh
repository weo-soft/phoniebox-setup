#!/usr/bin/env bash
# =============================================================================
# mcp23017.sh
# -----------------------------------------------------------------------------
# Settings and checks for an MCP23017 I2C GPIO expander (Adafruit 5346) on a
# Phoniebox. The expander is driven by the kernel driver through the
# device-tree overlay "mcp23017", so the GPIOs appear as a gpiochip next to the
# Raspberry Pi GPIOs.
#
# The installation itself (I2C interface, overlay, i2c-tools, groups and the
# application settings) is part of the Phoniebox installer: setup-phoniebox.sh
# passes ENABLE_MCP23017, MCP23017_ADDRESS and MCP23017_I2C_BUS through its
# --config file. This helper only parses and validates those settings and
# checks the result on the Pi.
#
# The PowerBlock driver uses the Raspberry Pi GPIOs 17 (status) and 18
# (shutdown) through gpiod. It has no I2C address, so it cannot collide with
# the address of the expander.
# =============================================================================

MCP23017_DEFAULT_ADDRESS="0x20"
MCP23017_DEFAULT_BUS="1"
MCP23017_MIN_ADDRESS=$(( 0x20 ))
MCP23017_MAX_ADDRESS=$(( 0x27 ))

# State of the last mcp23017_check(), used by the callers for their summaries.
MCP23017_CHECK_STATUS="not checked"
MCP23017_CHECK_WARNINGS=0

mcp23017_warn() {
    echo "WARNING: $*" >&2
}

# True for the driver names used by the kernel MCP23017 driver. Current
# kernels expose "mcp230xx"; older kernels used "mcp23s08".
mcp23017_is_driver() {
    case "$1" in
        mcp230xx|mcp23s08|gpio-mcp23s08) return 0 ;;
        *) return 1 ;;
    esac
}

# Reads a KEY=VALUE entry from a flat configuration file, with the same
# quoting rules as the setup scripts.
mcp23017_config_value() {
    local file="$1" key="$2" value=""

    if [[ -f "$file" ]]; then
        value="$(grep -E "^[[:space:]]*${key}=" "$file" \
            | tail -n 1 | cut -d= -f2- \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                  -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")"
    fi
    printf '%s' "$value"
}

# Normalizes an MCP23017 address to the form 0xNN. Accepts hexadecimal
# (0x20) and decimal (32) values and rejects everything outside 0x20-0x27.
mcp23017_normalize_address() {
    local value="$1" number

    if [[ -z "$value" ]]; then
        return 1
    fi

    if [[ "$value" =~ ^0[xX][0-9a-fA-F]{1,2}$ ]]; then
        number=$(( 16#${value:2} ))
    elif [[ "$value" =~ ^[0-9]{1,3}$ ]]; then
        number=$(( 10#$value ))
    else
        return 1
    fi

    if (( number < MCP23017_MIN_ADDRESS || number > MCP23017_MAX_ADDRESS )); then
        return 1
    fi

    printf '0x%02x' "$number"
}

# Loads ENABLE_MCP23017, MCP23017_ADDRESS and MCP23017_I2C_BUS from the
# application config into the MCP23017_* variables. Returns non-zero when a
# value is invalid.
mcp23017_load_settings() {
    local config="$1"
    local enable address bus

    MCP23017_CONFIG_FILE="$config"

    enable="$(mcp23017_config_value "$config" ENABLE_MCP23017)"
    if [[ -z "$enable" ]]; then
        enable="false"
    fi
    case "$enable" in
        true|false) ;;
        *)
            echo "ERROR: ENABLE_MCP23017 must be 'true' or 'false' (got '$enable')." >&2
            return 1
            ;;
    esac
    MCP23017_ENABLE="$enable"

    address="$(mcp23017_config_value "$config" MCP23017_ADDRESS)"
    if [[ -z "$address" ]]; then
        address="$MCP23017_DEFAULT_ADDRESS"
    fi
    if ! MCP23017_ADDRESS="$(mcp23017_normalize_address "$address")"; then
        echo "ERROR: MCP23017_ADDRESS must be an I2C address between 0x20 and 0x27 (got '$address')." >&2
        return 1
    fi

    bus="$(mcp23017_config_value "$config" MCP23017_I2C_BUS)"
    if [[ -z "$bus" ]]; then
        bus="$MCP23017_DEFAULT_BUS"
    fi
    if [[ ! "$bus" =~ ^[0-6]$ ]]; then
        echo "ERROR: MCP23017_I2C_BUS must be a bus number between 0 and 6 (got '$bus')." >&2
        return 1
    fi
    MCP23017_BUS="$bus"

    return 0
}

# Runs a script on the Pi. The script is base64-encoded so that its quoting
# cannot collide with the single-quoted wrapper of run_remote_sudo(). Arguments
# are restricted to values that need no shell quoting.
mcp23017_run_remote_script() {
    local use_sudo="$1" script="$2" arg encoded args="" cmd

    shift 2

    if ! declare -F run_remote > /dev/null; then
        echo "ERROR: run_remote() is not defined." >&2
        return 1
    fi
    if [[ "$use_sudo" == "true" ]] && ! declare -F run_remote_sudo > /dev/null; then
        echo "ERROR: run_remote_sudo() is not defined." >&2
        return 1
    fi

    encoded="$(printf '%s' "$script" | base64 | tr -d '\n')"
    for arg in "$@"; do
        if [[ ! "$arg" =~ ^[A-Za-z0-9._:-]+$ ]]; then
            echo "ERROR: unsafe argument for a remote script: $arg" >&2
            return 1
        fi
        args+=" $arg"
    done

    cmd="echo ${encoded} | base64 -d | bash -s --${args}"
    if [[ "$use_sudo" == "true" ]]; then
        run_remote_sudo "$cmd"
    else
        run_remote "$cmd"
    fi
}

# Prints one value out of the KEY=VALUE report of mcp23017_probe().
mcp23017_probe_value() {
    local state="$1" key="$2"

    printf '%s\n' "$state" | sed -n "s/^${key}=//p" | tail -n 1
}

# Reads the state of the I2C bus, the boot configuration and the expander from
# the Pi. Prints KEY=VALUE lines.
mcp23017_probe() {
    local bus="$1" addr="$2" script

    script="$(cat <<'PROBE'
#!/bin/bash
bus="$1"
addr="$2"

boot=/boot/firmware/config.txt
[ -f "$boot" ] || boot=/boot/config.txt
printf 'boot_file=%s\n' "$boot"

if [ -f "$boot" ]; then
    if grep -qE '^[[:space:]]*dtparam=i2c_arm=on([[:space:]]|$)' "$boot"; then
        echo 'i2c_boot=on'
    else
        echo 'i2c_boot=off'
    fi

    overlay_line="$(grep -E '^[[:space:]]*dtoverlay=mcp23017([,[:space:]]|$)' "$boot" | tail -n 1)"
    if [ -n "$overlay_line" ]; then
        echo 'overlay=yes'
        echo "overlay_line=${overlay_line}"
        echo "overlay_address=$(printf '%s\n' "$overlay_line" | sed -n 's/.*addr=\([^, ]*\).*/\1/p')"
        case "$overlay_line" in
            *noints*) echo 'overlay_noints=yes' ;;
            *) echo 'overlay_noints=no' ;;
        esac
    else
        echo 'overlay=no'
        echo 'overlay_line='
        echo 'overlay_address='
        echo 'overlay_noints=no'
    fi
else
    echo 'i2c_boot=unknown'
    echo 'overlay=unknown'
    echo 'overlay_line='
    echo 'overlay_address='
    echo 'overlay_noints=no'
fi

if [ -e "/dev/i2c-${bus}" ]; then
    echo 'bus_device=yes'
    if [ -r "/dev/i2c-${bus}" ] && [ -w "/dev/i2c-${bus}" ]; then
        echo 'i2c_access=yes'
    else
        echo 'i2c_access=no'
    fi
else
    echo 'bus_device=no'
    echo 'i2c_access=unknown'
fi

if command -v i2cdetect > /dev/null 2>&1; then
    i2cdetect_bin="$(command -v i2cdetect)"
elif [ -x /usr/sbin/i2cdetect ]; then
    i2cdetect_bin=/usr/sbin/i2cdetect
else
    i2cdetect_bin=""
fi
if [ -n "$i2cdetect_bin" ]; then
    echo 'i2c_tools=yes'
else
    echo 'i2c_tools=no'
fi

dev="/sys/bus/i2c/devices/${bus}-$(printf '%04x' "$addr")"
if [ -e "$dev" ]; then
    echo 'i2c_client=yes'
    echo "i2c_name=$(cat "$dev/name" 2>/dev/null)"
    if [ -L "$dev/driver" ]; then
        echo "i2c_driver=$(basename "$(readlink "$dev/driver")")"
    else
        echo 'i2c_driver='
    fi
else
    echo 'i2c_client=no'
    echo 'i2c_name='
    echo 'i2c_driver='
fi

token=''
if [ -n "$i2cdetect_bin" ] && [ -e "/dev/i2c-${bus}" ]; then
    row="$(printf '%02x' $(( addr & 0xf0 )))"
    line="$("$i2cdetect_bin" -y "$bus" 2>/dev/null | grep -E "^${row}:" | head -n 1)"
    if [ -n "$line" ]; then
        set -- $line
        idx=$(( (addr & 0x0f) + 2 ))
        eval "token=\${$idx:-}"
    fi
fi
echo "i2c_token=${token}"

if command -v i2cget > /dev/null 2>&1; then
    i2cget_bin="$(command -v i2cget)"
elif [ -x /usr/sbin/i2cget ]; then
    i2cget_bin=/usr/sbin/i2cget
else
    i2cget_bin=""
fi
gppu_a=''
gppu_b=''
if [ -n "$i2cget_bin" ] && [ -e "/dev/i2c-${bus}" ]; then
    gppu_a="$("$i2cget_bin" -f -y "$bus" "$addr" 0x0c 2>/dev/null || true)"
    gppu_b="$("$i2cget_bin" -f -y "$bus" "$addr" 0x0d 2>/dev/null || true)"
fi
echo "gppu_a=${gppu_a}"
echo "gppu_b=${gppu_b}"
if command -v gpioinfo > /dev/null 2>&1; then
    echo "gpiochips=$(gpioinfo 2>/dev/null | grep -c '^gpiochip')"
else
    echo 'gpiochips=unknown'
fi
PROBE
)"

    mcp23017_run_remote_script false "$script" "$bus" "$addr"
}

# Prints the state of the expander on the Pi and sets
# MCP23017_CHECK_STATUS and MCP23017_CHECK_WARNINGS.
mcp23017_check() {
    local address="${1:-${MCP23017_ADDRESS:-$MCP23017_DEFAULT_ADDRESS}}"
    local bus="${2:-${MCP23017_BUS:-$MCP23017_DEFAULT_BUS}}"
    local state boot_file i2c_boot overlay overlay_line overlay_address overlay_noints
    local bus_device i2c_access i2c_tools i2c_client i2c_name i2c_driver i2c_token gpiochips
    local gppu_a gppu_b
    local warnings=0 status

    MCP23017_CHECK_STATUS="not checked"
    MCP23017_CHECK_WARNINGS=0

    if ! state="$(mcp23017_probe "$bus" "$address")"; then
        mcp23017_warn "Could not read the MCP23017 state from the Pi."
        MCP23017_CHECK_STATUS="unknown"
        return 1
    fi

    boot_file="$(mcp23017_probe_value "$state" boot_file)"
    i2c_boot="$(mcp23017_probe_value "$state" i2c_boot)"
    overlay="$(mcp23017_probe_value "$state" overlay)"
    overlay_line="$(mcp23017_probe_value "$state" overlay_line)"
    overlay_address="$(mcp23017_probe_value "$state" overlay_address)"
    overlay_noints="$(mcp23017_probe_value "$state" overlay_noints)"
    bus_device="$(mcp23017_probe_value "$state" bus_device)"
    i2c_access="$(mcp23017_probe_value "$state" i2c_access)"
    i2c_tools="$(mcp23017_probe_value "$state" i2c_tools)"
    i2c_client="$(mcp23017_probe_value "$state" i2c_client)"
    i2c_name="$(mcp23017_probe_value "$state" i2c_name)"
    i2c_driver="$(mcp23017_probe_value "$state" i2c_driver)"
    i2c_token="$(mcp23017_probe_value "$state" i2c_token)"
    gpiochips="$(mcp23017_probe_value "$state" gpiochips)"
    gppu_a="$(mcp23017_probe_value "$state" gppu_a)"
    gppu_b="$(mcp23017_probe_value "$state" gppu_b)"

    echo "    MCP23017 status:"
    printf "%-16s: %s\n" "address" "${address} on I2C bus ${bus}"
    printf "%-16s: %s\n" "boot config" "${boot_file:-unknown}"

    case "$i2c_boot" in
        on) printf "%-16s: %s\n" "I2C interface" "enabled in the boot config" ;;
        off) printf "%-16s: %s\n" "I2C interface" "NOT enabled in the boot config" ;;
        *) printf "%-16s: %s\n" "I2C interface" "unknown" ;;
    esac

    if [[ "$overlay" == "yes" ]]; then
        printf "%-16s: %s\n" "driver overlay" "${overlay_line}"
    else
        printf "%-16s: %s\n" "driver overlay" "MISSING"
    fi

    case "$bus_device" in
        yes) printf "%-16s: %s\n" "I2C bus" "active" ;;
        no) printf "%-16s: %s\n" "I2C bus" "not active (a reboot activates it)" ;;
        *) printf "%-16s: %s\n" "I2C bus" "unknown" ;;
    esac

    case "$i2c_access" in
        yes) printf "%-16s: %s\n" "I2C access" "yes (the SSH user may use /dev/i2c-${bus})" ;;
        no) printf "%-16s: %s\n" "I2C access" "NO (add the SSH user to the group 'i2c')" ;;
        *) printf "%-16s: %s\n" "I2C access" "unknown" ;;
    esac

    case "$i2c_token" in
        ""|"--")
            printf "%-16s: %s\n" "device" "NOT detected at ${address}"
            ;;
        "UU")
            printf "%-16s: %s\n" "device" "detected at ${address}, kernel driver bound"
            ;;
        *)
            printf "%-16s: %s\n" "device" "detected at ${address}, kernel driver not bound yet"
            ;;
    esac

    if [[ "$i2c_client" == "yes" ]]; then
        printf "%-16s: %s\n" "kernel client" "${i2c_name:-unknown} (driver: ${i2c_driver:-none})"
    else
        printf "%-16s: %s\n" "kernel client" "not instantiated"
    fi

    printf "%-16s: %s\n" "gpiochips" "${gpiochips:-unknown}"
    if [[ -n "$gppu_a" ]]; then
        printf "%-16s: %s\n" "pull-ups" "GPPU A=${gppu_a} B=${gppu_b:-?} (written by the mcp23017 plugin on start)"
    else
        printf "%-16s: %s\n" "pull-ups" "not readable"
    fi

    if [[ "$overlay" != "yes" ]]; then
        status="not configured"
        mcp23017_warn "The mcp23017 overlay is missing from ${boot_file:-the boot config}."
        warnings=$(( warnings + 1 ))
    elif [[ -n "$overlay_address" && "$overlay_address" != "$address" ]]; then
        status="address mismatch"
        mcp23017_warn "The overlay uses ${overlay_address}, but ${address} is configured."
        warnings=$(( warnings + 1 ))
    elif [[ "$overlay_noints" != "yes" ]]; then
        status="interrupt pin enabled"
        mcp23017_warn "The overlay claims GPIO4 for INTA. Use noints unless INTA is wired."
        warnings=$(( warnings + 1 ))
    elif [[ -n "$i2c_driver" ]] && ! mcp23017_is_driver "$i2c_driver"; then
        status="address conflict"
        mcp23017_warn "I2C address ${address} is handled by '${i2c_driver}', not by the MCP23017 driver."
        warnings=$(( warnings + 1 ))
    elif [[ -n "$i2c_driver" ]] && mcp23017_is_driver "$i2c_driver"; then
        status="driver active (${address})"
    elif [[ "$bus_device" == "no" ]]; then
        status="configured (reboot required)"
    elif [[ "$i2c_access" == "no" ]]; then
        status="no I2C access"
        mcp23017_warn "The SSH user cannot access /dev/i2c-${bus}; add it to the group 'i2c'."
        warnings=$(( warnings + 1 ))
    elif [[ "$i2c_token" == "" || "$i2c_token" == "--" ]]; then
        status="configured, device not detected (${address})"
        mcp23017_warn "No device answers at ${address}. Check the wiring and the A0-A2 jumpers."
        warnings=$(( warnings + 1 ))
    elif [[ "$i2c_client" == "yes" ]]; then
        status="configured, driver pending (${address})"
    else
        status="device detected, overlay pending (${address})"
    fi

    if [[ "$i2c_tools" != "yes" ]]; then
        echo "    note: i2c-tools is missing; install it with 'sudo apt install i2c-tools'."
    fi

    if [[ "$i2c_boot" == "off" && "$overlay" == "yes" ]]; then
        echo "    note: the overlay enables the I2C bus; the dtparam line is missing."
    fi

    MCP23017_CHECK_WARNINGS=$warnings
    MCP23017_CHECK_STATUS=$status

    if (( warnings > 0 )); then
        echo "    ${warnings} warning(s): the MCP23017 is not ready."
    else
        echo "    no deviation found between the configuration and the expander on the Pi"
    fi

    return 0
}
