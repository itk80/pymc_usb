#!/bin/bash
# =============================================================================
# pyMC Repeater container entrypoint
#
# Three responsibilities:
#   1. If we were started as root (typical when bind-mounted host
#      directories arrive with arbitrary ownership), chown the data
#      directories to `repeater` and re-exec ourselves under that user
#      via gosu. That way config / db / logs end up with predictable
#      ownership on the host filesystem and the daemon never runs as
#      root.
#   2. On first start (volume empty), seed /etc/pymc_repeater/config.yaml
#      from the baked-in /etc/pymc_repeater/config.yaml.default.
#   3. Apply env-var overrides (HELTEC_HOST/PORT/TOKEN, SERIAL_PORT, …) to
#      the live config via PyYAML, so the user can change radio settings
#      without rebuilding the image.
#
# Deferred-connect: if HELTEC_HOST is unset and the placeholder is still
# in the config, we DO NOT abort. TCPLoRaRadio in pymc_usb supports
# deferred-connect mode — the repeater starts and the user finishes
# configuring the Heltec endpoint via the web UI's "Heltec config" panel.
# =============================================================================
set -e

CONFIG="/etc/pymc_repeater/config.yaml"
# Default lives OUTSIDE /etc/pymc_repeater/ on purpose — a host bind
# mount over that directory would otherwise hide the baked-in template.
DEFAULT="/opt/pymc_repeater/config.yaml.default"
DATA_DIRS=(/etc/pymc_repeater /var/lib/pymc_repeater /var/log/pymc_repeater)

# Step 1: privilege drop. Re-exec as `repeater` after fixing ownership
# of any bind-mounted directories. Skipped if the operator already
# pinned a uid via `docker run --user` (then we trust their setup).
if [ "$(id -u)" = "0" ]; then
    for d in "${DATA_DIRS[@]}"; do
        mkdir -p "$d"
        chown -R repeater:repeater "$d" 2>/dev/null || true
    done
    exec gosu repeater "$0" "$@"
fi

echo "=========================================="
echo "  pyMC Repeater (Heltec USB / TCP modem)"
echo "=========================================="

# Seed config from baked-in default on first start (volume / bind mount empty).
if [ ! -f "$CONFIG" ]; then
    cp "$DEFAULT" "$CONFIG"
    echo "[OK] Seeded $CONFIG from default"
fi

# Apply env-var overrides via PyYAML. Safer than sed against an indented
# YAML file because we round-trip through a real parser.
python3 - "$CONFIG" <<'PYEOF'
import os, sys, yaml

path = sys.argv[1]
with open(path) as f:
    cfg = yaml.safe_load(f) or {}

radio_type = os.environ.get("RADIO_TYPE", cfg.get("radio_type", "tcp_heltec")).strip()
cfg["radio_type"] = radio_type

if radio_type == "tcp_heltec":
    sec = cfg.setdefault("tcp_heltec", {})
    if os.environ.get("HELTEC_HOST"):
        sec["host"] = os.environ["HELTEC_HOST"]
    if os.environ.get("HELTEC_PORT"):
        sec["port"] = int(os.environ["HELTEC_PORT"])
    # Token override is opt-in; an empty env-var string still counts as
    # "set to empty" because users sometimes need to explicitly clear it.
    if "HELTEC_TOKEN" in os.environ:
        sec["token"] = os.environ["HELTEC_TOKEN"]
    if os.environ.get("HELTEC_CONNECT_TIMEOUT"):
        sec["connect_timeout"] = float(os.environ["HELTEC_CONNECT_TIMEOUT"])

elif radio_type == "usb_heltec":
    sec = cfg.setdefault("usb_heltec", {})
    if os.environ.get("SERIAL_PORT"):
        sec["port"] = os.environ["SERIAL_PORT"]
    if os.environ.get("BAUDRATE"):
        sec["baudrate"] = int(os.environ["BAUDRATE"])

