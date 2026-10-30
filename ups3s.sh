#!/usr/bin/env bash
# =============================================================================
# ups3s.sh
# -----------------------------------------------------------------------------
# Settings, installation and checks for a Waveshare UPS Module 3S.
#
# The UPS module reports battery voltage, current, power and percentage through
# an INA219 at I2C address 0x41. It uses the I2C bus (SDA/SCL on the 40-pin
# header), not a free GPIO line, so it does not conflict with the PowerBlock
# (GPIO 17/18) or with the MCP23017 overlay (I2C 0x20).
#
# The monitor service only provides the measurement. The battery display, the
# thresholds and the shutdown belong to the application: the helper enables the
# battmon module of the application configuration and reports what the
# application published.
#
# The helper is sourced by setup-phoniebox.sh, which installs the monitor
# service and enables the module, and by the local quick setup, which checks
# the result on the Pi.
# =============================================================================

UPS3S_DEFAULT_ADDRESS="0x41"
UPS3S_DEFAULT_BUS="1"
UPS3S_DEFAULT_INTERVAL="10"
UPS3S_MIN_ADDRESS=$(( 0x40 ))
UPS3S_MAX_ADDRESS=$(( 0x4F ))
UPS3S_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPS3S_INSTALL_SCRIPT="${UPS3S_SCRIPT_DIR}/ups3s_install.sh"
UPS3S_MONITOR_SCRIPT="${UPS3S_SCRIPT_DIR}/ups3s_monitor.py"

# Application installation and the configuration the monitor feeds.
UPS3S_APP_DIR="${UPS3S_APP_DIR:-RPi-Jukebox-RFID}"
UPS3S_APP_CONFIG="shared/settings/jukebox.yaml"
UPS3S_STATUS_FILE="/run/ups3s/status.json"
UPS3S_API_URL="http://127.0.0.1:5556/api/v1/rpc"

# State of the last ups3s_check(), used by the callers for their summaries.
UPS3S_CHECK_STATUS="not checked"
UPS3S_CHECK_WARNINGS=0
UPS3S_APP_STATUS="not checked"

ups3s_warn() {
    echo "WARNING: $*" >&2
}

# Reads a KEY=VALUE entry from a flat configuration file.
ups3s_config_value() {
    local file="$1" key="$2" value=""

    if [[ -f "$file" ]]; then
        value="$(grep -E "^[[:space:]]*${key}=" "$file" \
            | tail -n 1 | cut -d= -f2- \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                  -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//")"
    fi
    printf '%s' "$value"
}

# Normalizes an INA219 address to the form 0xNN. Accepts hexadecimal (0x41)
# and decimal (65) values and rejects everything outside 0x40-0x4F.
ups3s_normalize_address() {
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

    if (( number < UPS3S_MIN_ADDRESS || number > UPS3S_MAX_ADDRESS )); then
        return 1
    fi

    printf '0x%02x' "$number"
}

# Loads ENABLE_UPS3S, UPS3S_I2C_BUS, UPS3S_I2C_ADDRESS and UPS3S_INTERVAL.
ups3s_load_settings() {
    local config="$1"
    local enable bus address interval

    UPS3S_CONFIG_FILE="$config"

    enable="$(ups3s_config_value "$config" ENABLE_UPS3S)"
    if [[ -z "$enable" ]]; then
        enable="false"
    fi
    case "$enable" in
        true|false) ;;
        *)
            echo "ERROR: ENABLE_UPS3S must be 'true' or 'false' (got '$enable')." >&2
            return 1
            ;;
    esac
    UPS3S_ENABLE="$enable"

    bus="$(ups3s_config_value "$config" UPS3S_I2C_BUS)"
    if [[ -z "$bus" ]]; then
        bus="$UPS3S_DEFAULT_BUS"
    fi
    if [[ ! "$bus" =~ ^[0-6]$ ]]; then
        echo "ERROR: UPS3S_I2C_BUS must be a bus number between 0 and 6 (got '$bus')." >&2
        return 1
    fi
    UPS3S_BUS="$bus"

    address="$(ups3s_config_value "$config" UPS3S_I2C_ADDRESS)"
    if [[ -z "$address" ]]; then
        address="$UPS3S_DEFAULT_ADDRESS"
    fi
    if ! UPS3S_ADDRESS="$(ups3s_normalize_address "$address")"; then
        echo "ERROR: UPS3S_I2C_ADDRESS must be between 0x40 and 0x4F (got '$address')." >&2
        return 1
    fi

    interval="$(ups3s_config_value "$config" UPS3S_INTERVAL)"
    if [[ -z "$interval" ]]; then
        interval="$UPS3S_DEFAULT_INTERVAL"
    fi
    if [[ ! "$interval" =~ ^[0-9]+$ ]] || (( interval < 1 || interval > 3600 )); then
        echo "ERROR: UPS3S_INTERVAL must be between 1 and 3600 seconds (got '$interval')." >&2
        return 1
    fi
    UPS3S_INTERVAL="$interval"

    return 0
}

