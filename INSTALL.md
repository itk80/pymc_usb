# Installation — step by step

All commands assume you are in the repository root `pymc_usb/`.

## 1. Flash the firmware on a Heltec V3

### 1a. Prebuilt binaries (no PlatformIO) — recommended for end users

`firmware/` ships three prebuilt v0.5.9 artefacts:

- `bootloader.bin` (15 kB, offset `0x0`)
- `partitions.bin` (3 kB, offset `0x8000`)
- `firmware.bin` (841 kB, offset `0x10000`)

```bash
pip install esptool

# Full flash (fresh Heltec, first install):
esptool.py --chip esp32s3 --port /dev/ttyUSB0 --baud 921600 write_flash \
    0x0     firmware/bootloader.bin \
    0x8000  firmware/partitions.bin \
    0x10000 firmware/firmware.bin

# App-only update (Heltec that already has a matching bootloader):
esptool.py --chip esp32s3 --port /dev/ttyUSB0 --baud 921600 write_flash \
    0x10000 firmware/firmware.bin
```

On macOS the port is usually `/dev/cu.usbserial-*`. If the Heltec doesn't
enter flash mode automatically, hold **BOOT** while plugging in USB and
release it once `esptool.py` starts. After flashing press **RST** or
replug USB.

### 1b. Build and flash with PlatformIO (for developers)

```bash
cd firmware
pio run -e heltec_v3 -t upload
```

### 1c. OTA update over WiFi (after the first flash — no cable)

Once the Heltec is provisioned and visible via mDNS (`heltec-<mac3>.local`):

```bash
# From firmware/
pio run -e heltec_v3 -t upload --upload-port heltec-3e2834.local

# Or plain HTTP without PlatformIO:
curl -F firmware=@firmware/firmware.bin http://heltec-3e2834.local/update
```

The Heltec reboots automatically after upload. The old firmware is **not**
rolled back automatically if the new image is broken — keep the USB cable
as a fallback for recovery.

## 2. USB connection (`usb_heltec` radio type)

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

## 3. WiFi configuration (optional, for `tcp_heltec` mode)

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
    # {'mode_name': 'sta', 'ip': '192.168.5.3',
    #  'mdns': 'heltec-3e2834.local', ...}
```

## 4. Standalone connection test (no pymc_core)

```bash
pip install pyserial
python3 pymc_driver/test_modem.py /dev/ttyUSB0
```

You should see `PONG`, `CONFIG_RESP`, `STATUS_RESP`, `CAD_RESP`, `TX_DONE`.

## 5. Integration with pymc_core

### 5a. USB mode (`radio_type: usb_heltec`)

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
if radio_type == "usb_heltec":
    from pymc_core.hardware.usb_radio import USBLoRaRadio
    return USBLoRaRadio(
        port=config["usb_heltec"]["port"],
        baudrate=config["usb_heltec"].get("baudrate", 921600),
        frequency=config["radio"]["frequency"],
        bandwidth=config["radio"]["bandwidth"],
        spreading_factor=config["radio"]["spreading_factor"],
        coding_rate=config["radio"]["coding_rate"],
        tx_power=config["radio"]["tx_power"],
        sync_word=config["radio"].get("sync_word", 0x12),
        preamble_length=config["radio"].get("preamble_length", 16),
    )
```

### 5b. WiFi/TCP mode (`radio_type: tcp_heltec`) — no cable

Upstream `pymc_core` ships `TCPLoRaRadio` in `pymc_core/hardware/tcp_radio.py`
— nothing to copy if your `pymc_core` is up-to-date.

Example `/etc/pymc_repeater/config.yaml`:

```yaml
radio_type: tcp_heltec

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

tcp_heltec:
  host: 192.168.5.3          # Heltec LAN IP
  port: 5055
  token: ""                  # empty = open LAN
  connect_timeout: 5.0
  lbt_enabled: true
  lbt_max_attempts: 5

# Alternative — when radio_type is usb_heltec:
# usb_heltec:
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
TCPLoRaRadio configured: 192.168.5.3:5055 (auth=open), freq=869.6MHz, ...
TCP connected to 192.168.5.3:5055
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

## File placement summary

| Source file              | Destination                                  |
|--------------------------|----------------------------------------------|
| `firmware/*.bin`         | flashed onto the Heltec (esptool or OTA)    |
| `pymc_driver/usb_radio.py` | → `pymc_core/hardware/usb_radio.py`        |
| `patches/hardware__init__.py` | template for `pymc_core/hardware/__init__.py` |
| `patches/common.py`      | template for `pymc_core/examples/common.py` |

No other pymc_core files need modification beyond `__init__.py` and
`common.py` (the `usb_heltec` branch in `create_radio()`). The
`usb_radio.py` driver is self-contained — only `pyserial` is required.
