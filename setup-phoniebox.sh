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
#   3. Check the configured RFID reader against the hardware on the Pi
#   4. Verify the installation source (raw.githubusercontent.com)
#   5. Upload the application config to /tmp/install_config.env
#   6. Download install-jukebox.sh and run it non-interactively with --config
#   7. Check the installed reader configuration against the hardware again
#   8. optionally: reboot the Raspberry Pi (--reboot)
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

    # shellcheck disable=SC2016
    grep -v -E '^[[:space:]]*(GIT_USER|GIT_BRANCH|SOURCE_URL|RFID_READER_MODULE)=' \
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

# --- 3. Verify the installation source ----------------------------------------------
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

# --- 4. Check the RFID reader --------------------------------------------------------
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

# --- 5. Upload the configuration ---------------------------------------------------
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

# --- 6. Run the installer ------------------------------------------------------------
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

# --- 7. Optional: reboot ---------------------------------------------------------------
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
check_rfid_reader pre
upload_config
run_installer
check_rfid_reader post

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