# Runs a base64-encoded script on the Pi. Arguments are restricted to values
# that need no shell quoting.
ups3s_run_remote_script() {
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
        if [[ ! "$arg" =~ ^[A-Za-z0-9._:/-]+$ ]]; then
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

ups3s_probe_value() {
    local state="$1" key="$2"

    printf '%s\n' "$state" | sed -n "s/^${key}=//p" | tail -n 1
}

# Uploads the monitor to /tmp on the Pi. The caller provides run_remote_upload().
ups3s_upload_monitor() {
    if ! declare -F run_remote_upload > /dev/null; then
        echo "ERROR: run_remote_upload() is not defined." >&2
        return 1
    fi
    if [[ ! -f "$UPS3S_MONITOR_SCRIPT" ]]; then
        echo "ERROR: monitor script not found: $UPS3S_MONITOR_SCRIPT" >&2
        return 1
    fi
    run_remote_upload "$UPS3S_MONITOR_SCRIPT" /tmp/ups3s_monitor.py
}

# Reads the I2C state, the service state and the last status file from the Pi.
ups3s_probe() {
    local bus="$1" addr="$2" script

    script="$(cat <<'PROBE'
#!/bin/bash
bus="$1"
addr="$2"

boot=/boot/firmware/config.txt
[ -f "$boot" ] || boot=/boot/config.txt
printf 'boot_file=%s\n' "$boot"
if [ -f "$boot" ] && grep -qE '^[[:space:]]*dtparam=i2c_arm=on([[:space:]]|$)' "$boot"; then
    echo 'i2c_boot=on'
else
    echo 'i2c_boot=off'
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

echo "service_state=$(systemctl is-active ups3s-monitor.service 2>/dev/null || true)"
echo "service_enabled=$(systemctl is-enabled ups3s-monitor.service 2>/dev/null || true)"

status_file="$(sed -n 's/^UPS3S_STATUS_FILE=//p' /etc/ups3s-monitor.conf 2>/dev/null | tail -n 1)"
[ -n "$status_file" ] || status_file=/run/ups3s/status.json
if [ -r "$status_file" ]; then
    echo 'status_file=yes'
    /usr/bin/python3 - "$status_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        data = json.load(handle)
except Exception as exc:
    print(f"ups_status=invalid")
    print(f"ups_error={exc}")
    raise SystemExit(0)

print(f"ups_status={data.get('status', '')}")
if "error" in data:
    print(f"ups_error={data['error']}")
PY
else
    echo 'status_file=no'
fi
PROBE
)"

    ups3s_run_remote_script false "$script" "$bus" "$addr"
}

