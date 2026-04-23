// =============================================================
// wifi_manager.h — Wi-Fi STA + AP-fallback manager for Heltec V3
// NVS-backed config (Preferences), PRG button factory reset.
// =============================================================
#pragma once

#include <Arduino.h>
#include <IPAddress.h>

namespace WifiManager {

enum class Mode : uint8_t {
    OFFLINE        = 0,
    STA_CONNECTING = 1,
    STA_CONNECTED  = 2,
    AP_CONFIG      = 3,
};

struct Config {
    String    ssid;
    String    password;
    bool      useStaticIP;
    IPAddress staticIP;
    IPAddress gateway;
    IPAddress subnet;
    IPAddress dns;
    String    tcpToken;  // empty = no auth required
    uint16_t  tcpPort;   // default 5055
};

// Poll PRG button at boot; if held >= 3s, wipe NVS and reboot. Call from setup().
void checkResetButton();

// Load NVS config, try STA connect; on failure or empty config, start AP mode with
// on-device configuration web UI. Blocks up to ~30s during STA attempt.
void begin();

// Service background WiFi state transitions and config portal. Call every loop().
void loop();

Mode        getMode();
const char* getSSID();        // current STA SSID, or AP SSID in AP_CONFIG
const char* getIPString();    // dotted quad, "---" when offline
bool        isSTAConnected();
bool        isAPActive();

const Config& getConfig();
void          saveConfig(const Config& cfg);

// Clear NVS Wi-Fi config and restart device. Does not return.
void factoryReset();

} // namespace WifiManager
