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
echo -e "${YELLOW}[1/6] Finding pymc_core...${NC}"

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
echo -e "${YELLOW}[2/6] Installing USBLoRaRadio + TCPLoRaRadio drivers...${NC}"
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
echo -e "${YELLOW}[3/6] Patching pymc_repeater...${NC}"

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
    echo "  You'll need to manually add usb_heltec and tcp_heltec support"
else
    # Make a timestamped backup once if we're going to touch the file
    if ! grep -q "usb_heltec" "$RPT_CONFIG" || ! grep -q "tcp_heltec" "$RPT_CONFIG"; then
        cp "$RPT_CONFIG" "${RPT_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
        echo "  Backed up: ${RPT_CONFIG}.bak.*"
    fi

    # Patch in one Python pass: adds usb_heltec and/or tcp_heltec blocks if missing.
    RPT_CONFIG="$RPT_CONFIG" "$PYMC_PYTHON" <<'PATCH_EOF'
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
echo -e "${YELLOW}[4/6] Config file...${NC}"

CONFIG_PATH="/etc/pymc_repeater/config.yaml"

# What does the config currently say? Take the LAST radio_type line in
# case the upstream default file accidentally lists it twice.
current_radio_type() {
    [ -f "$CONFIG_PATH" ] || { echo "<missing>"; return; }
    grep -E "^radio_type:" "$CONFIG_PATH" 2>/dev/null | tail -1 | awk '{print $2}'
}

RT_NOW=$(current_radio_type)

if [ "$RT_NOW" = "usb_heltec" ] || [ "$RT_NOW" = "tcp_heltec" ]; then
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

    # Picking the radio: HELTEC_HOST env-var first, then USB auto-detect,
    # then a tcp_heltec placeholder. TCPLoRaRadio supports deferred-connect
    # mode (since v0.5.10), so the repeater service starts even when the
    # Heltec host is just a placeholder — the user fills in the real host
    # via the web setup wizard, and the radio reconnects on the fly.
    USB_DEV=$(ls /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | head -1)

    if [ -n "$HELTEC_HOST" ]; then
        sed -i "s|^radio_type: usb_heltec$|radio_type: tcp_heltec|" "$CONFIG_PATH"
        sed -i "s|host: 192.168.1.50|host: $HELTEC_HOST|" "$CONFIG_PATH"
        echo -e "  ${GREEN}HELTEC_HOST=$HELTEC_HOST → radio_type=tcp_heltec${NC}"

    elif [ -n "$USB_DEV" ]; then
        sed -i "s|^  port: /dev/ttyUSB0$|  port: $USB_DEV|" "$CONFIG_PATH"
        echo -e "  ${GREEN}Detected USB serial device: $USB_DEV${NC}"
        echo -e "  ${GREEN}→ radio_type=usb_heltec, port=$USB_DEV${NC}"
        echo "    (assumes the device runs our LoRa modem firmware —"
        echo "     flash firmware/firmware.bin first if you haven't already)"

    else
        # No USB and no env-var — leave placeholder. Service will start in
        # deferred-connect mode; user finishes config through /setup wizard
        # or by re-running with HELTEC_HOST=…
        sed -i "s|^radio_type: usb_heltec$|radio_type: tcp_heltec|" "$CONFIG_PATH"
        echo -e "  ${YELLOW}No USB device and HELTEC_HOST not set${NC}"
        echo -e "  ${GREEN}→ radio_type=tcp_heltec, placeholder host=heltec-abcdef.local${NC}"
        echo "    Service will start in deferred-connect mode — open the web UI"
        echo "    and use /setup to point tcp_heltec.host at your real Heltec,"
        echo "    or re-run: sudo HELTEC_HOST=<ip-or-mdns> $0"
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
echo -e "${YELLOW}[5/6] Wiring usb_heltec / tcp_heltec into the web setup wizard...${NC}"

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

# 5b. setup_wizard handler — insert usb_heltec / tcp_heltec branches before the SX1262 block
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
GUARD = "# pymc_usb wizard branches"

with open(target) as f:
    content = f.read()

if GUARD in content:
    print("  setup_wizard already patched — nothing to do")
    sys.exit(0)

# Anchor: the line that starts the SX1262/CH341 fallback block.
# We insert usb_heltec / tcp_heltec branches *before* it and convert it
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
    "                " + GUARD + " — usb_heltec / tcp_heltec\n"
    "                if config_yaml[\"radio_type\"] == \"usb_heltec\":\n"
    "                    config_yaml.setdefault(\"usb_heltec\", {})\n"
    "                    config_yaml[\"usb_heltec\"].setdefault(\"port\", \"/dev/ttyUSB0\")\n"
    "                    config_yaml[\"usb_heltec\"].setdefault(\"baudrate\", 921600)\n"
    "                    config_yaml[\"usb_heltec\"].setdefault(\"lbt_enabled\", True)\n"
    "                    config_yaml[\"usb_heltec\"].setdefault(\"lbt_max_attempts\", 5)\n"
    "                    if \"tx_power\" in hw_config:\n"
    "                        config_yaml[\"radio\"][\"tx_power\"] = hw_config.get(\"tx_power\", 22)\n"
    "                    if \"preamble_length\" in hw_config:\n"
    "                        config_yaml[\"radio\"][\"preamble_length\"] = hw_config.get(\"preamble_length\", 16)\n"
    "                elif config_yaml[\"radio_type\"] == \"tcp_heltec\":\n"
    "                    config_yaml.setdefault(\"tcp_heltec\", {})\n"
    "                    config_yaml[\"tcp_heltec\"].setdefault(\"host\", \"heltec-abcdef.local\")\n"
    "                    config_yaml[\"tcp_heltec\"].setdefault(\"port\", 5055)\n"
    "                    config_yaml[\"tcp_heltec\"].setdefault(\"token\", \"\")\n"
    "                    config_yaml[\"tcp_heltec\"].setdefault(\"connect_timeout\", 5.0)\n"
    "                    config_yaml[\"tcp_heltec\"].setdefault(\"lbt_enabled\", True)\n"
    "                    config_yaml[\"tcp_heltec\"].setdefault(\"lbt_max_attempts\", 5)\n"
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
print(f"  Patched setup_wizard: usb_heltec / tcp_heltec branches inserted")
WIZ_PATCH_EOF
    echo -e "  ${GREEN}setup_wizard ready${NC}"
