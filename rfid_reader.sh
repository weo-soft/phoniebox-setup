#!/usr/bin/env bash
# =============================================================================
# rfid_reader.sh
# -----------------------------------------------------------------------------
# Shared helper for setup-phoniebox.sh and quick-setup.sh. It holds
#
#   - the canonical reader names of the application and their technical module
#     names (resolve_rfid_reader_module), and
#   - the check that compares the RFID reader of the setup configuration with
#     the hardware connected to the Raspberry Pi.
#
# The check warns about every deviation and names the setting to change in the
# application configuration, so that the next run installs a reader
# configuration matching the hardware. It is advisory: it never aborts a run.
#
# The caller provides:
#   run_remote <command>     runs a shell command on the Pi and prints its output
#                            (both setup scripts define this function)
#   RFID_CHECK_CONFIG_FILE   application configuration file (named in messages)
#   RFID_CHECK_ENABLE        ENABLE_RFID_READER (true/false)
#   RFID_CHECK_MODULE        configured reader module (technical name)
#   RFID_CHECK_PARAMS        configured RFID_READER_PARAMS (may be empty)
#   RFID_CHECK_DEPS          configured RFID_READER_DEPS (auto/no)
#   RFID_CHECK_STAGE         'pre' (before the installation) or 'post'
#
# Entry points (in this order):
#   rfid_check_prepare                    reset the counters
#   rfid_check_hardware                   probe the Pi, keep the report
#   rfid_check_configured_reader          verdict for the configured reader
#   rfid_check_installed_configuration    compare the written reader config
#   rfid_check_summary                    warnings and hints for the next run
# =============================================================================

# State, initialised here so that the functions stay safe under 'set -u'.
RFID_CHECK_CONFIG_FILE=""
RFID_CHECK_ENABLE="true"
RFID_CHECK_MODULE=""
RFID_CHECK_PARAMS=""
RFID_CHECK_DEPS="auto"
RFID_CHECK_STAGE="pre"
RFID_CHECK_REPORT=""
RFID_CHECK_WARNINGS=0
RFID_CHECK_SUGGESTIONS=""
RFID_CHECK_STATUS=""
RFID_CHECK_HINTED=""
RFID_CHECK_PROBE_OK="yes"

# Canonical display name of a reader module and its technical module name. The
# application describes the readers with the canonical names, while the
# installer expects the technical module names.
RFID_READER_CANONICAL_NAMES=(
    "PN532 reader via I2C using py532 library|pn532_i2c_py532"
    "MFRC522 via SPI|rc522_spi"
    "RDM6300 via serial UART|rdm6300_serial"
    "MFRC522 Reader using I2C via the mfrc522_i2c library|mfrc522_i2c"
    "Generic NFCPY NFC Reader Module|generic_nfcpy"
    "Generic USB Reader|generic_usb"
)

# Maps a canonical reader name to its technical module name; technical module
# names pass through unchanged. Prints the module name on stdout and returns 0.
# Returns 1 (with a list of all supported names) when the value is neither.
resolve_rfid_reader_module() {
    local value="$1" entry canonical module
    if [ -z "$value" ]; then
        return 0
    fi
    for entry in "${RFID_READER_CANONICAL_NAMES[@]}"; do
        module="${entry#*|}"
        if [ "$value" == "$module" ]; then
            printf '%s' "$module"
            return 0
        fi
    done
    for entry in "${RFID_READER_CANONICAL_NAMES[@]}"; do
        canonical="${entry%%|*}"
        if [ "${value,,}" == "${canonical,,}" ]; then
            module="${entry#*|}"
            printf '%s' "$module"
            return 0
        fi
    done
    echo "ERROR: Unknown RFID reader module '$value'." >&2
    echo "Supported values (technical module or canonical name):" >&2
    for entry in "${RFID_READER_CANONICAL_NAMES[@]}"; do
        canonical="${entry%%|*}"
        module="${entry#*|}"
        echo "  - $module   ($canonical)" >&2
    done
    return 1
}

# Python support a reader module needs inside the application's venv.
rfid_module_package() {
    case "$1" in
        generic_nfcpy) printf 'nfc' ;;
        generic_usb) printf 'evdev' ;;
        rc522_spi) printf 'pirc522' ;;
        pn532_i2c_py532) printf 'py532lib' ;;
        mfrc522_i2c) printf 'mfrc522_i2c' ;;
        rdm6300_serial) printf 'serial' ;;
        *) printf '' ;;
    esac
}

# The same support as it is named in the documentation (package and import name).
rfid_module_package_label() {
    case "$1" in
        generic_nfcpy) printf 'nfcpy (nfc)' ;;
        generic_usb) printf 'evdev' ;;
        rc522_spi) printf 'pirc522' ;;
        pn532_i2c_py532) printf 'py532lib' ;;
        mfrc522_i2c) printf 'mfrc522_i2c' ;;
        rdm6300_serial) printf 'pyserial (serial)' ;;
        *) printf '' ;;
    esac
}

# Interface class of a reader module: which part of the Pi the reader uses.
rfid_module_interface() {
    case "$1" in
        generic_usb) printf 'usb-hid' ;;
        generic_nfcpy) printf 'usb-nfc' ;;
        rc522_spi) printf 'spi' ;;
        pn532_i2c_py532 | mfrc522_i2c) printf 'i2c' ;;
        rdm6300_serial) printf 'serial' ;;
        fake_reader_gui) printf 'simulator' ;;
        *) printf 'unknown' ;;
    esac
}

# I2C address the reader module expects, in the notation of i2cdetect.
rfid_module_i2c_address() {
    case "$1" in
        pn532_i2c_py532) printf '24' ;;
        mfrc522_i2c) printf '28' ;;
        *) printf '' ;;
    esac
}

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
rfid_line() {
    printf '    %-11s: %s\n' "$1" "$2"
}

rfid_note() {
    printf '             %s\n' "$1"
}

rfid_warn() {
    RFID_CHECK_WARNINGS=$((RFID_CHECK_WARNINGS + 1))
    printf '    WARNING: %s\n' "$1"
}

