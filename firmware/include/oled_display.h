// =============================================================
// oled_display.h — OLED status display for Heltec V3
// Uses Adafruit_SSD1306 (same as MeshCore firmware)
// =============================================================
#pragma once

#include <Wire.h>
#include <Adafruit_GFX.h>
#define SSD1306_NO_SPLASH
#include <Adafruit_SSD1306.h>

class OledDisplay {
public:
    void begin();
    void showBoot(const char* version);
    // state is a short tag (e.g. "AP", "WiFi", "RX") shown top-right.
    // version is shown in the header so the currently-running firmware is
    // visible at a glance — useful after OTA to confirm the new build.
    void showStatus(uint32_t rx, uint32_t tx,
                    const char* ssid, const char* ip,
                    const char* state, const char* version);
    // Secondary screen: live radio configuration (freq, SF, BW, CR, power,
    // preamble, sync word). Reached by short-tap PRG from the status screen.
    void showRadioConfig(uint32_t freq_hz, uint32_t bandwidth_hz,
                         uint8_t sf, uint8_t cr, int8_t power_dbm,
                         uint16_t syncword, uint8_t preamble_len,
                         const char* version);
    // Tertiary screen: uptime + host-link health (TCP client IP, last USB
    // command age, CRC error count). Reached by short-tap PRG from the
    // radio screen.
    void showDiagnostics(uint32_t uptime_sec,
                         const char* tcp_client_ip,   // "" when no client
                         uint32_t usb_idle_sec,        // UINT32_MAX = never
                         uint32_t rx_count, uint32_t tx_count,
                         uint32_t crc_errors,
                         const char* version);
    void showError(const char* msg);
    void clear();

    // Power control — panel stays initialized, only DISPLAYOFF/ON is toggled.
    void turnOff();
    void turnOn();

private:
    Adafruit_SSD1306 *_display = nullptr;
    bool _ready = false;
};