fi

# 5c. Heltec TCP configuration panel (HTML + 3 cherrypy endpoints).
# Idempotent: HTML is overwritten every run, endpoints are guarded by a
# marker comment.
HELTEC_PANEL_DST=""
if [ -n "$WIZARD" ]; then
    HELTEC_PANEL_DST="$(dirname "$WIZARD")/html/heltec_panel.html"
    cp "$REPO_DIR/patches/heltec_panel.html" "$HELTEC_PANEL_DST"
    chmod 644 "$HELTEC_PANEL_DST"
    echo -e "  ${GREEN}Installed: $HELTEC_PANEL_DST${NC}"

    WIZARD="$WIZARD" REPO_DIR="$REPO_DIR" "$PYMC_PYTHON" <<'PANEL_PATCH_EOF'
import os, datetime, shutil, sys

target = os.environ["WIZARD"]
endpoints_src = os.path.join(os.environ["REPO_DIR"], "patches", "heltec_endpoints.py")
GUARD = "# pymc_usb — Heltec TCP panel endpoints"

with open(target) as f:
    content = f.read()
if GUARD in content:
    print("  Heltec panel endpoints already present — skipping")
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
print(f"  Heltec panel endpoints inserted in {target}")
PANEL_PATCH_EOF
fi

# 5d-pre. Inject a sticky "Heltec config" link into the SPA's index.html.
# The Vue bundle is pre-compiled and we can't add UI fields to its
# Settings page from outside, so the next-best UX is a small floating
# button that opens our /api/heltec panel in a new tab. The button sits
# in a fixed position outside the Vue mount root (#app), so the SPA
# never touches it.
if [ -n "$WIZARD" ]; then
    INDEX_HTML="$(dirname "$WIZARD")/html/index.html"
    if [ -f "$INDEX_HTML" ]; then
        INDEX_HTML="$INDEX_HTML" "$PYMC_PYTHON" <<'INDEX_PATCH_EOF'
import os, datetime, shutil, sys

target = os.environ["INDEX_HTML"]
GUARD = "pymc_usb-heltec-link"

with open(target) as f:
    content = f.read()
if GUARD in content:
    print("  index.html already carries the Heltec link — skipping")
    sys.exit(0)

LINK = (
    '    <!-- ' + GUARD + ': stable across pymc_repeater upgrades, re-injected by install.sh -->\n'
    '    <a id="' + GUARD + '" href="/api/heltec" target="_blank" rel="noopener"\n'
    '       style="position:fixed;bottom:14px;right:14px;z-index:99999;'
    'background:#2e7d57;color:#fff;padding:9px 14px;border-radius:6px;'
    'font:13px/1.2 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;'
    'text-decoration:none;box-shadow:0 2px 8px rgba(0,0,0,.25);'
    'border:1px solid rgba(255,255,255,.12)">\n'
    '      Heltec config\n'
    '    </a>\n'
)

ANCHOR = '<div id="app"></div>'
if ANCHOR not in content:
    print("  WARN: cannot find <div id=\"app\"> in index.html — skipping link injection")
    sys.exit(0)

backup = f"{target}.bak.{datetime.datetime.now():%Y%m%d_%H%M%S}"
shutil.copy(target, backup)
print(f"  Backed up: {backup}")

with open(target, "w") as f:
    f.write(content.replace(ANCHOR, LINK + "    " + ANCHOR, 1))
print(f"  Injected Heltec config link into {target}")
INDEX_PATCH_EOF
    fi
fi

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
GUARD = "# pymc_usb — Heltec panel auth exemptions"

with open(target) as f:
    content = f.read()
if GUARD in content:
    print("  http_server already patched — skipping")
    sys.exit(0)

ANCHOR = '                "/favicon.ico": {\n'
INJECT = (
    '                ' + GUARD + '\n'
    '                "/api/heltec": {\n'
    '                    "tools.require_auth.on": False,\n'
    '                },\n'
    '                "/api/get_tcp_heltec_config": {\n'
    '                    "tools.require_auth.on": False,\n'
    '                },\n'
    '                "/api/update_tcp_heltec_config": {\n'
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
print(f"  Exempted Heltec panel endpoints from JWT in {target}")
HTTP_PATCH_EOF
fi

# 5e. Purge .pyc cache so the freshly-patched .py files are picked up.
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
echo -e "${YELLOW}[6/6] Checking USB device...${NC}"
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
