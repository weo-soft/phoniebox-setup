#!/usr/bin/env bash
# =============================================================================
# setup-phoniebox.sh
# -----------------------------------------------------------------------------
# Non-interactive installation of RPi-Jukebox-RFID (Phoniebox future3) on a
# Raspberry Pi over SSH.
#
# The official installer (installation/install-jukebox.sh) supports a
# non-interactive mode: all options are passed via a flat KEY=VALUE config
# file (--config <file>). This script handles the complete flow:
#   1. Establish an SSH connection to the Pi (IP, user, password)
#   2. Run pre-flight checks on the Pi (OS, architecture, python3, wget, apt)
#   3. Verify the installation source (raw.githubusercontent.com)
#   4. Validate the MCP23017 settings (the application installer sets it up)
#   5. Configure the Waveshare UPS Module 3S (INA219) monitor when it is enabled
#   6. Stop the jukebox service of an existing installation (it makes the
#      installer skip the reader registration)
#   7. Check the configured RFID reader against the hardware on the Pi
#   8. Upload the application config to /tmp/install_config.env
#   9. Download install-jukebox.sh and run it non-interactively with --config
#  10. Check the reader configuration and the MCP23017
#  11. Enable the battery display in the application configuration and restart
#      the jukebox service so it loads the new settings
#  12. Check the UPS 3S, the running monitor and the battery display
#  13. optionally: reboot the Raspberry Pi (--reboot)
#
# Configuration is split into two files:
#   - .env               the script's OWN settings: SSH connection data
#                        (PI_HOST, SSH_USER, SSH_PASSWORD) and the optional
#                        GitHub source URL (SOURCE_URL). This file contains
#                        credentials and is NEVER uploaded to the Pi.
#   - phoniebox.config   the APPLICATION config: all installer options
#                        (GIT_USER, GIT_BRANCH, ENABLE_*, ...). Only this
#                        file is transferred to the installer on the Pi.
#
# Command line arguments override values from .env.
#
# Prerequisites on the machine that runs the installation:
#   - ssh (OpenSSH client)
#   - sshpass (only for password authentication)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CONFIG="${SCRIPT_DIR}/phoniebox.config"
DEFAULT_SETUP_CONFIG="${SCRIPT_DIR}/.env"

# Canonical reader names and the RFID reader check
RFID_HELPER="${SCRIPT_DIR}/rfid_reader.sh"
if [[ ! -f "$RFID_HELPER" ]]; then
    echo "ERROR: RFID reader helper not found: $RFID_HELPER" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$RFID_HELPER"

# MCP23017 settings and the expander check
MCP23017_HELPER="${SCRIPT_DIR}/mcp23017.sh"
if [[ ! -f "$MCP23017_HELPER" ]]; then
    echo "ERROR: MCP23017 helper not found: $MCP23017_HELPER" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$MCP23017_HELPER"

# Waveshare UPS Module 3S (INA219) settings, installer and check
UPS3S_HELPER="${SCRIPT_DIR}/ups3s.sh"
if [[ ! -f "$UPS3S_HELPER" ]]; then
    echo "ERROR: UPS 3S helper not found: $UPS3S_HELPER" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$UPS3S_HELPER"

# Reader settings of the effective configuration, filled by
# build_effective_config() and used by check_rfid_reader().
RFID_EFFECTIVE_ENABLE="true"
RFID_EFFECTIVE_MODULE=""
RFID_EFFECTIVE_PARAMS=""
RFID_EFFECTIVE_DEPS="auto"

CONFIG_FILE="$DEFAULT_CONFIG"
CONFIG_FILE_CLI=""
SETUP_CONFIG_FILE="$DEFAULT_SETUP_CONFIG"
SOURCE_URL_ARG=""
RFID_READER_ARG=""
DO_REBOOT="false"
VERIFY_HOST_KEY="false"
SHOW_LOG="false"

