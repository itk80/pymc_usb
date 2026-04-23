// =============================================================
// wifi_manager.cpp — STA with AP-fallback, NVS config, PRG reset
// =============================================================
#include "wifi_manager.h"
#include "config_portal.h"

#include <WiFi.h>
#include <Preferences.h>

namespace WifiManager {

static constexpr const char* NVS_NAMESPACE         = "lora_modem";
static constexpr uint16_t    DEFAULT_TCP_PORT      = 5055;
static constexpr uint32_t    STA_CONNECT_TIMEOUT_MS = 30000;
static constexpr int         PRG_BUTTON_PIN        = 0;     // Heltec V3 PRG = GPIO0
static constexpr uint32_t    PRG_RESET_HOLD_MS     = 3000;

static Config  cfg;
static Mode    currentMode = Mode::OFFLINE;
static String  apSSID;
static String  ipStr       = "---";
static bool    eventsRegistered = false;

// Log lines use plain ASCII so any connected host protocol parser
// just discards them while waiting for the PROTO_SYNC (0xAA) byte.
static const char* wifiEventName(arduino_event_id_t id) {
    switch (id) {
        case ARDUINO_EVENT_WIFI_STA_START:        return "STA_START";
        case ARDUINO_EVENT_WIFI_STA_STOP:         return "STA_STOP";
        case ARDUINO_EVENT_WIFI_STA_CONNECTED:    return "STA_ASSOCIATED";
        case ARDUINO_EVENT_WIFI_STA_DISCONNECTED: return "STA_DISCONNECTED";
        case ARDUINO_EVENT_WIFI_STA_GOT_IP:       return "STA_GOT_IP";
        case ARDUINO_EVENT_WIFI_STA_LOST_IP:      return "STA_LOST_IP";
        case ARDUINO_EVENT_WIFI_AP_START:         return "AP_START";
        case ARDUINO_EVENT_WIFI_AP_STOP:          return "AP_STOP";
        default:                                  return "OTHER";
    }
}

static void onWiFiEvent(arduino_event_id_t event, arduino_event_info_t info) {
    switch (event) {
        case ARDUINO_EVENT_WIFI_STA_CONNECTED:
            Serial.printf("[WiFi] %s ch=%d\n",
                          wifiEventName(event), info.wifi_sta_connected.channel);
            break;
        case ARDUINO_EVENT_WIFI_STA_DISCONNECTED:
            Serial.printf("[WiFi] %s reason=%d\n",
                          wifiEventName(event), info.wifi_sta_disconnected.reason);
            break;
        case ARDUINO_EVENT_WIFI_STA_GOT_IP:
            Serial.printf("[WiFi] %s ip=%s\n",
                          wifiEventName(event), WiFi.localIP().toString().c_str());
            break;
        default:
            Serial.printf("[WiFi] event %s (%d)\n", wifiEventName(event), (int)event);
            break;
    }
}

static void loadConfig() {
    Preferences p;
    if (!p.begin(NVS_NAMESPACE, true)) {
        cfg = {};
        cfg.tcpPort = DEFAULT_TCP_PORT;
        return;
    }
    cfg.ssid        = p.getString("ssid",  "");
    cfg.password    = p.getString("pass",  "");
    cfg.useStaticIP = p.getBool  ("static", false);
    cfg.staticIP    = IPAddress(p.getUInt("ip",  0));
    cfg.gateway     = IPAddress(p.getUInt("gw",  0));
    cfg.subnet      = IPAddress(p.getUInt("sn",  0));
    cfg.dns         = IPAddress(p.getUInt("dns", 0));
    cfg.tcpToken    = p.getString("token", "");
    cfg.tcpPort     = p.getUShort("port", DEFAULT_TCP_PORT);
    p.end();
}

void saveConfig(const Config& newCfg) {
    Preferences p;
    if (!p.begin(NVS_NAMESPACE, false)) return;
    p.putString("ssid",  newCfg.ssid);
    p.putString("pass",  newCfg.password);
    p.putBool  ("static", newCfg.useStaticIP);
    p.putUInt  ("ip",    (uint32_t)newCfg.staticIP);
    p.putUInt  ("gw",    (uint32_t)newCfg.gateway);
    p.putUInt  ("sn",    (uint32_t)newCfg.subnet);
    p.putUInt  ("dns",   (uint32_t)newCfg.dns);
    p.putString("token", newCfg.tcpToken);
    p.putUShort("port",  newCfg.tcpPort);
    p.end();
    cfg = newCfg;
}

void factoryReset() {
    Preferences p;
    if (p.begin(NVS_NAMESPACE, false)) {
        p.clear();
        p.end();
    }
    delay(200);
    ESP.restart();
}

void checkResetButton() {
    pinMode(PRG_BUTTON_PIN, INPUT_PULLUP);
    if (digitalRead(PRG_BUTTON_PIN) != LOW) return;

    uint32_t start = millis();
    while (digitalRead(PRG_BUTTON_PIN) == LOW) {
        if (millis() - start >= PRG_RESET_HOLD_MS) {
            factoryReset();   // does not return
            return;
        }
        delay(10);
    }
}

static void buildAPSsid() {
    uint8_t mac[6];
    WiFi.macAddress(mac);
    char buf[32];
    snprintf(buf, sizeof(buf), "LoRa-Modem-%02X%02X", mac[4], mac[5]);
    apSSID = buf;
}

static void startAPMode() {
    buildAPSsid();
    WiFi.mode(WIFI_AP);
    WiFi.softAP(apSSID.c_str(), nullptr);   // open AP (user-requested)
    ipStr = WiFi.softAPIP().toString();
    currentMode = Mode::AP_CONFIG;
    ConfigPortal::begin();
}

static bool attemptSTA() {
    if (cfg.ssid.length() == 0) return false;

    Serial.printf("[WiFi] STA connecting to '%s' (%s, port=%u, auth=%s)\n",
                  cfg.ssid.c_str(),
                  cfg.useStaticIP ? "static IP" : "DHCP",
                  (unsigned)cfg.tcpPort,
                  cfg.tcpToken.length() > 0 ? "token" : "open");

    WiFi.persistent(false);   // we manage persistence via Preferences
    WiFi.setAutoReconnect(true);
    WiFi.mode(WIFI_STA);
    if (cfg.useStaticIP) {
        WiFi.config(cfg.staticIP, cfg.gateway, cfg.subnet, cfg.dns);
    }
    WiFi.begin(cfg.ssid.c_str(), cfg.password.c_str());
    currentMode = Mode::STA_CONNECTING;

    uint32_t start = millis();
    uint32_t lastLog = 0;
    while (WiFi.status() != WL_CONNECTED) {
        if (millis() - start >= STA_CONNECT_TIMEOUT_MS) {
            Serial.printf("[WiFi] STA timeout after %us, last status=%d\n",
                          (unsigned)(STA_CONNECT_TIMEOUT_MS / 1000),
                          (int)WiFi.status());
            return false;
        }
        if (millis() - lastLog >= 1000) {
            lastLog = millis();
            Serial.printf("[WiFi] waiting… status=%d  t=%us\n",
                          (int)WiFi.status(),
                          (unsigned)((millis() - start) / 1000));
        }
        delay(100);
    }

    ipStr = WiFi.localIP().toString();
    currentMode = Mode::STA_CONNECTED;
    Serial.printf("[WiFi] STA connected ip=%s rssi=%d\n",
                  ipStr.c_str(), WiFi.RSSI());
    return true;
}

void begin() {
    loadConfig();

    Serial.printf("[Boot] WifiManager: saved ssid='%s' %s\n",
                  cfg.ssid.c_str(),
                  cfg.ssid.length() == 0 ? "(empty -> AP mode)" : "");

    if (!eventsRegistered) {
        WiFi.onEvent(onWiFiEvent);
        eventsRegistered = true;
    }

    if (cfg.ssid.length() == 0) {
        startAPMode();
        Serial.printf("[WiFi] AP '%s' up, ip=%s\n", apSSID.c_str(), ipStr.c_str());
        return;
    }

    if (attemptSTA()) return;

    // STA failed — fall back to AP so user can fix credentials
    Serial.println("[WiFi] STA failed -> fallback to AP mode");
    WiFi.disconnect(true);
    startAPMode();
    Serial.printf("[WiFi] AP '%s' up, ip=%s\n", apSSID.c_str(), ipStr.c_str());
}

void loop() {
    switch (currentMode) {
    case Mode::AP_CONFIG:
        ConfigPortal::loop();
        break;

    case Mode::STA_CONNECTED:
        if (WiFi.status() != WL_CONNECTED) {
            currentMode = Mode::STA_CONNECTING;
            ipStr = "---";
        }
        break;

    case Mode::STA_CONNECTING:
        if (WiFi.status() == WL_CONNECTED) {
            ipStr = WiFi.localIP().toString();
            currentMode = Mode::STA_CONNECTED;
        }
        break;

    case Mode::OFFLINE:
        break;
    }
}

Mode        getMode()         { return currentMode; }
bool        isSTAConnected()  { return currentMode == Mode::STA_CONNECTED; }
bool        isAPActive()      { return currentMode == Mode::AP_CONFIG; }
const char* getIPString()     { return ipStr.c_str(); }
const Config& getConfig()     { return cfg; }

const char* getSSID() {
    if (currentMode == Mode::AP_CONFIG) return apSSID.c_str();
    if (cfg.ssid.length() > 0)          return cfg.ssid.c_str();
    return "---";
}

} // namespace WifiManager