rfid_status() {
    RFID_CHECK_STATUS="$1"
}

rfid_suggest() {
    case ";${RFID_CHECK_SUGGESTIONS};" in
        *";$1;"*) ;;
        *) RFID_CHECK_SUGGESTIONS="${RFID_CHECK_SUGGESTIONS:+${RFID_CHECK_SUGGESTIONS};}$1" ;;
    esac
}

# -----------------------------------------------------------------------------
# Report helpers
# -----------------------------------------------------------------------------
# One value of the report ('key=value' lines), empty when the key is absent.
rfid_report_value() {
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -n 1
}

# Prints a ';'-separated report value as one entry per line, with an optional
# prefix.
rfid_list() {
    local item
    [ -n "$1" ] || return 0
    while IFS= read -r item; do
        [ -n "$item" ] && printf '%s%s\n' "${2:-}" "$item"
    done < <(printf '%s\n' "$1" | tr ';' '\n')
}

# True when the ';'-separated list holds the entry.
rfid_list_contains() {
    case ";$1;" in
        *";$2;"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Number of entries in a ';'-separated list.
rfid_list_count() {
    [ -n "$1" ] || { printf '0'; return 0; }
    printf '%s' "$1" | tr ';' '\n' | grep -c '[^[:space:]]'
}

# Readable form of the USB devices in the report: 'id (product), ...'.
rfid_usb_text() {
    local entry id name text=""
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        id="${entry%% *}"
        name="${entry#"$id"}"
        name="$(printf '%s' "$name" | sed -e 's/^[[:space:]]*//')"
        if [ -n "$name" ]; then
            text="${text:+$text, }$id ($name)"
        else
            text="${text:+$text, }$id"
        fi
    done < <(rfid_list "$(rfid_report_value "$RFID_CHECK_REPORT" usb_list)")
    printf '%s' "$text"
}

# USB IDs that nfcpy supports, restricted to the devices on the USB bus. Only
# filled once the application is installed, because nfcpy lives in its venv.
rfid_usb_nfc_ids() {
    local id known ids="" usb_ids
    known="$(rfid_report_value "$RFID_CHECK_REPORT" nfcpy_ids)"
    [ -n "$known" ] || return 0
    usb_ids="$(rfid_report_value "$RFID_CHECK_REPORT" usb_ids)"
    for id in $(printf '%s' "$known" | tr ';' ' '); do
        if rfid_list_contains "$usb_ids" "$id"; then
            ids="${ids:+$ids;}$id"
        fi
    done
    printf '%s' "$ids"
}

# Value of one reader parameter out of a 'key=value;key=value' string.
rfid_param_value() {
    printf '%s' "$1" | tr ';' '\n' \
        | sed -n "s/^[[:space:]]*$2=//p" | head -n 1 \
        | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# -----------------------------------------------------------------------------
# Probe
# -----------------------------------------------------------------------------
# Read-only inspection of the Pi, printing 'key=value' lines. Nothing is changed
# and nothing is written on the Pi, so the probe is safe at any point of a run.
rfid_probe_remote_snippet() {
    cat <<'REMOTE_SNIPPET_EOF'
cfg=""
for f in /boot/firmware/config.txt /boot/config.txt; do
    if [ -f "$f" ]; then cfg="$f"; break; fi
done
printf 'boot_config=%s\n' "${cfg:-none}"

boot_params=""
if [ -n "$cfg" ]; then
    boot_params="$(grep -E '^[[:space:]]*(dtparam=(i2c|i2c_arm|spi)|enable_uart)' "$cfg" 2> /dev/null | tr -s ' ' | paste -sd';' -)"
fi
printf 'boot_params=%s\n' "$boot_params"

usb_ids=""
usb_list=""
for d in /sys/bus/usb/devices/*/; do
    [ -f "$d/idVendor" ] || continue
    vid="$(cat "$d/idVendor" 2> /dev/null)"
    pid="$(cat "$d/idProduct" 2> /dev/null)"
    # Root hubs carry no reader
    [ "$vid" = "1d6b" ] && continue
    name="$(cat "$d/product" 2> /dev/null)"
    [ -n "$name" ] || name="$(cat "$d/manufacturer" 2> /dev/null)"
    usb_ids="${usb_ids:+$usb_ids;}$vid:$pid"
    if [ -n "$name" ]; then
        usb_list="${usb_list:+$usb_list;}$vid:$pid $name"
    else
        usb_list="${usb_list:+$usb_list;}$vid:$pid"
    fi
done
printf 'usb_ids=%s\n' "$usb_ids"
printf 'usb_list=%s\n' "$usb_list"

i2c_devices=""
for f in /dev/i2c-[0-9]*; do
    [ -e "$f" ] && i2c_devices="${i2c_devices:+$i2c_devices;}${f##*/}"
done
printf 'i2c_devices=%s\n' "$i2c_devices"

spi_devices=""
for f in /dev/spidev[0-9]*; do
    [ -e "$f" ] && spi_devices="${spi_devices:+$spi_devices;}${f##*/}"
done
printf 'spi_devices=%s\n' "$spi_devices"

serial_devices=""
for f in /dev/ttyUSB[0-9]* /dev/ttyAMA[0-9]* /dev/serial[0-9] /dev/ttyS[0-9]*; do
    [ -e "$f" ] && serial_devices="${serial_devices:+$serial_devices;}${f##*/}"
done
printf 'serial_devices=%s\n' "$serial_devices"

i2c_scan=""
if command -v i2cdetect > /dev/null 2>&1; then
    for f in /dev/i2c-[0-9]*; do
        [ -e "$f" ] || continue
        bus="${f#/dev/i2c-}"
        addrs="$(i2cdetect -y "$bus" 2> /dev/null | awk '/^[0-9a-f][0-9a-f]:/ { for (i = 2; i <= NF; i++) if ($i != "--") printf "%s,", $i }')"
        [ -n "$addrs" ] && i2c_scan="${i2c_scan:+$i2c_scan;}i2c-$bus:${addrs%,}"
    done
fi
printf 'i2c_scan=%s\n' "$i2c_scan"

# Input devices with the key range that the USB reader support requires. The
# kernel exposes the same key capabilities the application reads through evdev,
# so this test matches the application's own device selection.
if command -v python3 > /dev/null 2>&1; then
    python3 - <<'PY' 2> /dev/null
import glob
import os

names = []
for event in sorted(glob.glob('/sys/class/input/event*')):
    base = os.path.join(event, 'device')
    try:
        name = open(os.path.join(base, 'name')).read().strip()
        words = open(os.path.join(base, 'capabilities', 'key')).read().split()
    except OSError:
        continue
    keys = 0
    for word in words:
        keys = (keys << 64) | int(word, 16)
    if all((keys >> bit) & 1 for bit in range(1, 32)) and not keys & 1:
        names.append('%s (%s)' % (name, event))
print('input_keyboards=' + ';'.join(names))
PY
else
    printf 'input_keyboards=%s\n' ""
fi

printf 'user=%s\n' "$(id -un 2> /dev/null)"
printf 'groups=%s\n' "$(id -nG 2> /dev/null | tr ' ' ';')"

# State of the jukebox service: the installer's reader registration exits
# without configuring anything while it is active
service=unknown
if command -v systemctl > /dev/null 2>&1; then
    service="$(XDG_RUNTIME_DIR="/run/user/$(id -u)" systemctl --user is-active jukebox-daemon 2> /dev/null || true)"
fi
[ -n "$service" ] || service=unknown
printf 'service=%s\n' "$service"

# Settings that the reader's own setup applies on the Pi
udev_nfc=missing
if [ -f /etc/udev/rules.d/50-usb-nfc-rule.rules ]; then
    udev_nfc=present
fi
printf 'udev_nfc=%s\n' "$udev_nfc"
printf 'udev_nfc_ids=%s\n' "$(sed -n 's/.*ATTRS{idVendor}=="\([0-9a-fA-F]\{4\}\)".*ATTRS{idProduct}=="\([0-9a-fA-F]\{4\}\)".*/\1:\2/p' /etc/udev/rules.d/50-usb-nfc-rule.rules 2> /dev/null | paste -sd';' -)"

nfcpy_blacklist=missing
if [ -f /etc/modprobe.d/disable_driver_jukebox_nfcpy.conf ]; then
    nfcpy_blacklist=present
fi
printf 'nfcpy_blacklist=%s\n' "$nfcpy_blacklist"
printf 'kernel_nfc_modules=%s\n' "$(lsmod 2> /dev/null | awk '/^(pn533_usb|port100|nfc) / { print $1 }' | paste -sd';' -)"

install_dir="$HOME/RPi-Jukebox-RFID"
if [ -d "$install_dir" ]; then
    printf 'installation=present\n'
else
    printf 'installation=missing\n'
fi

venv="$install_dir/.venv/bin/python"
if [ -x "$venv" ]; then
    printf 'venv=present\n'
    "$venv" - <<'PY' 2> /dev/null
try:
    import nfc.clf.device as device
    print('nfcpy=present')
    print('nfcpy_ids=' + ';'.join('%04x:%04x' % key for key in device.usb_device_map))
except Exception:
    pass
try:
    import importlib.util
    states = []
    for name in ('nfc', 'evdev', 'pirc522', 'py532lib', 'mfrc522_i2c', 'serial'):
        try:
            present = importlib.util.find_spec(name) is not None
        except Exception:
            present = False
        states.append('%s:%s' % (name, 'present' if present else 'missing'))
    print('reader_pkg=' + ';'.join(states))
except Exception:
    pass
PY
else
    printf 'venv=missing\n'
fi

rfid_yaml="$install_dir/shared/settings/rfid.yaml"
if [ -f "$rfid_yaml" ]; then
    printf 'rfid_yaml=present\n'
    printf 'rfid_modules=%s\n' "$(grep -E '^[[:space:]]*module:[[:space:]]*' "$rfid_yaml" 2> /dev/null | sed -e 's/.*module:[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^"//' -e 's/"$//' | paste -sd';' -)"
    printf 'rfid_config=%s\n' "$(grep -E '^[[:space:]]+(device_path|device_name|device_phys|spi_bus|spi_ce|pin_irq|pin_rst|i2c_bus|i2c_address):' "$rfid_yaml" 2> /dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | paste -sd';' -)"
else
    printf 'rfid_yaml=missing\n'
fi

exit 0
REMOTE_SNIPPET_EOF
}

rfid_check_prepare() {
    RFID_CHECK_WARNINGS=0
    RFID_CHECK_SUGGESTIONS=""
    RFID_CHECK_STATUS=""
    RFID_CHECK_HINTED=""
    RFID_CHECK_PROBE_OK="yes"
    RFID_CHECK_REPORT=""
}

rfid_check_hardware() {
    RFID_CHECK_REPORT="$(run_remote "$(rfid_probe_remote_snippet)")" || true
    if [ -z "$RFID_CHECK_REPORT" ]; then
        RFID_CHECK_PROBE_OK="no"
        rfid_warn "The RFID reader state could not be read from the Pi."
        rfid_note "the reader check is skipped; the installation itself is not affected"
        rfid_status "not checked (no data from the Pi)"
    fi
    return 0
}

# Hardware that the report holds, as one line for the 'detected' field.
rfid_detected_summary() {
    local parts="" nfc keyboards i2c spi serial usb
    nfc="$(rfid_usb_nfc_ids)"
    usb="$(rfid_report_value "$RFID_CHECK_REPORT" usb_list)"
    keyboards="$(rfid_report_value "$RFID_CHECK_REPORT" input_keyboards)"
    i2c="$(rfid_report_value "$RFID_CHECK_REPORT" i2c_devices)"
    spi="$(rfid_report_value "$RFID_CHECK_REPORT" spi_devices)"
    serial="$(rfid_report_value "$RFID_CHECK_REPORT" serial_devices)"

    [ -n "$nfc" ] && parts="${parts:+$parts, }NFC reader on USB ($(printf '%s' "$nfc" | tr ';' ' '))"
    # Without the nfcpy list (before the installation) the USB devices are
    # reported as they are, the assignment to a reader stays open.
    if [ -z "$nfc" ] && [ -n "$usb" ]; then
        parts="${parts:+$parts, }USB device(s) $(rfid_usb_text)"
    fi
    [ -n "$keyboards" ] && parts="${parts:+$parts, }keyboard-like input device ($(printf '%s' "$keyboards" | tr ';' ' '))"
    [ -n "$i2c" ] && parts="${parts:+$parts, }I2C bus $(printf '%s' "$i2c" | tr ';' ' ')"
    [ -n "$spi" ] && parts="${parts:+$parts, }SPI device $(printf '%s' "$spi" | tr ';' ' ')"
    [ -n "$serial" ] && parts="${parts:+$parts, }serial port $(printf '%s' "$serial" | tr ';' ' ')"
    [ -z "$parts" ] && parts="no reader-relevant device found"
    printf '%s' "$parts"
}

# True when the interface is enabled in the boot configuration and becomes
# active with the next reboot.
rfid_interface_enabled() {
    local boot_params
    boot_params="$(rfid_report_value "$RFID_CHECK_REPORT" boot_params)"
    case "$boot_params" in
        *"$1"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Group membership the reader support needs on the Pi (plugdev for USB devices,
# dialout for serial ports). Both are configured by the reader's own setup.
rfid_check_reader_group() {
    local group="$1" groups user
    groups="$(rfid_report_value "$RFID_CHECK_REPORT" groups)"
    user="$(rfid_report_value "$RFID_CHECK_REPORT" user)"
    rfid_list_contains "$groups" "$group" && return 0

    if [ "$RFID_CHECK_DEPS" = "no" ]; then
        rfid_warn "The user '$user' is not in the group '$group', and RFID_READER_DEPS=no skips the reader's system setup."
        rfid_note "Add it on the Pi: sudo usermod -aG $group $user"
    elif [ "$RFID_CHECK_STAGE" = "post" ]; then
        rfid_warn "The user '$user' is not in the group '$group' although the reader setup ran."
        rfid_note "Add it on the Pi: sudo usermod -aG $group $user (then log in again)"
    else
        rfid_note "the group '$group' is added by the reader setup during the installation"
    fi
    return 0
}

# Points at a detected USB reader when the configured reader is not confirmed.
rfid_hint_usb_alternatives() {
    local module="$1" keyboards nfc_ids
    [ "$RFID_CHECK_HINTED" = "yes" ] && return 0
    keyboards="$(rfid_report_value "$RFID_CHECK_REPORT" input_keyboards)"
    nfc_ids="$(rfid_usb_nfc_ids)"

    if [ "$module" != "generic_usb" ] && [ -n "$keyboards" ]; then
        RFID_CHECK_HINTED="yes"
        rfid_note "A keyboard-like input device is connected: $(printf '%s' "$keyboards" | tr ';' ' ')"
        rfid_note "If that is the reader, set RFID_READER_MODULE=generic_usb."
        rfid_suggest "RFID_READER_MODULE=generic_usb"
    fi
    if [ "$module" != "generic_nfcpy" ] && [ -n "$nfc_ids" ]; then
        RFID_CHECK_HINTED="yes"
        rfid_note "An NFC reader supported by nfcpy is connected: $(printf '%s' "$nfc_ids" | tr ';' ' ')"
        rfid_note "If that is the reader, set RFID_READER_MODULE=generic_nfcpy."
        rfid_suggest "RFID_READER_MODULE=generic_nfcpy"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Reader checks: one function per interface class
# -----------------------------------------------------------------------------
rfid_check_usb_nfc() {
    local module="$1" params="$2"
    local device_path usb_ids nfc_ids node name

    device_path="$(rfid_param_value "$params" device_path)"
    usb_ids="$(rfid_report_value "$RFID_CHECK_REPORT" usb_ids)"
    nfc_ids="$(rfid_usb_nfc_ids)"

    if [ -n "$device_path" ]; then
        rfid_line "expected" "device_path=$device_path"
        case "$device_path" in
            usb:*)
                name="${device_path#usb:}"
                if rfid_list_contains "$usb_ids" "$name"; then
                    rfid_check_reader_group "plugdev"
                    rfid_line "result" "confirmed - device usb:$name is connected"
                    rfid_status "confirmed ($module)"
                else
                    rfid_warn "No USB device with the ID '$name' is connected to the Pi."
                    rfid_note "USB devices found: $(rfid_usb_text)"
                    rfid_note "Check the reader and the USB connection, or correct RFID_READER_PARAMS"
                    rfid_note "in ${RFID_CHECK_CONFIG_FILE}."
                    rfid_hint_usb_alternatives "$module"
                    rfid_status "NOT CONFIRMED (device $name missing)"
                fi
                ;;
            *)
                node="${device_path%%:*}"
                name="${node##*/}"
                if rfid_list_contains "$(rfid_report_value "$RFID_CHECK_REPORT" serial_devices)" "$name" \
                    || rfid_list_contains "$usb_ids" "$name"; then
                    rfid_check_reader_group "dialout"
                    rfid_line "result" "confirmed - device node $node is present"
                    rfid_status "confirmed ($module)"
                else
                    rfid_warn "The configured device node '$node' does not exist on the Pi."
                    rfid_note "Serial ports found: $(rfid_report_value "$RFID_CHECK_REPORT" serial_devices)"
                    rfid_note "Check the reader and its connection, or correct RFID_READER_PARAMS"
                    rfid_note "in ${RFID_CHECK_CONFIG_FILE}."
                    rfid_hint_usb_alternatives "$module"
                    rfid_status "NOT CONFIRMED (device node $node missing)"
                fi
                ;;
        esac
        return 0
    fi

    if [ "$(rfid_report_value "$RFID_CHECK_REPORT" nfcpy)" = "present" ]; then
        # The application is installed, so nfcpy's own device list decides.
        if [ -n "$nfc_ids" ]; then
            rfid_check_reader_group "plugdev"
            if [ "$(rfid_list_count "$nfc_ids")" -gt 1 ]; then
                rfid_warn "Several NFC readers are connected: $(printf '%s' "$nfc_ids" | tr ';' ' ')"
                rfid_note "Without RFID_READER_PARAMS the reader setup cannot pick one."
                rfid_note "Select the reader with RFID_READER_PARAMS=\"device_path=usb:<id>\"."
                rfid_suggest "RFID_READER_PARAMS=\"device_path=usb:$(printf '%s' "$nfc_ids" | cut -d';' -f1)\""
                rfid_status "NOT CONFIRMED (several NFC readers)"
            else
                rfid_line "result" "confirmed - nfcpy detects usb:$(printf '%s' "$nfc_ids" | tr ';' ' ')"
                rfid_status "confirmed ($module)"
            fi
        else
            rfid_warn "No NFC reader supported by nfcpy is connected to the Pi."
            rfid_note "USB devices found: $(rfid_usb_text)"
            rfid_hint_usb_alternatives "$module"
            rfid_status "NOT CONFIRMED (no NFC reader on USB)"
        fi
    elif [ "$(rfid_report_value "$RFID_CHECK_REPORT" venv)" = "present" ]; then
        # The application is installed, but its reader support is not
        rfid_note "nfcpy is not available in the venv on the Pi, so its device list cannot be read"
        rfid_note "install the reader dependencies with RFID_READER_DEPS=auto"
        rfid_note "USB devices found: $(rfid_usb_text)"
        rfid_status "not verifiable (nfcpy missing)"
    else
        # Before the installation there is no nfcpy on the Pi, so only the
        # presence of USB devices can be judged.
        if [ -z "$usb_ids" ]; then
            rfid_warn "No USB device is connected to the Pi."
            rfid_note "Connect the reader before the installation, or correct"
            rfid_note "RFID_READER_MODULE in ${RFID_CHECK_CONFIG_FILE}."
            rfid_status "NOT CONFIRMED (no USB device)"
        else
            rfid_note "without RFID_READER_PARAMS the reader setup picks a uniquely"
            rfid_note "connected NFC device automatically"
            rfid_note "USB devices found: $(rfid_usb_text)"
            rfid_status "not verifiable before the installation"
        fi
    fi
    return 0
}

rfid_check_usb_hid() {
    local module="$1" params="$2"
    local device_name keyboards count

    device_name="$(rfid_param_value "$params" device_name)"
    keyboards="$(rfid_report_value "$RFID_CHECK_REPORT" input_keyboards)"
    count="$(rfid_list_count "$keyboards")"

    if [ -n "$device_name" ]; then
        rfid_line "expected" "device_name=$device_name"
        if [ "$count" -gt 0 ] && printf '%s' "$keyboards" | tr ';' '\n' | grep -qiF "$device_name"; then
            rfid_line "result" "confirmed - device '$device_name' is connected"
            rfid_status "confirmed ($module)"
        else
            rfid_warn "No keyboard-like input device named '$device_name' is connected to the Pi."
            rfid_note "Input devices found: ${keyboards:-none}"
            rfid_note "Check the reader and the USB connection, or correct RFID_READER_PARAMS"
            rfid_note "in ${RFID_CHECK_CONFIG_FILE}."
            rfid_hint_usb_alternatives "$module"
            rfid_status "NOT CONFIRMED (device_name $device_name missing)"
        fi
        return 0
    fi

    case "$count" in
        0)
            rfid_warn "No keyboard-like input device is connected to the Pi."
            rfid_note "The USB reader support needs a device that reports the full key range."
            rfid_note "Check the reader and the USB connection, or set RFID_READER_PARAMS"
            rfid_note "(device_name=...) in ${RFID_CHECK_CONFIG_FILE}."
            rfid_hint_usb_alternatives "$module"
            rfid_status "NOT CONFIRMED (no keyboard-like device)"
            ;;
        1)
            rfid_line "result" "confirmed - device $(printf '%s' "$keyboards" | tr ';' ' ') is connected"
            rfid_status "confirmed ($module)"
            ;;
        *)
            rfid_warn "Several keyboard-like input devices are connected: $(printf '%s' "$keyboards" | tr ';' ' ')"
            rfid_note "Without RFID_READER_PARAMS the reader setup cannot pick one."
            rfid_note "Select the reader with RFID_READER_PARAMS=\"device_name=<name>\"."
            rfid_status "NOT CONFIRMED (several keyboard-like devices)"
            ;;
    esac
    return 0
}