# Prints the state of the UPS monitor and sets UPS3S_CHECK_STATUS and
# UPS3S_CHECK_WARNINGS.
ups3s_check() {
    local address="${1:-${UPS3S_ADDRESS:-$UPS3S_DEFAULT_ADDRESS}}"
    local bus="${2:-${UPS3S_BUS:-$UPS3S_DEFAULT_BUS}}"
    local state boot_file i2c_boot bus_device i2c_access i2c_tools i2c_client i2c_name
    local i2c_driver i2c_token service_state service_enabled status_file
    local ups_status ups_error
    local app_state_raw app_status app_available app_soc app_state
    local warnings=0 status

    UPS3S_CHECK_STATUS="not checked"
    UPS3S_CHECK_WARNINGS=0

    if ! state="$(ups3s_probe "$bus" "$address")"; then
        ups3s_warn "Could not read the UPS 3S state from the Pi."
        UPS3S_CHECK_STATUS="unknown"
        return 1
    fi

    boot_file="$(ups3s_probe_value "$state" boot_file)"
    i2c_boot="$(ups3s_probe_value "$state" i2c_boot)"
    bus_device="$(ups3s_probe_value "$state" bus_device)"
    i2c_access="$(ups3s_probe_value "$state" i2c_access)"
    i2c_tools="$(ups3s_probe_value "$state" i2c_tools)"
    i2c_client="$(ups3s_probe_value "$state" i2c_client)"
    i2c_name="$(ups3s_probe_value "$state" i2c_name)"
    i2c_driver="$(ups3s_probe_value "$state" i2c_driver)"
    i2c_token="$(ups3s_probe_value "$state" i2c_token)"
    service_state="$(ups3s_probe_value "$state" service_state)"
    service_enabled="$(ups3s_probe_value "$state" service_enabled)"
    status_file="$(ups3s_probe_value "$state" status_file)"
    ups_status="$(ups3s_probe_value "$state" ups_status)"
    ups_error="$(ups3s_probe_value "$state" ups_error)"

    # The application is the authoritative view; it publishes what its battery
    # plugin read from the status file.
    app_state_raw="$(ups3s_app_status || true)"
    app_status="$(ups3s_probe_value "$app_state_raw" app_status)"
    app_available="$(ups3s_probe_value "$app_state_raw" app_available)"
    app_soc="$(ups3s_probe_value "$app_state_raw" app_soc)"
    app_state="$(ups3s_probe_value "$app_state_raw" app_state)"

    echo "    UPS 3S status:"
    printf "%-16s: %s\n" "address" "${address} on I2C bus ${bus}"
    printf "%-16s: %s\n" "boot config" "${boot_file:-unknown}"

    case "$i2c_boot" in
        on) printf "%-16s: %s\n" "I2C interface" "enabled in the boot config" ;;
        off) printf "%-16s: %s\n" "I2C interface" "NOT enabled in the boot config" ;;
        *) printf "%-16s: %s\n" "I2C interface" "unknown" ;;
    esac

    case "$bus_device" in
        yes) printf "%-16s: %s\n" "I2C bus" "active" ;;
        no) printf "%-16s: %s\n" "I2C bus" "not active (a reboot activates it)" ;;
        *) printf "%-16s: %s\n" "I2C bus" "unknown" ;;
    esac

    case "$i2c_access" in
        yes) printf "%-16s: %s\n" "I2C access" "yes (the service user may use /dev/i2c-${bus})" ;;
        no) printf "%-16s: %s\n" "I2C access" "NO (service user needs the group 'i2c')" ;;
        *) printf "%-16s: %s\n" "I2C access" "unknown" ;;
    esac

    case "$i2c_token" in
        ""|"--")
            printf "%-16s: %s\n" "device" "NOT detected at ${address}"
            ;;
        "UU")
            printf "%-16s: %s\n" "device" "detected at ${address}, kernel driver bound (${i2c_name:-unknown}/${i2c_driver:-unknown})"
            ;;
        *)
            printf "%-16s: %s\n" "device" "detected at ${address}"
            ;;
    esac

    printf "%-16s: %s\n" "service" "${service_state:-unknown} (${service_enabled:-unknown})"

    if [[ "$ups_status" == "ok" ]]; then
        printf "%-16s: %s\n" "monitor" "reading"
    elif [[ "$ups_status" == "error" ]]; then
        printf "%-16s: %s\n" "monitor" "ERROR: ${ups_error:-unknown}"
    else
        printf "%-16s: %s\n" "monitor" "no reading yet"
    fi

    case "$app_available" in
        yes)
            UPS3S_APP_STATUS="active (${app_soc:-?} %, ${app_state:-unknown})"
            printf "%-16s: %s\n" "battery display" "${UPS3S_APP_STATUS}"
            ;;
        no)
            UPS3S_APP_STATUS="configured, source not available"
            printf "%-16s: %s\n" "battery display" "${UPS3S_APP_STATUS}"
            ;;
        *)
            UPS3S_APP_STATUS="not answering (${app_status:-unknown})"
            printf "%-16s: %s\n" "battery display" "${UPS3S_APP_STATUS}"
            ;;
    esac

    if [[ "$i2c_boot" != "on" ]]; then
        status="I2C not enabled"
        ups3s_warn "The I2C interface is not enabled in ${boot_file:-the boot config}."
        warnings=$(( warnings + 1 ))
    elif [[ "$bus_device" == "no" ]]; then
        status="configured (reboot required)"
        ups3s_warn "The I2C bus is not active yet; a reboot activates it."
        warnings=$(( warnings + 1 ))
    elif [[ "$i2c_access" == "no" ]]; then
        status="no I2C access"
        ups3s_warn "The service user cannot access /dev/i2c-${bus}."
        warnings=$(( warnings + 1 ))
    elif [[ "$i2c_token" == "" || "$i2c_token" == "--" ]]; then
        status="device not detected (${address})"
        ups3s_warn "No device answers at ${address}. Check the UPS wiring and that the module is powered."
        warnings=$(( warnings + 1 ))
    elif [[ -n "$i2c_driver" ]]; then
        status="kernel driver bound"
        ups3s_warn "Kernel driver '${i2c_driver}' is bound to ${address}; the userspace monitor needs exclusive access."
        warnings=$(( warnings + 1 ))
    elif [[ "$service_state" != "active" ]]; then
        status="service ${service_state:-unknown}"
        ups3s_warn "The ups3s-monitor service is not active."
        warnings=$(( warnings + 1 ))
    elif [[ "$ups_status" == "error" ]]; then
        status="service active, no reading"
        ups3s_warn "The service cannot read the UPS: ${ups_error:-unknown}"
        warnings=$(( warnings + 1 ))
    elif [[ "$ups_status" != "ok" ]]; then
        status="service active, waiting for a reading"
        ups3s_warn "The service is active but has not written a reading yet."
        warnings=$(( warnings + 1 ))
    elif [[ "$app_available" == "no" ]]; then
        status="service running, display without data"
        ups3s_warn "The application reports the battery source as unavailable. Check the status file and 'journalctl --user -u jukebox-daemon'."
        warnings=$(( warnings + 1 ))
    elif [[ "$app_available" != "yes" ]]; then
        status="service running, display not configured"
        ups3s_warn "The application does not publish a battery status. Check the battmon module in ${UPS3S_APP_CONFIG}."
        warnings=$(( warnings + 1 ))
    else
        status="running (${app_soc} %, ${app_state})"
    fi

    if [[ "$i2c_tools" != "yes" ]]; then
        echo "    note: i2c-tools is missing; install it with 'sudo apt install i2c-tools'."
    fi
    if [[ "$status_file" != "yes" ]]; then
        echo "    note: no status file yet; check 'journalctl -u ups3s-monitor -n 20'."
    fi

    UPS3S_CHECK_WARNINGS=$warnings
    UPS3S_CHECK_STATUS=$status

    if (( warnings > 0 )); then
        echo "    ${warnings} warning(s): the UPS 3S is not ready."
    else
        echo "    no deviation found between the configuration and the UPS on the Pi"
    fi

    return 0
}

