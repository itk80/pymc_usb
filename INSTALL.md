# Installation — step by step

All commands assume you are in the repository root `pymc_usb/`.

## 1. Flash the firmware

The same source tree builds two binaries; pick the env that matches
your board:

| Board | PlatformIO env | mDNS name |
|---|---|---|
| Heltec WiFi LoRa 32 V3 | `heltec_v3` | `heltec-<mac3>.local` |
| Ikoka Stick (XIAO ESP32-S3 + E22-P868M30S) | `ikoka_stick` | `ikoka-<mac3>.local` |

### 1a. Prebuilt binaries (no PlatformIO) — Heltec V3 only

`firmware/` ships prebuilt artefacts for the Heltec env. For the Ikoka
env build from source (§ 1b) — there are no pre-flashed binaries since
the project doesn't ship hardware.

- `bootloader.bin` (15 kB, offset `0x0`)
- `partitions.bin` (3 kB, offset `0x8000`)
- `firmware.bin`   (~850 kB, offset `0x10000`)

```bash
pip install esptool

# Full flash (fresh board, first install):
esptool.py --chip esp32s3 --port /dev/ttyUSB0 --baud 921600 write_flash \
    0x0     firmware/bootloader.bin \
    0x8000  firmware/partitions.bin \
    0x10000 firmware/firmware.bin

# App-only update (board that already has a matching bootloader):
esptool.py --chip esp32s3 --port /dev/ttyUSB0 --baud 921600 write_flash \
    0x10000 firmware/firmware.bin
```

On macOS the port is usually `/dev/cu.usbserial-*`. If the board doesn't
enter flash mode automatically, hold **BOOT** while plugging in USB and
release it once `esptool.py` starts. After flashing press **RST** or
replug USB.

### 1b. Build and flash with PlatformIO

```bash
cd firmware

# Heltec V3
pio run -e heltec_v3 -t upload

# Ikoka Stick (XIAO ESP32-S3 + E22-P868M30S)
pio run -e ikoka_stick -t upload
```

The XIAO board enters bootloader mode automatically when PlatformIO
issues the reset; if not, double-tap RESET on the XIAO to enter the
Adafruit/SAM-DA bootloader, or hold BOOT while plugging USB.

### 1c. OTA update over Wi-Fi (after the first flash — no cable)

Once the board is provisioned and visible via mDNS:

```bash
# From firmware/ — Heltec
pio run -e heltec_v3 -t upload --upload-port heltec-abcdef.local
# Or plain HTTP:
curl -F firmware=@.pio/build/heltec_v3/firmware.bin http://heltec-abcdef.local/update

# Ikoka
pio run -e ikoka_stick -t upload --upload-port ikoka-abcdef.local
curl -F firmware=@.pio/build/ikoka_stick/firmware.bin http://ikoka-abcdef.local/update
```

The board reboots automatically after upload. The old firmware is **not**
rolled back automatically if the new image is broken — keep the USB cable
as a fallback for recovery.

### Adding a new board

Drop a new file under `firmware/include/boards/<my_board>.h` modelled on
`heltec_v3.h`, add `-DBOARD_MY_BOARD` to a new env in `platformio.ini`,
and a matching `#elif defined(BOARD_MY_BOARD)` arm in `board_config.h`.
The rest of the firmware reads everything through `BOARD.*` and doesn't
need to change.

## 2. USB connection (`pymc_usb` radio type)

```bash
ls -la /dev/ttyACM* /dev/ttyUSB*
```

Usually `/dev/ttyUSB0` (CP2102) or `/dev/ttyACM0` (native CDC). Optional udev
rule for a stable symlink:

```bash
sudo tee /etc/udev/rules.d/99-lora-modem.rules << 'EOF'
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", SYMLINK+="lora-modem", MODE="0666"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger
```

(VID/PID `10c4:ea60` matches the CP2102 on the Heltec V3; for native USB-CDC
use `303a:1001`.)

## 3. WiFi configuration (optional, for `pymc_tcp` mode)

On first boot the Heltec starts an open access point `LoRa-Modem-XXXX`.
Connect a phone/laptop to that AP, open `http://192.168.4.1`, pick your
Wi-Fi + password, hit **Save & Restart**.

Alternatively — **provisioning over USB** (doesn't require physical access
to the Heltec):

