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
│   ├── heltec_endpoints.py        # 3 CherryPy methods injected into api_endpoints.py
│   └── heltec_panel.html          # Heltec TCP config panel served at /api/heltec
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
