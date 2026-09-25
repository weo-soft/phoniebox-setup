# phoniebox-setup

Non-interactive installation of [RPi-Jukebox-RFID (Phoniebox future3)](https://github.com/MiczFlor/RPi-Jukebox-RFID)
on a Raspberry Pi — fully automated over SSH, without prompts.

| File | Purpose |
| --- | --- |
| `setup-phoniebox.sh` | Installation script (run on **your own machine**) |
| `rfid_reader.sh` | Reader names and the RFID reader check |
| `.env` | **Script configuration** — SSH connection data (`PI_HOST`, `SSH_USER`, `SSH_PASSWORD`) and the optional GitHub source URL (`SOURCE_URL`). Contains credentials, **never uploaded to the Pi**, **never committed to git** (see `.gitignore`). Create it from `.env-example`. |
| `.env-example` | **Template** for `.env` with example values. Copy it and fill in your values: `cp .env-example .env && chmod 600 .env`. |
| `phoniebox.config` | **Application configuration** — all non-interactive installer options (`GIT_USER`, `GIT_BRANCH`, `ENABLE_*`, ...). This is the file transferred to the installer. |
| `phoniebox.config-example` | **Template** for `phoniebox.config` with example values. Copy it and fill in your values: `cp phoniebox.config-example phoniebox.config`. |

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
3. Check the configured RFID reader against the hardware on the Pi
   — see [RFID reader check](#rfid-reader-check)
4. Verify the installation source: `installation/install-jukebox.sh` is fetched
   from `raw.githubusercontent.com` on the Pi, and a branch that does not exist
   aborts here — see [Setting the source](#setting-the-source-repobranch)
5. Upload `phoniebox.config` to `/tmp/install_config.env` on the Pi
   (the resolved source `GIT_USER`/`GIT_BRANCH` is written into the uploaded
   file — see [Setting the source](#setting-the-source-repobranch))
6. Download `install-jukebox.sh` and run it non-interactively with `--config`
   (output is streamed live, including the path of the installation log
   `INSTALLATION_LOGFILE=...`)
7. Check the reader configuration the installer wrote against the hardware again
   — see [RFID reader check](#rfid-reader-check)
8. optionally: reboot the Raspberry Pi (`--reboot`)

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
| `-s, --source <url>` | GitHub URL with repository/branch used for the installation, e.g. `https://github.com/weo-soft/RPi-Jukebox-RFID/tree/future3/feature/installer-noninteractive-plugins` or the raw URL of the installer script (`https://raw.githubusercontent.com/<user>/RPi-Jukebox-RFID/<branch>/installation/install-jukebox.sh`). Overrides `SOURCE_URL` from `.env`. The repository must be named `RPi-Jukebox-RFID` (the official installer only supports forks with this name). |
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

Two URL forms are accepted:

```text
https://github.com/<user>/RPi-Jukebox-RFID/tree/<branch>
https://raw.githubusercontent.com/<user>/RPi-Jukebox-RFID/<branch>/installation/install-jukebox.sh
```

The branch may contain slashes (e.g. `future3/feature/xyz`). An address that
carries the fully qualified ref (`.../tree/refs/heads/<branch>`, as some views
and menus produce it) is reduced to the branch name. When uploading, the script
appends the resolved `GIT_USER`/`GIT_BRANCH` values to the transferred
config, so the official installer on the Pi also installs from the selected
fork/branch.

Before the installation starts, the script fetches the installer script
`installation/install-jukebox.sh` from `raw.githubusercontent.com` on the Pi:
a branch that does not exist is answered with `404` and aborts the script with
the name of the branch and of the setting it came from. A network problem or a
rate limit only produces a warning — the installation then runs and reports its
own reason.

> The official installer initializes a Git checkout of the branch on the Pi
> (`git fetch` of `refs/heads/<branch>`). GitHub limits unauthenticated
> requests, which covers cloning over HTTPS as well as downloads from
> `raw.githubusercontent.com`
> ([GitHub changelog](https://github.blog/changelog/2025-05-08-updated-rate-limits-for-unauthenticated-requests/));
> authenticated access keeps the higher limits.

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

## RFID reader check

The script compares the RFID reader that the application config asks for with
the hardware that is connected to the Pi. The check runs twice:

| Stage | Runs | Compares |
| --- | --- | --- |
| `pre` | after the pre-flight checks, before the installer | `ENABLE_RFID_READER`, `RFID_READER_MODULE` and `RFID_READER_PARAMS` of `phoniebox.config` with the interfaces and devices of the Pi |
| `post` | after the installer has run | additionally the reader configuration the installer wrote (`~/RPi-Jukebox-RFID/shared/settings/rfid.yaml`) with the config and the hardware |

The check only warns: it changes nothing on the Pi, does not stop the run and
does not affect the installation. Every warning names the setting to change for
the next run, so a wrong reader module can be corrected in
`phoniebox.config` and the installation repeated.

A run that matches looks like this:

```text
>>> Checking the RFID reader configuration (post)
    configured : generic_nfcpy (RFID_READER_PARAMS="device_path=usb:072f:2200")
    detected   : NFC reader on USB (072f:2200)
    expected   : device_path=usb:072f:2200
    result     : confirmed - device usb:072f:2200 is connected
    installed  : generic_nfcpy (shared/settings/rfid.yaml)
    no deviation found between the configuration and the reader on the Pi
```

A deviation is reported with a suggestion for the configuration (here from
the `post` stage: the config asks for an SPI reader while an NFC reader is
connected and the installation configured it):

```text
>>> Checking the RFID reader configuration (post)
    configured : rc522_spi (RFID_READER_PARAMS not set)
    detected   : NFC reader on USB (072f:2200)
    WARNING: The SPI interface is still not enabled after the installation.
             Check the installation log on the Pi for the reader setup, or enable it with
             'sudo raspi-config nonint do_spi 0'.
             An NFC reader supported by nfcpy is connected: 072f:2200
             If that is the reader, set RFID_READER_MODULE=generic_nfcpy.
    installed  : generic_nfcpy (shared/settings/rfid.yaml)
    WARNING: The installation configured 'generic_nfcpy' while the setup asks for 'rc522_spi'.
             Correct RFID_READER_MODULE in phoniebox.config, or install the reader again.
    2 warning(s): the configuration and the reader on the Pi differ.

    Settings for the next run in phoniebox.config:
        RFID_READER_MODULE=generic_nfcpy
```

What the check looks at, per reader module:

| Reader module | Hardware on the Pi |
| --- | --- |
| `generic_nfcpy` | nfcpy's own device list (its venv is on the Pi after the installation) and the USB bus for the configured `device_path` |
| `generic_usb` | input devices whose key capabilities match the reader support, and the configured `device_name` |
| `pn532_i2c_py532`, `mfrc522_i2c` | the I²C bus and `dtparam=i2c_arm` in the boot config; with `i2c-tools` installed also the reader address (`0x24`, `0x28`) |
| `rc522_spi` | `/dev/spidev*` and `dtparam=spi` in the boot config; the reader itself cannot be detected, its pins come from `RFID_READER_PARAMS` |
| `rdm6300_serial` | `/dev/ttyAMA*`, `/dev/ttyUSB*`, `enable_uart=1` in the boot config and membership in the group `dialout` |
| `fake_reader_gui` | nothing, the simulator needs no hardware |

I²C, SPI and the serial hardware are enabled by the reader setup during the
installation and become active with the next reboot. The check before the
installation therefore reports them as "not enabled yet", the check afterwards
as "enabled in the boot config, active after the next reboot".

## Troubleshooting

- **The reader check reports `NOT CONFIRMED`** — the printed warning names the
  setting and the value to use. Correct `RFID_READER_MODULE`,
  `RFID_READER_PARAMS` or `ENABLE_RFID_READER` in `phoniebox.config` and run
  the script again. Reader modules that cannot determine their device
  automatically (`generic_usb`, `generic_nfcpy`, `rc522_spi`) need
  `RFID_READER_PARAMS` when several candidates are connected.
- **`sshpass` missing** — see the prerequisites above.
- **Installation aborts** — the installation log on the Pi
  (`~/INSTALL-<id>.log`, the path is printed during the installation as
  `INSTALLATION_LOGFILE=...`) contains the details. Common cause:
  `ENABLE_RFID_READER=true` without `RFID_READER_MODULE`.
- **"The source is not available on GitHub"** — the branch in `--source` /
  `SOURCE_URL` / `GIT_BRANCH` does not exist in that fork. The message names
  the branch and the setting it came from; fix the value and run the script
  again.
- **The installation aborts in "Install Git & init repository"** — the official
  installer converts its tarball download into a Git checkout and fetches
  `refs/heads/<branch>` from github.com. A branch that does not exist, a
  network problem or a rate limit for unauthenticated requests fails that step;
  the installer log shows the reason
  (`fatal: couldn't find remote ref ...`).
- **Connection drops during the installation** — the installation can take
  20–60 minutes. The script uses `ServerAliveInterval` to keep the
  connection alive; if it drops, simply run `setup-phoniebox.sh` again
  (`EXISTING_INSTALL_ACTION=backup` in the config backs up an existing
  installation).
- **Host key verification fails with `VERIFY_HOST_KEY=true`** — the Pi's key
  no longer matches `~/.ssh/known_hosts` (e.g. after reimaging). Remove the
  old entry and run the script again:
  `ssh-keygen -R <IP>`
