#!/bin/bash
# =============================================================
# install.sh — Install Heltec LoRa Modem support into pymc_core
# + pymc_repeater.
#
# Copies USBLoRaRadio + TCPLoRaRadio drivers into the installed
# pymc_core, then patches pymc_repeater/config.py to understand
# the `pymc_usb` and `pymc_tcp` radio_type values (the legacy
# `usb_heltec` / `tcp_heltec` names are still accepted as aliases).
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
echo -e "${YELLOW}[1/7] Finding pymc_core...${NC}"

# pymc_repeater is sometimes installed system-wide (apt / pip --user) and
# sometimes in a self-contained venv (the canonical post-2026 layout uses
# /opt/pymc_repeater/venv). Probe each candidate interpreter until one
# imports pymc_core successfully.
PYMC_PYTHON=""
PYMC_HW=""
for py in \
    "/opt/pymc_repeater/venv/bin/python" \
    "/opt/pymc_repeater/venv/bin/python3" \
    "/opt/companion/pyMC_Repeater/venv/bin/python" \
    "python3"; do
    if [ -x "$py" ] || command -v "$py" >/dev/null 2>&1; then
        candidate=$("$py" -c "import pymc_core, os; print(pymc_core.__path__[0])" 2>/dev/null) || continue
        if [ -n "$candidate" ] && [ -d "$candidate/hardware" ]; then
            PYMC_PYTHON="$py"
            PYMC_HW="$candidate/hardware"
            break
        fi
    fi
done

if [ -z "$PYMC_HW" ]; then
    echo -e "${RED}ERROR: pymc_core not found in any known location:${NC}"
    echo "        - /opt/pymc_repeater/venv/bin/python"
    echo "        - /opt/companion/pyMC_Repeater/venv/bin/python"
    echo "        - system python3"
    echo "        Install pymc_repeater (which pulls pymc_core) first."
    exit 1
fi
echo -e "  ${GREEN}Found: $PYMC_HW${NC}"
echo -e "  ${GREEN}Using interpreter: $PYMC_PYTHON${NC}"

# ─── 2. Install USB radio driver ─────────────────────────────
echo ""
echo -e "${YELLOW}[2/7] Installing USBLoRaRadio + TCPLoRaRadio drivers...${NC}"
cp "$REPO_DIR/pymc_driver/usb_radio.py" "$PYMC_HW/usb_radio.py"
chmod 644 "$PYMC_HW/usb_radio.py"
echo -e "  ${GREEN}Installed: $PYMC_HW/usb_radio.py${NC}"

cp "$REPO_DIR/pymc_driver/tcp_radio.py" "$PYMC_HW/tcp_radio.py"
chmod 644 "$PYMC_HW/tcp_radio.py"
echo -e "  ${GREEN}Installed: $PYMC_HW/tcp_radio.py${NC}"

# Verify imports work
"$PYMC_PYTHON" -c "from pymc_core.hardware.usb_radio import USBLoRaRadio; print('  USB import OK')" || {
    echo -e "${RED}ERROR: USBLoRaRadio import failed${NC}"
    exit 1
}
"$PYMC_PYTHON" -c "from pymc_core.hardware.tcp_radio import TCPLoRaRadio; print('  TCP import OK')" || {
    echo -e "${RED}ERROR: TCPLoRaRadio import failed${NC}"
    exit 1
}

# ─── 3. Patch pymc_repeater config.py ─────────────────────────
echo ""
echo -e "${YELLOW}[3/7] Patching pymc_repeater...${NC}"

# Find repeater location (try multiple paths)
RPT_CONFIG=""
for path in \
    "$("$PYMC_PYTHON" -c 'import repeater; print(repeater.__path__[0])' 2>/dev/null)/config.py" \
    "/opt/pymc_repeater/repeater/config.py" \
    "/opt/companion/pyMC_Repeater/repeater/config.py"; do
    if [ -f "$path" ]; then
        RPT_CONFIG="$path"
        break
    fi
done

if [ -z "$RPT_CONFIG" ]; then
    echo -e "${YELLOW}  WARNING: pymc_repeater config.py not found — skipping patch${NC}"
    echo "  You'll need to manually add pymc_usb and pymc_tcp support"
else
    # Make a timestamped backup once if we're going to touch the file
    if ! grep -q "pymc_usb" "$RPT_CONFIG" || ! grep -q "pymc_tcp" "$RPT_CONFIG"; then
        cp "$RPT_CONFIG" "${RPT_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
        echo "  Backed up: ${RPT_CONFIG}.bak.*"
    fi

    # Patch in one Python pass: adds pymc_usb and/or pymc_tcp blocks if missing.
    RPT_CONFIG="$RPT_CONFIG" "$PYMC_PYTHON" <<'PATCH_EOF'
import os, re, sys

config_path = os.environ["RPT_CONFIG"]
with open(config_path, "r") as f:
    content = f.read()