usage() {
    cat <<EOF
Usage: $(basename "$0") [<IP> <USER> <PASSWORD>] [options]

Installs RPi-Jukebox-RFID (Phoniebox future3) NON-INTERACTIVELY on a
Raspberry Pi over SSH. The installation options come from a flat KEY=VALUE
application config (default: phoniebox.config).

The script's own settings — the SSH connection (IP, user, password) and the
optional GitHub source URL — are read from .env (default) or can
be passed as arguments. The setup config is NEVER uploaded to the Pi; only
the application config is transferred to the installer.

Arguments (optional, override .env):
  <IP>        IP address or hostname of the Raspberry Pi
  <USER>      SSH username on the Pi
  <PASSWORD>  SSH password (leave empty if SSH keys are set up)

Options:
  --setup-config <file>  Script configuration (SSH connection, source URL)
                         (default: ${DEFAULT_SETUP_CONFIG})
  -s, --source <url>     GitHub URL with repository/branch used for the
                         installation (overrides SOURCE_URL from .env).
                         Accepted forms:
                           https://github.com/<user>/RPi-Jukebox-RFID/tree/<branch>
                           https://raw.githubusercontent.com/<user>/RPi-Jukebox-RFID/<branch>/installation/install-jukebox.sh
                         The branch may contain slashes; a leading
                         'refs/heads/' is removed.
  --rfid-reader <mod>    RFID reader module for the installation: technical
                         module name (e.g. pn532_i2c_py532) or canonical
                         display name (e.g. "PN532 reader via I2C using py532
                         library"). Overrides RFID_READER_MODULE from the config.
  -c, --config <file>    Application config file (default: ${DEFAULT_CONFIG})
  -r, --reboot           Reboot the Raspberry Pi after a successful installation
  --verify-host-key      Verify the SSH host key against ~/.ssh/known_hosts
                         (accept-new: a new host is added automatically, a
                         CHANGED key aborts — fix: ssh-keygen -R <IP>).
                         Default: off (host key is not verified).
  --show-log             Show the detailed installation log
                         (~/INSTALL-<timestamp>.log) LIVE while the
                         installation runs — a parallel SSH session tails the
                         log file on the Pi until the installation finishes.
                         Default: off (only the installer's console output).
  -h, --help             Show this help

Examples:
  $(basename "$0")                            # everything from .env
  $(basename "$0") 192.168.1.50 pi            # password from .env
  $(basename "$0") 192.168.1.50 pi myPassword --reboot
  $(basename "$0") --source https://github.com/weo-soft/RPi-Jukebox-RFID/tree/future3/feature/installer-noninteractive-plugins

MCP23017: the I2C GPIO expander is installed by the application installer
when ENABLE_MCP23017=true in the application config. The keys are passed
through, so the installer enables I2C, adds the device-tree overlay "mcp23017"
(default address 0x20 on I2C bus 1) and creates the application settings. The
PowerBlock uses GPIO 17/18 and has no I2C address, so both boards can share the
40-pin header.

UPS 3S: the Waveshare module's INA219 is read by a monitor service when
ENABLE_UPS3S=true (address 0x41 on I2C bus 1). It also uses only the I2C bus,
not a free GPIO line. The service writes /run/ups3s/status.json; the setup
enables the battery plugin of the application on that file, so the Web App
shows the charge level and the application evaluates the thresholds.

Security: keep .env private (chmod 600). Prefer storing the
password there instead of passing it on the command line.

Prerequisites on this machine: ssh, sshpass (only for password auth)
EOF
}

# --- Parse command line arguments ---------------------------------------------
POSITIONAL=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --setup-config)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --setup-config requires a file name." >&2
                exit 2
            fi
            SETUP_CONFIG_FILE="$2"
            shift 2
            ;;
        -s|--source)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --source requires a GitHub URL." >&2
                exit 2
            fi
            SOURCE_URL_ARG="$2"
            shift 2
            ;;
        --rfid-reader)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --rfid-reader requires a value." >&2
                exit 2
            fi
            RFID_READER_ARG="$2"
            shift 2
            ;;
        -c|--config)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --config requires a file name." >&2
                exit 2
            fi
            CONFIG_FILE="$2"
            CONFIG_FILE_CLI="$2"
            shift 2
            ;;
        -r|--reboot)
            DO_REBOOT="true"
            shift
            ;;
        --verify-host-key)
            VERIFY_HOST_KEY="true"
            shift
            ;;
        --show-log)
            SHOW_LOG="true"
            shift
            ;;
        -*)
            echo "ERROR: Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

# --- Read the script configuration (.env) -------------------------
# .env holds the script's own settings: SSH connection data and
# the optional source URL. It contains credentials and is NEVER uploaded to
# the Pi — only the application config is transferred. Command line
# arguments take precedence over values from this file.
get_value_from() {
    local file="$1" key="$2"
    local value=""
    if [[ -f "$file" ]]; then
        value="$(grep -E "^[[:space:]]*${key}=" "$file" \
            | tail -n 1 | cut -d= -f2- \
            | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
                  -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//")"
    fi
    printf '%s' "$value"
}

PI_HOST="$(get_value_from "$SETUP_CONFIG_FILE" PI_HOST)"
SETUP_SSH_USER="$(get_value_from "$SETUP_CONFIG_FILE" SSH_USER)"
SETUP_SSH_PASSWORD="$(get_value_from "$SETUP_CONFIG_FILE" SSH_PASSWORD)"
SETUP_SOURCE_URL="$(get_value_from "$SETUP_CONFIG_FILE" SOURCE_URL)"
SETUP_APP_CONFIG="$(get_value_from "$SETUP_CONFIG_FILE" APP_CONFIG)"
SETUP_REBOOT="$(get_value_from "$SETUP_CONFIG_FILE" REBOOT)"
SETUP_VERIFY_HOST_KEY="$(get_value_from "$SETUP_CONFIG_FILE" VERIFY_HOST_KEY)"
SETUP_SHOW_LOG="$(get_value_from "$SETUP_CONFIG_FILE" SHOW_LOG)"

