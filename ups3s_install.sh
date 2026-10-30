#!/bin/bash
# =============================================================================
# ups3s_install.sh
# -----------------------------------------------------------------------------
# Installs the monitor service for a Waveshare UPS Module 3S on a Raspberry Pi.
# The monitor script is uploaded to /tmp/ups3s_monitor.py by the setup script;
# this script installs it, writes the environment file and the systemd unit,
# enables the I2C interface and starts the service.
#
# Usage: sudo bash ups3s_install.sh <user> <bus> <address> <interval>
#
# The UPS module uses an INA219 at address 0x41 on the I2C bus. It does not use
# any Raspberry Pi GPIO line, so it does not conflict with the PowerBlock
# (GPIO 17/18) or with the MCP23017 overlay.
# =============================================================================
set -eu

USER_NAME="${1:-}"
BUS="${2:-1}"
ADDRESS="${3:-0x41}"
INTERVAL="${4:-10}"

MONITOR_SOURCE=/tmp/ups3s_monitor.py
MONITOR_TARGET=/usr/local/bin/ups3s_monitor.py
CONFIG_FILE=/etc/ups3s-monitor.conf
UNIT_FILE=/etc/systemd/system/ups3s-monitor.service

if [ -z "$USER_NAME" ] || ! id "$USER_NAME" > /dev/null 2>&1; then
    echo "ERROR: user '$USER_NAME' does not exist." >&2
    exit 1
fi
if ! [[ "$BUS" =~ ^[0-6]$ ]]; then
    echo "ERROR: bus must be a number between 0 and 6." >&2
    exit 1
fi
if ! [[ "$ADDRESS" =~ ^0[xX][0-9a-fA-F]{1,2}$ ]]; then
    echo "ERROR: address must be given as a hexadecimal value, e.g. 0x41." >&2
    exit 1
