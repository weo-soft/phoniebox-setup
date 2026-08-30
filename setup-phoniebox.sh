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
#   3. Upload the application config to /tmp/install_config.env
#   4. Download install-jukebox.sh and run it non-interactively with --config
#   5. optionally: reboot the Raspberry Pi (--reboot)
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
                         installation, e.g.
                         https://github.com/weo-soft/RPi-Jukebox-RFID/tree/future3/feature/installer-noninteractive-plugins
                         (overrides SOURCE_URL from .env)
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

# Splits a GitHub web URL into GIT_USER and GIT_BRANCH.
# Expected format: https://github.com/<user>/<repo>/tree/<branch>
# The branch may contain slashes (e.g. future3/feature/xyz).
parse_source_url() {
    local url="$1"
    local rest user_repo user repo

    # Strip the protocol and the github.com prefix (also works for
    # "github.com/...", "www.github.com/..." or "http(s)://...")
    rest="${url#*github.com/}"
    if [[ "$rest" == "$url" ]]; then
        echo "ERROR: Invalid GitHub URL: $url" >&2
        echo "        Expected format: https://github.com/<user>/<repo>/tree/<branch>" >&2
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

SOURCE_URL="${SOURCE_URL_ARG:-${SETUP_SOURCE_URL:-}}"
if [[ -n "$SOURCE_URL" ]]; then
    parse_source_url "$SOURCE_URL"
else
    GIT_USER="$(get_config_value GIT_USER)"
    GIT_BRANCH="$(get_config_value GIT_BRANCH)"
    GIT_USER="${GIT_USER:-MiczFlor}"
    GIT_BRANCH="${GIT_BRANCH:-future3/main}"
fi

# --- RFID reader module: canonical names vs. technical module names ----------
# The official installer understands the TECHNICAL module names (e.g.
# pn532_i2c_py532). This script accepts both the technical module names and
# the human-readable CANONICAL display names (e.g. "PN532 reader via I2C
# using py532 library") and maps the canonical names to the module names.
# Format of the table: "canonical display name|technical module name"
RFID_READER_CANONICAL_NAMES=(
    "PN532 reader via I2C using py532 library|pn532_i2c_py532"
    "MFRC522 via SPI|rc522_spi"
    "RDM6300 via serial UART|rdm6300_serial"
    "MFRC522 Reader using I2C via the mfrc522_i2c library|mfrc522_i2c"
    "Generic NFCPY NFC Reader Module|generic_nfcpy"
    "Generic USB Reader|generic_usb"
)

# Maps a canonical reader name to its technical module name; technical module
# names pass through unchanged. Prints the module name on stdout and returns
# 0. Returns 1 (with an error listing all supported names) if the value is
# neither a canonical nor a technical name.
resolve_rfid_reader_module() {
    local value="$1"
    local entry canonical module
    if [[ -z "$value" ]]; then
        return 0
    fi
    # Technical module name given? -> passthrough
    for entry in "${RFID_READER_CANONICAL_NAMES[@]}"; do
        module="${entry#*|}"
        if [[ "$value" == "$module" ]]; then
            printf '%s' "$module"
            return 0
        fi
    done
    # Canonical display name given? -> map to the module name (case-insensitive)
    for entry in "${RFID_READER_CANONICAL_NAMES[@]}"; do
        canonical="${entry%%|*}"
        if [[ "${value,,}" == "${canonical,,}" ]]; then
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
    local rfid_module enable_rfid resolved_module
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

    # shellcheck disable=SC2016
    grep -v -E '^[[:space:]]*(GIT_USER|GIT_BRANCH|SOURCE_URL|RFID_READER_MODULE)=' \
        "$CONFIG_FILE" > "$EFFECTIVE_CONFIG" || true

    if [[ -n "$rfid_module" ]]; then
        resolved_module="$(resolve_rfid_reader_module "$rfid_module")" || exit 1
        printf "RFID_READER_MODULE='%s'\n" "$resolved_module" >> "$EFFECTIVE_CONFIG"
    fi
    printf "GIT_USER='%s'\nGIT_BRANCH='%s'\n" "$GIT_USER" "$GIT_BRANCH" >> "$EFFECTIVE_CONFIG"
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
    echo " Reboot         : $([ "$DO_REBOOT" = "true" ] && echo "yes (after success)" || echo "no")"
    echo " Host key check : $([ "$VERIFY_HOST_KEY" = "true" ] && echo "yes (accept-new, ${KNOWN_HOSTS_FILE})" || echo "no (not verified)")"
    echo " Detailed log   : $([ "$SHOW_LOG" = "true" ] && echo "yes (live tail of INSTALL-<id>.log)" || echo "no")"
    echo "---------------------------------------------------------------"
}

# --- 1. Test the SSH connection --------------------------------------------------
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

# --- 2. Pre-flight checks on the Pi ----------------------------------------------
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

# --- 3. Upload the configuration ---------------------------------------------------
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

# --- 4. Run the installer ------------------------------------------------------------
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
        https://raw.githubusercontent.com/${GIT_USER}/RPi-Jukebox-RFID/${GIT_BRANCH}/installation/install-jukebox.sh \
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

# --- 5. Optional: reboot ---------------------------------------------------------------
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
upload_config
run_installer

echo ""
echo "==============================================================="
echo "  Installation completed successfully!"
echo "==============================================================="
echo " The installation log is on the Pi at ~/INSTALL-<id>.log"
echo " (the path was printed during the installation: INSTALLATION_LOGFILE=...)."
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
