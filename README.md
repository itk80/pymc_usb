# pymc_usb — USB/TCP LoRa Modem for pymc_core

Firmware + Python driver that turns an ESP32-S3 board with an SX1262
front end into a "dumb" LoRa modem controlled from a Raspberry Pi over
USB-CDC or Wi-Fi/TCP.

**Supported boards** (one source tree, picked at compile time):

- **Heltec WiFi LoRa 32 V3** — ESP32-S3 + bare SX1262, integrated OLED
- **Ikoka Stick** ([ndoo/ikoka-stick-meshtastic-device](https://github.com/ndoo/ikoka-stick-meshtastic-device)) — XIAO ESP32-S3 + Ebyte E22-P868M30S (SX1262 + PA + LNA, 30 dBm) + external SSD1306

Drop-in replacement for `SX1262Radio` in pymc_core — all MeshCore logic
(routing, encryption, retransmission) runs on the RPi. The modem handles
only the SX1262 physical layer: TX, RX, CAD, LoRa parameter configuration.

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
- **Wi-Fi/TCP mode** — no cable; modem can live anywhere on the LAN while the
  Pi sits elsewhere. Provisioned once via on-device AP portal (open AP
  `LoRa-Modem-XXXX` → `http://192.168.4.1`) or over USB with
  `USBLoRaRadio.set_wifi_credentials()`.

## Project layout

```
pymc_usb/
├── firmware/                      # Shared firmware tree (PlatformIO)
│   ├── platformio.ini             # two envs: heltec_v3 + ikoka_stick
│   ├── build_release.sh           # builds every env + copies binaries below
│   ├── heltec_v3/                 # prebuilt for Heltec V3
│   │   ├── bootloader.bin         #   offset 0x0
│   │   ├── partitions.bin         #   offset 0x8000
│   │   └── firmware.bin           #   offset 0x10000
│   ├── ikoka_stick/               # prebuilt for Ikoka Stick (XIAO + E22-P)
│   │   ├── bootloader.bin
│   │   ├── partitions.bin
│   │   └── firmware.bin
│   ├── include/
│   │   ├── protocol.h             # Binary protocol (shared FW ↔ Python)
│   │   ├── board_config.h         # BoardConfig + RfSwitchPolicy types
│   │   ├── boards/
│   │   │   ├── heltec_v3.h        # Pin map + RF switch policy per board
│   │   │   └── ikoka_stick.h
│   │   ├── oled_display.h
│   │   ├── wifi_manager.h
│   │   ├── tcp_server.h
│   │   ├── config_portal.h
│   │   ├── frame_parser.h
│   │   └── ota_manager.h
│   └── src/                       # All .cpp counterparts + main.cpp
│
├── pymc_driver/                   # Python drivers for pymc_core
│   ├── __init__.py
│   ├── usb_radio.py               # USBLoRaRadio — LoRaRadio over USB-CDC
│   ├── tcp_radio.py               # TCPLoRaRadio — LoRaRadio over WiFi/TCP
│   └── test_modem.py              # Standalone test (pyserial only)
│
├── patches/                       # Files applied by scripts/install.sh
│   ├── common.py                  # → pymc_core examples/common.py
│   ├── hardware__init__.py        # → pymc_core/hardware/__init__.py
│   ├── radio-settings-additions.json  # merged into pymc_repeater radio-settings.json
│   ├── pymc_tcp_endpoints.py      # 3 CherryPy methods injected into api_endpoints.py
│   ├── pymc_tcp_panel.html        # pymc_tcp config panel served at /api/pymc_tcp
│   └── pymc_tcp_setup_panel.js    # /setup wizard inline host/port/token block
│
├── scripts/
│   └── install.sh                 # one-shot: copy drivers + patch pymc_repeater
│
├── docker/                        # Container deployment (Wi-Fi/TCP by default)
│   ├── Dockerfile                 # build with: docker compose build
│   ├── entrypoint.sh              # config seed + env-var overrides
│   └── config.yaml                # baked-in /etc/pymc_repeater/config.yaml.default
│
├── docker-compose.yml             # one-shot: `docker compose up -d --build`
├── config.yaml.example            # example /etc/pymc_repeater/config.yaml
├── README.md
├── LICENSE
└── INSTALL.md
```

## Installation

Native install, Docker deployment, firmware flashing (esptool / PlatformIO /
OTA), Wi-Fi provisioning and the full pymc_core integration steps are
documented in [INSTALL.md](INSTALL.md).

## Per-board pin map

All board-specific GPIOs live in `firmware/include/boards/<name>.h`.
Adding a new SX1262 carrier board is a one-file job — copy one of the
existing headers and edit pins / RF-switch policy.

| | Heltec V3 | Ikoka Stick |
|--|--|--|
| MCU | ESP32-S3 (built-in) | XIAO ESP32-S3 (socketed) |
| LoRa front end | bare SX1262 | Ebyte E22-P868M30S (SX1262 + PA + LNA) |
| LoRa SPI NSS / RST / BUSY / DIO1 | 8 / 12 / 13 / 14 | 5 / 3 / 4 / 2 |
| OLED I2C SDA / SCL / RST | 17 / 18 / 21 | 43 / 44 / — |
| OLED VEXT enable (active-LOW) | 36 | — (powered from 3V3) |
| User button (PRG) | GPIO 0 | GPIO 1 (D0) |
| Max TX power | 22 dBm | **30 dBm** (firmware ceiling) |
| RF switch policy | DIO2 → SX1262 internal | EN held HIGH + DIO2 → external TXEN trace |
| mDNS hostname | `heltec-<MAC3>.local` | `ikoka-<MAC3>.local` |

### E22-P RF switch handling (Ikoka & future Ebyte boards)

The E22-P series exposes two control pins per the [E22 datasheet §4.2
truth table](_incoming/E22P-xxxMxxS_UserManual_FR_v1.1.pdf):

| EN | T/R CTRL | Mode |
|---|---|---|
| 1 | 1 | TX |
| 1 | 0 | RX |
| 0 | × | CLOSE |

On Ikoka the firmware drives them like this:

- **EN (module pin 6, GPIO 6)** — held LOW for 5 s at boot so the LDOs
  and PA bias settle, then latched HIGH for the rest of the device's
  lifetime. Never toggled by TX/RX.
- **T/R CTRL (module pin 7)** — not wired to MCU. The Ikoka PCB has
  a trace from module pin 8 (SX1262 DIO2) to pin 7, and firmware
  enables `radio.setDio2AsRfSwitch(true)` so the SX1262 toggles it
  HIGH on TX automatically.

The full policy is captured per-board in `RfSwitchPolicy`
(see `firmware/include/board_config.h`); a future board with two
separate MCU-driven enable lines just sets `rx_pin` / `tx_pin` and
RadioLib's `setRfSwitchPins` takes care of toggling.

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