rfid_check_i2c() {
    local module="$1"
    local i2c_devices i2c_scan address found

    i2c_devices="$(rfid_report_value "$RFID_CHECK_REPORT" i2c_devices)"
    address="$(rfid_module_i2c_address "$module")"

    if [ -z "$i2c_devices" ]; then
        if rfid_interface_enabled "dtparam=i2c"; then
            rfid_line "interface" "I2C enabled in $(rfid_report_value "$RFID_CHECK_REPORT" boot_config), active after the next reboot"
            rfid_status "I2C active after the reboot ($module)"
        elif [ "$RFID_CHECK_DEPS" = "no" ]; then
            rfid_warn "The I2C interface is not enabled, and RFID_READER_DEPS=no skips the enabling."
            rfid_note "Enable it on the Pi with 'sudo raspi-config nonint do_i2c 0' (then reboot)."
            rfid_status "NOT CONFIRMED (I2C disabled)"
        elif [ "$RFID_CHECK_STAGE" = "post" ]; then
            rfid_warn "The I2C interface is still not enabled after the installation."
            rfid_note "Check the installation log on the Pi for the reader setup, or enable it with"
            rfid_note "'sudo raspi-config nonint do_i2c 0'."
            rfid_hint_usb_alternatives "$module"
            rfid_status "NOT CONFIRMED (I2C disabled)"
        else
            rfid_line "interface" "I2C not enabled yet"
            rfid_note "the reader setup enables I2C during the installation; a reboot is required"
            rfid_status "I2C is enabled during the installation ($module)"
        fi
        return 0
    fi

    rfid_line "interface" "I2C bus ready ($(printf '%s' "$i2c_devices" | tr ';' ' '))"
    if [ -z "$address" ]; then
        rfid_status "I2C ready ($module)"
        return 0
    fi

    i2c_scan="$(rfid_report_value "$RFID_CHECK_REPORT" i2c_scan)"
    if [ -z "$i2c_scan" ]; then
        rfid_note "install i2c-tools on the Pi (sudo apt install i2c-tools) to look for the"
        rfid_note "reader at address 0x$address"
        rfid_status "I2C ready, reader not verifiable ($module)"
        return 0
    fi

    found="$(printf '%s' "$i2c_scan" | tr ';' '\n' | sed 's/^[^:]*://' | tr ',' '\n' | grep -i -x "$address" | head -n 1)"
    if [ -n "$found" ]; then
        rfid_line "result" "confirmed - device at address 0x$address"
        rfid_status "confirmed ($module)"
    else
        rfid_warn "No device answers at address 0x$address on the I2C bus ($(printf '%s' "$i2c_scan" | tr ';' ' '))."
        rfid_note "Check the wiring and the address, or correct RFID_READER_PARAMS"
        rfid_note "(i2c_address=...) in ${RFID_CHECK_CONFIG_FILE}."
        rfid_hint_usb_alternatives "$module"
        rfid_status "NOT CONFIRMED (no device at 0x$address)"
    fi
    return 0
}

