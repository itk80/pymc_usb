#!/bin/bash
# =============================================================
# install.sh — Install Heltec LoRa Modem support into pymc_core
# + pymc_repeater.
#
# Copies USBLoRaRadio + TCPLoRaRadio drivers into the installed
# pymc_core, then patches pymc_repeater/config.py to understand
# the `usb_heltec` and `tcp_heltec` radio_type values.
#
# Idempotent — safe to re-run after every pymc_core / pymc_repeater
# upgrade. Existing radio_type branches are detected by guard strings;
# config.py is backed up with a timestamped suffix before edits.
#
# Usage:
#   sudo scripts/install.sh
# =============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "═══════════════════════════════════════════"
echo "  Heltec USB LoRa Modem — Installer"
echo "═══════════════════════════════════════════"

# Check root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root: sudo ./install.sh${NC}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# scripts/install.sh lives one level below the repo root
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── 1. Find pymc_core location ──────────────────────────────
echo ""
echo -e "${YELLOW}[1/5] Finding pymc_core...${NC}"
PYMC_HW=$(python3 -c "import pymc_core; print(pymc_core.__path__[0])" 2>/dev/null)/hardware
if [ ! -d "$PYMC_HW" ]; then
    echo -e "${RED}ERROR: pymc_core not found. Install it first.${NC}"
    exit 1
fi
echo -e "  ${GREEN}Found: $PYMC_HW${NC}"

# ─── 2. Install USB radio driver ─────────────────────────────
echo ""
echo -e "${YELLOW}[2/5] Installing USBLoRaRadio + TCPLoRaRadio drivers...${NC}"
cp "$REPO_DIR/pymc_driver/usb_radio.py" "$PYMC_HW/usb_radio.py"
chmod 644 "$PYMC_HW/usb_radio.py"
echo -e "  ${GREEN}Installed: $PYMC_HW/usb_radio.py${NC}"

cp "$REPO_DIR/pymc_driver/tcp_radio.py" "$PYMC_HW/tcp_radio.py"
chmod 644 "$PYMC_HW/tcp_radio.py"
echo -e "  ${GREEN}Installed: $PYMC_HW/tcp_radio.py${NC}"

# Verify imports work
python3 -c "from pymc_core.hardware.usb_radio import USBLoRaRadio; print('  USB import OK')" || {
    echo -e "${RED}ERROR: USBLoRaRadio import failed${NC}"
    exit 1
}
python3 -c "from pymc_core.hardware.tcp_radio import TCPLoRaRadio; print('  TCP import OK')" || {
    echo -e "${RED}ERROR: TCPLoRaRadio import failed${NC}"
    exit 1
}

# ─── 3. Patch pymc_repeater config.py ─────────────────────────
echo ""
echo -e "${YELLOW}[3/5] Patching pymc_repeater...${NC}"

# Find repeater location (try multiple paths)
RPT_CONFIG=""
for path in \
    "$(python3 -c 'import repeater; print(repeater.__path__[0])' 2>/dev/null)/config.py" \
    "/opt/pymc_repeater/repeater/config.py" \
    "/opt/companion/pyMC_Repeater/repeater/config.py"; do
    if [ -f "$path" ]; then
        RPT_CONFIG="$path"
        break
    fi
done

if [ -z "$RPT_CONFIG" ]; then
    echo -e "${YELLOW}  WARNING: pymc_repeater config.py not found — skipping patch${NC}"
    echo "  You'll need to manually add usb_heltec and tcp_heltec support"
else
    # Make a timestamped backup once if we're going to touch the file
    if ! grep -q "usb_heltec" "$RPT_CONFIG" || ! grep -q "tcp_heltec" "$RPT_CONFIG"; then
        cp "$RPT_CONFIG" "${RPT_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
        echo "  Backed up: ${RPT_CONFIG}.bak.*"
    fi

    # Patch in one Python pass: adds usb_heltec and/or tcp_heltec blocks if missing.
    RPT_CONFIG="$RPT_CONFIG" python3 <<'PATCH_EOF'
