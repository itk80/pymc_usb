# Heltec LoRa Modem — USB/TCP Radio Driver for pymc_core

Firmware + Python driver that turns a **Heltec WiFi LoRa 32 V3** (ESP32-S3 + SX1262)
into a "dumb" LoRa modem controlled from a Raspberry Pi over USB-CDC or WiFi/TCP.

Drop-in replacement for `SX1262Radio` in pymc_core — all MeshCore logic
(routing, encryption, retransmission) runs on the RPi. The Heltec handles only
the SX1262 physical layer: TX, RX, CAD, LoRa parameter configuration.

## Architecture

```
                          USB-CDC / WiFi-TCP
Raspberry Pi                                  Heltec V3
┌────────────────────┐                        ┌─────────────────┐
│ pymc_repeater      │◄ USB 921600 ────────►  │ LoRa Modem FW   │
│  └─ pymc_core      │                        │  └─ SX1262      │
│     ├─ USBLoRaRadio│──── OR ──────          │  └─ RadioLib    │
│     └─ TCPLoRaRadio│◄ TCP 5055 ─────────►   │  └─ OLED status │
│                    │                        │  └─ Wi-Fi STA   │
└────────────────────┘                        └─────────────────┘
```

- **USB mode** — cable, instant, no provisioning; ideal for single-board setups.
- **Wi-Fi/TCP mode** — no cable; Heltec can live anywhere on the LAN while the
  Pi sits elsewhere. Provisioned once via on-device AP portal (open AP
  `LoRa-Modem-XXXX` → `http://192.168.4.1`) or over USB with
  `USBLoRaRadio.set_wifi_credentials()`.

## Project layout

```
pymc_usb/
├── firmware/                      # Heltec V3 firmware (PlatformIO)
│   ├── platformio.ini
│   ├── bootloader.bin             # prebuilt v0.5.9 (offset 0x0)
│   ├── partitions.bin             # prebuilt v0.5.9 (offset 0x8000)
│   ├── firmware.bin               # prebuilt v0.5.9 (offset 0x10000)
│   ├── include/
│   │   ├── protocol.h             # Binary protocol (shared FW ↔ Python)
│   │   ├── oled_display.h
│   │   ├── wifi_manager.h
│   │   ├── tcp_server.h
│   │   ├── config_portal.h
│   │   ├── frame_parser.h
│   │   └── ota_manager.h
│   └── src/                       # All .cpp counterparts + main.cpp
│
├── pymc_driver/                   # Python driver for pymc_core
│   ├── __init__.py
│   ├── usb_radio.py               # USBLoRaRadio — drop-in LoRaRadio impl
│   └── test_modem.py              # Standalone test (pyserial only)
│
├── patches/                       # Files to copy into pymc_core install
│   ├── common.py                  # → pymc_core examples/common.py
│   └── hardware__init__.py        # → pymc_core/hardware/__init__.py
│
├── README.md
└── INSTALL.md
```

## Quick start

### 1. Flash the firmware

No PlatformIO needed — prebuilt binaries live in `firmware/`:

```bash
pip install esptool
esptool.py --chip esp32s3 --port /dev/ttyUSB0 --baud 921600 write_flash \
    0x0     firmware/bootloader.bin \
    0x8000  firmware/partitions.bin \
    0x10000 firmware/firmware.bin
```

Or build from source:

```bash
cd firmware
pio run -e heltec_v3 -t upload
```

See `INSTALL.md` for the full procedure, including OTA updates over WiFi and
Wi-Fi provisioning from the host side.

### 2. Standalone test

```bash
pip install pyserial
python3 pymc_driver/test_modem.py /dev/ttyUSB0
```

You should see `PONG`, `CONFIG_RESP`, `STATUS_RESP`, `CAD_RESP`, `TX_DONE`.

### 3. Integrate with pymc_core

Copy the driver:

```bash
cp pymc_driver/usb_radio.py /path/to/pymc_core/hardware/usb_radio.py
```

Add the conditional import to `pymc_core/hardware/__init__.py`:

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

Usage in code (in place of `SX1262Radio`):

```python
from pymc_core.hardware.usb_radio import USBLoRaRadio

radio = USBLoRaRadio(
    port="/dev/ttyUSB0",            # or /dev/lora-modem (udev)
    frequency=869618000,             # MeshCore EU Narrow / Switzerland
    bandwidth=62500,
    spreading_factor=8,
    coding_rate=8,                   # 4/8
    tx_power=22,
    sync_word=0x12,                  # private LoRa sync word
    preamble_length=16,
)
radio.begin()

# From here the radio behaves exactly like SX1262Radio:
# - Dispatcher calls radio.set_rx_callback() to get packets
# - Packets are sent with `await radio.send(data)`
# - LBT (CAD) is run automatically before TX
```