# Each branch handles BOTH the new pymc_* names and the legacy
# usb_heltec / tcp_heltec aliases so existing config.yaml files keep
# loading after upgrade.
USB_BLOCK = '''
    elif radio_type in ("pymc_usb", "usb_heltec"):
        from pymc_core.hardware.usb_radio import USBLoRaRadio

        radio_config = board_config.get("radio")
        if not radio_config:
            raise ValueError("Missing 'radio' section in configuration file")

        usb_config = board_config.get("pymc_usb") or board_config.get("usb_heltec") or {}

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
            raise RuntimeError(f"Failed to initialize pymc_usb radio: {e}") from e

        return radio

'''

TCP_BLOCK = '''
    elif radio_type in ("pymc_tcp", "tcp_heltec"):
        from pymc_core.hardware.tcp_radio import TCPLoRaRadio

        radio_config = board_config.get("radio")
        if not radio_config:
            raise ValueError("Missing 'radio' section in configuration file")

        tcp_config = board_config.get("pymc_tcp") or board_config.get("tcp_heltec") or {}
        if not tcp_config.get("host"):
            raise ValueError("pymc_tcp.host is required for radio_type: pymc_tcp")

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
            raise RuntimeError(f"Failed to initialize pymc_tcp radio: {e}") from e

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
# Guard string is the literal `elif` clause we insert — present only
# in the v2 branches that recognise pymc_usb/pymc_tcp. The v1 guard
# `'radio_type == "usb_heltec"'` would NOT match this string, so an
# install.sh re-run on a previously-patched (v1) file inserts the v2
# branch alongside the older one. Both keep working.
content, inserted = insert_block(content, USB_BLOCK, 'radio_type in ("pymc_usb", "usb_heltec")')
if inserted:
    changed = True
    print("  + inserted pymc_usb branch (with usb_heltec alias)")

content, inserted = insert_block(content, TCP_BLOCK, 'radio_type in ("pymc_tcp", "tcp_heltec")')
if inserted:
    changed = True
    print("  + inserted pymc_tcp branch (with tcp_heltec alias)")

if changed:
    # Extend the error message to list the new radio types.
    NEW_LIST = "pymc_usb, pymc_tcp"
    for old, new in [
        ('Supported: sx1262"',                                  f'Supported: sx1262, {NEW_LIST}"'),
        ('Supported: sx1262, usb_heltec, tcp_heltec"',          f'Supported: sx1262, {NEW_LIST}"'),
        ('Supported: sx1262, sx1262_ch341, kiss (or kiss-modem)"',
         f'Supported: sx1262, sx1262_ch341, kiss (or kiss-modem), {NEW_LIST}"'),
        ('Supported: sx1262, sx1262_ch341, kiss (or kiss-modem), usb_heltec, tcp_heltec"',
         f'Supported: sx1262, sx1262_ch341, kiss (or kiss-modem), {NEW_LIST}"'),
    ]:
        content = content.replace(old, new)
    with open(config_path, "w") as f:
        f.write(content)
    print(f"  Patched {config_path}")
else:
    print("  Already patched — nothing to change")
PATCH_EOF

    echo -e "  ${GREEN}config.py ready for pymc_usb + pymc_tcp${NC}"
fi

# ─── 4. Install example config ───────────────────────────────
echo ""
echo -e "${YELLOW}[4/7] Config file...${NC}"

CONFIG_PATH="/etc/pymc_repeater/config.yaml"

# What does the config currently say? Take the LAST radio_type line in
# case the upstream default file accidentally lists it twice.
current_radio_type() {
    [ -f "$CONFIG_PATH" ] || { echo "<missing>"; return; }
    grep -E "^radio_type:" "$CONFIG_PATH" 2>/dev/null | tail -1 | awk '{print $2}'
}

RT_NOW=$(current_radio_type)

if [ "$RT_NOW" = "pymc_usb" ] || [ "$RT_NOW" = "pymc_tcp" ] \
    || [ "$RT_NOW" = "usb_heltec" ] || [ "$RT_NOW" = "tcp_heltec" ]; then
    echo -e "  ${GREEN}Config already uses $RT_NOW — leaving as-is${NC}"
else
    echo "  Current radio_type: ${RT_NOW:-<missing>}  →  switching to a working pymc_usb config"

    # Backup before touching
    if [ -f "$CONFIG_PATH" ]; then
        BACKUP="${CONFIG_PATH}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "$CONFIG_PATH" "$BACKUP"
        echo "  Backed up: $BACKUP"
    fi

    # Replace with our example baseline
    cp "$REPO_DIR/config.yaml.example" "$CONFIG_PATH"

    # Picking the radio: PYMC_TCP_HOST env-var first (HELTEC_HOST kept as
    # legacy alias), then USB auto-detect, then a pymc_tcp placeholder.
    # TCPLoRaRadio supports deferred-connect mode (since v0.5.10), so the
    # repeater service starts even when the host is just a placeholder —
    # the user fills in the real host via the web setup wizard and the
    # radio reconnects on the fly.
    USB_DEV=$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -1)
    TCP_HOST="${PYMC_TCP_HOST:-$HELTEC_HOST}"

    if [ -n "$TCP_HOST" ]; then
        sed -i "s|^radio_type: pymc_usb$|radio_type: pymc_tcp|" "$CONFIG_PATH"
        sed -i "s|host: 192.168.1.50|host: $TCP_HOST|" "$CONFIG_PATH"
        echo -e "  ${GREEN}PYMC_TCP_HOST=$TCP_HOST → radio_type=pymc_tcp${NC}"

    elif [ -n "$USB_DEV" ]; then
        sed -i "s|^  port: /dev/ttyUSB0$|  port: $USB_DEV|" "$CONFIG_PATH"
        echo -e "  ${GREEN}Detected USB serial device: $USB_DEV${NC}"
        echo -e "  ${GREEN}→ radio_type=pymc_usb, port=$USB_DEV${NC}"
        echo "    (assumes the device runs our LoRa modem firmware —"
        echo "     flash firmware/firmware.bin first if you haven't already)"

    else
        # No USB and no env-var — leave placeholder. Service will start in
        # deferred-connect mode; user finishes config through /setup wizard
        # or by re-running with PYMC_TCP_HOST=…
        sed -i "s|^radio_type: pymc_usb$|radio_type: pymc_tcp|" "$CONFIG_PATH"
        echo -e "  ${YELLOW}No USB device and PYMC_TCP_HOST not set${NC}"
        echo -e "  ${GREEN}→ radio_type=pymc_tcp, placeholder host=ikoka-abcdef.local${NC}"
        echo "    Service will start in deferred-connect mode — open the web UI"
        echo "    and use /setup to point pymc_tcp.host at your real modem,"
        echo "    or re-run: sudo PYMC_TCP_HOST=<ip-or-mdns> $0"
    fi

    # Force first-run setup wizard: keep node_name + admin_password at
    # well-known defaults so /api/needs_setup returns true and the user
    # can pick the radio in the web UI.
    if ! grep -q "^repeater:" "$CONFIG_PATH"; then
        echo "" >> "$CONFIG_PATH"
        echo "repeater:" >> "$CONFIG_PATH"
        echo "  node_name: mesh-repeater-01" >> "$CONFIG_PATH"
        echo "  security:" >> "$CONFIG_PATH"
        echo "    admin_password: admin123" >> "$CONFIG_PATH"
    fi

    echo -e "  ${GREEN}Config installed at $CONFIG_PATH${NC}"

    # Restart so the new config + drivers take effect immediately.
    if systemctl list-unit-files pymc-repeater.service >/dev/null 2>&1; then
        systemctl restart pymc-repeater 2>/dev/null || true
        sleep 5
        if systemctl is-active --quiet pymc-repeater; then
            echo -e "  ${GREEN}pymc-repeater restarted — service is active${NC}"
        else
            echo -e "  ${YELLOW}pymc-repeater restart attempted — service is not active yet${NC}"
            echo "    Check: sudo journalctl -u pymc-repeater -n 30 --no-pager"
        fi
    fi
fi

# ─── 5. Patch web setup wizard (radio-settings.json + api_endpoints.py) ──
echo ""
echo -e "${YELLOW}[5/7] Wiring pymc_usb / pymc_tcp into the web setup wizard...${NC}"

# 5a. radio-settings.json — merge our two entries (idempotent)
RADIO_SETTINGS=""
for path in \
    "/var/lib/pymc_repeater/radio-settings.json" \
    "$("$PYMC_PYTHON" -c 'import repeater, os; print(os.path.dirname(repeater.__path__[0]))' 2>/dev/null)/radio-settings.json"; do
    if [ -f "$path" ]; then
        RADIO_SETTINGS="$path"
        break
    fi
done

if [ -z "$RADIO_SETTINGS" ]; then
    echo -e "  ${YELLOW}WARN: radio-settings.json not found — skip JSON merge${NC}"
else
    REPO_DIR="$REPO_DIR" RADIO_SETTINGS="$RADIO_SETTINGS" "$PYMC_PYTHON" <<'JSON_PATCH_EOF'
import json, os, sys, datetime, shutil

target = os.environ["RADIO_SETTINGS"]
additions = os.path.join(os.environ["REPO_DIR"], "patches", "radio-settings-additions.json")

with open(target) as f:
    cur = json.load(f)
with open(additions) as f:
    add = json.load(f)

cur_hw = cur.setdefault("hardware", {})
add_hw = add.get("hardware", {})

inserted = []
for key, val in add_hw.items():
    if key in cur_hw:
        continue
    cur_hw[key] = val
    inserted.append(key)

if not inserted:
    print("  Already merged — nothing to add")
    sys.exit(0)

backup = f"{target}.bak.{datetime.datetime.now():%Y%m%d_%H%M%S}"
shutil.copy(target, backup)
print(f"  Backed up: {backup}")

with open(target, "w") as f:
    json.dump(cur, f, indent=2)
print(f"  Merged into {target}: {', '.join(inserted)}")
JSON_PATCH_EOF
    echo -e "  ${GREEN}radio-settings.json ready${NC}"
fi

# 5b. setup_wizard handler — insert pymc_usb / pymc_tcp branches before the SX1262 block
WIZARD=""
for path in \
    "$("$PYMC_PYTHON" -c 'import repeater; print(repeater.__path__[0])' 2>/dev/null)/web/api_endpoints.py" \
    "/opt/pymc_repeater/repeater/web/api_endpoints.py" \
    "/opt/companion/pyMC_Repeater/repeater/web/api_endpoints.py"; do
    if [ -f "$path" ]; then
        WIZARD="$path"
        break
    fi
done

if [ -z "$WIZARD" ]; then
    echo -e "  ${YELLOW}WARN: api_endpoints.py not found — skip wizard patch${NC}"
else
    WIZARD="$WIZARD" "$PYMC_PYTHON" <<'WIZ_PATCH_EOF'
import os, re, sys, datetime, shutil

target = os.environ["WIZARD"]
# v2 guard — bumped on the rename so an in-place re-run on a previously
# patched (v1) api_endpoints.py inserts the new branch alongside the old
# one. Both keep working; new install.sh runs against fresh source land
# in a single clean v2 block.
GUARD = "# pymc_usb wizard branches v2"

with open(target) as f:
    content = f.read()

if GUARD in content:
    print("  setup_wizard already patched (v2) — nothing to do")
    sys.exit(0)

# Anchor: the line that starts the SX1262/CH341 fallback block.
# We insert pymc_usb / pymc_tcp branches *before* it and convert it
# into an `else:` of an if/elif chain.
ANCHOR = (
    "                if \"radio_type\" in hw_config:\n"
    "                    config_yaml[\"radio_type\"] = hw_config.get(\"radio_type\")\n"
    "                else:\n"
    "                    config_yaml[\"radio_type\"] = \"sx1262\"\n"
)
REPLACE = (
    "                config_yaml[\"radio_type\"] = hw_config.get(\"radio_type\", \"sx1262\")\n"
    "\n"
    "                " + GUARD + " — pymc_usb / pymc_tcp (legacy aliases accepted)\n"
    "                _RT = config_yaml[\"radio_type\"]\n"
    "                if _RT in (\"pymc_usb\", \"usb_heltec\"):\n"
    "                    config_yaml[\"radio_type\"] = \"pymc_usb\"\n"
    "                    config_yaml.setdefault(\"pymc_usb\", {})\n"
    "                    config_yaml[\"pymc_usb\"].setdefault(\"port\", \"/dev/ttyUSB0\")\n"
    "                    config_yaml[\"pymc_usb\"].setdefault(\"baudrate\", 921600)\n"
    "                    config_yaml[\"pymc_usb\"].setdefault(\"lbt_enabled\", True)\n"
    "                    config_yaml[\"pymc_usb\"].setdefault(\"lbt_max_attempts\", 5)\n"
    "                    if \"tx_power\" in hw_config:\n"
    "                        config_yaml[\"radio\"][\"tx_power\"] = hw_config.get(\"tx_power\", 22)\n"
    "                    if \"preamble_length\" in hw_config:\n"
    "                        config_yaml[\"radio\"][\"preamble_length\"] = hw_config.get(\"preamble_length\", 16)\n"
    "                elif _RT in (\"pymc_tcp\", \"tcp_heltec\"):\n"
    "                    config_yaml[\"radio_type\"] = \"pymc_tcp\"\n"
    "                    # Migrate any pre-existing legacy section name first\n"
    "                    if \"tcp_heltec\" in config_yaml and \"pymc_tcp\" not in config_yaml:\n"
    "                        config_yaml[\"pymc_tcp\"] = config_yaml.pop(\"tcp_heltec\")\n"
    "                    config_yaml.setdefault(\"pymc_tcp\", {})\n"
    "                    # Values from the injected /setup panel (pymc_tcp_setup_panel.js)\n"
    "                    # take priority over the placeholder defaults below. Legacy\n"
    "                    # field names tcp_heltec_* are also accepted.\n"
    "                    _host = data.get(\"pymc_tcp_host\") or data.get(\"tcp_heltec_host\")\n"
    "                    if _host:\n"
    "                        config_yaml[\"pymc_tcp\"][\"host\"] = str(_host).strip()\n"
    "                    else:\n"
    "                        config_yaml[\"pymc_tcp\"].setdefault(\"host\", \"ikoka-abcdef.local\")\n"
    "                    _port = data.get(\"pymc_tcp_port\") or data.get(\"tcp_heltec_port\")\n"
    "                    if _port:\n"
    "                        try:\n"
    "                            config_yaml[\"pymc_tcp\"][\"port\"] = int(_port)\n"
    "                        except (TypeError, ValueError):\n"
    "                            config_yaml[\"pymc_tcp\"].setdefault(\"port\", 5055)\n"
    "                    else:\n"
    "                        config_yaml[\"pymc_tcp\"].setdefault(\"port\", 5055)\n"
    "                    if \"pymc_tcp_token\" in data:\n"
    "                        config_yaml[\"pymc_tcp\"][\"token\"] = str(data.get(\"pymc_tcp_token\") or \"\")\n"
    "                    elif \"tcp_heltec_token\" in data:\n"
    "                        config_yaml[\"pymc_tcp\"][\"token\"] = str(data.get(\"tcp_heltec_token\") or \"\")\n"
    "                    else:\n"
    "                        config_yaml[\"pymc_tcp\"].setdefault(\"token\", \"\")\n"
    "                    config_yaml[\"pymc_tcp\"].setdefault(\"connect_timeout\", 5.0)\n"
    "                    config_yaml[\"pymc_tcp\"].setdefault(\"lbt_enabled\", True)\n"
    "                    config_yaml[\"pymc_tcp\"].setdefault(\"lbt_max_attempts\", 5)\n"
    "                    if \"tx_power\" in hw_config:\n"
    "                        config_yaml[\"radio\"][\"tx_power\"] = hw_config.get(\"tx_power\", 22)\n"
    "                    if \"preamble_length\" in hw_config:\n"
    "                        config_yaml[\"radio\"][\"preamble_length\"] = hw_config.get(\"preamble_length\", 16)\n"
    "                else:\n"
    "                    pass  # fall through to existing SX1262 / CH341 block below\n"
)

if ANCHOR not in content:
    print("  WARN: could not find expected anchor in setup_wizard; "
          "either it has already been refactored or the upstream changed shape. "
          "Skipping wizard patch — falling back to manual config.yaml editing.")
    sys.exit(0)

new_content = content.replace(ANCHOR, REPLACE, 1)

backup = f"{target}.bak.{datetime.datetime.now():%Y%m%d_%H%M%S}"
shutil.copy(target, backup)
print(f"  Backed up: {backup}")

with open(target, "w") as f:
    f.write(new_content)
print(f"  Patched setup_wizard: pymc_usb / pymc_tcp branches inserted (v2)")
WIZ_PATCH_EOF
    echo -e "  ${GREEN}setup_wizard ready${NC}"
fi

# 5c. pymc_tcp configuration panel (HTML + 3 cherrypy endpoints).
# Idempotent: HTML is overwritten every run, endpoints are guarded by a
# marker comment.
PANEL_DST=""
if [ -n "$WIZARD" ]; then
    PANEL_DST="$(dirname "$WIZARD")/html/pymc_tcp_panel.html"
    cp "$REPO_DIR/patches/pymc_tcp_panel.html" "$PANEL_DST"
    chmod 644 "$PANEL_DST"
    echo -e "  ${GREEN}Installed: $PANEL_DST${NC}"

    WIZARD="$WIZARD" REPO_DIR="$REPO_DIR" "$PYMC_PYTHON" <<'PANEL_PATCH_EOF'
import os, datetime, shutil, sys

target = os.environ["WIZARD"]
endpoints_src = os.path.join(os.environ["REPO_DIR"], "patches", "pymc_tcp_endpoints.py")
GUARD = "# pymc_usb — pymc_tcp panel endpoints"

with open(target) as f:
    content = f.read()
if GUARD in content:
    print("  pymc_tcp panel endpoints already present — skipping")
    sys.exit(0)
with open(endpoints_src) as f:
    block = f.read()

# Insert just before the closing line of the API class. The class is the
# last big block in api_endpoints.py; we anchor on the final 'def'-less
# closing region by appending right before the module-level code (after the
# last method). Simplest robust anchor: insert before the very last
# occurrence of '}' or at the file end if the file ends inside the class.
# In practice the class definition runs to EOF (CherryPy mounts a single
# class), so we append the new methods at the end of the class by adding
# them just before the final blank/indent boundary.
#
# Concretely: append after the last method definition of the class, which
# is the last line that starts with "    def " (4-space indent).
import re
last = None
for m in re.finditer(r"\n    def [a-zA-Z_]\w*\s*\(", content):
    last = m

if last is None:
    print("  ERROR: cannot locate a method to anchor on", file=sys.stderr)
    sys.exit(2)

# Find end of that method = the next "\n    def " or "\nclass " or EOF.
search_from = last.end()
next_anchor = re.search(r"\n    def [a-zA-Z_]\w*\s*\(|\nclass ", content[search_from:])
insert_at = (search_from + next_anchor.start()) if next_anchor else len(content)

backup = f"{target}.bak.{datetime.datetime.now():%Y%m%d_%H%M%S}"
shutil.copy(target, backup)
print(f"  Backed up: {backup}")

new_content = content[:insert_at] + "\n" + block + content[insert_at:]
with open(target, "w") as f:
    f.write(new_content)
print(f"  pymc_tcp panel endpoints inserted in {target}")
PANEL_PATCH_EOF
fi

# 5c2. Install pymc_console — a richer dashboard from
# https://github.com/dmduran12/pymc_console-dist that overlays on top
# of pyMC_Repeater's CherryPy server. Repeater reads `web.web_path`
# from config.yaml and serves whichever directory is pointed there;
# the default is repeater's own Vue bundle, but we point it at the
# console bundle for a much nicer UI. The pymc_tcp endpoints we expose
# (/api/pymc_tcp etc.) keep working unchanged because they are CherryPy
# routes, independent of which static bundle is being served.
#
# Skip this step entirely with PYMC_NO_CONSOLE=1 if you prefer the
# upstream UI. Pin a specific release with PYMC_CONSOLE_VERSION=v0.9.327.
if [ -z "$PYMC_NO_CONSOLE" ]; then
    echo ""
    echo -e "${YELLOW}[6/7] Installing pymc_console UI bundle...${NC}"

    CONSOLE_DIR="/opt/pymc_console/web/html"
    CONSOLE_VERSION="${PYMC_CONSOLE_VERSION:-latest}"
    if [ "$CONSOLE_VERSION" = "latest" ]; then
        TARBALL_URL="https://github.com/dmduran12/pymc_console-dist/releases/latest/download/pymc-ui-latest.tar.gz"
    else
        TARBALL_URL="https://github.com/dmduran12/pymc_console-dist/releases/download/${CONSOLE_VERSION}/pymc-ui-${CONSOLE_VERSION}.tar.gz"
    fi

    if [ -f "$CONSOLE_DIR/index.html" ] && [ -z "$PYMC_CONSOLE_FORCE" ]; then
        echo -e "  ${GREEN}Already present at $CONSOLE_DIR — skipping download (set PYMC_CONSOLE_FORCE=1 to refresh)${NC}"
    else
        mkdir -p "$CONSOLE_DIR"
        TMPTAR="/tmp/pymc-console-$$.tar.gz"
        echo "  Downloading $TARBALL_URL"
        if ! curl -fsSL -o "$TMPTAR" "$TARBALL_URL"; then
            echo -e "  ${RED}Download failed — leaving upstream UI in place${NC}"
            rm -f "$TMPTAR"
        else
            # Wipe stale assets first; tarball doesn't carry every file across versions.
            rm -rf "$CONSOLE_DIR"/*
            tar -xzf "$TMPTAR" -C "$CONSOLE_DIR/"
            rm -f "$TMPTAR"
            # Best-effort chown — `repeater` user may not exist on a non-systemd
            # box; in that case pymc_repeater runs as the invoking user and the
            # default ownership from extraction is fine.
            chown -R repeater:repeater /opt/pymc_console 2>/dev/null || true
            VER=$(cat "$CONSOLE_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')
            echo -e "  ${GREEN}Installed pymc_console ${VER:-(unknown)} at $CONSOLE_DIR${NC}"
        fi
    fi

    # Point pymc_repeater at the console bundle. Only edit if web.web_path
    # is unset or still points at upstream's repeater/web/html — never
    # clobber a user-customised path.
    if [ -f "$CONFIG_PATH" ] && [ -d "$CONSOLE_DIR" ]; then
        CONFIG_PATH="$CONFIG_PATH" CONSOLE_DIR="$CONSOLE_DIR" "$PYMC_PYTHON" <<'WEBPATH_PATCH_EOF'
import os, yaml
p = os.environ["CONFIG_PATH"]
target = os.environ["CONSOLE_DIR"]
with open(p) as f:
    cfg = yaml.safe_load(f) or {}
web = cfg.setdefault("web", {})
cur = (web.get("web_path") or "").rstrip("/")
if cur and cur != target and "pymc_console" not in cur and "/opt/pymc_repeater" not in cur:
    print(f"  web.web_path already custom ({cur}) — leaving as-is")
elif cur == target:
    print("  web.web_path already pointed at pymc_console")
else:
    web["web_path"] = target
    with open(p, "w") as f:
        yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False)
    print(f"  Set web.web_path = {target} in {p}")
WEBPATH_PATCH_EOF
    fi
fi

# 5d-pre. Inject a sticky "pymc_tcp config" link into the served SPA's
# index.html. We patch whichever bundle is actually serving — defaults
# to /opt/pymc_console/web/html (set above), falls back to repeater's
# own Vue bundle if the console step was skipped or failed.
INDEX_CANDIDATES=()
if [ -f "$CONFIG_PATH" ]; then
    WEB_PATH=$("$PYMC_PYTHON" -c "import yaml; print((yaml.safe_load(open('$CONFIG_PATH')) or {}).get('web',{}).get('web_path','') or '')" 2>/dev/null)
    [ -n "$WEB_PATH" ] && [ -f "$WEB_PATH/index.html" ] && INDEX_CANDIDATES+=("$WEB_PATH/index.html")
fi
if [ -n "$WIZARD" ]; then
    UPSTREAM_INDEX="$(dirname "$WIZARD")/html/index.html"
    [ -f "$UPSTREAM_INDEX" ] && INDEX_CANDIDATES+=("$UPSTREAM_INDEX")
fi

for INDEX_HTML in "${INDEX_CANDIDATES[@]}"; do
    if [ -f "$INDEX_HTML" ]; then
        REPO_DIR="$REPO_DIR" INDEX_HTML="$INDEX_HTML" "$PYMC_PYTHON" <<'INDEX_PATCH_EOF'
import os, datetime, shutil, sys

target = os.environ["INDEX_HTML"]
repo_dir = os.environ["REPO_DIR"]
# v2 ids — bumped when the rename to pymc_tcp landed. The legacy
# `pymc_usb-heltec-link` element on already-patched pages is left in
# place so existing bookmarks keep working; we just add the new one
# alongside.
GUARD = "pymc_usb-pymc_tcp-link"
SETUP_GUARD = "pymc_usb-tcp-setup-panel"

with open(target) as f:
    content = f.read()

# Different SPAs mount on different roots — pyMC_Repeater's Vue bundle
# uses #app, pymc_console uses #root. Try both before giving up.
ANCHOR = None
for cand in ('<div id="app"></div>', '<div id="root"></div>'):
    if cand in content:
        ANCHOR = cand
        break
if ANCHOR is None:
    print("  WARN: cannot find <div id=\"app\"> or <div id=\"root\"> in index.html — skipping injection")
    sys.exit(0)

# Two separate injections, each guarded independently so re-runs are safe
# even if a future upstream replaces only one of them.
to_prepend = ""

if GUARD not in content:
    to_prepend += (
        '    <!-- ' + GUARD + ': stable across pymc_repeater upgrades, re-injected by install.sh -->\n'
        '    <a id="' + GUARD + '" href="/api/pymc_tcp" target="_blank" rel="noopener"\n'
        '       style="position:fixed;bottom:14px;right:14px;z-index:99999;'
        'background:#2e7d57;color:#fff;padding:9px 14px;border-radius:6px;'
        'font:13px/1.2 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;'
        'text-decoration:none;box-shadow:0 2px 8px rgba(0,0,0,.25);'
        'border:1px solid rgba(255,255,255,.12)">\n'
        '      pymc_tcp config\n'
        '    </a>\n'
    )

setup_js_path = os.path.join(repo_dir, "patches", "pymc_tcp_setup_panel.js")
if SETUP_GUARD not in content and os.path.exists(setup_js_path):
    with open(setup_js_path) as jf:
        js_body = jf.read()
    to_prepend += (
        '    <!-- ' + SETUP_GUARD + ': /setup wizard host/port/token panel, re-injected by install.sh -->\n'
        '    <script id="' + SETUP_GUARD + '">\n'
        + js_body +
        '    </script>\n'
    )

if not to_prepend:
    print("  index.html already carries Heltec link + setup panel — skipping")
    sys.exit(0)

backup = f"{target}.bak.{datetime.datetime.now():%Y%m%d_%H%M%S}"
shutil.copy(target, backup)
print(f"  Backed up: {backup}")

with open(target, "w") as f:
    f.write(content.replace(ANCHOR, to_prepend + "    " + ANCHOR, 1))
print(f"  Injected into {target}: link={GUARD not in content}? setup-panel-script")
INDEX_PATCH_EOF
    fi
done

# 5d. Exempt our 3 endpoints from the global JWT require_auth tool.
# They have their own HTTP Basic auth (admin password from config.yaml).
HTTP_SERVER=""
if [ -n "$WIZARD" ]; then
    HTTP_SERVER="$(dirname "$WIZARD")/http_server.py"
fi

if [ -n "$HTTP_SERVER" ] && [ -f "$HTTP_SERVER" ]; then
    HTTP_SERVER="$HTTP_SERVER" "$PYMC_PYTHON" <<'HTTP_PATCH_EOF'
import os, datetime, shutil, sys

target = os.environ["HTTP_SERVER"]
# v2 guard — bumped on rename. Re-runs on a previously-patched
# (v1 / Heltec-named) http_server.py append the new exemptions
# alongside the old ones; both endpoint sets remain JWT-free.
GUARD = "# pymc_usb — pymc_tcp panel auth exemptions"

with open(target) as f:
    content = f.read()
if GUARD in content:
    print("  http_server already patched — skipping")
    sys.exit(0)

ANCHOR = '                "/favicon.ico": {\n'
INJECT = (
    '                ' + GUARD + '\n'
    '                "/api/pymc_tcp": {\n'
    '                    "tools.require_auth.on": False,\n'
    '                },\n'
    '                "/api/get_pymc_tcp_config": {\n'
    '                    "tools.require_auth.on": False,\n'
    '                },\n'
    '                "/api/update_pymc_tcp_config": {\n'
    '                    "tools.require_auth.on": False,\n'
    '                },\n'
)

if ANCHOR not in content:
    print("  WARN: cannot find favicon.ico anchor in http_server.py — skip", file=sys.stderr)
    sys.exit(0)

backup = f"{target}.bak.{datetime.datetime.now():%Y%m%d_%H%M%S}"
shutil.copy(target, backup)
print(f"  Backed up: {backup}")

with open(target, "w") as f:
    f.write(content.replace(ANCHOR, INJECT + ANCHOR, 1))
print(f"  Exempted pymc_tcp panel endpoints from JWT in {target}")
HTTP_PATCH_EOF
fi

# 5f. Make `restart_service()` work inside Docker. The setup wizard
# relies on it after writing config.yaml, but the upstream implementation
# only knows Buildroot init scripts and systemctl — neither exists inside
# a container, so the daemon never reloads, the SPA refresh shows the
# wizard again, and the user is stuck in a loop. We monkey-patch by
# adding a Docker branch at the top of restart_service: if /.dockerenv
# is present, send SIGTERM to PID 1 and let the container's restart
# policy bring us back with the fresh on-disk config.
SERVICE_UTILS=""
if [ -n "$PYMC_PYTHON" ]; then
    SERVICE_UTILS=$("$PYMC_PYTHON" -c "import repeater.service_utils as m; print(m.__file__)" 2>/dev/null) || true
fi

if [ -n "$SERVICE_UTILS" ] && [ -f "$SERVICE_UTILS" ]; then
    SERVICE_UTILS="$SERVICE_UTILS" "$PYMC_PYTHON" <<'SVC_PATCH_EOF'
import os, datetime, shutil, sys

target = os.environ["SERVICE_UTILS"]
GUARD = "# pymc_usb — Docker restart branch"

with open(target) as f:
    content = f.read()

if GUARD in content:
    print("  service_utils already patched — skipping")
    sys.exit(0)

# Anchor: the very first executable line inside restart_service(). We
# splice in a /.dockerenv check before the existing Buildroot/systemd
# logic so plain-host installs are unaffected.
ANCHOR = '    if is_buildroot():\n'
INJECT = (
    '    ' + GUARD + ' — Python running as PID 1 in Docker has no\n'
    '    # default signal handlers, so a plain os.kill(1, SIGTERM) gets\n'
    '    # ignored. Instead we spawn a detached helper that waits long\n'
    '    # enough for the HTTP response to flush, then os._exit()\'s the\n'
    '    # daemon. The container restart policy brings it back up with\n'
    '    # the freshly-written config.\n'
    '    if os.path.exists("/.dockerenv"):\n'
    '        import threading, time as _t\n'
    '        def _docker_exit():\n'
    '            _t.sleep(0.5)\n'
    '            logger.info("Docker detected — exiting PID 1 to reload config")\n'
    '            os._exit(0)\n'
    '        threading.Thread(target=_docker_exit, daemon=True).start()\n'
    '        return True, "Service restart initiated (Docker)"\n'
    '\n'
)

if ANCHOR not in content:
    print("  WARN: cannot find restart_service anchor — skip", file=sys.stderr)
    sys.exit(0)

backup = f"{target}.bak.{datetime.datetime.now():%Y%m%d_%H%M%S}"
shutil.copy(target, backup)
print(f"  Backed up: {backup}")

with open(target, "w") as f:
    f.write(content.replace(ANCHOR, INJECT + ANCHOR, 1))
print(f"  Patched restart_service in {target}: Docker branch inserted")
SVC_PATCH_EOF
else
    echo -e "  ${YELLOW}WARN: service_utils.py not located — wizard's restart will be a no-op in Docker${NC}"
fi

# 5g. Purge .pyc cache so the freshly-patched .py files are picked up.
# Python won't recompile cached .pyc unless source mtime is newer; with
# in-place sed-like edits the timestamps can race and leave stale bytecode.
PKG_ROOT="$(dirname "$PYMC_HW")"          # …/site-packages/pymc_core
SITE_ROOT="$(dirname "$PKG_ROOT")"        # …/site-packages

# Build a list of dirs that actually exist before passing them to find —
# `find /missing/dir` returns exit 1 even with stderr suppressed and
# would trip `set -e`. Editable installs (pip install -e ...) keep the
# package at its source checkout, so we also probe `repeater.__path__`.
PURGE_PATHS=()
[ -d "$SITE_ROOT/pymc_core" ] && PURGE_PATHS+=("$SITE_ROOT/pymc_core")
[ -d "$SITE_ROOT/repeater" ] && PURGE_PATHS+=("$SITE_ROOT/repeater")
REPEATER_SRC=$("$PYMC_PYTHON" -c "import repeater; print(repeater.__path__[0])" 2>/dev/null) || true
[ -n "$REPEATER_SRC" ] && [ -d "$REPEATER_SRC" ] && PURGE_PATHS+=("$REPEATER_SRC")

if [ ${#PURGE_PATHS[@]} -gt 0 ]; then
    find "${PURGE_PATHS[@]}" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true
    echo -e "  ${GREEN}Cleared __pycache__ in: ${PURGE_PATHS[*]}${NC}"
else
    echo -e "  ${YELLOW}No __pycache__ targets found — skipped${NC}"
fi

# ─── 6. Check USB device ─────────────────────────────────────
echo ""
echo -e "${YELLOW}[7/7] Checking USB device...${NC}"
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
echo "       (set radio_type: pymc_usb or pymc_tcp)"
echo "    5. Restart: sudo systemctl restart pymc-repeater"
echo "═══════════════════════════════════════════"
