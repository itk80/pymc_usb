# Instalacja — krok po kroku

## 1. Flash firmware na Heltec V3

Na komputerze z VSCode + PlatformIO:

```bash
cd firmware
pio run -e heltec_v3 -t upload
```

## 2. Podłącz Heltec do Raspberry Pi przez USB-C

Sprawdź czy się pojawił:

```bash
ls -la /dev/ttyACM*
# Powinien być /dev/ttyACM0
```

Opcjonalnie — udev rule żeby zawsze był jako /dev/lora-modem:

```bash
sudo tee /etc/udev/rules.d/99-lora-modem.rules << 'EOF'
SUBSYSTEM=="tty", ATTRS{idVendor}=="303a", ATTRS{idProduct}=="1001", SYMLINK+="lora-modem", MODE="0666"
EOF
sudo udevadm control --reload-rules && sudo udevadm trigger
```

## 3. Test połączenia (standalone, bez pymc_core)

```bash
pip install pyserial
python3 pymc_driver/test_modem.py /dev/ttyACM0
```

Powinieneś zobaczyć PONG, CONFIG_RESP, STATUS_RESP, CAD_RESP, TX_DONE.

## 4. Integracja z pymc_core

### 4a. Skopiuj driver do pymc_core

```bash
# Zakładając że pymc_core jest w ~/pyMC_core-main/
cp pymc_driver/usb_radio.py ~/pyMC_core-main/src/pymc_core/hardware/usb_radio.py
```

### 4b. Zmodyfikuj hardware/__init__.py

W pliku `src/pymc_core/hardware/__init__.py` dodaj na końcu (przed `__all__`):

```python
# Conditional import for USBLoRaRadio (requires pyserial)
try:
    from .usb_radio import USBLoRaRadio
    _USB_AVAILABLE = True
except ImportError:
    _USB_AVAILABLE = False
    USBLoRaRadio = None
```

I poniżej, przy budowaniu `__all__`:

```python
if _USB_AVAILABLE:
    __all__.append("USBLoRaRadio")
```

Gotowy plik jest w `patches/hardware__init__.py`.

### 4c. Zmodyfikuj examples/common.py (fabryka radia)

W funkcji `create_radio()` dodaj blok `usb-heltec` — gotowy plik
jest w `patches/common.py`. Kluczowa zmiana:

```python
if radio_type == "usb-heltec":
    from pymc_core.hardware.usb_radio import USBLoRaRadio

    radio = USBLoRaRadio(
        port=serial_port,        # /dev/ttyACM0 lub /dev/lora-modem
        frequency=868000000,
        bandwidth=125000,
        spreading_factor=7,
        coding_rate=5,
        tx_power=22,
        sync_word=0x3444,
        preamble_length=12,
    )
    return radio
```

### 4d. Uruchom pymc_repeater z nowym radio

Wszędzie gdzie wcześniej podawałeś `radio_type="waveshare"` lub inny,
teraz podajesz:

```python
radio_type = "usb-heltec"
serial_port = "/dev/ttyACM0"   # lub "/dev/lora-modem"
```

Przykładowo:

```python
mesh_node, identity = create_mesh_node(
    node_name="MyRepeater",
    radio_type="usb-heltec",
    serial_port="/dev/ttyACM0",
)
await mesh_node.start()
```

Albo jeśli tworzysz radio ręcznie:

```python
from pymc_core.hardware.usb_radio import USBLoRaRadio

radio = USBLoRaRadio(port="/dev/ttyACM0")
radio.begin()
# ... dalej jak zwykle z Dispatcher/MeshNode
```

## 5. Parametry LoRa przez zmienne środowiskowe

Zamiast hardkodować parametry, można je podać przez env:

```bash
export LORA_FREQ=868000000
export LORA_BW=125000
export LORA_SF=7
export LORA_CR=5
export LORA_POWER=22
export LORA_SYNCWORD=0x3444
export LORA_PREAMBLE=12

python3 my_repeater.py --radio usb-heltec --port /dev/ttyACM0
```

Te zmienne są odczytywane w zmodyfikowanym `common.py`.

## Podsumowanie zmian w plikach

```
pymc_core/
└── src/pymc_core/hardware/
    ├── __init__.py          ← dodaj import USBLoRaRadio
    ├── base.py              ← BEZ ZMIAN
    ├── sx1262_wrapper.py    ← BEZ ZMIAN
    ├── kiss_serial_wrapper.py ← BEZ ZMIAN
    └── usb_radio.py         ← NOWY PLIK (skopiuj z pymc_driver/)

examples/
└── common.py                ← dodaj blok "usb-heltec" w create_radio()
```

Żaden istniejący plik pymc_core nie wymaga modyfikacji poza __init__.py.
Driver usb_radio.py jest samodzielny — wymaga tylko `pyserial`.