# Stops and disables a monitor that a previous run installed.
ups3s_disable() {
    if ! declare -F run_remote_sudo > /dev/null; then
        return 1
    fi
    run_remote_sudo "systemctl disable --now ups3s-monitor.service > /dev/null 2>&1 || true"
    UPS3S_CHECK_STATUS="disabled"
    return 0
}

# Installs or updates the monitor on the Pi and checks the result.
ups3s_install() {
    local config="$1" user="${SSH_USER:-}" state token driver

    if ! ups3s_load_settings "$config"; then
        return 1
    fi
    if [[ "$UPS3S_ENABLE" != "true" ]]; then
        echo "    UPS 3S: disabled (ENABLE_UPS3S=false)"
        ups3s_disable || true
        UPS3S_CHECK_STATUS="disabled"
        return 0
    fi
    if [[ -z "$user" ]]; then
        echo "ERROR: the SSH user is not known; cannot set the service user." >&2
        return 1
    fi
    if [[ ! -f "$UPS3S_INSTALL_SCRIPT" ]]; then
        echo "ERROR: UPS 3S installer not found: $UPS3S_INSTALL_SCRIPT" >&2
        return 1
    fi

    echo "    UPS 3S: ${UPS3S_ADDRESS} (INA219) on I2C bus ${UPS3S_BUS}"

    # A kernel driver on the address would compete with the userspace monitor.
    state="$(ups3s_probe "$UPS3S_BUS" "$UPS3S_ADDRESS" 2> /dev/null || true)"
    token="$(ups3s_probe_value "$state" i2c_token)"
    driver="$(ups3s_probe_value "$state" i2c_driver)"
    if [[ -n "$driver" ]]; then
        echo "ERROR: I2C address ${UPS3S_ADDRESS} is handled by the kernel driver '${driver}'." >&2
        echo "       The userspace monitor needs exclusive access to the INA219." >&2
        UPS3S_CHECK_STATUS="kernel driver bound"
        return 1
    fi
    if [[ -n "$token" && "$token" != "--" && "$token" != "UU" ]]; then
        echo "    note: the INA219 answers at ${UPS3S_ADDRESS}."
    fi

    if ! ups3s_upload_monitor; then
        return 1
    fi
    if ! ups3s_run_remote_script true "$(cat "${UPS3S_INSTALL_SCRIPT}")" \
            "$user" "$UPS3S_BUS" "$UPS3S_ADDRESS" "$UPS3S_INTERVAL"; then
        echo "ERROR: Could not install the UPS 3S monitor on the Pi." >&2
        echo "       The setup needs root privileges (passwordless sudo or the SSH password)." >&2
        return 1
    fi

    echo "    UPS 3S: monitor installed"
    return 0
}