```python
import asyncio
from pymc_driver.usb_radio import USBLoRaRadio

async def provision():
    r = USBLoRaRadio(port="/dev/ttyUSB0")
    r.begin()
    resp = await r.set_wifi_credentials(
        ssid="MyLAN", password="...",
        tcp_port=5055, tcp_token="",   # token="" means open LAN
    )
    print(resp)   # device reboots into STA; reconnect after ~10s
    r.cleanup()

asyncio.run(provision())
```

Check the status after reconnect:

```python
async def check():
    r = USBLoRaRadio(port="/dev/ttyUSB0")
    r.begin()
    status = await r.get_wifi_status()
    print(status)
    # {'mode_name': 'sta', 'ip': '192.168.1.50',
    #  'mdns': 'heltec-abcdef.local', ...}
```

## 4. Standalone connection test (no pymc_core)

```bash
pip install pyserial
python3 pymc_driver/test_modem.py /dev/ttyUSB0
```

You should see `PONG`, `CONFIG_RESP`, `STATUS_RESP`, `CAD_RESP`, `TX_DONE`.

## 5. Integration with pymc_core

### Option A — automatic (recommended): `scripts/install.sh`

One script does everything that sections 5a and 5b describe manually:

```bash
sudo scripts/install.sh
```

It will:
1. Locate the installed `pymc_core` via `python3 -c "import pymc_core"`.
2. Copy `pymc_driver/usb_radio.py` and `pymc_driver/tcp_radio.py` into
   `pymc_core/hardware/`.
3. Verify both modules import cleanly.
4. Locate `pymc_repeater/config.py` (tries the installed package first,
   then `/opt/pymc_repeater`, then `/opt/companion/pyMC_Repeater`).
5. Patch `create_radio()` / `get_radio_for_board()` with the `pymc_usb`
   and `pymc_tcp` branches — **only if missing** (guard-string checked,
   so re-running is safe). Each branch also accepts the legacy
   `usb_heltec` / `tcp_heltec` aliases for backward compatibility.
6. Back up the original `config.py` with a timestamped `.bak.` suffix
   before any edit.
7. Print the next steps (flash firmware, configure `/etc/pymc_repeater/config.yaml`,
   restart the service).

Re-run the script after every `pip install --upgrade pymc_core` or
`apt upgrade pymc_repeater` — it will re-copy the drivers and re-patch
`config.py` if the upgrade overwrote them.

### Option B — manual

If you prefer to apply changes by hand (or to adapt them to a non-standard
install layout), use sections 5a / 5b below.

### 5a. USB mode (`radio_type: pymc_usb`)

Copy the driver:

```bash
cp pymc_driver/usb_radio.py /usr/local/lib/python3.13/dist-packages/pymc_core/hardware/usb_radio.py
# adjust the destination path to match your pymc_core install
```

Modify `pymc_core/hardware/__init__.py` — reference template in
`patches/hardware__init__.py`:

```python
try:
    from .usb_radio import USBLoRaRadio
    _USB_AVAILABLE = True
except ImportError:
    _USB_AVAILABLE = False
    USBLoRaRadio = None

if _USB_AVAILABLE:
    __all__.append("USBLoRaRadio")
```

Modify `pymc_core/examples/common.py::create_radio()` — reference template
in `patches/common.py`:

```python
if radio_type in ("pymc_usb", "usb_heltec"):
    from pymc_core.hardware.usb_radio import USBLoRaRadio
    usb_cfg = config.get("pymc_usb") or config.get("usb_heltec") or {}
    return USBLoRaRadio(
        port=usb_cfg["port"],
        baudrate=usb_cfg.get("baudrate", 921600),
        frequency=config["radio"]["frequency"],
        bandwidth=config["radio"]["bandwidth"],
        spreading_factor=config["radio"]["spreading_factor"],
        coding_rate=config["radio"]["coding_rate"],
        tx_power=config["radio"]["tx_power"],
        sync_word=config["radio"].get("sync_word", 0x12),
        preamble_length=config["radio"].get("preamble_length", 16),
    )
```

### 5b. WiFi/TCP mode (`radio_type: pymc_tcp`) — no cable

`TCPLoRaRadio` is **not** part of upstream `pymc_core`. Copy it the same way
you did `usb_radio.py`:

```bash
cp pymc_driver/tcp_radio.py /usr/local/lib/python3.13/dist-packages/pymc_core/hardware/tcp_radio.py
```

Then add a conditional import alongside the USB one in
`pymc_core/hardware/__init__.py`:

```python
try:
    from .tcp_radio import TCPLoRaRadio
    _TCP_AVAILABLE = True
except ImportError:
    _TCP_AVAILABLE = False
    TCPLoRaRadio = None

if _TCP_AVAILABLE:
    __all__.append("TCPLoRaRadio")
```