fi
ADDRESS_VALUE=$(( 16#${ADDRESS:2} ))
if [ "$ADDRESS_VALUE" -lt 64 ] || [ "$ADDRESS_VALUE" -gt 79 ]; then
    echo "ERROR: address must be between 0x40 and 0x4F." >&2
    exit 1
fi
ADDRESS="$(printf '0x%02x' "$ADDRESS_VALUE")"
if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || [ "$INTERVAL" -lt 1 ]; then
    echo "ERROR: interval must be a positive number of seconds." >&2
    exit 1
fi
if [ ! -f "$MONITOR_SOURCE" ]; then
    echo "ERROR: monitor script not found: $MONITOR_SOURCE" >&2
    exit 1
fi

# --- I2C boot configuration ---------------------------------------------------
# An explicit dtparam keeps the bus enabled for i2c-tools and the monitor. The
# MCP23017 installer writes the same line when the expander is enabled; this
# script only adds it when it is missing.
BOOT_CONFIG="${UPS3S_BOOT_CONFIG:-}"
if [ -z "$BOOT_CONFIG" ]; then
    BOOT_CONFIG=/boot/firmware/config.txt
    if [ ! -f "$BOOT_CONFIG" ]; then
        BOOT_CONFIG=/boot/config.txt
    fi
fi
if [ ! -f "$BOOT_CONFIG" ]; then
    echo "ERROR: boot configuration not found (tried /boot/firmware/config.txt and /boot/config.txt)." >&2
    exit 1
fi

BACKUP="${BOOT_CONFIG}.ups3s.bak"
if [ ! -f "$BACKUP" ]; then
    cp -a "$BOOT_CONFIG" "$BACKUP"
fi

if ! grep -qE '^[[:space:]]*dtparam=i2c_arm=on([[:space:]]|$)' "$BOOT_CONFIG"; then
    # Appending to a file without a final newline would join the new line with
    # the last one.
    if [ -n "$(tail -c 1 "$BOOT_CONFIG")" ]; then
        printf '\n' >> "$BOOT_CONFIG"
    fi
    LAST_SECTION="$(grep -E '^\[[^]]+\][[:space:]]*$' "$BOOT_CONFIG" | tail -n 1 | tr -d '[:space:]')"
    if [ "$LAST_SECTION" != "[all]" ]; then
        printf '\n[all]\n' >> "$BOOT_CONFIG"
    fi
    printf 'dtparam=i2c_arm=on\n' >> "$BOOT_CONFIG"
fi

# The service runs as the SSH user and needs access to /dev/i2c-<bus>.
if ! getent group i2c > /dev/null 2>&1; then
    groupadd -r i2c
fi
usermod -aG i2c "$USER_NAME" > /dev/null 2>&1 || true

# i2c-dev provides /dev/i2c-* for the monitor and i2c-tools.
if [ -d /etc/modules-load.d ]; then
    printf 'i2c-dev\n' > /etc/modules-load.d/i2c-dev.conf
else
    grep -qE '^[[:space:]]*i2c-dev([[:space:]]|$)' /etc/modules 2> /dev/null \
        || printf 'i2c-dev\n' >> /etc/modules
fi
if command -v modprobe > /dev/null 2>&1; then
    modprobe i2c-dev > /dev/null 2>&1 || true
elif [ -x /usr/sbin/modprobe ]; then
    /usr/sbin/modprobe i2c-dev > /dev/null 2>&1 || true
fi

if [ ! -e "/dev/i2c-${BUS}" ]; then
    if command -v dtparam > /dev/null 2>&1; then
        dtparam i2c_arm=on > /dev/null 2>&1 || true
    fi
fi

# The userspace monitor needs exclusive access to the INA219. Refuse to
# install when a kernel driver already owns the address.
I2C_DEVICE="/sys/bus/i2c/devices/${BUS}-$(printf '%04x' "$ADDRESS_VALUE")"
if [ -L "${I2C_DEVICE}/driver" ]; then
    echo "ERROR: a kernel driver is bound to ${ADDRESS} on bus ${BUS}." >&2
    echo "       The UPS monitor needs exclusive access to the INA219." >&2
    exit 1
fi

# --- Packages -----------------------------------------------------------------
NEED_PACKAGES=no
if ! command -v i2cdetect > /dev/null 2>&1 && [ ! -x /usr/sbin/i2cdetect ]; then
    NEED_PACKAGES=yes
fi
if ! /usr/bin/python3 -c 'import smbus2' > /dev/null 2>&1; then
    NEED_PACKAGES=yes
fi
if [ "$NEED_PACKAGES" = "yes" ]; then
    export DEBIAN_FRONTEND=noninteractive
    if ! apt-get install -y python3-smbus2 i2c-tools > /dev/null 2>&1; then
        apt-get update -qq > /dev/null 2>&1 || true
        apt-get install -y python3-smbus2 i2c-tools > /dev/null 2>&1 || true
    fi
fi
if ! /usr/bin/python3 -c 'import smbus2' > /dev/null 2>&1; then
    echo "ERROR: python3-smbus2 is not available. Install it with:" >&2
    echo "       sudo apt install python3-smbus2" >&2
    exit 1
fi

# --- Service ------------------------------------------------------------------
systemctl stop ups3s-monitor.service > /dev/null 2>&1 || true

install -m 0755 "$MONITOR_SOURCE" "$MONITOR_TARGET"
rm -f "$MONITOR_SOURCE"

cat > "$CONFIG_FILE" <<CONF
# Waveshare UPS Module 3S monitor (INA219).
# Changes take effect after: sudo systemctl restart ups3s-monitor
UPS3S_I2C_BUS=${BUS}
UPS3S_I2C_ADDRESS=${ADDRESS}
UPS3S_INTERVAL=${INTERVAL}
UPS3S_SHUNT_OHMS=0.01
UPS3S_MAX_CURRENT_A=5
UPS3S_CELLS=3
UPS3S_CHARGING_THRESHOLD_MA=50
UPS3S_DISCHARGING_THRESHOLD_MA=200
UPS3S_CURRENT_SIGN=1
UPS3S_STATUS_FILE=/run/ups3s/status.json
CONF
chmod 0644 "$CONFIG_FILE"

cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=Waveshare UPS Module 3S monitor
After=systemd-modules-load.service
Wants=systemd-modules-load.service

[Service]
Type=simple
User=${USER_NAME}
SupplementaryGroups=i2c
EnvironmentFile=${CONFIG_FILE}
ExecStart=/usr/bin/python3 ${MONITOR_TARGET}
Restart=on-failure
RestartSec=10
RuntimeDirectory=ups3s
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
UNIT
chmod 0644 "$UNIT_FILE"

systemctl daemon-reload
systemctl enable --now ups3s-monitor.service
# Give the first read (or the first error) time to reach the status file.
sleep 1

echo "service=ups3s-monitor"
echo "service_state=$(systemctl is-active ups3s-monitor.service 2> /dev/null || true)"
echo "config=${CONFIG_FILE}"
echo "status_file=/run/ups3s/status.json"
if command -v i2cdetect > /dev/null 2>&1 || [ -x /usr/sbin/i2cdetect ]; then
    echo "i2c_tools=yes"
else
    echo "i2c_tools=no"
fi
echo "smbus2=yes"