## Wire protocol v0.5.9

*(Full command list in `firmware/include/protocol.h`; the section below is
summarised.)*

### Frame format

```
┌──────┬──────┬───────┬──────────┬───────┐
│ SYNC │ CMD  │  LEN  │ PAYLOAD  │  CRC  │
│ 0xAA │ 1B   │ 2B LE │  0-255B  │ 2B LE │
└──────┴──────┴───────┴──────────┴───────┘
CRC-16/CCITT (poly 0x1021, init 0xFFFF) over CMD+LEN+PAYLOAD.
```

### Host → Modem

| CMD  | Name              | Payload                               |
|------|-------------------|---------------------------------------|
| 0x01 | TX_REQUEST        | Raw LoRa data (1–255 B)               |
| 0x10 | SET_CONFIG        | `RadioConfig` (14 B)                  |
| 0x11 | GET_CONFIG        | —                                     |
| 0x20 | STATUS_REQ        | —                                     |
| 0x22 | NOISE_REQ         | —                                     |
| 0x30 | CAD_REQUEST       | — (Listen Before Talk)                |
| 0x31 | RX_START          | — (restart RX continuous mode)        |
| 0x34 | SET_CAD_PARAMS    | 4 B: symNum / detPeak / detMin / exit |
| 0x41 | SET_WIFI          | ssid+pass+port+token (variable)       |
| 0x50 | AUTH              | token bytes (TCP only)                |
| 0x60 | WIFI_RESET        | —                                     |
| 0x61 | GET_WIFI          | —                                     |
| 0x70 | GET_VERSION       | —                                     |
| 0xFF | PING              | —                                     |

### Modem → Host

| CMD  | Name              | Payload                               |
|------|-------------------|---------------------------------------|
| 0x02 | TX_DONE           | `airtime_us` (4 B LE)                 |
| 0x03 | TX_FAIL           | —                                     |
| 0x04 | RX_PACKET         | RSSI(2) + SNR(2) + sigRSSI(2) + data  |
| 0x12 | CONFIG_RESP       | `RadioConfig` (14 B)                  |
| 0x21 | STATUS_RESP       | `StatusResp` (24 B)                   |
| 0x23 | NOISE_RESP        | int16 LE (dBm × 10)                   |
| 0x32 | CAD_RESP          | 1 B (0=clear, 1=busy)                 |
| 0x33 | RX_STARTED        | —                                     |
| 0x35 | CAD_PARAMS_RESP   | echoes the 4-byte config              |
| 0x51 | AUTH_OK           | —                                     |
| 0x62 | WIFI_STATUS       | mode + ip + port + ssid + hostname    |
| 0x71 | VERSION_RESP      | ASCII version string                  |
| 0xFE | ERROR             | error code (1 B)                      |
| 0xFF | PONG              | —                                     |

## udev rule (Linux)

```bash
# /etc/udev/rules.d/99-lora-modem.rules
# CP2102 on Heltec V3
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", \
    SYMLINK+="lora-modem", MODE="0666"
```

```bash
sudo udevadm control --reload-rules && sudo udevadm trigger
```

## Default radio parameters

Firmware boots into the MeshCore **EU Narrow / Switzerland** preset; the host
overrides these via `CMD_SET_CONFIG` at `begin()`:

| Parameter    | Value          |
|--------------|----------------|
| Frequency    | 869.618 MHz    |
| Bandwidth    | 62.5 kHz       |
| SF           | 8              |
| CR           | 4/8            |
| TX Power     | 22 dBm         |
| Sync Word    | 0x12 (private) |
| Preamble     | 16 symbols     |
| Header       | Explicit       |
| CRC          | CRC-8          |
| IQ           | Standard       |
| LDRO         | Auto           |

## OLED screens

Short PRG tap cycles through:

1. **SLEEP** (display off after 30 s of idle)
2. **STATUS** — RX/TX counters, SSID, IP, firmware version
3. **RADIO** — current radio config (freq, SF, BW, CR, power, preamble, sync)
4. **DIAGNOSTICS** — uptime, TCP client IP, USB idle time, RX/TX/CRC counters

Long PRG hold (≥3 s at boot) = factory reset: wipes Wi-Fi NVS and reboots into
AP configuration mode.