rfid_check_spi() {
    local module="$1" spi_devices

    spi_devices="$(rfid_report_value "$RFID_CHECK_REPORT" spi_devices)"
    if [ -n "$spi_devices" ]; then
        rfid_line "interface" "SPI ready ($(printf '%s' "$spi_devices" | tr ';' ' '))"
        rfid_note "the reader itself is not detectable; its pins come from the configuration"
        rfid_status "SPI ready ($module)"
    elif rfid_interface_enabled "dtparam=spi=on"; then
        rfid_line "interface" "SPI enabled in $(rfid_report_value "$RFID_CHECK_REPORT" boot_config), active after the next reboot"
        rfid_status "SPI active after the reboot ($module)"
    elif [ "$RFID_CHECK_DEPS" = "no" ]; then
        rfid_warn "The SPI interface is not enabled, and RFID_READER_DEPS=no skips the enabling."
        rfid_note "Enable it on the Pi with 'sudo raspi-config nonint do_spi 0' (then reboot)."
        rfid_hint_usb_alternatives "$module"
        rfid_status "NOT CONFIRMED (SPI disabled)"
    elif [ "$RFID_CHECK_STAGE" = "post" ]; then
        rfid_warn "The SPI interface is still not enabled after the installation."
        rfid_note "Check the installation log on the Pi for the reader setup, or enable it with"
        rfid_note "'sudo raspi-config nonint do_spi 0'."
        rfid_hint_usb_alternatives "$module"
        rfid_status "NOT CONFIRMED (SPI disabled)"
    else
        rfid_line "interface" "SPI not enabled yet"
        rfid_note "the reader setup enables SPI during the installation; a reboot is required"
        rfid_status "SPI is enabled during the installation ($module)"
    fi
    return 0
}