import os, re, sys

config_path = os.environ["RPT_CONFIG"]
with open(config_path, "r") as f:
    content = f.read()

USB_BLOCK = '''
    elif radio_type == "usb_heltec":
        from pymc_core.hardware.usb_radio import USBLoRaRadio

        radio_config = board_config.get("radio")
        if not radio_config:
            raise ValueError("Missing 'radio' section in configuration file")

        usb_config = board_config.get("usb_heltec", {})

        radio = USBLoRaRadio(
            port=usb_config.get("port", "/dev/ttyUSB0"),
            baudrate=int(usb_config.get("baudrate", 921600)),
            frequency=int(radio_config["frequency"]),
            tx_power=radio_config["tx_power"],
            spreading_factor=radio_config["spreading_factor"],
            bandwidth=int(radio_config["bandwidth"]),
            coding_rate=radio_config["coding_rate"],
            sync_word=int(str(radio_config.get("sync_word", 18)).strip().rstrip(","), 0) if isinstance(radio_config.get("sync_word", 18), str) else int(radio_config.get("sync_word", 18)),
            preamble_length=radio_config.get("preamble_length", 16),
            lbt_enabled=usb_config.get("lbt_enabled", True),
            lbt_max_attempts=int(usb_config.get("lbt_max_attempts", 5)),
        )

        try:
            radio.begin()
        except Exception as e:
            raise RuntimeError(f"Failed to initialize USB Heltec radio: {e}") from e

        return radio

'''

TCP_BLOCK = '''
    elif radio_type == "tcp_heltec":
        from pymc_core.hardware.tcp_radio import TCPLoRaRadio

        radio_config = board_config.get("radio")
        if not radio_config:
            raise ValueError("Missing 'radio' section in configuration file")

        tcp_config = board_config.get("tcp_heltec", {})
        if not tcp_config.get("host"):
            raise ValueError("tcp_heltec.host is required for radio_type: tcp_heltec")

        radio = TCPLoRaRadio(
            host=tcp_config["host"],
            port=int(tcp_config.get("port", 5055)),
            token=str(tcp_config.get("token", "") or ""),
            connect_timeout=float(tcp_config.get("connect_timeout", 5.0)),
            frequency=int(radio_config["frequency"]),
            tx_power=radio_config["tx_power"],
            spreading_factor=radio_config["spreading_factor"],
            bandwidth=int(radio_config["bandwidth"]),
            coding_rate=radio_config["coding_rate"],
            sync_word=int(str(radio_config.get("sync_word", 18)).strip().rstrip(","), 0) if isinstance(radio_config.get("sync_word", 18), str) else int(radio_config.get("sync_word", 18)),
            preamble_length=radio_config.get("preamble_length", 16),
            lbt_enabled=tcp_config.get("lbt_enabled", True),
            lbt_max_attempts=int(tcp_config.get("lbt_max_attempts", 5)),
        )

        try:
            radio.begin()
        except Exception as e:
            raise RuntimeError(f"Failed to initialize TCP Heltec radio: {e}") from e

        return radio

'''

def insert_block(text, block, guard):
    """Insert block before 'raise RuntimeError("Unknown radio type:')' if guard not present."""
    if guard in text:
        return text, False
    pattern = r'(\n    raise RuntimeError\(\s*\n?\s*f?"Unknown radio type:)'
    m = re.search(pattern, text)
    if not m:
        print(f"  WARNING: Could not find insertion point for {guard}")
        return text, False
    pos = m.start()
    return text[:pos] + block + text[pos:], True

changed = False
content, inserted = insert_block(content, USB_BLOCK, 'radio_type == "usb_heltec"')
if inserted:
    changed = True
    print("  + inserted usb_heltec block")

content, inserted = insert_block(content, TCP_BLOCK, 'radio_type == "tcp_heltec"')
if inserted:
    changed = True
    print("  + inserted tcp_heltec block")

