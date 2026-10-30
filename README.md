# phoniebox-setup

Non-interactive installation of [RPi-Jukebox-RFID (Phoniebox future3)](https://github.com/MiczFlor/RPi-Jukebox-RFID)
on a Raspberry Pi — fully automated over SSH, without prompts.

| File | Purpose |
| --- | --- |
| `setup-phoniebox.sh` | Installation script (run on **your own machine**) |
| `rfid_reader.sh` | Reader names and the RFID reader check |
| `mcp23017.sh` | MCP23017 settings, validation and the expander check |
| `ups3s.sh` | Waveshare UPS Module 3S settings, the monitor check, the remote installer call and the battery block of the application configuration |
| `ups3s_install.sh` | Root script that installs the UPS monitor service and enables I2C on the Pi |
| `ups3s_monitor.py` | Userspace INA219 reader for the UPS; runs as the `ups3s-monitor` service |
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
3. Verify the installation source: `installation/install-jukebox.sh` is fetched
   from `raw.githubusercontent.com` on the Pi, and a branch that does not exist
   aborts here — see [Setting the source](#setting-the-source-repobranch)
4. Validate the MCP23017 settings when `ENABLE_MCP23017=true`; the
   application installer sets up the expander
   — see [I2C GPIO expander (MCP23017)](#i2c-gpio-expander-mcp23017)
5. Install the Waveshare UPS Module 3S monitor when `ENABLE_UPS3S=true`
   — see [Waveshare UPS Module 3S](#waveshare-ups-module-3s-ina219)
6. Stop the jukebox service of an existing installation — it makes the installer
   skip the reader registration, see
   [Installation over an existing installation](#installation-over-an-existing-installation)
7. Check the configured RFID reader against the hardware on the Pi
   — see [RFID reader check](#rfid-reader-check)
8. Upload `phoniebox.config` to `/tmp/install_config.env` on the Pi
   (the resolved source `GIT_USER`/`GIT_BRANCH` is written into the uploaded
   file — see [Setting the source](#setting-the-source-repobranch))
9. Download `install-jukebox.sh` and run it non-interactively with `--config`
   (output is streamed live, including the path of the installation log
   `INSTALLATION_LOGFILE=...`)
10. Check the reader configuration and the MCP23017
    — see [RFID reader check](#rfid-reader-check) and
    [I2C GPIO expander (MCP23017)](#i2c-gpio-expander-mcp23017)
11. Enable the battery display in the application configuration and restart
    the jukebox service
    — see [Battery display](#battery-display)
12. Check the UPS 3S, the running monitor and the battery display
    — see [Waveshare UPS Module 3S](#waveshare-ups-module-3s-ina219)
13. optionally: reboot the Raspberry Pi (`--reboot`)

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

## Installation over an existing installation

The non-interactive installer can run over an installation that is already on
the Pi: `EXISTING_INSTALL_ACTION=backup` moves it to
`~/RPi-Jukebox-RFID.bak-<timestamp>`, `remove` deletes it. The running
application is not part of that handling, and it matters for the RFID reader:

- The installer's reader registration (`run_register_rfid_reader.py`) exits
  without configuring anything while the jukebox service is active. The service
  of the previous installation is still running, so an installation over an
  existing installation finishes **without a reader**: no entry in
  `shared/settings/rfid.yaml` and no reader dependency in the venv — while the
  installation itself reports success.
- The script therefore stops `jukebox-daemon` before the installation and
  starts it again afterwards, so the reader registration runs and the reader
  support is installed.
- The [RFID reader check](#rfid-reader-check) reports the service state in both
  stages and names the consequence when it is still running (for example when
  stopping it failed because the service does not belong to the SSH user).

The jukebox daemon is a user service of the SSH user
(`systemctl --user jukebox-daemon`), so it is controlled without `sudo`.

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

## I2C GPIO expander (MCP23017)

The [Adafruit MCP23017 I2C GPIO Expander Breakout](https://www.adafruit.com/product/5346)
adds 16 GPIOs over the I2C bus. Set `ENABLE_MCP23017=true` in
`phoniebox.config`; the setup script validates the keys and passes them to the
application installer, which then:

- enables the ARM I2C interface (`dtparam=i2c_arm=on`) and `i2c-dev`
- installs `i2c-tools`
- adds the kernel driver overlay
  `dtoverlay=mcp23017,addr=<address>,noints,i2c<bus>` to the boot configuration
- adds the service user to the groups `i2c` and `gpio`
- creates `shared/settings/mcp23017.yaml` from the application example and
  enables the `mcp23017` module in `shared/settings/jukebox.yaml`

The button-to-action mapping is part of the application; see
[MCP23017 buttons](https://github.com/MiczFlor/RPi-Jukebox-RFID/blob/future3/main/documentation/builders/mcp23017-buttons.md).
The `mcp23017` plugin owns the `GPPU` pull-up registers; no separate service
is installed.

The configuration becomes active with the next reboot. The check in this
script runs after the installation and before the reboot, so it reports
`configured (reboot required)` while the I2C bus is not active yet.

### Driver: kernel or Adafruit CircuitPython?

The application installer uses the **Linux kernel driver**
(`pinctrl-mcp23s08_i2c`, driver name `mcp230xx`). It binds to the chip through
the device-tree overlay and exposes the 16 GPIOs as a `gpiochip`, which is the
same access model the PowerBlock uses through libgpiod. It needs no Python
package and survives a reinstallation of the application.

Adafruit's guide uses the CircuitPython library
`adafruit-circuitpython-mcp230xx` (with `adafruit-blinka`) instead. That is a
userspace library that talks to `/dev/i2c-*` directly; it does not use the
kernel driver. Do not use it on the same chip while the kernel driver is bound:
both would program the same registers without knowing about each other. If the
application later needs the Adafruit `digitalio` API, disable the overlay
(`ENABLE_MCP23017=false`) and install the library into the application venv
instead.

### Button pull-ups

The MCP23017 has internal pull-ups on every GPIO, but they are **off by
default** (`GPPU` = 0). The Adafruit breakout does not add external resistors
on `GPA`/`GPB`; only the I2C lines have 10 kΩ pull-ups. The kernel/libgpiod
bias path does not reliably program `GPPU` on the Pi, so the `mcp23017` plugin
writes the registers directly with `i2cset -f` when it starts and verifies the
readback with `i2cget -f`:

```bash
i2cget -f -y 1 0x20 0x0c     # GPPUA, set for the configured internal pull-ups
i2cget -f -y 1 0x20 0x0d     # GPPUB
```

The plugin derives the mask from the buttons in
`shared/settings/mcp23017.yaml` that use `pull_up: internal`. There is no
separate service and no `MCP23017_PULLUP_MASK` key in `phoniebox.config`.

### Addresses and collisions

The MCP23017 responds on `0x20`-`0x27`; the breakout selects the address with
the `A0`/`A1`/`A2` jumpers. The default is `0x20`.

Power the breakout from **3V3** (pin 1), not from 5V: the board's I2C pull-ups
reference VIN, and 5V on SDA/SCL is not safe for the Raspberry Pi.

The PowerBlock is **not an I2C device**. Its driver uses GPIO 17 (status) and
GPIO 18 (shutdown) through gpiod; `/etc/powerblockconfig.cfg` holds those pin
numbers. It has no I2C address at all, so it cannot collide with the expander.
The only shared resource is the 40-pin header, which the G341 1-to-2 extension
adapter duplicates for both boards.

| Device | Address |
| --- | --- |
| MCP23017 (default) | `0x20` (range `0x20`-`0x27`) |
| PN532 RFID reader (I2C) | `0x24` |
| MFRC522 RFID reader (I2C) | `0x28` |
| SSD1306 OLED display | `0x3C` |
| INA219 battery monitor (core plugin) | `0x40` |
| Waveshare UPS Module 3S (INA219) | `0x41` |
| ADS1015 battery monitor | `0x48` |
| DS3231 real-time clock (common) | `0x68` |
| PowerBlock | no I2C address (GPIO 17/18) |

`0x20` is free with the devices above. The range also overlaps with other port
expanders (for example a PCF8574 at `0x20`-`0x27`). If such a device is already
on the bus, set `MCP23017_ADDRESS` to a free address and close the matching
jumpers on the breakout.

### Configuration

```bash
ENABLE_MCP23017=true
MCP23017_ADDRESS=0x20
MCP23017_I2C_BUS=1
```

The keys are passed through to `install-jukebox.sh --config`, so the installer
validates them and writes the I2C interface, the overlay and the application
settings. A direct run of `install-jukebox.sh --config phoniebox.config`
configures the expander as well. The address must be in `0x20`-`0x27` and the
bus in `0`-`6`; the setup script aborts before the upload when a value is
invalid.

### Verification on the Pi

```bash
# The device answers. "UU" means the kernel driver is bound; a numeric value
# (for example "20") means the chip answers but the driver is not active yet.
i2cdetect -y 1

# The kernel client and its driver
cat /sys/bus/i2c/devices/1-0020/name          # mcp23017
readlink /sys/bus/i2c/devices/1-0020/driver   # .../drivers/mcp230xx
i2cget -f -y 1 0x20 0x0c                      # GPPUA
i2cget -f -y 1 0x20 0x0d                      # GPPUB

# The 16 additional lines
gpioinfo | grep -A 16 '16 lines'
```

After the reboot, the application reports the plugin state and the configured
buttons:

```bash
cd ~/RPi-Jukebox-RFID
tools/run_rpc_tool.sh -c mcp23017.ctrl.get_status
tools/run_rpc_tool.sh -c mcp23017.ctrl.list_buttons
tools/run_configure_mcp23017_buttons.sh --probe
```

### Boot configuration

The application installer appends one block to `/boot/firmware/config.txt`
(or `/boot/config.txt`) and keeps a backup next to it (`config.txt.orig`,
created by `config_file_backup`):

```text
[all]
dtparam=i2c_arm=on
# MCP23017 I2C GPIO expander (Adafruit 5346)
dtoverlay=mcp23017,addr=0x20,noints,i2c1
```

`noints` is intentional: without it the overlay claims GPIO4 for the INTA
signal. The Adafruit breakout does not wire INTA by default, and GPIO4 stays
free for other hardware. Repeated installer runs keep exactly one block.

`i2c-dev` is written to `/etc/modules-load.d/i2c-dev.conf`; it provides
`/dev/i2c-*` for `i2c-tools` and userspace libraries. The kernel driver itself
only needs the I2C controller.

## Waveshare UPS Module 3S (INA219)

The [Waveshare UPS Module 3S](https://www.waveshare.com/wiki/UPS_Module_3S)
reports battery voltage, current, power and percentage through an **INA219 at
I2C address `0x41`**. Its data interface is the I2C bus (SDA/SCL on the 40-pin
header), **not a free GPIO line**. It therefore does not use GPIO17/18 and does
not collide with the PowerBlock or with the MCP23017 at `0x20`.

`ENABLE_UPS3S=true` installs a small monitor service:

- reads the INA219 every `UPS3S_INTERVAL` seconds
- logs one line per reading to the journal
- writes the latest reading to `/run/ups3s/status.json`
- runs as the SSH user with the `i2c` group and retries while the module is
  missing, so the service can stay enabled before the board is connected

The module is powered from the battery; its I2C lines are 3.3 V. The address
`0x41` is fixed by the module. The INA219 measures the **3S battery side**, not
the 5 V output rail.

### Configuration

```bash
ENABLE_UPS3S=true
UPS3S_I2C_BUS=1
UPS3S_I2C_ADDRESS=0x41
UPS3S_INTERVAL=10
```

Further values are in `/etc/ups3s-monitor.conf`; changes take effect after
`sudo systemctl restart ups3s-monitor`:

| Key | Default | Meaning |
| --- | --- | --- |
| `UPS3S_SHUNT_OHMS` | `0.01` | Shunt on the UPS board |
| `UPS3S_MAX_CURRENT_A` | `5` | Calibration range of the INA219 |
| `UPS3S_CELLS` | `3` | 3S pack; percentage window 9.0 V–12.6 V |
| `UPS3S_CHARGING_THRESHOLD_MA` | `50` | Current above this is charging |
| `UPS3S_DISCHARGING_THRESHOLD_MA` | `200` | Current below minus this is discharging |
| `UPS3S_CURRENT_SIGN` | `1` | Flip to `-1` if charging/discharging are reversed |

The percentage uses the vendor formula
`(bus voltage - 9.0 V) / 3.6 V * 100`, clamped to 0–100 %.

### Battery display

The setup enables the battery plugin of the application in
`~/RPi-Jukebox-RFID/shared/settings/jukebox.yaml`:

- `modules.named.battmon: battery_monitor.batt_mon_json_file`
- a `battmon` block that reads `/run/ups3s/status.json`, maps the monitor fields
  onto the canonical battery fields and sets the thresholds for a 3S pack

The block is delimited by `# BEGIN battmon` and `# END battmon`. A repeated run
replaces it; `ENABLE_UPS3S=false` removes it again. The jukebox service is
restarted afterwards, so the plugin loads without a reboot.

The thresholds live in the application, not in this setup: warning at or below
20 %, all-clear at or above 90 %, shutdown at or below 10 %. The single-cell
voltage thresholds are disabled, because the pack has three cells. Adjust the
values in `shared/settings/jukebox.yaml` when the pack behaves differently.

### Verification on the Pi

```bash
systemctl status ups3s-monitor
journalctl -u ups3s-monitor -n 20
cat /run/ups3s/status.json
i2cdetect -y 1          # 41: 41 (userspace monitor), no UU
```

The monitor is a userspace reader and needs exclusive access to the INA219.
The setup refuses to configure it when a kernel driver (for example `ina2xx`)
is bound to `0x41`.

The monitor only produces the status file. The display, the thresholds and the
shutdown belong to the application: the `battmon` plugin reads the file and
publishes `batt_status`, which the Web App renders. See
[Battery display](#battery-display).

### Power path

The UPS 3S has a 5 V output. Do not connect the UPS 5 V output and the
PowerBlock 5 V output to the Pi's 5 V rail at the same time: these are two
regulated sources. Use one path, for example:

```text
UPS 3S 5V output -> PowerBlock 5V input -> Raspberry Pi
```

The UPS 3.3 V output (300 mA) is for small accessories; do not use it to
backfeed the Pi's 3.3 V rail. The PowerBlock's GPIO17/18 stay free.

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

Next to the hardware, the check reports the prerequisites the reader needs at
runtime:

| Prerequisite | Checked as |
| --- | --- |
| Python support | the reader's package in the venv of the application (`nfc`, `evdev`, `pirc522`, `py532lib`, `mfrc522_i2c`, `serial`) |
| Device access for `generic_nfcpy` | the udev rule `/etc/udev/rules.d/50-usb-nfc-rule.rules` and whether it covers the configured `usb:<id>` |
| Kernel driver | loaded `pn533_usb`/`port100` modules without the blacklist of the reader setup — they take the reader away from nfcpy |
| Group membership | `plugdev` for USB readers, `dialout` for serial readers |
| Jukebox service | a running `jukebox-daemon`, see [Installation over an existing installation](#installation-over-an-existing-installation) |

A missing package before the installation is a note: the installation installs
it with `RFID_READER_DEPS=auto`. After the installation, and with
`RFID_READER_DEPS=no`, it is a warning with the command that installs it.

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
- **The MCP23017 is not detected** — the check only warns, it does not abort.
  Check that the breakout is connected to 3V3/GND/SDA/SCL, that the A0/A1/A2
  jumpers match `MCP23017_ADDRESS`, and that `i2cdetect -y 1` shows the address.
  The chip is detected by the kernel driver after the reboot.
- **The MCP23017 reports an address conflict** — another device already answers
  on the configured address. `i2cdetect -y 1` shows which address is used; set
  `MCP23017_ADDRESS` to a free value in `0x20`-`0x27` and close the matching
  jumpers on the breakout.
- **`ENABLE_MCP23017=true` but the expander check says `not configured`** — the
  installer did not write the boot configuration. Check the installation log
  (`~/INSTALL-<id>.log`) for the MCP23017 step and `mcp23017.ctrl.get_status`
  after the reboot.
- **The UPS service is active but reports no reading** — the INA219 does not
  answer at `0x41`. Check the module's 5 V/battery supply, the SDA/SCL wiring
  and `i2cdetect -y 1`. The service keeps retrying, so it starts reading as
  soon as the module is connected.
- **The UPS current sign is reversed** — set `UPS3S_CURRENT_SIGN=-1` in
  `/etc/ups3s-monitor.conf` and run `sudo systemctl restart ups3s-monitor`.
  With the default `1`, positive current means charging.
- **The UPS check reports a kernel driver on `0x41`** — the userspace monitor
  needs exclusive access. Remove the `ina2xx`/`i2c-sensor` overlay or blacklist
  the driver, then restart the service.
- **Two 5 V sources on the Pi** — do not connect the UPS 3S 5 V output and the
  PowerBlock 5 V output to the Pi's 5 V rail at the same time. Use the UPS as
  the input of the PowerBlock (or one of the two, not both).