# Writes or removes the battery block of the application configuration. The
# block is delimited by markers so a later run can replace or remove it.
ups3s_app_config_script() {
    cat <<'SCRIPT'
#!/bin/bash
/usr/bin/python3 - "$@" <<'PY'
import pathlib
import subprocess
import sys

mode, app_dir, status_file, stale_after, poll_interval = sys.argv[1:6]

BEGIN = "# BEGIN battmon"
END = "# END battmon"
MODULE_LINE = "    battmon: battery_monitor.batt_mon_json_file"

target = pathlib.Path.home() / app_dir / "shared/settings/jukebox.yaml"
if not target.is_file():
    if mode == "remove":
        print("remove: no application configuration yet")
        raise SystemExit(0)
    print(f"error: {target} does not exist")
    raise SystemExit(1)

original = target.read_text(encoding="utf-8")
lines = original.splitlines()

if BEGIN in lines:
    start = lines.index(BEGIN)
    end = lines.index(END, start)
    del lines[start:end + 1]
    while lines and not lines[-1].strip():
        lines.pop()

lines = [line for line in lines if not line.startswith("    battmon:")]

if mode == "remove":
    text = "\n".join(lines) + "\n"
else:
    if any(line.startswith("battmon:") for line in lines):
        print("error: the application configuration already contains a battmon block without setup markers")
        raise SystemExit(1)

    named = None
    for index, line in enumerate(lines):
        if line.rstrip() == "  named:":
            named = index
            break
    if named is None:
        print("error: modules.named is missing in the application configuration")
        raise SystemExit(1)

    index = named + 1
    while index < len(lines):
        line = lines[index]
        if not line.strip() or line.startswith("    "):
            index += 1
            continue
        break
    lines.insert(index, MODULE_LINE)

    if lines and lines[-1].strip():
        lines.append("")
    lines.extend([
        BEGIN,
        "battmon:",
        f"  poll_interval_sec: {poll_interval}",
        "  warning_voltage_mv: null",
        "  all_clear_voltage_mv: null",
        "  shutdown_voltage_mv: null",
        "  warning_soc: 20",
        "  all_clear_soc: 90",
        "  shutdown_soc: 10",
        "  json_file:",
        f"    path: {status_file}",
        f"    stale_after_sec: {stale_after}",
        "    fields:",
        "      soc: percent",
        "      state: state",
        "      voltage_v: battery_voltage_v",
        "      current_ma: current_ma",
        "      power_w: power_w",
        "      timestamp: timestamp",
        END,
    ])
    text = "\n".join(lines) + "\n"

backup = target.with_name(target.name + ".setup-backup")
if not backup.exists():
    backup.write_text(original, encoding="utf-8")

temporary = target.with_name(target.name + ".setup-tmp")
temporary.write_text(text, encoding="utf-8")

venv = pathlib.Path.home() / app_dir / ".venv/bin/python"
if venv.is_file():
    check = subprocess.run(
        [str(venv), "-c",
         "import sys, yaml; yaml.safe_load(open(sys.argv[1], encoding='utf-8'))",
         str(temporary)],
        capture_output=True,
        text=True,
    )
    if check.returncode != 0:
        temporary.unlink()
        print(f"error: the new configuration is not valid YAML: {check.stderr.strip()}")
        raise SystemExit(1)

temporary.replace(target)
print(f"{mode}: {target}")
PY
SCRIPT
}