if changed:
    # Extend the error message to list the new radio types.
    for old, new in [
        ('Supported: sx1262"',                                  'Supported: sx1262, usb_heltec, tcp_heltec"'),
        ('Supported: sx1262, usb_heltec"',                      'Supported: sx1262, usb_heltec, tcp_heltec"'),
        ('Supported: sx1262, sx1262_ch341, kiss (or kiss-modem)"',
         'Supported: sx1262, sx1262_ch341, kiss (or kiss-modem), usb_heltec, tcp_heltec"'),
        ('Supported: sx1262, sx1262_ch341, kiss (or kiss-modem), usb_heltec"',
         'Supported: sx1262, sx1262_ch341, kiss (or kiss-modem), usb_heltec, tcp_heltec"'),
    ]:
        content = content.replace(old, new)
    with open(config_path, "w") as f:
        f.write(content)
    print(f"  Patched {config_path}")
else:
    print("  Already patched — nothing to change")
PATCH_EOF

    echo -e "  ${GREEN}config.py ready for usb_heltec + tcp_heltec${NC}"
fi

# ─── 4. Install example config ───────────────────────────────
echo ""
echo -e "${YELLOW}[4/5] Config file...${NC}"
if [ -f /etc/pymc_repeater/config.yaml ]; then
    if grep -q "usb_heltec" /etc/pymc_repeater/config.yaml; then
        echo -e "  ${GREEN}Config already set for usb_heltec${NC}"
    else
        echo "  Current config uses: $(grep 'radio_type' /etc/pymc_repeater/config.yaml 2>/dev/null || echo 'sx1262 (default)')"
        echo ""
        echo "  To switch to USB Heltec, edit /etc/pymc_repeater/config.yaml:"
        echo "    1. Add 'radio_type: usb_heltec' at top level"
        echo "    2. Add 'usb_heltec:' section with port: /dev/ttyUSB0"
        echo "    3. Set sync_word: 18 and preamble_length: 16"
        echo ""
        echo "  Or replace with example config:"
        echo "    sudo cp $REPO_DIR/config.yaml.example /etc/pymc_repeater/config.yaml"
    fi
else
    echo "  No config found at /etc/pymc_repeater/config.yaml"
    echo "  Copy example: sudo cp $REPO_DIR/config.yaml.example /etc/pymc_repeater/config.yaml"
fi

# ─── 5. Check USB device ─────────────────────────────────────
echo ""
echo -e "${YELLOW}[5/5] Checking USB device...${NC}"
if ls /dev/ttyUSB* 2>/dev/null | head -1 > /dev/null; then
    USB_DEV=$(ls /dev/ttyUSB* 2>/dev/null | head -1)
    echo -e "  ${GREEN}Found: $USB_DEV${NC}"
else
    echo -e "  ${YELLOW}No /dev/ttyUSB* found — connect Heltec V3 via USB${NC}"
fi

# ─── Done ─────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════"
echo -e "  ${GREEN}Installation complete!${NC}"
echo ""
echo "  Next steps:"
echo "    1. Flash firmware to Heltec V3:"
echo "         esptool.py --chip esp32s3 --port /dev/ttyUSB0 --baud 921600 \\"
echo "           write_flash 0x0 $REPO_DIR/firmware/bootloader.bin \\"
echo "                       0x8000 $REPO_DIR/firmware/partitions.bin \\"
echo "                       0x10000 $REPO_DIR/firmware/firmware.bin"
echo "    2. Connect Heltec (USB mode) or provision Wi-Fi (TCP mode — see INSTALL.md)"
echo "    3. Test: python3 $REPO_DIR/pymc_driver/test_modem.py /dev/ttyUSB0"
echo "    4. Configure: sudo nano /etc/pymc_repeater/config.yaml"
echo "       (set radio_type: usb_heltec or tcp_heltec)"
echo "    5. Restart: sudo systemctl restart pymc-repeater"
echo "═══════════════════════════════════════════"
