# =============================================================================
# pyMC Repeater + Heltec modem (Wi-Fi/TCP or USB-CDC)
# https://github.com/itk80/pymc_usb
#
# Default transport is tcp_heltec — the Heltec board lives on the LAN and
# the container talks to it over TCP, no USB passthrough required. Switch
# to usb_heltec via env vars if you want to plug the modem into the host.
#
# Build (from repo root):
#   docker build -f docker/Dockerfile -t pymc-usb-repeater .
#
# Run (TCP mode):
#   docker run -d --name repeater -p 8000:8000 \
#     -e HELTEC_HOST=192.168.1.50 -e HELTEC_PORT=5055 \
#     pymc-usb-repeater
#
# Run (USB mode):
#   docker run -d --name repeater \
#     --device=/dev/ttyUSB0:/dev/ttyUSB0 \
#     -p 8000:8000 \
#     -e RADIO_TYPE=usb_heltec -e SERIAL_PORT=/dev/ttyUSB0 \
#     pymc-usb-repeater
# =============================================================================

FROM python:3.12-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        git usbutils curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Dialout group keeps USB-CDC mode usable when the host passes --device.
RUN useradd -r -m -s /bin/bash -G dialout repeater

# --- pyMC_Repeater (editable so install.sh can patch in place) ---
RUN git clone --depth 1 https://github.com/rightup/pyMC_Repeater.git /opt/pymc_repeater

# --- Python deps ---
RUN pip install --no-cache-dir \
        pymc_core \
        pyserial \
        cherrypy \
        pyyaml \
    && pip install --no-cache-dir -e /opt/pymc_repeater 2>/dev/null || true

# --- Bring the whole repo in so install.sh can find pymc_driver/, patches/,
#     scripts/ and config.yaml.example using its normal relative paths.
WORKDIR /tmp/pymc_usb
COPY pymc_driver/  ./pymc_driver/
COPY patches/      ./patches/
COPY scripts/      ./scripts/
COPY config.yaml.example ./config.yaml.example

# --- Required directories (volumes mount on top of these later). ---
RUN mkdir -p /etc/pymc_repeater /var/lib/pymc_repeater /var/log/pymc_repeater \
    && chown -R repeater:repeater /etc/pymc_repeater /var/lib/pymc_repeater /var/log/pymc_repeater

# Pre-seed a sentinel config.yaml so install.sh skips its config-installer
# step (section [4/6]) — we provide our own docker/config.yaml.default below.
RUN printf "radio_type: tcp_heltec\n" > /etc/pymc_repeater/config.yaml

# --- Run the canonical installer: drivers, config.py, radio-settings.json,
#     setup_wizard, Heltec panel HTML+endpoints, JWT exemption, sticky link.
#     systemctl is absent → install.sh's restart block silently skips. ---
RUN chmod +x scripts/install.sh && scripts/install.sh

# --- Replace the sentinel with the real Docker default; the entrypoint
#     re-seeds /etc/pymc_repeater/config.yaml from .default on first run. ---
COPY docker/config.yaml /etc/pymc_repeater/config.yaml.default
RUN rm -f /etc/pymc_repeater/config.yaml \
    && chown -R repeater:repeater /etc/pymc_repeater

COPY docker/entrypoint.sh /opt/pymc_repeater/entrypoint.sh
RUN chmod +x /opt/pymc_repeater/entrypoint.sh

# Build-time scratch no longer needed at runtime.
RUN rm -rf /tmp/pymc_usb

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD curl -sf http://localhost:8000/ || exit 1

USER repeater
ENTRYPOINT ["/opt/pymc_repeater/entrypoint.sh"]