# Resolve the SSH connection: command line arguments win over .env
IP="${PI_HOST:-}"
SSH_USER="${SETUP_SSH_USER:-}"
PASSWORD="${SETUP_SSH_PASSWORD:-}"
if [[ ${#POSITIONAL[@]} -ge 1 ]]; then IP="${POSITIONAL[0]}"; fi
if [[ ${#POSITIONAL[@]} -ge 2 ]]; then SSH_USER="${POSITIONAL[1]}"; fi
if [[ ${#POSITIONAL[@]} -ge 3 ]]; then PASSWORD="${POSITIONAL[2]}"; fi

# Application config path and reboot flag from .env (unless the
# command line already set them)
if [[ -z "$CONFIG_FILE_CLI" && -n "$SETUP_APP_CONFIG" ]]; then
    if [[ "$SETUP_APP_CONFIG" == /* ]]; then
        CONFIG_FILE="$SETUP_APP_CONFIG"
    else
        CONFIG_FILE="$(dirname "$SETUP_CONFIG_FILE")/$SETUP_APP_CONFIG"
    fi
fi
[[ "$SETUP_REBOOT" == "true" ]] && DO_REBOOT="true"
[[ "$SETUP_VERIFY_HOST_KEY" == "true" ]] && VERIFY_HOST_KEY="true"
[[ "$SETUP_SHOW_LOG" == "true" ]] && SHOW_LOG="true"

# --- Validate arguments -------------------------------------------------------
if [[ -z "$IP" || -z "$SSH_USER" ]]; then
    echo "ERROR: IP address and SSH user are required." >&2
    echo "Provide them as arguments or set PI_HOST/SSH_USER in $SETUP_CONFIG_FILE." >&2
    usage >&2
    exit 2
fi
if [[ "$IP" == *" "* ]]; then
    echo "ERROR: '$IP' is not a valid IP address/hostname." >&2
    exit 2
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Application config file not found: $CONFIG_FILE" >&2
    exit 1
fi

# --- Determine source (repository/branch) -------------------------------------
# Reads GIT_USER/GIT_BRANCH from the application config (defaults like the
# official installer: MiczFlor / future3/main). Alternatively the complete
# source can be given as a GitHub URL (--source <url> or SOURCE_URL in
# .env), e.g.:
#   https://github.com/weo-soft/RPi-Jukebox-RFID/tree/future3/feature/installer-noninteractive-plugins
# The URL is split into GIT_USER and GIT_BRANCH — this way both this script
# and the official installer on the Pi fetch the correct source.
# Priority: --source (CLI) > SOURCE_URL (.env) >
#           GIT_USER/GIT_BRANCH (application config)
get_config_value() {
    get_value_from "$CONFIG_FILE" "$1"
}

# Reduces a branch reference to its branch name. Addresses copied from a
# GitHub branch view carry the fully qualified ref ('refs/heads/<branch>'),
# while the installer on the Pi resolves the branch as 'refs/heads/<value>'
# and would look for 'refs/heads/refs/heads/<branch>'.
normalize_branch() {
    local branch="$1"

    while [[ "$branch" == "refs/heads/"* ]]; do
        branch="${branch#refs/heads/}"
    done
    branch="${branch#/}"
    branch="${branch%/}"

    printf '%s' "$branch"
}

# Splits a GitHub URL into GIT_USER and GIT_BRANCH. Accepted forms:
#   https://github.com/<user>/RPi-Jukebox-RFID/tree/<branch>
#   https://raw.githubusercontent.com/<user>/RPi-Jukebox-RFID/<branch>/installation/install-jukebox.sh
# The branch may contain slashes (e.g. future3/feature/xyz).
parse_source_url() {
    local url="$1"
    local rest user_repo user repo branch

    if [[ "$url" == *"raw.githubusercontent.com/"* ]]; then
        # File URL of the installer script: the branch is everything between
        # the repository name and the path of the script.
        rest="${url#*raw.githubusercontent.com/}"
        rest="${rest%%\?*}"   # drop a query string if present
        rest="${rest%/}"
        if [[ "$rest" != *"/installation/install-jukebox.sh" ]]; then
            echo "ERROR: Invalid GitHub URL: $url" >&2
            echo "        Expected format: https://raw.githubusercontent.com/<user>/<repo>/<branch>/installation/install-jukebox.sh" >&2
            return 1
        fi
        rest="${rest%/installation/install-jukebox.sh}"
        # rest is <user>/<repo>/<branch>; the branch may contain slashes
        user="${rest%%/*}"
        rest="${rest#*/}"
        repo="${rest%%/*}"
        branch="${rest#*/}"
    else
        # Strip the protocol and the github.com prefix (also works for
        # "github.com/...", "www.github.com/..." or "http(s)://...")
        rest="${url#*github.com/}"
        if [[ "$rest" == "$url" ]]; then
            echo "ERROR: Invalid GitHub URL: $url" >&2
            echo "        Expected format: https://github.com/<user>/<repo>/tree/<branch>" >&2
            echo "        or:              https://raw.githubusercontent.com/<user>/<repo>/<branch>/installation/install-jukebox.sh" >&2
            return 1
        fi
        rest="${rest%/}"   # remove a trailing slash if present

        if [[ "$rest" != *"/tree/"* ]]; then
            echo "ERROR: Invalid GitHub URL (missing /tree/): $url" >&2
            echo "        Expected format: https://github.com/<user>/<repo>/tree/<branch>" >&2
            return 1
        fi

        user_repo="${rest%%/tree/*}"
        branch="${rest#*/tree/}"
        user="${user_repo%%/*}"
        repo="${user_repo#*/}"
    fi

    branch="$(normalize_branch "$branch")"

    if [[ -z "$user" || -z "$repo" || -z "$branch" ]]; then
        echo "ERROR: Could not parse GitHub URL: $url" >&2
        return 1
    fi
    if [[ "$repo" != "RPi-Jukebox-RFID" ]]; then
        echo "ERROR: The repository must be named 'RPi-Jukebox-RFID' (found: '$repo')." >&2
        echo "        The official installer only supports forks with this name." >&2
        return 1
    fi

    GIT_USER="$user"
    GIT_BRANCH="$branch"
    return 0
}

SOURCE_ORIGIN=""
SOURCE_URL="${SOURCE_URL_ARG:-${SETUP_SOURCE_URL:-}}"
if [[ -n "$SOURCE_URL" ]]; then
    if [[ -n "$SOURCE_URL_ARG" ]]; then
        SOURCE_ORIGIN="--source"
    else
        SOURCE_ORIGIN="SOURCE_URL in $SETUP_CONFIG_FILE"
    fi
    parse_source_url "$SOURCE_URL"
else
    GIT_USER="$(get_config_value GIT_USER)"
    GIT_BRANCH="$(normalize_branch "$(get_config_value GIT_BRANCH)")"
    GIT_USER="${GIT_USER:-MiczFlor}"
    GIT_BRANCH="${GIT_BRANCH:-future3/main}"
    SOURCE_ORIGIN="$CONFIG_FILE"
fi

# URL of the installer script: it is fetched from raw.githubusercontent.com by
# the verification below and by the installation on the Pi.
INSTALLER_URL="https://raw.githubusercontent.com/${GIT_USER}/RPi-Jukebox-RFID/${GIT_BRANCH}/installation/install-jukebox.sh"

# --- RFID reader module: canonical names vs. technical module names ----------
# The official installer understands the TECHNICAL module names (e.g.
# pn532_i2c_py532). This script accepts both the technical module names and the
# human-readable CANONICAL display names (e.g. "PN532 reader via I2C using
# py532 library"). RFID_READER_CANONICAL_NAMES and resolve_rfid_reader_module()
# live in rfid_reader.sh, together with the RFID reader check.

# Build the effective config: remove GIT_USER/GIT_BRANCH (and the RFID reader
# module) from the original application config and append the resolved values.
# This way the official installer on the Pi installs exactly the source this
# script shows — also when --source/SOURCE_URL overrides the config values —
# and the RFID reader module is always written in its technical form. Only
# the application config goes into this file; the setup config (with
# credentials) never does.
EFFECTIVE_CONFIG="$(mktemp /tmp/install_config.XXXXXX.env)"
trap 'rm -f "$EFFECTIVE_CONFIG"' EXIT

build_effective_config() {
    local rfid_module enable_rfid resolved_module=""
    rfid_module="${RFID_READER_ARG:-$(get_config_value RFID_READER_MODULE)}"

    # Mirror the official installer's validation: with an enabled reader the
    # module must be set (ENABLE_RFID_READER defaults to true).
    enable_rfid="$(get_config_value ENABLE_RFID_READER)"
    [[ -z "$enable_rfid" ]] && enable_rfid="true"
    if [[ "$enable_rfid" == "true" && -z "$rfid_module" ]]; then
        echo "ERROR: RFID reader is enabled (ENABLE_RFID_READER=true) but no" >&2
        echo "       RFID_READER_MODULE is set." >&2
        echo "Set RFID_READER_MODULE in $CONFIG_FILE to a technical module name" >&2
        echo "or a canonical reader name, or disable the reader with" >&2
        echo "ENABLE_RFID_READER=false." >&2
        exit 1
    fi

    # The reader module and the UPS 3S keys are handled by this script and are
    # not options of the upstream installer. ENABLE_MCP23017, MCP23017_ADDRESS
    # and MCP23017_I2C_BUS are passed through: the installer enables I2C, adds
    # the overlay and creates the application settings.
    # shellcheck disable=SC2016
    grep -v -E '^[[:space:]]*(GIT_USER|GIT_BRANCH|SOURCE_URL|RFID_READER_MODULE|ENABLE_UPS3S|UPS3S_[A-Z0-9_]+)=' \
        "$CONFIG_FILE" > "$EFFECTIVE_CONFIG" || true

    if [[ -n "$rfid_module" ]]; then
        resolved_module="$(resolve_rfid_reader_module "$rfid_module")" || exit 1
        printf "RFID_READER_MODULE='%s'\n" "$resolved_module" >> "$EFFECTIVE_CONFIG"
    fi
    printf "GIT_USER='%s'\nGIT_BRANCH='%s'\n" "$GIT_USER" "$GIT_BRANCH" >> "$EFFECTIVE_CONFIG"

    # Reader settings as they reach the installer, for the reader check
    RFID_EFFECTIVE_ENABLE="$enable_rfid"
    RFID_EFFECTIVE_MODULE="$resolved_module"
    RFID_EFFECTIVE_PARAMS="$(get_config_value RFID_READER_PARAMS)"
    RFID_EFFECTIVE_DEPS="$(get_config_value RFID_READER_DEPS)"
    if [[ -z "$RFID_EFFECTIVE_DEPS" ]]; then
        RFID_EFFECTIVE_DEPS="auto"
    fi
}
build_effective_config

# Safety: the file uploaded to the Pi must NEVER contain SSH credentials or
# other connection data. Abort if the application config contains such keys.
if grep -qE '^[[:space:]]*(SSH_PASSWORD|SSH_USER|PI_HOST|PI_IP|SSHPASS)=' "$EFFECTIVE_CONFIG"; then
    echo "ERROR: The application config ($CONFIG_FILE) contains SSH connection" >&2
    echo "       credentials (SSH_PASSWORD/SSH_USER/PI_HOST/...)." >&2
    echo "       Those belong in $SETUP_CONFIG_FILE and are never uploaded." >&2
    exit 1
fi

# Warn if the setup config (which may contain the SSH password) is readable
# by other users.
if [[ -f "$SETUP_CONFIG_FILE" && -n "$PASSWORD" ]]; then
    perm="$(stat -c '%a' "$SETUP_CONFIG_FILE" 2>/dev/null || true)"
    if [[ -n "$perm" && "$perm" != "600" && "$perm" != "400" && "$perm" != "000" ]]; then
        echo "WARNING: $SETUP_CONFIG_FILE contains credentials but is not restricted" >&2
        echo "         (mode $perm). Consider: chmod 600 $SETUP_CONFIG_FILE" >&2
    fi
fi

# --- Check local prerequisites -------------------------------------------------
if ! command -v ssh >/dev/null 2>&1; then
    echo "ERROR: 'ssh' is not installed (OpenSSH client required)." >&2
    exit 1
fi
if [[ -n "$PASSWORD" ]] && ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: 'sshpass' is not installed but is required for" >&2
    echo "        password authentication." >&2
    echo "        Install it e.g. with: sudo apt install sshpass" >&2
    echo "                            or: sudo pacman -S sshpass" >&2
    exit 1
fi

# --- SSH helpers -----------------------------------------------------------------
# Host key handling:
#   VERIFY_HOST_KEY=false (default): the host key is NOT verified. The real
#     known_hosts file is ignored (UserKnownHostsFile=/dev/null) — a differing
#     fingerprint is neither detected nor blocks the connection. This keeps
#     the script working across reimaged Pis, but offers no protection
#     against man-in-the-middle attacks.
#   VERIFY_HOST_KEY=true: the host key is verified against ~/.ssh/known_hosts
#     with StrictHostKeyChecking=accept-new — an unknown host is added
#     silently (no prompt), but a CHANGED key aborts the connection (the
#     script prints a hint: ssh-keygen -R <IP>).
KNOWN_HOSTS_FILE="${HOME}/.ssh/known_hosts"
SSH_OPTS=(
    -o LogLevel=ERROR
    -o ConnectTimeout=15
    -o ServerAliveInterval=60
    -o ServerAliveCountMax=10
)
if [[ "$VERIFY_HOST_KEY" == "true" ]]; then
    mkdir -p "$(dirname "$KNOWN_HOSTS_FILE")"
    touch "$KNOWN_HOSTS_FILE"
    SSH_OPTS+=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN_HOSTS_FILE")
else
    SSH_OPTS+=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null)
fi
SSH_TARGET="${SSH_USER}@${IP}"

# Runs a command remotely. The password is passed via the SSHPASS environment
# variable (not via argv — no problems with special characters and not
# visible in 'ps').
run_remote() {
    local cmd="$1"
    if [[ -n "$PASSWORD" ]]; then
        SSHPASS="$PASSWORD" sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$cmd"
    else
        ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$cmd"
    fi
}

# Runs a shell snippet on the Pi as root. With a password, sudo reads it from
# stdin; without one, passwordless sudo is required (the official installer
# needs that as well). The snippet must not contain single quotes.
run_remote_sudo() {
    local snippet="$1"
    if [[ -n "$PASSWORD" ]]; then
        printf '%s\n' "$PASSWORD" | SSHPASS="$PASSWORD" sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo -S -p '' bash -c '${snippet}'"
    else
        ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo -n bash -c '${snippet}'"
    fi
}

# Copies a local file to the Pi through the SSH connection. The destination is
# a plain path chosen by the caller (for example /tmp/ups3s_monitor.py).
run_remote_upload() {
    local source="$1" destination="$2"
    if [[ -n "$PASSWORD" ]]; then
        SSHPASS="$PASSWORD" sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "cat > '${destination}'" < "$source"
    else
        ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "cat > '${destination}'" < "$source"
    fi
}

print_banner() {
    echo "==============================================================="
    echo "  Phoniebox (RPi-Jukebox-RFID) — Non-interactive Installation"
    echo "==============================================================="
    echo " Target         : ${SSH_TARGET}"
    echo " Config         : ${CONFIG_FILE}"
    if [[ -f "$SETUP_CONFIG_FILE" ]]; then
        echo " Setup config   : ${SETUP_CONFIG_FILE}"
    fi
    if [[ -n "$SOURCE_URL" ]]; then
        echo " Source (URL)   : ${SOURCE_URL}"
    fi
    echo " Source         : ${GIT_USER}/RPi-Jukebox-RFID @ ${GIT_BRANCH}"
    if ! mcp23017_load_settings "$CONFIG_FILE" > /dev/null 2>&1; then
        echo " MCP23017       : invalid configuration"
    elif [[ "$MCP23017_ENABLE" == "true" ]]; then
        echo " MCP23017       : ${MCP23017_ADDRESS} on I2C bus ${MCP23017_BUS}"
    else
        echo " MCP23017       : disabled"
    fi
    if ! ups3s_load_settings "$CONFIG_FILE" > /dev/null 2>&1; then
        echo " UPS 3S         : invalid configuration"
    elif [[ "$UPS3S_ENABLE" == "true" ]]; then
        echo " UPS 3S         : INA219 ${UPS3S_ADDRESS} on I2C bus ${UPS3S_BUS}"
    else
        echo " UPS 3S         : disabled"
    fi
    echo " Reboot         : $([ "$DO_REBOOT" = "true" ] && echo "yes (after success)" || echo "no")"
    echo " Host key check : $([ "$VERIFY_HOST_KEY" = "true" ] && echo "yes (accept-new, ${KNOWN_HOSTS_FILE})" || echo "no (not verified)")"
    echo " Detailed log   : $([ "$SHOW_LOG" = "true" ] && echo "yes (live tail of INSTALL-<id>.log)" || echo "no")"
    echo "---------------------------------------------------------------"
}

# --- Test the SSH connection --------------------------------------------------
test_connection() {
    echo ">>> Checking SSH connection to ${SSH_TARGET} ..."
    local out
    if ! out="$(run_remote 'echo "OK: connected to $(hostname) ($(uname -m))"' 2>&1)"; then
        echo "ERROR: SSH connection to ${SSH_TARGET} failed." >&2
        if [[ "$VERIFY_HOST_KEY" == "true" ]] \
            && [[ "$out" == *"REMOTE HOST IDENTIFICATION"* || "$out" == *"Host key verification failed"* ]]; then
            echo "Hint: The host key of ${IP} does not match the entry in ${KNOWN_HOSTS_FILE}." >&2
            echo "      This happens e.g. after reimaging the Pi. Remove the old key:" >&2
            echo "      ssh-keygen -R ${IP}" >&2
        fi
        exit 1
    fi
    echo "    $out"
}

# --- Pre-flight checks on the Pi ----------------------------------------------
preflight() {
    echo ">>> Running pre-flight checks on the Pi ..."
    local preflight_cmd
    preflight_cmd='
        if [ -r /etc/os-release ]; then
            . /etc/os-release
            echo "OS             : ${PRETTY_NAME:-unknown}"
        fi
        echo "Architecture   : $(uname -m)"
        echo "Kernel         : $(uname -r)"
        if command -v python3 >/dev/null 2>&1; then
            python3 --version
        else
            echo "python3        : NOT found"
        fi
        if command -v wget >/dev/null 2>&1; then
            echo "wget           : present"
        else
            echo "wget           : MISSING"
        fi
        if command -v apt-get >/dev/null 2>&1; then
            echo "apt-get        : present (Debian/Raspberry Pi OS OK)"
        else
            echo "ERROR: apt-get is missing — the target is not a Debian/Raspberry Pi OS system."
            exit 1
        fi
    '
    run_remote "$preflight_cmd"
}

# --- The jukebox service of an existing installation --------------------------------
# The reader registration of the installer (run_register_rfid_reader.py) exits
# without configuring anything while a jukebox service is active: no reader is
# written to shared/settings/rfid.yaml and no reader dependency is installed.
# An installation over an existing installation finds that service running, so it
# is stopped for the installation and started again afterwards.
JUKEBOX_SERVICE_STOPPED="false"

jukebox_service_state() {
    run_remote 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; systemctl --user is-active jukebox-daemon 2> /dev/null || true'
}

stop_jukebox_service() {
    local state

    state="$(jukebox_service_state)"
    if [[ "$state" != "active" ]]; then
        return 0
    fi

    echo ">>> Stopping the jukebox service of the existing installation"
    echo "    The installer skips the reader registration while the service runs."
    if run_remote 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; systemctl --user stop jukebox-daemon'; then
        JUKEBOX_SERVICE_STOPPED="true"
        echo "    Stopped - the service is started again after the installation."
    else
        echo "WARNING: The jukebox service could not be stopped. The installation" >&2
        echo "         finishes without a reader configuration in that case." >&2
        echo "         Stop it on the Pi and run the setup again:" >&2
        echo "             systemctl --user stop jukebox-daemon" >&2
    fi
}

start_jukebox_service() {
    if [[ "$JUKEBOX_SERVICE_STOPPED" != "true" ]]; then
        return 0
    fi

    echo ""
    echo ">>> Starting the jukebox service again"
    if run_remote 'export XDG_RUNTIME_DIR="/run/user/$(id -u)"; systemctl --user start jukebox-daemon'; then
        JUKEBOX_SERVICE_STOPPED="false"
        echo "    Started."
    else
        echo "WARNING: The jukebox service could not be started again." >&2
        echo "         Start it on the Pi with: systemctl --user start jukebox-daemon" >&2
    fi
    return 0
}

# A stopped service must not stay stopped when the script aborts (failing source
# check, failed installation, interpreted signal).
trap 'start_jukebox_service' EXIT

# --- Verify the installation source ----------------------------------------------
# The installer script is fetched from raw.githubusercontent.com on the Pi. This
# check runs before the installer changes anything there, so a branch that does
# not exist is reported together with the setting the value came from.
check_source() {
    echo ">>> Verifying the installation source on the Pi ..."
    echo "    ${INSTALLER_URL}"
    echo "    Source: ${SOURCE_ORIGIN}"

    local response=""
    if response="$(run_remote "wget -O /dev/null --server-response '${INSTALLER_URL}' 2>&1")"; then
        echo "    Source is available: ${GIT_USER}/RPi-Jukebox-RFID @ ${GIT_BRANCH}"
        return 0
    fi

    if [[ "$response" == *"404"* || "$response" == *"Not Found"* ]]; then
        echo "ERROR: The source is not available on GitHub: ${GIT_USER}/RPi-Jukebox-RFID @ ${GIT_BRANCH}" >&2
        echo "       Check the branch name in ${SOURCE_ORIGIN}." >&2
        echo "       The branch may contain slashes (future3/feature/xyz); a leading" >&2
        echo "       'refs/heads/' is removed automatically." >&2
        exit 1
    fi

    if [[ "$response" == *"command not found"* ]]; then
        echo "ERROR: 'wget' is missing on the Pi, so no source can be downloaded there." >&2
        echo "       Install it with: sudo apt install wget" >&2
        exit 1
    fi

    echo "WARNING: The source could not be verified on the Pi." >&2
    echo "         This is a network problem or a rate limit of GitHub for" >&2
    echo "         unauthenticated requests. The installation starts anyway and" >&2
    echo "         downloads the same URL; the installer log names the reason." >&2
    return 0
}

# --- MCP23017 I2C GPIO expander ---------------------------------------------
# The expander is installed by the application installer: the keys
# ENABLE_MCP23017, MCP23017_ADDRESS and MCP23017_I2C_BUS are passed through
# the --config file. This pre-flight step validates them, so an invalid
# address never reaches the boot configuration.
validate_mcp23017() {
    echo ">>> Validating the I2C GPIO expander (MCP23017) settings"
    if ! mcp23017_load_settings "$CONFIG_FILE"; then
        echo "ERROR: Invalid MCP23017 settings in $CONFIG_FILE." >&2
        exit 1
    fi
    if [[ "$MCP23017_ENABLE" == "true" ]]; then
        echo "    ${MCP23017_ADDRESS} on I2C bus ${MCP23017_BUS}; the installer enables I2C and the overlay."
    else
        echo "    Disabled (ENABLE_MCP23017=false)."
    fi
    return 0
}

check_mcp23017() {
    echo ">>> Checking the I2C GPIO expander (MCP23017)"
    if ! mcp23017_load_settings "$CONFIG_FILE"; then
        MCP23017_CHECK_STATUS="invalid configuration"
        return 0
    fi
    if [[ "$MCP23017_ENABLE" != "true" ]]; then
        echo "    Disabled (ENABLE_MCP23017=false)."
        MCP23017_CHECK_STATUS="disabled"
        return 0
    fi
    mcp23017_check || true
}

# --- Waveshare UPS Module 3S (INA219) ---------------------------------------
# The monitor service reads the UPS over I2C; it is installed before the
# application, because it does not depend on it. The application then gets the
# battery block in its configuration, so the Web App shows the charge level.
configure_ups3s() {
    echo ">>> Configuring the Waveshare UPS Module 3S (INA219)"
    if ! ups3s_load_settings "$CONFIG_FILE"; then
        echo "WARNING: Invalid UPS 3S settings; the monitor is not configured." >&2
        UPS3S_CHECK_STATUS="invalid configuration"
        return 0
    fi
    if [[ "$UPS3S_ENABLE" != "true" ]]; then
        echo "    Disabled (ENABLE_UPS3S=false)."
        ups3s_disable || true
        UPS3S_CHECK_STATUS="disabled"
        return 0
    fi
    if ! ups3s_install "$CONFIG_FILE"; then
        echo "WARNING: The UPS 3S configuration failed; the installation continues." >&2
    fi
    return 0
}

check_ups3s() {
    echo ">>> Checking the Waveshare UPS Module 3S (INA219)"
    if ! ups3s_load_settings "$CONFIG_FILE"; then
        UPS3S_CHECK_STATUS="invalid configuration"
        return 0
    fi
    if [[ "$UPS3S_ENABLE" != "true" ]]; then
        echo "    Disabled (ENABLE_UPS3S=false)."
        UPS3S_CHECK_STATUS="disabled"
        return 0
    fi
    ups3s_check || true
}

# Enables the battery display of the application after the installation. The
# configuration is written only once the application directory exists.
configure_ups3s_app() {
    echo ">>> Enabling the battery display in the application"
    if ! ups3s_load_settings "$CONFIG_FILE"; then
        echo "WARNING: Invalid UPS 3S settings; the display is not configured." >&2
        UPS3S_APP_STATUS="invalid configuration"
        return 0
    fi
    if [[ "$UPS3S_ENABLE" != "true" ]]; then
        echo "    Disabled (ENABLE_UPS3S=false)."
        ups3s_remove_app || true
    elif ! ups3s_configure_app "$CONFIG_FILE"; then
        echo "WARNING: The battery display could not be configured; the installation continues." >&2
        return 0
    fi
    if ! ups3s_restart_app; then
        echo "WARNING: Restart the jukebox service to load the battery configuration." >&2
    fi
    return 0
}

# --- Check the RFID reader --------------------------------------------------------
# Compares the RFID reader of the application config with the hardware on the Pi.
# 'pre' runs before the installation, so a wrong reader module can still be
# corrected for this run. 'post' runs after the installation and compares the
# reader configuration the installer wrote with the settings of this setup.
# Both stages only warn; the installation itself stays unchanged.
check_rfid_reader() {
    local stage="$1"

    echo ">>> Checking the RFID reader configuration ($stage)"
    RFID_CHECK_CONFIG_FILE="$CONFIG_FILE"
    RFID_CHECK_STAGE="$stage"
    RFID_CHECK_ENABLE="$RFID_EFFECTIVE_ENABLE"
    RFID_CHECK_MODULE="$RFID_EFFECTIVE_MODULE"
    RFID_CHECK_PARAMS="$RFID_EFFECTIVE_PARAMS"
    RFID_CHECK_DEPS="$RFID_EFFECTIVE_DEPS"
    rfid_check_prepare
    rfid_check_hardware
    rfid_check_configured_reader
    if [[ "$stage" == "post" ]]; then
        rfid_check_installed_configuration
    fi
    rfid_check_summary
}

# --- Upload the configuration ---------------------------------------------------
upload_config() {
    echo ">>> Uploading config to /tmp/install_config.env ..."
    if [[ -n "$PASSWORD" ]]; then
        SSHPASS="$PASSWORD" sshpass -e ssh "${SSH_OPTS[@]}" "$SSH_TARGET" \
            "cat > /tmp/install_config.env" < "$EFFECTIVE_CONFIG"
    else
        ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "cat > /tmp/install_config.env" < "$EFFECTIVE_CONFIG"
    fi
    echo "    Config uploaded ($(wc -l < "$EFFECTIVE_CONFIG") lines)."
}

# --- Run the installer ------------------------------------------------------------
# Streams the installer's console output and, once the installer announces its
# detailed log file (INSTALLATION_LOGFILE=...), tails that log LIVE in a
# parallel SSH session until the installation finishes (--show-log).
run_installer_with_log() {
    local install_cmd="$1"
    local log_file="" tail_pid=""

    # shellcheck disable=SC2031
    if ! run_remote "$install_cmd" | {
        while IFS= read -r line; do
            echo "$line"
            if [[ -z "$log_file" && "$line" == INSTALLATION_LOGFILE=* ]]; then
                log_file="${line#INSTALLATION_LOGFILE=}"
                echo ""
                echo ">>> Detailed install log: ${log_file}"
                echo ">>> (live tail — ends when the installation finishes)"
                echo ""
                # stdin </dev/null is essential: the background ssh must NOT
                # inherit the pipeline as its stdin. OpenSSH sets its stdin to
                # non-blocking, which would make the shared pipe non-blocking
                # too — our 'while read' loop would then fail with
                # "read: 0: read error: Resource temporarily unavailable" and
                # the tail would steal installer output from the pipe.
                run_remote "tail -n +1 -f '${log_file}'" < /dev/null &
                tail_pid=$!
            fi
        done
        # Stop the log tail once the installer's output stream has ended.
        if [[ -n "$tail_pid" ]]; then
            kill "$tail_pid" 2>/dev/null || true
            wait "$tail_pid" 2>/dev/null || true
        fi
    }; then
        return 1
    fi
    return 0
}

run_installer() {
    local install_cmd
    # TERM=dumb silences the installer's 'clear' calls (no TTY over SSH) —
    # otherwise it prints "TERM environment variable not set." repeatedly.
    install_cmd="export TERM=dumb; wget -qO /tmp/install-jukebox.sh \
        ${INSTALLER_URL} \
        && bash /tmp/install-jukebox.sh --config /tmp/install_config.env"
    echo ">>> Starting installation (non-interactive, --config) ..."
    echo "    Duration: approx. 20-60 minutes. Do not interrupt the connection!"
    if [[ "$SHOW_LOG" == "true" ]]; then
        echo "    Detailed log (~/INSTALL-<id>.log) will be shown as soon as it is created."
    fi
    echo "---------------------------------------------------------------"
    if [[ "$SHOW_LOG" == "true" ]]; then
        if ! run_installer_with_log "$install_cmd"; then
            echo "---------------------------------------------------------------" >&2
            echo "ERROR: The installation failed." >&2
            echo "The installation log on the Pi (INSTALL-<id>.log) contains details." >&2
            exit 1
        fi
    elif ! run_remote "$install_cmd"; then
        echo "---------------------------------------------------------------" >&2
        echo "ERROR: The installation failed." >&2
        echo "The installation log on the Pi (INSTALL-<id>.log) contains details." >&2
        exit 1
    fi
    echo "---------------------------------------------------------------"
}

# --- Optional: reboot ---------------------------------------------------------------
reboot_pi() {
    echo ">>> Rebooting the Raspberry Pi ..."
    if run_remote "sudo -n reboot"; then
        echo "    Reboot triggered. The Pi will be reachable again shortly."
    else
        echo "WARNING: Could not trigger the reboot automatically" >&2
        echo "         (sudo password required?)." >&2
        echo "         Please reboot the Pi manually: sudo reboot" >&2
    fi
}

# =============================================================================
# Main flow
# =============================================================================
print_banner
test_connection
preflight
check_source
validate_mcp23017
configure_ups3s
stop_jukebox_service
check_rfid_reader pre
upload_config
run_installer
check_rfid_reader post
check_mcp23017
configure_ups3s_app
start_jukebox_service
check_ups3s

echo ""
echo "==============================================================="
echo "  Installation completed successfully!"
echo "==============================================================="
echo " The installation log is on the Pi at ~/INSTALL-<id>.log"
echo " (the path was printed during the installation: INSTALLATION_LOGFILE=...)."
echo ""
echo " RFID reader    : ${RFID_CHECK_STATUS:-${RFID_EFFECTIVE_MODULE:-not configured}}"
if [[ "${RFID_CHECK_WARNINGS:-0}" -gt 0 ]]; then
    echo "                  ${RFID_CHECK_WARNINGS} warning(s) - see the reader check above"
fi
echo " MCP23017       : ${MCP23017_CHECK_STATUS:-not checked}"
if [[ "${MCP23017_CHECK_WARNINGS:-0}" -gt 0 ]]; then
    echo "                  ${MCP23017_CHECK_WARNINGS} warning(s) - see the expander check above"
fi
echo " UPS 3S         : ${UPS3S_CHECK_STATUS:-not checked}"
if [[ "${UPS3S_CHECK_WARNINGS:-0}" -gt 0 ]]; then
    echo "                  ${UPS3S_CHECK_WARNINGS} warning(s) - see the UPS check above"
fi
echo " Battery display: ${UPS3S_APP_STATUS:-not configured}"
echo ""
echo " Continue with the configuration:"
echo "   https://github.com/${GIT_USER}/RPi-Jukebox-RFID/blob/${GIT_BRANCH}/documentation/builders/configuration.md"
echo ""
if [[ "$DO_REBOOT" == "true" ]]; then
    reboot_pi
else
    echo " Note: The Raspberry Pi should now be rebooted"
    echo "          (e.g. with --reboot or manually 'sudo reboot')."
fi
echo "==============================================================="
