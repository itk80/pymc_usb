# Heltec LoRa Modem — USB Radio Driver for pymc_core

Firmware + Python driver zamieniający **Heltec WiFi LoRa 32 V3** (ESP32-S3 + SX1262)
w moduł radiowy LoRa sterowany z Raspberry Pi przez USB-CDC.

Drop-in replacement dla `SX1262Radio` w pymc_core — cała logika MeshCore
(routing, szyfrowanie, retransmisja) działa na RPi. Heltec zajmuje się wyłącznie
obsługą SX1262: TX, RX, CAD, konfiguracja parametrów LoRa.

## Architektura

```
Raspberry Pi                      Heltec V3
┌────────────────────┐  USB-CDC  ┌─────────────────┐
│ pymc_repeater      │◄────────►│ LoRa Modem FW   │
│  └─ pymc_core      │ 921600   │  └─ SX1262      │
│     └─ Dispatcher  │ binary   │  └─ RadioLib    │
│     └─ USBLoRaRadio│ protocol │  └─ OLED status │
└────────────────────┘          └─────────────────┘
```

## Struktura projektu

```
pymc_usb/
├── firmware/                      # Heltec V3 firmware (PlatformIO)
│   ├── platformio.ini
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

## Szybki start

### 1. Flash firmware na Heltec V3

```bash
cd firmware
pio run -e heltec_v3 -t upload
```

### 2. Test połączenia

```bash
pip install pyserial
python3 pymc_driver/test_modem.py /dev/ttyACM0
```

### 3. Integracja z pymc_core

Skopiuj driver do pymc_core:

```bash
cp pymc_driver/usb_radio.py /path/to/pymc_core/hardware/usb_radio.py
```

Dodaj import w `pymc_core/hardware/__init__.py`:

```python
# Conditional import for USBLoRaRadio
try:
    from .usb_radio import USBLoRaRadio
    _USB_AVAILABLE = True
except ImportError:
    _USB_AVAILABLE = False
    USBLoRaRadio = None

if _USB_AVAILABLE:
    __all__.append("USBLoRaRadio")
```

Użycie w kodzie (zamiast SX1262Radio):

```python
from pymc_core.hardware.usb_radio import USBLoRaRadio

radio = USBLoRaRadio(
    port="/dev/ttyACM0",       # lub /dev/lora-modem (udev)
    frequency=868000000,
    bandwidth=125000,
    spreading_factor=7,
    coding_rate=5,
    tx_power=22,
    sync_word=0x3444,          # pymc_core default
    preamble_length=12,        # pymc_core default
)
radio.begin()

# Od tego momentu radio działa identycznie jak SX1262Radio:
# - Dispatcher rejestruje rx_callback przez radio.set_rx_callback()
# - Pakiety wysyłane przez await radio.send(data)
# - LBT (CAD) wykonywane automatycznie przed TX
```

## Protokół binarny v0.5.9

*(Pełna lista komend jest w `firmware/include/protocol.h` — sekcja poniżej jest skrócona.)*

### Frame format

```
┌──────┬──────┬───────┬──────────┬───────┐
│ SYNC │ CMD  │  LEN  │ PAYLOAD  │  CRC  │
│ 0xAA │ 1B   │ 2B LE │  0-255B  │ 2B LE │
└──────┴──────┴───────┴──────────┴───────┘
CRC-16/CCITT (0x1021, init 0xFFFF) po CMD+LEN+PAYLOAD
```

### Komendy Host → Modem

| CMD  | Nazwa       | Payload                          |
|------|-------------|----------------------------------|
| 0x01 | TX_REQUEST  | Raw LoRa data (1-255B)           |
| 0x10 | SET_CONFIG  | RadioConfig (14B)                |
| 0x11 | GET_CONFIG  | —                                |
| 0x20 | STATUS_REQ  | —                                |
| 0x30 | CAD_REQUEST | — (Listen Before Talk)           |
| 0x31 | RX_START    | — (restart RX continuous)        |
| 0xFF | PING        | —                                |

### Komendy Modem → Host

| CMD  | Nazwa       | Payload                          |
|------|-------------|----------------------------------|
| 0x02 | TX_DONE     | airtime_us (4B LE)               |
| 0x04 | RX_PACKET   | RSSI(2)+SNR(2)+sigRSSI(2)+data   |
| 0x12 | CONFIG_RESP | RadioConfig (14B)                |
| 0x21 | STATUS_RESP | StatusResp (24B)                 |
| 0x32 | CAD_RESP    | 1B: 0=clear, 1=busy             |
| 0x33 | RX_STARTED  | —                                |
| 0xFE | ERROR       | error code (1B)                  |
| 0xFF | PONG        | —                                |

## udev rule

```bash
# /etc/udev/rules.d/99-lora-modem.rules
SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", ATTRS{idProduct}=="1001", \
    SYMLINK+="lora-modem", MODE="0666"
```

```bash
sudo udevadm control --reload-rules && sudo udevadm trigger
```

## Domyślne parametry (zgodne z pymc_core)

| Parametr    | Wartość     |
|-------------|-------------|
| Frequency   | 868 MHz     |
| Bandwidth   | 125 kHz     |
| SF          | 7           |
| CR          | 4/5         |
| TX Power    | 22 dBm      |
| Sync Word   | 0x3444      |
| Preamble    | 12 symboli  |
| Header      | Explicit    |
| CRC         | CRC-8       |
| IQ          | Standard    |

Firmware startuje na preset MeshCore Switzerland (869.618 MHz / 62.5 kHz / SF8 / 4/8 / syncword 0x12). Host nadpisuje parametry przez `CMD_SET_CONFIG` przy `begin()`.
