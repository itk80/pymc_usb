// =============================================================
// config_portal.cpp — HTML setup form served in AP mode
// =============================================================
#include "config_portal.h"
#include "wifi_manager.h"

#include <WebServer.h>
#include <WiFi.h>

namespace ConfigPortal {

static WebServer* server = nullptr;
static bool       active = false;

static String htmlEscape(const String& s) {
    String out;
    out.reserve(s.length() + 8);
    for (size_t i = 0; i < s.length(); i++) {
        char c = s[i];
        switch (c) {
            case '<':  out += "&lt;";   break;
            case '>':  out += "&gt;";   break;
            case '&':  out += "&amp;";  break;
            case '"':  out += "&quot;"; break;
            case '\'': out += "&#39;";  break;
            default:   out += c;
        }
    }
    return out;
}

static void handleRoot() {
    const auto& cfg = WifiManager::getConfig();

    // Fresh scan for SSID list (blocks ~1–2 s). Many routers/mesh APs broadcast
    // the same SSID from multiple BSSIDs, so we dedupe by name (keep max RSSI)
    // and sort strongest first.
    int n = WiFi.scanNetworks(false, true);

    static const int MAX_UNIQUE = 32;
    String uniq_ssid[MAX_UNIQUE];
    int    uniq_rssi[MAX_UNIQUE];
    int    uniq_count = 0;
    for (int i = 0; i < n; i++) {
        String s = WiFi.SSID(i);
        int    r = WiFi.RSSI(i);
        if (s.length() == 0) continue;
        int found = -1;
        for (int j = 0; j < uniq_count; j++) {
            if (uniq_ssid[j] == s) { found = j; break; }
        }
        if (found >= 0) {
            if (r > uniq_rssi[found]) uniq_rssi[found] = r;
        } else if (uniq_count < MAX_UNIQUE) {
            uniq_ssid[uniq_count] = s;
            uniq_rssi[uniq_count] = r;
            uniq_count++;
        }
    }
    for (int i = 0; i < uniq_count - 1; i++) {
        for (int j = i + 1; j < uniq_count; j++) {
            if (uniq_rssi[j] > uniq_rssi[i]) {
                int    tr = uniq_rssi[i]; uniq_rssi[i] = uniq_rssi[j]; uniq_rssi[j] = tr;
                String ts = uniq_ssid[i]; uniq_ssid[i] = uniq_ssid[j]; uniq_ssid[j] = ts;
            }
        }
    }

    String html;
    html.reserve(6144);
    html += F("<!DOCTYPE html><html><head><meta charset='utf-8'>"
              "<meta name='viewport' content='width=device-width,initial-scale=1'>"
              "<title>LoRa Modem Setup</title>"
              "<style>"
              "body{font-family:system-ui,sans-serif;max-width:480px;margin:1em auto;padding:0 1em;color:#222}"
              "h1{font-size:1.3em}"
              "label{display:block;margin-top:1em;font-weight:600}"
              "input,select{width:100%;padding:.5em;box-sizing:border-box;font-size:1em}"
              "input[type=checkbox]{width:auto;margin-right:.5em}"
              "button{margin-top:1.5em;padding:.75em;width:100%;background:#3a7;color:#fff;border:0;font-size:1em;border-radius:4px}"
              ".hint{color:#666;font-size:.85em;font-weight:400}"
              "hr{margin:2em 0;border:0;border-top:1px solid #ddd}"
              "</style></head><body>");
    html += F("<h1>LoRa Modem Setup</h1>");
    html += F("<form method='POST' action='/save'>");

    html += F("<label>Wi-Fi SSID</label>");
    html += F("<select name='ssid'>");
    html += F("<option value=''>-- select --</option>");
    for (int i = 0; i < uniq_count; i++) {
        html += "<option value='";
        html += htmlEscape(uniq_ssid[i]);
        html += "'";
        if (uniq_ssid[i] == cfg.ssid) html += " selected";
        html += ">";
        html += htmlEscape(uniq_ssid[i]);
        html += " (";
        html += String(uniq_rssi[i]);
        html += " dBm)</option>";
    }
    html += F("</select>");

    html += F("<label>or manual SSID <span class='hint'>(overrides dropdown)</span></label>");
    html += F("<input type='text' name='ssid_manual' autocomplete='off'>");

    html += F("<label>Wi-Fi password</label>");
    html += "<input type='password' name='password' value='" + htmlEscape(cfg.password) + "'>";

    html += F("<label><input type='checkbox' name='static' value='1'");
    if (cfg.useStaticIP) html += F(" checked");
    html += F("> Use static IP (otherwise DHCP)</label>");

    html += F("<label>Static IP</label>");
    html += "<input type='text' name='ip' value='" + cfg.staticIP.toString() + "' placeholder='192.168.1.42'>";
    html += F("<label>Gateway</label>");
    html += "<input type='text' name='gw' value='" + cfg.gateway.toString() + "' placeholder='192.168.1.1'>";
    html += F("<label>Subnet mask</label>");
    html += "<input type='text' name='sn' value='" + cfg.subnet.toString() + "' placeholder='255.255.255.0'>";
    html += F("<label>DNS</label>");
    html += "<input type='text' name='dns' value='" + cfg.dns.toString() + "' placeholder='1.1.1.1'>";

    html += F("<hr>");
    html += F("<label>TCP port</label>");
    html += "<input type='number' name='port' min='1' max='65535' value='" + String(cfg.tcpPort) + "'>";
    html += F("<label>TCP auth token <span class='hint'>(optional; empty = no auth)</span></label>");
    html += "<input type='text' name='token' autocomplete='off' value='" + htmlEscape(cfg.tcpToken) + "'>";

    html += F("<button type='submit'>Save &amp; Restart</button>");
    html += F("</form></body></html>");

    server->send(200, "text/html; charset=utf-8", html);
    WiFi.scanDelete();
}

static IPAddress parseIP(const String& s) {
    IPAddress ip;
    if (!ip.fromString(s)) ip = IPAddress((uint32_t)0);
    return ip;
}

static void handleSave() {
    WifiManager::Config newCfg = WifiManager::getConfig();

    String ssidSel = server->arg("ssid");
    String ssidMan = server->arg("ssid_manual");
    ssidMan.trim();
    ssidSel.trim();
    newCfg.ssid        = ssidMan.length() > 0 ? ssidMan : ssidSel;
    newCfg.password    = server->arg("password");
    newCfg.useStaticIP = server->hasArg("static");
    newCfg.staticIP    = parseIP(server->arg("ip"));
    newCfg.gateway     = parseIP(server->arg("gw"));
    newCfg.subnet      = parseIP(server->arg("sn"));
    newCfg.dns         = parseIP(server->arg("dns"));
    newCfg.tcpToken    = server->arg("token");

    int port = server->arg("port").toInt();
    if (port < 1 || port > 65535) port = 5055;
    newCfg.tcpPort = (uint16_t)port;

    Serial.printf("[Portal] POST /save: ssid_sel='%s' ssid_manual='%s' -> ssid='%s' "
                  "password_len=%u static=%d port=%u token_len=%u\n",
                  ssidSel.c_str(), ssidMan.c_str(), newCfg.ssid.c_str(),
                  (unsigned)newCfg.password.length(),
                  (int)newCfg.useStaticIP,
                  (unsigned)newCfg.tcpPort,
                  (unsigned)newCfg.tcpToken.length());

    if (newCfg.ssid.length() == 0) {
        Serial.println("[Portal] Save rejected: empty SSID");
        String err = F("<!DOCTYPE html><html><body style='font-family:system-ui,sans-serif;max-width:480px;margin:2em auto;padding:0 1em'>"
                       "<h2>SSID missing</h2>"
                       "<p>Select a network from the dropdown (not the '-- select --' entry) "
                       "or type one in the manual field. Password alone is not enough.</p>"
                       "<p><a href='/'>&larr; Back to form</a></p>"
                       "</body></html>");
        server->send(400, "text/html; charset=utf-8", err);
        return;
    }

    WifiManager::saveConfig(newCfg);
    Serial.printf("[Portal] Saved to NVS, rebooting into STA for '%s'\n",
                  newCfg.ssid.c_str());

    String body = F("<!DOCTYPE html><html><body style='font-family:system-ui,sans-serif;text-align:center;margin-top:3em'>"
                    "<h2>Saved. Rebooting…</h2>"
                    "<p>Device will attempt to join <b>");
    body += htmlEscape(newCfg.ssid);
    body += F("</b>.</p></body></html>");
    server->send(200, "text/html; charset=utf-8", body);

    delay(1000);
    ESP.restart();
}

void begin() {
    if (server) return;
    server = new WebServer(80);
    server->on("/",     HTTP_GET,  handleRoot);
    server->on("/save", HTTP_POST, handleSave);
    server->onNotFound([]() { server->send(404, "text/plain", "Not found"); });
    server->begin();
    active = true;
}

void loop() {
    if (server) server->handleClient();
}

bool isActive() { return active; }

} // namespace ConfigPortal
