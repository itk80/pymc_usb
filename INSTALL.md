# Instalacja — krok po kroku

Wszystkie komendy zakładają, że jesteś w katalogu głównym repo `pymc_usb/`.

## 1. Flash firmware na Heltec V3

### 1a. Gotowe binarki (bez PlatformIO) — zalecane dla użytkowników końcowych

W `firmware/` leżą trzy gotowe pliki v0.5.9:
- `bootloader.bin` (15 kB, offset 0x0)
- `partitions.bin` (3 kB, offset 0x8000)
- `firmware.bin` (841 kB, offset 0x10000)

```bash
pip install esptool

# Pełny flash (czysty Heltec, pierwszy raz):
esptool.py --chip esp32s3 --port /dev/ttyUSB0 --baud 921600 write_flash \
    0x0     firmware/bootloader.bin \
    0x8000  firmware/partitions.bin \
    0x10000 firmware/firmware.bin

# Aktualizacja samego firmware (Heltec z już wgranym bootloaderem):
esptool.py --chip esp32s3 --port /dev/ttyUSB0 --baud 921600 write_flash \
    0x10000 firmware/firmware.bin
```

Na macOS port to zwykle `/dev/cu.usbserial-*`. Jeśli Heltec nie wejdzie w tryb flash automatycznie, przytrzymaj **BOOT** podczas podłączania USB i puść po starcie `esptool.py`. Po flashu naciśnij **RST** albo przepnij USB.

### 1b. Build + flash przez PlatformIO (dla developerów)

```bash
cd firmware
pio run -e heltec_v3 -t upload
```

### 1c. OTA update przez WiFi (po pierwszym flashu — bez kabla)

Gdy Heltec jest sprovisjonowany i widoczny pod mDNS `heltec-<MAC3>.local`:

```bash
# W katalogu firmware/
pio run -e heltec_v3 -t upload --upload-port heltec-3e2834.local

# Albo HTTP bez PlatformIO:
curl -F firmware=@firmware/firmware.bin http://heltec-3e2834.local/update
```

Heltec zrebootuje się po zakończeniu uploadu. Stary firmware **NIE cofa się automatycznie** jeśli nowy okaże się zepsuty — musisz mieć możliwość fizycznego dostępu do kabla USB jako fallback.

## 2. Podłączenie przez USB (tryb `usb_heltec`)

```bash
ls -la /dev/ttyACM* /dev/ttyUSB*
```

Zwykle `/dev/ttyUSB0` (CP2102) albo `/dev/ttyACM0` (native CDC). Udev rule żeby mieć stabilny symlink:

```bash
sudo tee /etc/udev/rules.d/99-lora-modem.rules << 'EOF'
SUBSYSTEM=="tty", ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", SYMLINK+="lora-modem", MODE="0666"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger
```

(VID/PID `10c4:ea60` to CP2102 na Heltec V3; dla native USB-CDC byłoby `303a:1001`.)

## 3. Konfiguracja WiFi (opcjonalnie, dla trybu `tcp_heltec`)

Przy pierwszym boot Heltec wchodzi w tryb AP `LoRa-Modem-XXXX`. Telefon/laptop łączy się z tą siecią, otwierasz `http://192.168.4.1`, wybierasz swoje WiFi + hasło, Save & Restart.

Alternatywnie — **provisioning przez USB** (nie wymaga fizycznego dostępu do Helteca):

```python
import asyncio
from pymc_driver.usb_radio import USBLoRaRadio

async def provision():
    r = USBLoRaRadio(port="/dev/ttyUSB0")
    r.begin()
    resp = await r.set_wifi_credentials(
        ssid="MyLAN", password="...",
        tcp_port=5055, tcp_token="",   # token="" = open LAN
    )
    print(resp)   # device reboots into STA; reconnect after ~10s
    r.cleanup()

asyncio.run(provision())
```

Po restarcie Heltec zgłasza się w LAN — sprawdź stan:

```python
async def check():
    r = USBLoRaRadio(port="/dev/ttyUSB0")
    r.begin()
    status = await r.get_wifi_status()
    print(status)   # {'mode_name': 'sta', 'ip': '192.168.5.3', 'mdns': 'heltec-3e2834.local', ...}
```

## 4. Test połączenia (bez pymc_core)

```bash
pip install pyserial
python3 pymc_driver/test_modem.py /dev/ttyUSB0
```

