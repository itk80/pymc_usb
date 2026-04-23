// =============================================================
// ota_manager.cpp — OTA via ArduinoOTA + HTTP /update, with
// dual-bank rollback guarded by a sanity watchdog.
// =============================================================
#include "ota_manager.h"

#include <ArduinoOTA.h>
#include <ESPmDNS.h>
#include <Update.h>
#include <WebServer.h>
#include <WiFi.h>
#include <esp_ota_ops.h>

namespace OTAManager {

static constexpr uint32_t SANITY_TIMEOUT_MS = 120000;  // mark firmware valid after 2 min of health
static constexpr uint16_t HTTP_PORT         = 80;

static String      hostname;
static String      token;
static WebServer*  httpServer       = nullptr;
static bool        started          = false;
static bool        markedValid      = false;
static uint32_t    sanityDeadline   = 0;
static bool        sawValidFrame    = false;

// ─── Rollback sanity check ──────────────────────────────────
//
// When ESP-IDF boots from a newly-written slot, otadata marks it as
// "PENDING_VERIFY". On the NEXT reboot the bootloader auto-reverts to
// the previous slot unless we call esp_ota_mark_app_valid_cancel_rollback()
// first. We only call it once we've proven:
//   1. the radio came up (checked in main.cpp before OTAManager::begin)
//   2. a valid host frame was parsed — proves USB-CDC + frame parser work
//   3. we've been running for SANITY_TIMEOUT_MS without crashing
static void attemptMarkValid() {
    if (markedValid) return;
    if (!sawValidFrame) return;
    if ((int32_t)(millis() - sanityDeadline) < 0) return;

    const esp_partition_t* running = esp_ota_get_running_partition();
    esp_ota_img_states_t state;
    if (esp_ota_get_state_partition(running, &state) != ESP_OK) {
        markedValid = true;   // nothing we can do; stop retrying
        return;
    }
    if (state == ESP_OTA_IMG_PENDING_VERIFY) {
        esp_err_t err = esp_ota_mark_app_valid_cancel_rollback();
        Serial.printf("[OTA] marked running app valid: %s\n",
                      err == ESP_OK ? "OK" : "FAIL");
    } else {
        Serial.printf("[OTA] running app state=%d (no rollback needed)\n", (int)state);
    }
    markedValid = true;
}

// ─── HTTP POST /update handler ──────────────────────────────
static bool checkAuth() {
    if (token.length() == 0) return true;  // open — matches TCP "no-auth" mode
    if (!httpServer->authenticate("heltec", token.c_str())) {
        httpServer->requestAuthentication(BASIC_AUTH, "Heltec LoRa Modem");
        return false;
    }
    return true;
}

static void handleRoot() {
    if (!checkAuth()) return;
    String body;
    body.reserve(1024);
    body += F("<!DOCTYPE html><html><head><meta charset='utf-8'>"
              "<title>Heltec LoRa Modem</title>"
              "<style>body{font-family:system-ui,sans-serif;max-width:540px;"
              "margin:1em auto;padding:0 1em;color:#222}"
              "input[type=file]{margin:1em 0}"
              "button{padding:.6em 1em;background:#3a7;color:#fff;border:0;border-radius:4px}"
              ".m{color:#666;font-size:.9em}</style></head><body>");
    body += F("<h2>Heltec LoRa Modem</h2>");
    body += "<p class='m'>mDNS: <b>" + hostname + ".local</b> &nbsp; IP: <b>" +
            WiFi.localIP().toString() + "</b></p>";
    body += F("<h3>OTA update</h3>"
              "<form method='POST' action='/update' enctype='multipart/form-data'>"
              "<input type='file' name='firmware' accept='.bin' required>"
              "<br><button type='submit'>Upload firmware.bin</button>"
              "</form>"
              "<p class='m'>CLI alternative: "
              "<code>curl -F firmware=@firmware.bin http://");
    body += hostname + ".local/update</code></p>";
    body += F("</body></html>");
    httpServer->send(200, "text/html; charset=utf-8", body);
}

static void handleUpdateResult() {
    if (!checkAuth()) return;
    bool ok = !Update.hasError();
    String body;
    if (ok) {
        body = F("OK — rebooting into new firmware. "
                 "If the new image fails its sanity check within 2 minutes, "
                 "the bootloader will roll back automatically.");
    } else {
        body = String(F("FAIL — ")) + Update.errorString();
    }
    httpServer->send(ok ? 200 : 500, "text/plain", body);
    if (ok) {
        delay(500);
        ESP.restart();
    }
}

static void handleUpdateUpload() {
    if (!checkAuth()) return;
    HTTPUpload& up = httpServer->upload();

    if (up.status == UPLOAD_FILE_START) {
        Serial.printf("[OTA/HTTP] upload start: %s (%u bytes expected)\n",
                      up.filename.c_str(), (unsigned)up.totalSize);
        if (!Update.begin(UPDATE_SIZE_UNKNOWN)) {
            Update.printError(Serial);
        }
    } else if (up.status == UPLOAD_FILE_WRITE) {
        if (Update.write(up.buf, up.currentSize) != up.currentSize) {
            Update.printError(Serial);
        }
    } else if (up.status == UPLOAD_FILE_END) {
        if (Update.end(true)) {
            Serial.printf("[OTA/HTTP] upload complete: %u bytes\n",
                          (unsigned)up.totalSize);
        } else {
            Update.printError(Serial);
        }
    } else if (up.status == UPLOAD_FILE_ABORTED) {
        Update.end();
        Serial.println("[OTA/HTTP] upload aborted");
    }
}

// ─── ArduinoOTA plumbing ────────────────────────────────────
static void configureArduinoOTA() {
    ArduinoOTA.setHostname(hostname.c_str());
    if (token.length() > 0) {
        ArduinoOTA.setPassword(token.c_str());
    }
    ArduinoOTA.onStart([]() {
        Serial.println("[OTA/Arduino] start");
    });
    ArduinoOTA.onEnd([]() {
        Serial.println("[OTA/Arduino] end");
    });
    ArduinoOTA.onError([](ota_error_t e) {
        Serial.printf("[OTA/Arduino] error %u\n", (unsigned)e);
    });
    ArduinoOTA.begin();
}

// ─── Public API ─────────────────────────────────────────────
void begin(const String& hn, const String& tk) {
    if (started) return;
    hostname = hn;
    token    = tk;

    if (!MDNS.begin(hostname.c_str())) {
        Serial.println("[OTA] mDNS start failed");
    } else {
        MDNS.addService("http", "tcp", HTTP_PORT);
        MDNS.addService("arduino", "tcp", 3232);
        Serial.printf("[OTA] mDNS advertising %s.local\n", hostname.c_str());
    }

    configureArduinoOTA();

    httpServer = new WebServer(HTTP_PORT);
    httpServer->on("/",       HTTP_GET,  handleRoot);
    httpServer->on("/update", HTTP_POST, handleUpdateResult, handleUpdateUpload);
    httpServer->onNotFound([]() { httpServer->send(404, "text/plain", "Not found"); });
    httpServer->begin();

    sanityDeadline = millis() + SANITY_TIMEOUT_MS;
    sawValidFrame  = false;
    markedValid    = false;
    started        = true;

    Serial.printf("[OTA] HTTP /update + ArduinoOTA ready on %s (%s)\n",
                  WiFi.localIP().toString().c_str(),
                  token.length() > 0 ? "auth: token" : "auth: open");
}

void loop() {
    if (!started) return;
    ArduinoOTA.handle();
    if (httpServer) httpServer->handleClient();
    if (!markedValid) attemptMarkValid();
}

void notifyValidFrame() {
    sawValidFrame = true;
}

const char* getHostname() {
    return hostname.c_str();
}

} // namespace OTAManager