# Shared radio-parameter overrides apply regardless of transport.
radio = cfg.setdefault("radio", {})
if os.environ.get("FREQUENCY"):        radio["frequency"]        = int(os.environ["FREQUENCY"])
if os.environ.get("TX_POWER"):         radio["tx_power"]         = int(os.environ["TX_POWER"])
if os.environ.get("BANDWIDTH"):        radio["bandwidth"]        = int(os.environ["BANDWIDTH"])
if os.environ.get("SPREADING_FACTOR"): radio["spreading_factor"] = int(os.environ["SPREADING_FACTOR"])
if os.environ.get("CODING_RATE"):      radio["coding_rate"]      = int(os.environ["CODING_RATE"])
if os.environ.get("SYNC_WORD"):        radio["sync_word"]        = int(os.environ["SYNC_WORD"], 0)
if os.environ.get("PREAMBLE_LENGTH"):  radio["preamble_length"]  = int(os.environ["PREAMBLE_LENGTH"])

# Repeater identity / admin password — SEED-ONLY semantics.
# Once the user has chosen something other than the placeholder default
# (typically through the /setup wizard) we leave their value alone, even
# if NODE_NAME / ADMIN_PASSWORD are still set in the env. Otherwise the
# wizard's effort would be reverted on every container restart and the
# `needs_setup` indicator would never clear.
rpt = cfg.setdefault("repeater", {})
NAME_PLACEHOLDERS = {"", "mesh-repeater-01", "pyMC_USB_RPT", "USB_Repeater"}
PW_PLACEHOLDERS = {"", "admin123"}

if os.environ.get("NODE_NAME"):
    cur = rpt.get("node_name", "")
    if cur in NAME_PLACEHOLDERS:
        rpt["node_name"] = os.environ["NODE_NAME"]

if os.environ.get("ADMIN_PASSWORD"):
    sec = rpt.setdefault("security", {})
    cur_pw = sec.get("admin_password", "")
    if cur_pw in PW_PLACEHOLDERS:
        sec["admin_password"] = os.environ["ADMIN_PASSWORD"]

with open(path, "w") as f:
    yaml.safe_dump(cfg, f, sort_keys=False)

print(f"[OK] Config prepared: radio_type={radio_type}")
PYEOF

# Reachability summary — non-fatal in every branch. With deferred-connect
# the repeater can start without a live Heltec; the user provisions the
# real endpoint through the web UI.
RADIO_TYPE=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG')).get('radio_type','tcp_heltec'))")

case "$RADIO_TYPE" in
    tcp_heltec)
        HOST=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG')).get('tcp_heltec',{}).get('host',''))")
        PORT=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG')).get('tcp_heltec',{}).get('port',5055))")
        echo "[INFO] TCP Heltec target: ${HOST:-<unset>}:${PORT}"

        case "$HOST" in
            ""|"192.168.1.50"|"heltec-abcdef.local")
                echo "[WARN] tcp_heltec.host is still a placeholder."
                echo "       The repeater will start in deferred-connect mode —"
                echo "       open the web UI and set the real host via the"
                echo "       \"Heltec config\" panel, or restart with HELTEC_HOST=<ip>."
                ;;
            *)
                python3 - <<PYPROBE || true
import socket
try:
    s = socket.create_connection(("$HOST", int("$PORT")), timeout=3)
    s.close()
    print("[OK]   Modem reachable on TCP")
except Exception as e:
    print(f"[WARN] Modem not reachable yet: {e} — continuing (deferred connect)")
PYPROBE
                ;;
        esac
        ;;

    usb_heltec)
        PORT=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG')).get('usb_heltec',{}).get('port','/dev/ttyUSB0'))")
        if [ -c "$PORT" ]; then
            echo "[OK]   USB device present: $PORT"
        else
            echo "[WARN] USB device not found: $PORT"
            echo "       Pass --device=$PORT to docker run, or set SERIAL_PORT."
            ls -la /dev/ttyUSB* /dev/ttyACM* 2>/dev/null \
                || echo "       No serial devices visible in container."
        fi
        ;;

    *)
        echo "[ERROR] Unknown RADIO_TYPE: $RADIO_TYPE"
        echo "        Expected one of: tcp_heltec, usb_heltec, sx1262"
        # sx1262 falls through to the repeater itself for validation.
        ;;
esac

echo "[INFO] Starting pymc_repeater..."
cd /opt/pymc_repeater

# pymc_repeater's entrypoint module path moved a few times across releases —
# probe the most likely options before falling back to `python -m repeater`.
if [ -f "repeater/main.py" ]; then
    exec python3 -u repeater/main.py --config "$CONFIG" "$@"
elif [ -f "main.py" ]; then
    exec python3 -u main.py --config "$CONFIG" "$@"
else
    exec python3 -u -m repeater --config "$CONFIG" "$@"
fi