Powinieneś zobaczyć `PONG`, `CONFIG_RESP`, `STATUS_RESP`, `CAD_RESP`, `TX_DONE`.

## 5. Integracja z pymc_core

### 5a. Tryb USB (`radio_type: usb_heltec`)

Skopiuj driver:

```bash
cp pymc_driver/usb_radio.py /usr/local/lib/python3.13/dist-packages/pymc_core/hardware/usb_radio.py
# lub zależnie od miejsca instalacji pymc_core
```

Zmodyfikuj `pymc_core/hardware/__init__.py` — wzorzec w `patches/hardware__init__.py`:

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

Zmodyfikuj `pymc_core/examples/common.py::create_radio()` — wzorzec w `patches/common.py`:

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

### 5b. Tryb WiFi/TCP (`radio_type: tcp_heltec`) — bez kabla

Upstream pymc_core ma `TCPLoRaRadio` w `pymc_core/hardware/tcp_radio.py` — nic nie trzeba kopiować jeśli masz aktualny pymc_core.

Pełna konfiguracja `/etc/pymc_repeater/config.yaml`:

```yaml
radio_type: tcp_heltec

radio:
  frequency: 869618000       # MeshCore EU Narrow / Switzerland
  bandwidth: 62500
  spreading_factor: 8
  coding_rate: 8             # 4/8
  tx_power: 22
  sync_word: 18              # 0x12 private
  preamble_length: 16
  cad:
    peak_threshold: 23
    min_threshold: 11

tcp_heltec:
  host: 192.168.5.3          # IP Helteca w LAN
  port: 5055
  token: ""                  # puste = open LAN
  connect_timeout: 5.0
  lbt_enabled: true
  lbt_max_attempts: 5

# alternatywa — gdy radio_type: usb_heltec:
# usb_heltec:
#   port: /dev/ttyUSB0
#   baudrate: 921600
#   lbt_enabled: true
#   lbt_max_attempts: 5
```

## 6. Uruchomienie repeatera

```bash
sudo systemctl restart pymc-repeater
sudo journalctl -u pymc-repeater -f
```

W logach powinieneś zobaczyć:
```
TCPLoRaRadio configured: 192.168.5.3:5055 (auth=open), freq=869.6MHz, ...
TCP connected to 192.168.5.3:5055
Modem PONG received — alive
Radio configured: 869.6MHz SF8 BW62kHz 22dBm sync=0x0012 pre=16
CAD thresholds pushed peak=23 min=11: OK
RX callback registered
Retransmitted packet (X bytes, Yms airtime)   ← mesh forwarding działa
```

## 7. Verification checklist

- **Firmware wersja:** OLED boot splash pokazuje `v0.5.9`. Albo programowo:
  ```python
  await radio.get_version()   # "v0.5.9"
  ```
- **OLED screen cycle** (krótkie tapnięcia PRG): SLEEP → STATUS → RADIO → DIAGNOSTICS.
  Ekran RADIO pokazuje aktualne parametry chipa (freq, SF, BW, CR, power, sync, preamble).
  Ekran DIAGNOSTICS pokazuje uptime, IP klienta TCP, wiek ostatniego CMD z USB, liczniki RX/TX/CRC.
- **Uptime rośnie** — nie zerowany co 60 s (to był objaw firmware hang v0.5.4 → v0.5.8).
- **CAD działa** — w logach repeater'a `Modem error: 0x07` powinien być **rzadki**, nie częsty. Dla SF8/62.5k ~27% fail to norma (SX1262 quirk).

## Podsumowanie — które pliki idą gdzie

| Plik u nas            | Przeznaczenie                                    |
|-----------------------|--------------------------------------------------|
| `firmware/*.bin`      | flash na Heltec (esptool lub OTA)               |
| `pymc_driver/usb_radio.py` | `→ pymc_core/hardware/usb_radio.py`       |
| `patches/hardware__init__.py` | wzorzec dla `pymc_core/hardware/__init__.py` |
| `patches/common.py`   | wzorzec dla `pymc_core/examples/common.py`      |

Żaden istniejący plik pymc_core nie wymaga modyfikacji poza `__init__.py` oraz `common.py` (gałąź `usb_heltec`). Driver `usb_radio.py` jest samodzielny — wymaga tylko `pyserial`.
