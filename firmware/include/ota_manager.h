// =============================================================
// ota_manager.h — OTA firmware update over Wi-Fi (STA mode)
//
// Two routes, both always-on whenever STA is connected:
//   - ArduinoOTA  : espota.py / pio run -t upload --upload-port <host>.local
//   - HTTP POST   : curl -F firmware=@firmware.bin http://<host>.local/update
//
// Dual-bank rollback: new firmware only "stays" if it passes a sanity
// check (SX1262 init OK + at least one valid USB/TCP frame received
// within OTA_SANITY_TIMEOUT_MS). Otherwise bootloader auto-reverts to
// the previous partition.
// =============================================================
#pragma once

#include <Arduino.h>
#include <stdint.h>

namespace OTAManager {

// Start ArduinoOTA + HTTP /update endpoint on port 80.
// `token` is reused from WifiManager config — if non-empty, HTTP /update
// requires Basic auth with user="heltec", pass=token; ArduinoOTA uses the
// same value as its upload password. Must be called after WiFi STA is up.
void begin(const String& hostname, const String& token);

// Service pending OTA transactions + feed the rollback sanity watchdog.
// Call every loop().
void loop();

// Call once from the host-frame path when a valid frame has been processed.
// After OTA_SANITY_TIMEOUT_MS (default 120 s) of operating without crash
// AND this ping, the current firmware is marked valid and rollback is
// cancelled. Cheap — safe to invoke on every frame.
void notifyValidFrame();

// Current mDNS hostname ("heltec-ab12cd"), suitable for building
// "heltec-ab12cd.local" on the host. Returns empty string before begin().
const char* getHostname();

} // namespace OTAManager