rfid_check_serial() {
    local module="$1" serial_devices

    serial_devices="$(rfid_report_value "$RFID_CHECK_REPORT" serial_devices)"
    if [ -n "$serial_devices" ]; then
        rfid_line "interface" "serial port ready ($(printf '%s' "$serial_devices" | tr ';' ' '))"
        rfid_check_reader_group "dialout"
        rfid_note "the reader sends its data continuously; its card data is not part of this check"
        rfid_status "serial port ready ($module)"
    elif rfid_interface_enabled "enable_uart=1"; then
        rfid_line "interface" "serial hardware enabled in $(rfid_report_value "$RFID_CHECK_REPORT" boot_config), active after the next reboot"
        rfid_status "serial port active after the reboot ($module)"
    elif [ "$RFID_CHECK_DEPS" = "no" ]; then
        rfid_warn "No serial port is available, and RFID_READER_DEPS=no skips enabling it."
        rfid_note "Enable the serial hardware on the Pi with"
        rfid_note "'sudo raspi-config nonint do_serial_hw 1' (then reboot)."
        rfid_hint_usb_alternatives "$module"
        rfid_status "NOT CONFIRMED (no serial port)"
    elif [ "$RFID_CHECK_STAGE" = "post" ]; then
        rfid_warn "No serial port is available although the reader setup ran."
        rfid_note "Check the installation log on the Pi for the reader setup, or enable the"
        rfid_note "serial hardware with 'sudo raspi-config nonint do_serial_hw 1'."
        rfid_hint_usb_alternatives "$module"
        rfid_status "NOT CONFIRMED (no serial port)"
    else
        rfid_line "interface" "serial port not available yet"
        rfid_note "the reader setup enables the serial hardware during the installation"
        rfid_status "serial port enabled during the installation ($module)"
    fi
    return 0
}