# Enables the battery display in the application configuration after the
# installation. A stale window of three monitor intervals keeps a single missed
# write from turning the display unavailable.
ups3s_configure_app() {
    local config="$1" stale

    if ! ups3s_load_settings "$config"; then
        return 1
    fi
    if [[ "$UPS3S_ENABLE" != "true" ]]; then
        ups3s_remove_app
        return 0
    fi

    stale=$(( UPS3S_INTERVAL * 3 ))
    (( stale < 60 )) && stale=60

    echo "    battery display: enabling the battmon module in ${UPS3S_APP_CONFIG}"
    if ! ups3s_run_remote_script false "$(ups3s_app_config_script)" \
            write "$UPS3S_APP_DIR" "$UPS3S_STATUS_FILE" "$stale" 10; then
        ups3s_warn "The battery display could not be enabled in the application configuration."
        UPS3S_APP_STATUS="not configured"
        return 1
    fi
    UPS3S_APP_STATUS="configured"
    return 0
}

# Removes the battery block from the application configuration.
ups3s_remove_app() {
    echo "    battery display: removing the battmon module from ${UPS3S_APP_CONFIG}"
    if ! ups3s_run_remote_script false "$(ups3s_app_config_script)" \
            remove "$UPS3S_APP_DIR" "$UPS3S_STATUS_FILE" 0 10; then
        ups3s_warn "The battery display could not be removed from the application configuration."
        UPS3S_APP_STATUS="not configured"
        return 1
    fi
    UPS3S_APP_STATUS="disabled"
    return 0
}

# Restarts the jukebox service so the application reads the new configuration.
ups3s_restart_app() {
    echo ">>> Restarting the jukebox service for the battery configuration"
    if run_remote 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; systemctl --user restart jukebox-daemon'; then
        echo "    Restarted."
        return 0
    fi
    ups3s_warn "The jukebox service could not be restarted; the battery display starts with the next start."
    return 1
}

# Asks the application what its battery plugin published. Retries until the
# daemon answers, because it needs a moment after a restart.
ups3s_app_status() {
    local script

    script="$(cat <<'PROBE'
#!/bin/bash
url="$1"
/usr/bin/python3 - "$url" <<'PY'
import json
import sys
import time
import urllib.error
import urllib.request

url = sys.argv[1]
payload = json.dumps({
    "id": "setup-battmon",
    "package": "battmon",
    "plugin": "batt_mon",
    "method": "get_batt_status",
}).encode("utf-8")

last_error = ""
for _attempt in range(10):
    request = urllib.request.Request(
        url, data=payload, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            data = json.load(response)
    except (urllib.error.URLError, OSError, ValueError) as error:
        last_error = str(error)
        time.sleep(3)
        continue

    if "error" in data:
        print("app_status=error")
        print(f"app_error={data['error']}")
        raise SystemExit(0)

    result = data.get("result") or {}
    # The plugin answers with an unavailable object until its first poll has
    # run, so an unavailable result right after a restart is not a failure.
    if not result.get("available") and _attempt < 9:
        time.sleep(3)
        continue

    print("app_status=ok")
    print(f"app_available={'yes' if result.get('available') else 'no'}")
    print(f"app_soc={result.get('soc', '')}")
    print(f"app_state={result.get('state', '')}")
    raise SystemExit(0)

print("app_status=unreachable")
print(f"app_error={last_error}")
PY
PROBE
)"

    ups3s_run_remote_script false "$script" "$UPS3S_API_URL"
}
