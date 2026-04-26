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
#   3. Apply env-var overrides (PYMC_TCP_HOST/PORT/TOKEN, SERIAL_PORT, …)
#      to the live config via PyYAML, so the user can change radio
#      settings without rebuilding the image. Legacy HELTEC_* env vars
#      are still accepted as fallbacks.
#
# Deferred-connect: if PYMC_TCP_HOST is unset and the placeholder is
# still in the config, we DO NOT abort. TCPLoRaRadio in pymc_usb
# supports deferred-connect mode — the repeater starts and the user
# finishes configuring the modem endpoint via the web UI's
# "pymc_tcp config" panel.
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

# Accept both the new pymc_* names and the legacy *_heltec aliases.
# Normalise to the new ones on disk so the in-place file migrates
# forward on first start with the new entrypoint.
TCP_TYPES = {"pymc_tcp", "tcp_heltec"}
USB_TYPES = {"pymc_usb", "usb_heltec"}
radio_type = os.environ.get("RADIO_TYPE", cfg.get("radio_type", "pymc_tcp")).strip()
if radio_type in TCP_TYPES:
    radio_type = "pymc_tcp"
elif radio_type in USB_TYPES:
    radio_type = "pymc_usb"
cfg["radio_type"] = radio_type

if radio_type == "pymc_tcp":
    # Migrate any legacy `tcp_heltec` section to `pymc_tcp` on first
    # touch so the on-disk file ends up with a single section name.
    if "tcp_heltec" in cfg and "pymc_tcp" not in cfg:
        cfg["pymc_tcp"] = cfg.pop("tcp_heltec")
    elif "tcp_heltec" in cfg:
        cfg.pop("tcp_heltec", None)
    sec = cfg.setdefault("pymc_tcp", {})
    # PYMC_TCP_* env wins over the legacy HELTEC_* names.
    host = os.environ.get("PYMC_TCP_HOST") or os.environ.get("HELTEC_HOST")
    if host:
        sec["host"] = host
    port = os.environ.get("PYMC_TCP_PORT") or os.environ.get("HELTEC_PORT")
    if port:
        sec["port"] = int(port)
    # Token override is opt-in; an empty env-var string still counts as
    # "set to empty" because users sometimes need to explicitly clear it.
    if "PYMC_TCP_TOKEN" in os.environ:
        sec["token"] = os.environ["PYMC_TCP_TOKEN"]
    elif "HELTEC_TOKEN" in os.environ:
        sec["token"] = os.environ["HELTEC_TOKEN"]
    timeout = (os.environ.get("PYMC_TCP_CONNECT_TIMEOUT")
               or os.environ.get("HELTEC_CONNECT_TIMEOUT"))
    if timeout:
        sec["connect_timeout"] = float(timeout)

elif radio_type == "pymc_usb":
    if "usb_heltec" in cfg and "pymc_usb" not in cfg:
        cfg["pymc_usb"] = cfg.pop("usb_heltec")
    elif "usb_heltec" in cfg:
        cfg.pop("usb_heltec", None)
    sec = cfg.setdefault("pymc_usb", {})
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

# Backfill defaults that pymc_console's Configuration page assumes are
# present. Older configs (any deployment older than 2026-04-25) often
# don't have repeater.advert_adaptive — without these keys the page
# crashes with "undefined is not an object (evaluating
# 'v.thresholds.quiet_max')". setdefault keeps user-customised values
# intact; we only add the keys that are missing.
ADAPTIVE_DEFAULTS = {"quiet_max": 0.05, "normal_max": 0.20, "busy_max": 0.50}
adaptive = rpt.setdefault("advert_adaptive", {})
thr = adaptive.setdefault("thresholds", {})
for k, v in ADAPTIVE_DEFAULTS.items():
    thr.setdefault(k, v)

with open(path, "w") as f:
    yaml.safe_dump(cfg, f, sort_keys=False)

print(f"[OK] Config prepared: radio_type={radio_type}")
PYEOF

# Reachability summary — non-fatal in every branch. With deferred-connect
# the repeater can start without a live modem; the user provisions the
# real endpoint through the web UI.
RADIO_TYPE=$(python3 -c "import yaml; print(yaml.safe_load(open('$CONFIG')).get('radio_type','pymc_tcp'))")

case "$RADIO_TYPE" in
    pymc_tcp|tcp_heltec)
        HOST=$(python3 -c "import yaml; c=yaml.safe_load(open('$CONFIG')); print((c.get('pymc_tcp') or c.get('tcp_heltec') or {}).get('host',''))")
        PORT=$(python3 -c "import yaml; c=yaml.safe_load(open('$CONFIG')); print((c.get('pymc_tcp') or c.get('tcp_heltec') or {}).get('port',5055))")
        echo "[INFO] pymc_tcp target: ${HOST:-<unset>}:${PORT}"

        case "$HOST" in
            ""|"192.168.1.50"|"ikoka-abcdef.local"|"heltec-abcdef.local")
                echo "[WARN] pymc_tcp.host is still a placeholder."
                echo "       The repeater will start in deferred-connect mode —"
                echo "       open the web UI and set the real host via the"
                echo "       \"pymc_tcp config\" panel, or restart with PYMC_TCP_HOST=<ip>."
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

    pymc_usb|usb_heltec)
        PORT=$(python3 -c "import yaml; c=yaml.safe_load(open('$CONFIG')); print((c.get('pymc_usb') or c.get('usb_heltec') or {}).get('port','/dev/ttyUSB0'))")
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
        echo "        Expected one of: pymc_tcp, pymc_usb, sx1262"
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