# State of one Python package in the venv of the Pi.
rfid_package_state() {
    local entry
    while IFS= read -r entry; do
        case "$entry" in
            "$1:present") printf 'present'; return 0 ;;
            "$1:missing") printf 'missing'; return 0 ;;
        esac
    done < <(printf '%s\n' "$(rfid_report_value "$RFID_CHECK_REPORT" reader_pkg)" | tr ';' '\n')
    printf 'unknown'
}

# Packages and settings the reader needs at runtime: its Python support in the
# venv and the settings that the reader's own setup applies on the Pi.
rfid_check_reader_prerequisites() {
    local module="$1" package label state

    package="$(rfid_module_package "$module")"
    [ -n "$package" ] || return 0
    label="$(rfid_module_package_label "$module")"

    if [ "$(rfid_report_value "$RFID_CHECK_REPORT" venv)" != "present" ]; then
        rfid_note "the application is not installed on the Pi yet, so its reader support is installed by the installation"
        return 0
    fi

    state="$(rfid_package_state "$package")"
    if [ "$state" = "present" ]; then
        rfid_line "support" "$label is installed in the venv"
    elif [ "$state" = "unknown" ]; then
        rfid_note "the venv on the Pi did not report its reader support; $label cannot be checked"
    elif [ "$RFID_CHECK_DEPS" = "no" ]; then
        rfid_warn "The reader support $label is not installed in the venv, and RFID_READER_DEPS=no skips its installation."
        rfid_note "Set RFID_READER_DEPS=auto in $RFID_CHECK_CONFIG_FILE, or install the reader's"
        rfid_note "requirements.txt in the venv on the Pi."
    elif [ "$RFID_CHECK_STAGE" = "post" ]; then
        rfid_warn "The reader support $label is missing in the venv although the installation ran."
        rfid_note "Install it on the Pi with the reader's requirements.txt:"
        rfid_note "~/RPi-Jukebox-RFID/.venv/bin/pip install -r ~/RPi-Jukebox-RFID/src/jukebox/components/rfid/hardware/$module/requirements.txt"
    else
        rfid_note "the reader support $label is installed by the installation (RFID_READER_DEPS=auto)"
    fi

    if [ "$module" = "generic_nfcpy" ]; then
        rfid_check_nfcpy_settings
    fi
    return 0
}

