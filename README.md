# phoniebox-setup

Non-interactive installation of [RPi-Jukebox-RFID (Phoniebox future3)](https://github.com/MiczFlor/RPi-Jukebox-RFID)
on a Raspberry Pi — fully automated over SSH, without prompts.

| File | Purpose |
| --- | --- |
| `setup-phoniebox.sh` | Installation script (run on **your own machine**) |
| `.env` | **Script configuration** — SSH connection data (`PI_HOST`, `SSH_USER`, `SSH_PASSWORD`) and the optional GitHub source URL (`SOURCE_URL`). Contains credentials, **never uploaded to the Pi**, **never committed to git** (see `.gitignore`). Create it from `.env-example`. |
| `.env-example` | **Template** for `.env` with example values. Copy it and fill in your values: `cp .env-example .env && chmod 600 .env`. |
| `phoniebox.config` | **Application configuration** — all non-interactive installer options (`GIT_USER`, `GIT_BRANCH`, `ENABLE_*`, ...). This is the file transferred to the installer. |
| `phoniebox.config-example` | **Template** for `phoniebox.config` with example values. Copy it and fill in your values: `cp phoniebox.config phoniebox.config`. |

## Configuration separation

The configuration is split into two files so that credentials never leak into
the installation process:

| | `.env` | `phoniebox.config` |
| --- | --- | --- |
| Contents | SSH connection (`PI_HOST`, `SSH_USER`, `SSH_PASSWORD`), source URL (`SOURCE_URL`), optional `APP_CONFIG`/`REBOOT`/`VERIFY_HOST_KEY` | Installer options: `GIT_USER`, `GIT_BRANCH`, `ENABLE_STATIC_IP`, `RFID_READER_MODULE`, ... |
| Transferred to the Pi? | **Never** | Yes (as `/tmp/install_config.env`) |
| Security | Keep private: `chmod 600 .env`; listed in `.gitignore` (use `.env-example` as template) | Must not contain SSH credentials |

The script enforces this: it aborts if the application config contains
credential keys (`SSH_PASSWORD`/`SSH_USER`/`PI_HOST`/...), and it warns if
`.env` is readable by other users. The SSH password is passed to
`sshpass` via an environment variable — not via the command line, so it is
not visible in the process list.

## SSH host key handling

By default the script does **not** verify the SSH host key
(`StrictHostKeyChecking=no` + `UserKnownHostsFile=/dev/null`): an existing
differing fingerprint in `~/.ssh/known_hosts` is ignored and never blocks the
connection. This keeps the installation working across reimaged Pis (the key
changes with every new image), but offers no protection against
man-in-the-middle attacks.

To enable host key verification, set `VERIFY_HOST_KEY=true` in
`.env` or pass `--verify-host-key`. The script then uses
`StrictHostKeyChecking=accept-new` against `~/.ssh/known_hosts`:

- **Unknown host** → the key is added automatically, no prompt, installation
  continues (trust-on-first-use).
- **Same key** → works as before.
- **Changed key** (e.g. after reimaging, or another machine on the same IP)
  → SSH aborts and the script prints a hint how to fix it:
  `ssh-keygen -R <IP>` (removes the old entry, then run the script again).

## How it works

The official RPi-Jukebox-RFID installer (`installation/install-jukebox.sh`)
supports a non-interactive mode: all options are passed via a flat
`KEY=VALUE` config file (`bash install-jukebox.sh --config <file>`). This
script handles the complete flow:

1. Establish an SSH connection to the Pi (IP, user, password from
   `.env` or command line)
2. Run pre-flight checks on the Pi (OS, architecture, `python3`, `wget`, `apt-get`)
3. Upload `phoniebox.config` to `/tmp/install_config.env` on the Pi
   (the resolved source `GIT_USER`/`GIT_BRANCH` is written into the uploaded
   file — see [Setting the source](#setting-the-source-repobranch))
4. Download `install-jukebox.sh` and run it non-interactively with `--config`
   (output is streamed live, including the path of the installation log
   `INSTALLATION_LOGFILE=...`)
5. optionally: reboot the Raspberry Pi (`--reboot`)

> The non-interactive mode skips the welcome and the final reboot prompts —
> the caller is responsible for the reboot (hence the `--reboot` option).

## Prerequisites

**On the Raspberry Pi** (checked before the installation):

- Raspberry Pi OS Lite (Debian-based, `apt-get` present)
- SSH enabled (e.g. preconfigured with the Raspberry Pi Imager)

**On the machine that runs the installation:**

- `ssh` (OpenSSH client)
- `sshpass` (only for password authentication):
  - Debian/Ubuntu: `sudo apt install sshpass`
  - Arch: `sudo pacman -S sshpass`

## Usage

```bash
./setup-phoniebox.sh [<IP> <USER> <PASSWORD>] [options]
```

First copy `.env-example` to `.env` and fill in your Pi's IP address, SSH
user and password:

```bash
cp .env-example .env
chmod 600 .env
# then edit .env
```

Then simply run:

```bash
# Everything from .env
./setup-phoniebox.sh

# Override IP/user on the command line (password still from .env)
./setup-phoniebox.sh 192.168.1.50 pi
```

### Examples

```bash
# Simplest variant — all settings from .env
./setup-phoniebox.sh

# Custom application config + reboot after success
./setup-phoniebox.sh --config my-config.env --reboot

# Installation from your own fork / feature branch (GitHub URL)
./setup-phoniebox.sh \
    --source https://github.com/weo-soft/RPi-Jukebox-RFID/tree/future3/feature/installer-noninteractive-plugins

# SSH key authentication (no password in .env)
./setup-phoniebox.sh 192.168.1.50 pi ""
```

### Options

| Option | Description |
| --- | --- |
| `--setup-config <file>` | Script configuration (SSH connection, source URL). Default: `.env` in the same directory. |
| `-s, --source <url>` | GitHub URL with repository/branch used for the installation, e.g. `https://github.com/weo-soft/RPi-Jukebox-RFID/tree/future3/feature/installer-noninteractive-plugins`. Overrides `SOURCE_URL` from `.env`. The repository must be named `RPi-Jukebox-RFID` (the official installer only supports forks with this name). |
| `--rfid-reader <mod>` | RFID reader module for the installation: technical module name (e.g. `pn532_i2c_py532`) **or** canonical display name (e.g. `"PN532 reader via I2C using py532 library"`). Overrides `RFID_READER_MODULE` from `phoniebox.config`. See [RFID reader module names](#rfid-reader-module-names). |
| `-c, --config <file>` | Application config file. Default: `phoniebox.config` in the same directory (or `APP_CONFIG` from `.env`). |
| `-r, --reboot` | Reboot the Raspberry Pi after a successful installation (or `REBOOT=true` in `.env`). |
| `--verify-host-key` | Verify the SSH host key against `~/.ssh/known_hosts` (`accept-new`; or `VERIFY_HOST_KEY=true` in `.env`). See [SSH host key handling](#ssh-host-key-handling). |
| `--show-log` | Show the detailed installation log (`~/INSTALL-<timestamp>.log`) **live** while the installation runs (or `SHOW_LOG=true` in `.env`). The script tails the log file on the Pi in a parallel SSH session until the installation finishes. |
| `-h, --help` | Show help |

Command line arguments override the values from `.env`.

### Setting the source (repo/branch)

The source is determined in this order (first match wins):

1. `--source <url>` on the command line
2. `SOURCE_URL=<url>` in `.env`
3. `GIT_USER`/`GIT_BRANCH` in `phoniebox.config`
4. Default: `MiczFlor` / `future3/main`

The GitHub URL has the form `https://github.com/<user>/<repo>/tree/<branch>`
— the branch may contain slashes (e.g. `future3/feature/xyz`). When
uploading, the script appends the resolved `GIT_USER`/`GIT_BRANCH` values to
the transferred config, so the official installer on the Pi also installs
from the selected fork/branch.

## Customizing the application configuration (`phoniebox.config`)

All non-interactive installation options are set in `phoniebox.config`
(flat `KEY=VALUE` format, no YAML). Important points:

- **`RFID_READER_MODULE`** — **required** when `ENABLE_RFID_READER=true`
  (default). No reader? Set `ENABLE_RFID_READER=false`.

### RFID reader module names

`RFID_READER_MODULE` (and the `--rfid-reader` option) accept **both** the
technical module name and the canonical display name. The script maps the
canonical name to the technical module name before the config is uploaded to
the Pi.

| Technical module | Canonical name |
| --- | --- |
| `pn532_i2c_py532` | PN532 reader via I2C using py532 library |
| `rc522_spi` | MFRC522 via SPI |
| `rdm6300_serial` | RDM6300 via serial UART |
| `mfrc522_i2c` | MFRC522 Reader using I2C via the mfrc522_i2c library |
| `generic_nfcpy` | Generic NFCPY NFC Reader Module |
| `generic_usb` | Generic USB Reader |

Examples:

```bash
# Technical module name in the config (no spaces — no quotes needed)
RFID_READER_MODULE=rc522_spi

# Canonical name in the config (mapped automatically)
# NOTE: canonical names contain spaces — wrap them in quotes
RFID_READER_MODULE="MFRC522 via SPI"

# Or via the command line (canonical names MUST be quoted here)
./setup-phoniebox.sh --rfid-reader "PN532 reader via I2C using py532 library"
```

> **Quoting:** canonical names always contain spaces, so wrap them in quotes.
> This is **required** on the command line — without quotes the shell would
> split the value, e.g. `--rfid-reader MFRC522 via SPI` would pass only
> `MFRC522` as the reader and treat `via`/`SPI` as further arguments. In
> `phoniebox.config` quotes are recommended: they keep the value intact and
> the file directly usable with the official installer
> (`bash install-jukebox.sh --config <file>`). Technical module names (e.g.
> `rc522_spi`) never contain spaces and never need quotes.

Unknown names abort the script with a list of all supported values.
- **`RFID_READER_PARAMS`** — only needed if the reader cannot determine a
  unique configuration automatically (e.g. `"spi_ce=0;pin_irq=24"` for
  `rc522_spi`). Values containing `;` or spaces must be quoted.
- **`ENABLE_STATIC_IP`** — set to `false` so the Pi's existing network
  configuration (and thus the SSH connection) stays untouched.

The full list of options is documented under
[`documentation/builders/installation.md` → „Non-Interactive Installation“](https://github.com/MiczFlor/RPi-Jukebox-RFID/blob/future3/main/documentation/builders/installation.md#non-interactive-installation)
in the RPi-Jukebox-RFID repository.

## Troubleshooting

- **`sshpass` missing** — see the prerequisites above.
- **Installation aborts** — the installation log on the Pi
  (`~/INSTALL-<id>.log`, the path is printed during the installation as
  `INSTALLATION_LOGFILE=...`) contains the details. Common cause:
  `ENABLE_RFID_READER=true` without `RFID_READER_MODULE`.
- **Connection drops during the installation** — the installation can take
  20–60 minutes. The script uses `ServerAliveInterval` to keep the
  connection alive; if it drops, simply run `setup-phoniebox.sh` again
  (`EXISTING_INSTALL_ACTION=backup` in the config backs up an existing
  installation).
- **Host key verification fails with `VERIFY_HOST_KEY=true`** — the Pi's key
  no longer matches `~/.ssh/known_hosts` (e.g. after reimaging). Remove the
  old entry and run the script again:
  `ssh-keygen -R <IP>`