And a matching branch in `pymc_core/examples/common.py::create_radio()`:

```python
if radio_type in ("pymc_tcp", "tcp_heltec"):
    from pymc_core.hardware.tcp_radio import TCPLoRaRadio
    tcp = config.get("pymc_tcp") or config.get("tcp_heltec") or {}
    return TCPLoRaRadio(
        host=tcp["host"],
        port=int(tcp.get("port", 5055)),
        token=str(tcp.get("token", "") or ""),
        connect_timeout=float(tcp.get("connect_timeout", 5.0)),
        frequency=int(config["radio"]["frequency"]),
        bandwidth=int(config["radio"]["bandwidth"]),
        spreading_factor=int(config["radio"]["spreading_factor"]),
        coding_rate=int(config["radio"]["coding_rate"]),
        tx_power=int(config["radio"]["tx_power"]),
        sync_word=int(config["radio"].get("sync_word", 0x12)),
        preamble_length=int(config["radio"].get("preamble_length", 16)),
        lbt_enabled=tcp.get("lbt_enabled", True),
        lbt_max_attempts=int(tcp.get("lbt_max_attempts", 5)),
    )
```

Example `/etc/pymc_repeater/config.yaml`:

```yaml
radio_type: pymc_tcp

radio:
  frequency: 869618000       # MeshCore EU Narrow / Switzerland
  bandwidth: 62500
  spreading_factor: 8
  coding_rate: 8             # 4/8
  tx_power: 22
  sync_word: 18              # 0x12, private
  preamble_length: 16
  cad:
    peak_threshold: 23
    min_threshold: 11

pymc_tcp:
  host: 192.168.1.50          # modem LAN IP or mDNS name
  port: 5055
  token: ""                  # empty = open LAN
  connect_timeout: 5.0
  lbt_enabled: true
  lbt_max_attempts: 5

# Alternative — when radio_type is pymc_usb:
# pymc_usb:
#   port: /dev/ttyUSB0
#   baudrate: 921600
#   lbt_enabled: true
#   lbt_max_attempts: 5
```

## 6. Start the repeater

```bash
sudo systemctl restart pymc-repeater
sudo journalctl -u pymc-repeater -f
```

Expected log lines:

```
TCPLoRaRadio configured: 192.168.1.50:5055 (auth=open), freq=869.6MHz, ...
TCP connected to 192.168.1.50:5055
Modem PONG received — alive
Radio configured: 869.6MHz SF8 BW62kHz 22dBm sync=0x0012 pre=16
CAD thresholds pushed peak=23 min=11: OK
RX callback registered
Retransmitted packet (X bytes, Yms airtime)   ← mesh forwarding is live
```

## 7. Verification checklist

- **Firmware version:** OLED boot splash shows `v0.5.9`. Or programmatically:
  ```python
  await radio.get_version()   # "v0.5.9"
  ```
- **OLED screen cycle** (short PRG taps): SLEEP → STATUS → RADIO → DIAGNOSTICS.
  The RADIO screen shows the live chip configuration (freq, SF, BW, CR,
  power, sync, preamble). The DIAGNOSTICS screen shows uptime, the TCP
  client IP, the age of the last USB command, and RX/TX/CRC counters.
- **Uptime grows monotonically** — it should no longer reset every 60 s
  (that was the firmware-hang symptom fixed between v0.5.4 and v0.5.8).
- **CAD actually works** — `Modem error: 0x07` in the repeater log should
  be infrequent, not routine. Around ~27 % failure at SF8/62.5k is the
  baseline SX1262 IRQ-miss rate (same as on the SPI HAT reference).

## 8. Docker deployment (alternative to native install)

The image at `docker/Dockerfile` bundles pymc_repeater + pymc_core,
runs `scripts/install.sh` at build time so all the patches in §5
(drivers, config.py branches, web setup wizard, pymc_tcp config panel,
JWT exemption, sticky link) land in the same place as a native install.
Default transport is `pymc_tcp` — the modem lives on the LAN and the
container has no need for `--device` or dialout group membership.

### Build and run

```bash
# Set PYMC_TCP_HOST in a .env file next to docker-compose.yml first
# (or leave the placeholder and finish setup from the web UI's
# "pymc_tcp config" panel afterwards).
docker compose up -d --build
docker compose logs -f
```

Dashboard: `http://localhost:8000`. Three host bind mounts under
`./data/` (relative to the compose file) keep config / database / logs
on the host filesystem so they survive `docker rm`, can be backed up
with the usual file tools, and can be edited without `docker exec`:

| Host path             | Container mount             | Purpose                              |
|-----------------------|-----------------------------|--------------------------------------|
| `./data/config/`      | `/etc/pymc_repeater`        | `config.yaml`, identity files        |
| `./data/state/`       | `/var/lib/pymc_repeater`    | `radio-settings.json`, SQLite, MQTT  |
| `./data/logs/`        | `/var/log/pymc_repeater`    | `repeater.log`                       |

The directories are auto-created on first start. The container starts
as root just long enough to chown them to its `repeater` user, then
drops privileges via `gosu` — so the daemon never runs as root and the
files are still owned by the same uid every time.

### Environment variables

The entrypoint applies env-var overrides on every container start —
change a value in `docker-compose.yml` and `docker compose up -d` to
re-stamp the running config.

| Variable                  | Default       | Notes                                      |
|---------------------------|---------------|--------------------------------------------|
| `RADIO_TYPE`              | `pymc_tcp`    | `pymc_tcp` or `pymc_usb`                   |
| `PYMC_TCP_HOST`           | `192.168.1.50`| Modem LAN IP or `ikoka-XXXXXX.local` etc.  |
| `PYMC_TCP_PORT`           | `5055`        | Firmware TCP listener                      |
| `PYMC_TCP_TOKEN`          | *(empty)*     | Match the firmware NVS auth token          |
| `PYMC_TCP_CONNECT_TIMEOUT`| `5.0`         | Seconds — raise on slow Wi-Fi              |
| `SERIAL_PORT`             | `/dev/ttyUSB0`| Used when `RADIO_TYPE=pymc_usb`            |
| `BAUDRATE`                | `921600`      | USB-CDC baudrate (must match firmware)     |
| `NODE_NAME`               | `pyMC_USB_RPT`| Repeater node name in the mesh             |
| `ADMIN_PASSWORD`          | `admin123`    | Web UI admin — change before exposing      |
| `FREQUENCY`               | `869618000`   | Hz                                         |
| `TX_POWER`                | `22`          | dBm                                        |
| `BANDWIDTH`               | `62500`       | Hz                                         |
| `SPREADING_FACTOR`        | `8`           |                                            |
| `CODING_RATE`             | `8`           | 4/8                                        |
| `SYNC_WORD`               | `18`          | `0x12` (private)                           |
| `PREAMBLE_LENGTH`         | `16`          | symbols                                    |

The legacy `HELTEC_HOST` / `HELTEC_PORT` / `HELTEC_TOKEN` /
`HELTEC_CONNECT_TIMEOUT` env vars are still honoured as fallbacks so
pre-rename `.env` files keep working without edits.

### USB mode in containers

USB-CDC requires passing the device through and matching the dialout group:

```bash
docker run -d --name repeater \
  -p 8000:8000 \
  --device=/dev/ttyUSB0:/dev/ttyUSB0 \
  -e RADIO_TYPE=pymc_usb -e SERIAL_PORT=/dev/ttyUSB0 \
  itkeny/pymc-usb-repeater:latest
```

Or in `docker-compose.yml`, uncomment both `SERIAL_PORT` and the
`devices:` block.

### Deferred-connect

If `PYMC_TCP_HOST` stays at the placeholder (or is left unset), the
container does **not** abort. `TCPLoRaRadio` enters deferred-connect
mode and the entrypoint logs `[WARN] Modem not reachable yet` —
finish provisioning by clicking **pymc_tcp config** in the web UI's
bottom-right corner and entering the real host. The driver reconnects
on the fly with no service restart.

## File placement summary

| Source file                    | Destination                                      |
|--------------------------------|--------------------------------------------------|
| `firmware/*.bin`               | flashed onto the Heltec (esptool or OTA)         |
| `pymc_driver/usb_radio.py`     | → `pymc_core/hardware/usb_radio.py`              |
| `pymc_driver/tcp_radio.py`     | → `pymc_core/hardware/tcp_radio.py`              |
| `patches/hardware__init__.py`  | template for `pymc_core/hardware/__init__.py`    |
| `patches/common.py`            | template for `pymc_core/examples/common.py`      |

Both driver files are self-contained — `usb_radio.py` needs `pyserial`, and
`tcp_radio.py` uses the Python standard library (`socket`, `threading`,
`asyncio`) with no extra dependencies. Neither ships with upstream
`pymc_core`; they live here and get copied into your installed `pymc_core`.