# Settings that the generic_nfcpy reader setup applies on the Pi: the udev rule
# that hands the reader to the group 'plugdev' and the kernel modules that would
# claim the reader otherwise.
rfid_check_nfcpy_settings() {
    local device_path reader_id udev_ids

    device_path="$(rfid_param_value "$RFID_CHECK_PARAMS" device_path)"
    case "$device_path" in
        usb:*) reader_id="${device_path#usb:}" ;;
        *) reader_id="" ;;
    esac

    if [ "$(rfid_report_value "$RFID_CHECK_REPORT" udev_nfc)" = "present" ]; then
        udev_ids="$(rfid_report_value "$RFID_CHECK_REPORT" udev_nfc_ids)"
        if [ -n "$reader_id" ] && ! rfid_list_contains "$udev_ids" "$reader_id"; then
            rfid_warn "The udev rule on the Pi does not cover the configured reader '$reader_id'."
            rfid_note "It covers: ${udev_ids:-nothing}. The rule hands the device to the group 'plugdev'."
        fi
    elif [ "$RFID_CHECK_STAGE" = "post" ] || [ "$RFID_CHECK_DEPS" = "no" ]; then
        rfid_warn "The udev rule for the USB NFC reader is missing on the Pi."
        rfid_note "Without /etc/udev/rules.d/50-usb-nfc-rule.rules the reader belongs to root"
        rfid_note "and the jukebox cannot open it."
    else
        rfid_note "the udev rule for the USB reader is created by the installation"
    fi

    case "$(rfid_report_value "$RFID_CHECK_REPORT" kernel_nfc_modules)" in
        *pn533_usb* | *port100*)
            if [ "$(rfid_report_value "$RFID_CHECK_REPORT" nfcpy_blacklist)" != "present" ]; then
                rfid_warn "The kernel module $(rfid_report_value "$RFID_CHECK_REPORT" kernel_nfc_modules) claims the USB NFC reader."
                rfid_note "The reader setup disables it; as long as it is loaded, nfcpy cannot open the reader."
            fi
            ;;
    esac
    return 0
}

# The installer's reader registration exits without configuring anything while
# the jukebox service of an existing installation is active.
rfid_check_service() {
    local service modules

    service="$(rfid_report_value "$RFID_CHECK_REPORT" service)"
    [ "$service" = "active" ] || return 0

    if [ "$RFID_CHECK_STAGE" = "pre" ]; then
        rfid_line "service" "the jukebox service of the existing installation is running"
        rfid_warn "The installer's reader registration exits without configuring anything while the jukebox service is active."
        rfid_note "The installation would finish without a reader configuration."
        rfid_note "Stop it before the installation: systemctl --user stop jukebox-daemon"
    elif [ -z "$(rfid_report_value "$RFID_CHECK_REPORT" rfid_modules)" ]; then
        # Only worth mentioning when the reader is missing as well
        rfid_line "service" "the jukebox service of the existing installation is running"
        rfid_note "the reader registration of the installer ran while the service was active and"
        rfid_note "therefore did not write a reader configuration"
    fi
    return 0
}

# Verdict for the reader that the setup configuration asks for.
rfid_check_configured_reader() {
    local module="$RFID_CHECK_MODULE"
    local params="$RFID_CHECK_PARAMS"
    local interface

    [ "$RFID_CHECK_PROBE_OK" = "yes" ] || return 0

    if [ "$RFID_CHECK_ENABLE" = "false" ]; then
        rfid_line "configured" "no RFID reader (ENABLE_RFID_READER=false in $RFID_CHECK_CONFIG_FILE)"
        rfid_line "detected" "$(rfid_detected_summary)"
        rfid_status "no reader configured"
        return 0
    fi

    if [ -z "$module" ]; then
        rfid_line "detected" "$(rfid_detected_summary)"
        rfid_check_service
        rfid_warn "RFID_READER_MODULE is not set in $RFID_CHECK_CONFIG_FILE although the reader setup is enabled."
        rfid_note "Set RFID_READER_MODULE to the module of the connected reader,"
        rfid_note "or disable the reader setup with ENABLE_RFID_READER=false."
        rfid_hint_usb_alternatives ""
        rfid_status "NOT CONFIRMED (no reader module configured)"
        return 0
    fi

    interface="$(rfid_module_interface "$module")"
    if [ -n "$params" ]; then
        rfid_line "configured" "$module (RFID_READER_PARAMS=\"$params\")"
    else
        rfid_line "configured" "$module (RFID_READER_PARAMS not set)"
    fi
    rfid_line "detected" "$(rfid_detected_summary)"
    rfid_check_service
    rfid_check_reader_prerequisites "$module"

    case "$interface" in
        usb-nfc) rfid_check_usb_nfc "$module" "$params" ;;
        usb-hid) rfid_check_usb_hid "$module" "$params" ;;
        i2c) rfid_check_i2c "$module" ;;
        spi) rfid_check_spi "$module" ;;
        serial) rfid_check_serial "$module" ;;
        simulator) rfid_line "result" "not applicable (simulator, no hardware required)" ;;
        *)
            rfid_warn "Unknown reader module '$module'; no hardware check possible."
            rfid_status "not verifiable (unknown module)"
            ;;
    esac
    return 0
}

