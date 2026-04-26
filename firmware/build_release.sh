#!/bin/bash
# =============================================================
# build_release.sh — Build every supported PlatformIO env and
# copy the three flashable artefacts (bootloader / partitions /
# firmware) into firmware/<env>/ so end users can flash with
# esptool without running PlatformIO themselves.
#
# Run from anywhere; resolves paths relative to this script.
# =============================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

PIO="${PIO:-$HOME/.platformio/penv/bin/pio}"
if ! [ -x "$PIO" ] && command -v pio >/dev/null 2>&1; then
    PIO=pio
fi
if ! [ -x "$PIO" ] && ! command -v "$PIO" >/dev/null 2>&1; then
    echo "ERROR: PlatformIO not found. Install via:"
    echo "         pip install platformio"
    exit 1
fi

# Discover envs from platformio.ini (any [env:NAME] line — minus the
# common [env] block — counts as a build target).
ENVS=$(grep -oE '^\[env:[a-zA-Z0-9_-]+\]' platformio.ini | sed 's/^\[env:\(.*\)\]/\1/')
if [ -z "$ENVS" ]; then
    echo "ERROR: no [env:NAME] blocks found in platformio.ini"
    exit 1
fi

echo "Building envs: $(echo "$ENVS" | xargs)"

for env in $ENVS; do
    echo
    echo "=== $env ==="
    "$PIO" run -e "$env"
    out_dir=".pio/build/$env"
    if [ ! -f "$out_dir/firmware.bin" ]; then
        echo "ERROR: $out_dir/firmware.bin missing after build"
        exit 1
    fi
    mkdir -p "$env"
    cp "$out_dir/bootloader.bin" "$env/bootloader.bin"
    cp "$out_dir/partitions.bin" "$env/partitions.bin"
    cp "$out_dir/firmware.bin"   "$env/firmware.bin"
    echo "  → firmware/$env/{bootloader,partitions,firmware}.bin"
done

echo
echo "Done. Flash any board with:"
echo "    esptool.py --chip esp32s3 --port /dev/ttyUSB0 --baud 921600 \\"
echo "        write_flash 0x0 firmware/<env>/bootloader.bin \\"
echo "                    0x8000 firmware/<env>/partitions.bin \\"
echo "                    0x10000 firmware/<env>/firmware.bin"