# Compares the reader configuration that the installation wrote on the Pi with
# the configuration of this setup and with the connected hardware.
rfid_check_installed_configuration() {
    local modules config entry key value expected installed pair

    [ "$RFID_CHECK_PROBE_OK" = "yes" ] || return 0

    if [ "$RFID_CHECK_ENABLE" = "false" ]; then
        return 0
    fi

    if [ "$(rfid_report_value "$RFID_CHECK_REPORT" rfid_yaml)" != "present" ]; then
        rfid_warn "No reader configuration was written: ~/RPi-Jukebox-RFID/shared/settings/rfid.yaml is missing."
        rfid_note "Check the installation log on the Pi for the reader setup."
        rfid_status "NOT CONFIRMED (no reader configuration written)"
        return 0
    fi

    modules="$(rfid_report_value "$RFID_CHECK_REPORT" rfid_modules)"
    config="$(rfid_report_value "$RFID_CHECK_REPORT" rfid_config)"
    rfid_line "installed" "${modules:-none} (shared/settings/rfid.yaml)"

    if [ -n "$RFID_CHECK_MODULE" ] && ! rfid_list_contains "$modules" "$RFID_CHECK_MODULE"; then
        if [ -z "$modules" ]; then
            rfid_warn "The installation wrote no reader configuration, while the setup asks for '$RFID_CHECK_MODULE'."
        else
            rfid_warn "The installation configured '$modules' while the setup asks for '$RFID_CHECK_MODULE'."
        fi
        rfid_note "Correct RFID_READER_MODULE in $RFID_CHECK_CONFIG_FILE, or install the reader again."
        rfid_hint_usb_alternatives "$RFID_CHECK_MODULE"
    fi

    # Values that the reader setup determined have to match the hardware.
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        key="${entry%%:*}"
        value="${entry#*:}"
        value="$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        case "$key" in
            device_path)
                case "$value" in
                    usb:*)
                        installed="${value#usb:}"
                        if ! rfid_list_contains "$(rfid_report_value "$RFID_CHECK_REPORT" usb_ids)" "$installed"; then
                            rfid_warn "The installed configuration uses the NFC device 'usb:$installed', which is not connected to the Pi."
                            rfid_note "USB devices found: $(rfid_usb_text)"
                            rfid_note "Connect the reader, or correct RFID_READER_PARAMS in $RFID_CHECK_CONFIG_FILE."
                        fi
                        ;;
                    *)
                        installed="${value%%:*}"
                        installed="${installed##*/}"
                        if ! rfid_list_contains "$(rfid_report_value "$RFID_CHECK_REPORT" serial_devices)" "$installed" \
                            && ! rfid_list_contains "$(rfid_report_value "$RFID_CHECK_REPORT" usb_ids)" "$installed"; then
                            rfid_warn "The installed configuration uses the device node '$value', which is not present on the Pi."
                        fi
                        ;;
                esac
                ;;
            device_name)
                if ! printf '%s' "$(rfid_report_value "$RFID_CHECK_REPORT" input_keyboards)" | tr ';' '\n' | grep -qiF "$value"; then
                    rfid_warn "The installed configuration uses the USB device '$value', which is not connected to the Pi."
                    rfid_note "Input devices found: $(rfid_report_value "$RFID_CHECK_REPORT" input_keyboards)"
                    rfid_note "Connect the reader, or correct RFID_READER_PARAMS in $RFID_CHECK_CONFIG_FILE."
                fi
                ;;
        esac
    done < <(printf '%s' "$config" | tr ';' '\n')

    # The reader parameters of the setup have to survive into the configuration.
    while IFS= read -r pair; do
        [ -n "$pair" ] || continue
        key="${pair%%=*}"
        expected="${pair#*=}"
        case "$key" in
            device_path | device_name | i2c_address | i2c_bus | spi_ce | pin_irq) ;;
            *) continue ;;
        esac
        installed="$(printf '%s' "$config" | tr ';' '\n' | sed -n "s/^$key:[[:space:]]*//p" | head -n 1)"
        if [ "$installed" != "$expected" ]; then
            rfid_warn "The installation wrote '$key: ${installed:-missing}' while the setup asks for '$key=$expected'."
            rfid_note "Check $key in RFID_READER_PARAMS of $RFID_CHECK_CONFIG_FILE."
        fi
    done < <(printf '%s' "$RFID_CHECK_PARAMS" | tr ';' '\n')
    return 0
}

# Warnings and the settings to change for the next run.
rfid_check_summary() {
    local suggestion
    if [ "$RFID_CHECK_WARNINGS" -eq 0 ]; then
        printf '    no deviation found between the configuration and the reader on the Pi\n'
        return 0
    fi

    RFID_CHECK_STATUS="${RFID_CHECK_STATUS:-unknown} - $RFID_CHECK_WARNINGS warning(s)"
    printf '    %s warning(s): the configuration and the reader on the Pi differ.\n' "$RFID_CHECK_WARNINGS"
    if [ -n "$RFID_CHECK_SUGGESTIONS" ]; then
        printf '\n    Settings for the next run in %s:\n' "$RFID_CHECK_CONFIG_FILE"
        while IFS= read -r suggestion; do
            [ -n "$suggestion" ] && printf '        %s\n' "$suggestion"
        done < <(printf '%s\n' "$RFID_CHECK_SUGGESTIONS" | tr ';' '\n')
    fi
    return 0
}
