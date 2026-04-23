// =============================================================
// main.cpp — Heltec LoRa Modem firmware
// Serial + Wi-Fi/TCP bridge to SX1262 for pymc_core on RPi.
//
// Heltec WiFi LoRa 32 V3 (ESP32-S3 + SX1262)
// USB-CDC @ 921600 baud AND/OR TCP on the port configured via NVS.
// OTA (ArduinoOTA + HTTP) is always-on whenever STA is connected.
//
// All MeshCore protocol logic runs on the RPi in pymc_core.
// =============================================================

#include <Arduino.h>
#include <RadioLib.h>
#include <WiFi.h>
#include <esp_task_wdt.h>
#include "protocol.h"
#include "oled_display.h"
#include "wifi_manager.h"
#include "tcp_server.h"
#include "frame_parser.h"
#include "ota_manager.h"

// ─── Version ─────────────────────────────────────────────────
#define FW_VERSION "v0.5.9"

// ─── Task watchdog — self-heal on loop() hang ───────────────
// A 30 s deadline is comfortably longer than any legitimate loop() burst
// (OTA HTTP upload chunks, CAD scans, OLED redraw) but short enough to
// reboot automatically if ArduinoOTA / WebServer / WifiManager deadlocks.
static constexpr uint32_t LOOP_WDT_TIMEOUT_S = 30;

// ─── Hardware setup ──────────────────────────────────────────
// SX1262 on Heltec V3: NSS=8, DIO1=14, RST=12, BUSY=13
SX1262 radio = new Module(LORA_NSS, LORA_DIO1, LORA_RST, LORA_BUSY);

OledDisplay oled;

// ─── Default config: EU/UK (Narrow), Switzerland preset ──────
static RadioConfig currentConfig = {
    .freq_hz      = 869618000,
    .bandwidth_hz = 62500,
    .sf           = 8,
    .cr           = 8,
    .power_dbm    = 22,
    .syncword     = 0x12,
    .preamble_len = 16
};

static StatusResp  status        = {};
// Single DIO1 ISR flag — interpreted as RX_DONE when !isTxActive, otherwise as TX_DONE.
// A single flag avoids the race where an IRQ that fires at the tail of a TX
// could leak into the next RX handler or vice-versa.
static volatile bool dio1Flag    = false;
static bool        radioReady    = false;
static bool        isTxActive    = false;

// ─── Noise floor sampling (mirrors SX1262Radio._sample_noise_floor) ──
#define NUM_NOISE_FLOOR_SAMPLES 20
#define NOISE_SAMPLING_THRESHOLD 10
static float    noiseFloor       = -99.0f;
static float    noiseFloorSum    = 0.0f;
static int      noiseFloorCount  = 0;
static uint32_t lastPacketTime   = 0;
static uint32_t lastNoiseSample  = 0;

// ─── CAD parameters (set by host via CMD_SET_CAD_PARAMS) ─────
// When cadCustom == false we call scanChannel() with RadioLib's defaults;
// host can override by programming peak/min/symbols/exit_mode.
static bool    cadCustom   = false;
static uint8_t cadSymNum   = 0x01;  // RADIOLIB_SX126X_CAD_ON_2_SYMB — matches pymc_core
static uint8_t cadDetPeak  = 22;    // pymc_core default for SF7-SF8
static uint8_t cadDetMin   = 10;    // AN1200.48 recommendation
static uint8_t cadExitMode = 0x00;  // RADIOLIB_SX126X_CAD_GOTO_STDBY

// ─── Transport state ─────────────────────────────────────────
static FrameParser serialParser;
static bool        tcpStarted    = false;
static bool        otaStarted    = false;
static String      deviceHostname;   // e.g. "heltec-ab12cd" (no .local)

// Timing
static uint32_t lastOledUpdate = 0;

// OLED sleep timer + screen cycle
enum class Screen : uint8_t { SLEEP = 0, STATUS = 1, RADIO = 2, DIAGNOSTICS = 3 };
static Screen   currentScreen  = Screen::SLEEP;
static constexpr uint32_t OLED_WAKE_DURATION_MS = 30000;
static constexpr uint32_t PRG_DEBOUNCE_MS       = 200;
static uint32_t oledWakeUntil = 0;
static uint32_t prgIgnoreUntil = 0;

// Host-link health for the DIAGNOSTICS screen: millis() of the last USB
// frame that parsed cleanly. 0 = no frame yet since boot.
static uint32_t lastUsbCmdMs = 0;

// ─── ISR callback ────────────────────────────────────────────
#if defined(ESP32)
IRAM_ATTR
#endif
void onDio1Rise() {
    dio1Flag = true;
}

// ─── Hostname derivation (deterministic from MAC) ───────────
// "heltec-XXXXXX" from last 3 MAC bytes. No OLED needed to find device —
// host resolves it via mDNS: `heltec-ab12cd.local`.
static String buildHostname() {
    uint8_t mac[6];
    WiFi.macAddress(mac);
    char buf[24];
    snprintf(buf, sizeof(buf), "heltec-%02x%02x%02x", mac[3], mac[4], mac[5]);
    return String(buf);
}

// ─── Frame output ────────────────────────────────────────────
static void writeFrame(uint8_t cmd, const uint8_t* payload, uint16_t len,
                       bool toSerial, bool toTCP) {
    uint8_t buf[MAX_FRAME_SIZE];
    uint16_t i = 0;
    buf[i++] = PROTO_SYNC;
    buf[i++] = cmd;
    buf[i++] = len & 0xFF;
    buf[i++] = (len >> 8) & 0xFF;
    if (len > 0 && payload) {
        memcpy(buf + i, payload, len);
        i += len;
    }
    uint16_t crc = crc16_ccitt(buf + 1, 3 + len);
    buf[i++] = crc & 0xFF;
    buf[i++] = (crc >> 8) & 0xFF;

    if (toSerial) {
        // Skip Serial.flush(): on ESP32-S3 TinyUSB, flush blocks indefinitely
        // when the host stops reading from /dev/ttyACM. USB-CDC is buffered by
        // the stack and delivered asynchronously — not calling flush is the
        // recommended pattern and was identified as one cause of loop() hang
        // in v0.5.4.
        Serial.write(buf, i);
    }
    if (toTCP) {
        TCPServer::write(buf, i);
    }
}

void sendFrame(uint8_t cmd, const uint8_t* payload, uint16_t len, TransportSource dest) {
    writeFrame(cmd, payload, len,
               dest == TransportSource::USB,
               dest == TransportSource::TCP);
}

void sendError(uint8_t errCode, TransportSource dest) {
    sendFrame(CMD_ERROR, &errCode, 1, dest);
}

void broadcastFrame(uint8_t cmd, const uint8_t* payload, uint16_t len) {
    writeFrame(cmd, payload, len,
               /*toSerial=*/true,
               /*toTCP=*/TCPServer::isClientReady());
}

// ─── WIFI_STATUS response builder ───────────────────────────
// Payload: mode(1) ip(4,BE) port(2,LE) ssid_len(1) ssid(N) host_len(1) host(M)
static uint16_t buildWifiStatusPayload(uint8_t* out) {
    uint16_t i = 0;

    uint8_t mode;
    switch (WifiManager::getMode()) {
        case WifiManager::Mode::STA_CONNECTED:  mode = 2; break;
        case WifiManager::Mode::STA_CONNECTING: mode = 1; break;
        case WifiManager::Mode::AP_CONFIG:      mode = 3; break;
        default:                                mode = 0; break;
    }
    out[i++] = mode;

    IPAddress ip = WifiManager::isSTAConnected() ? WiFi.localIP()
                 : WifiManager::isAPActive()     ? WiFi.softAPIP()
                                                 : IPAddress((uint32_t)0);
    out[i++] = ip[0];  // big-endian dotted quad
    out[i++] = ip[1];
    out[i++] = ip[2];
    out[i++] = ip[3];

    uint16_t port = WifiManager::getConfig().tcpPort;
    out[i++] = port & 0xFF;
    out[i++] = (port >> 8) & 0xFF;

    const char* ssid = WifiManager::getSSID();
    uint8_t ssid_len = ssid ? (uint8_t)strnlen(ssid, 32) : 0;
    out[i++] = ssid_len;
    if (ssid_len) { memcpy(out + i, ssid, ssid_len); i += ssid_len; }

    uint8_t host_len = (uint8_t)deviceHostname.length();
    if (host_len > 32) host_len = 32;
    out[i++] = host_len;
    if (host_len) { memcpy(out + i, deviceHostname.c_str(), host_len); i += host_len; }

    return i;
}

// ─── SET_WIFI payload parser ────────────────────────────────
// Layout: ssid_len(1) ssid(N) pass_len(1) pass(M) port(2,LE) tok_len(1) tok(K)
static bool parseSetWifi(const uint8_t* p, uint16_t len, WifiManager::Config& out) {
    out = WifiManager::getConfig();   // preserve static IP settings by default
    uint16_t i = 0;

    if (i + 1 > len) return false;
    uint8_t slen = p[i++];
    if (slen == 0 || slen > 32 || i + slen > len) return false;
    out.ssid = String((const char*)(p + i), slen);
    i += slen;

    if (i + 1 > len) return false;
    uint8_t plen = p[i++];
    if (plen > 64 || i + plen > len) return false;
    out.password = plen ? String((const char*)(p + i), plen) : String();
    i += plen;

    if (i + 2 > len) return false;
    uint16_t port = p[i] | ((uint16_t)p[i+1] << 8);
    i += 2;
    if (port == 0) return false;
    out.tcpPort = port;

    if (i + 1 > len) return false;
    uint8_t tlen = p[i++];
    if (tlen > 64 || i + tlen > len) return false;
    out.tcpToken = tlen ? String((const char*)(p + i), tlen) : String();

    out.useStaticIP = false;   // USB provisioning = DHCP only
    return true;
}

// ─── Radio configuration ────────────────────────────────────
bool applyConfig(const RadioConfig& cfg) {
    radio.standby();
    int state;

    state = radio.setFrequency(cfg.freq_hz / 1e6f);
    if (state != RADIOLIB_ERR_NONE) return false;

    state = radio.setBandwidth(cfg.bandwidth_hz / 1000.0f);
    if (state != RADIOLIB_ERR_NONE) return false;

    state = radio.setSpreadingFactor(cfg.sf);
    if (state != RADIOLIB_ERR_NONE) return false;

    state = radio.setCodingRate(cfg.cr);
    if (state != RADIOLIB_ERR_NONE) return false;

    state = radio.setOutputPower(cfg.power_dbm);
    if (state != RADIOLIB_ERR_NONE) return false;

    state = radio.setSyncWord(cfg.syncword);
    if (state != RADIOLIB_ERR_NONE) return false;

    state = radio.setPreambleLength(cfg.preamble_len);
    if (state != RADIOLIB_ERR_NONE) return false;

    radio.explicitHeader();
    radio.setCRC(1);
    radio.invertIQ(false);

    // Auto-LDRO mirrors pymc_core sx1262_wrapper.py — without this,
    // SF11/SF12 presets are modulation-incompatible with pymc_core.
    radio.autoLDRO();

    return true;
}

bool startReceive() {
    return radio.startReceive() == RADIOLIB_ERR_NONE;
}

// ─── Handle received LoRa packet ────────────────────────────
void handleLoRaRx() {
    int len = radio.getPacketLength();
    if (len <= 0 || len > MAX_LORA_PAYLOAD) {
        startReceive();
        return;
    }

    uint8_t rxBuf[MAX_LORA_PAYLOAD];
    int state = radio.readData(rxBuf, len);
    if (state != RADIOLIB_ERR_NONE) {
        status.crc_errors++;
        startReceive();
        return;
    }

    int16_t rssi = (int16_t)radio.getRSSI();
    int16_t snr  = (int16_t)(radio.getSNR() * 10.0f);
    int16_t signal_rssi = rssi;

    status.rx_count++;
    status.last_rssi = rssi;
    status.last_snr  = snr;

    uint8_t rxPayload[6 + MAX_LORA_PAYLOAD];
    rxPayload[0] = rssi & 0xFF;
    rxPayload[1] = (rssi >> 8) & 0xFF;
    rxPayload[2] = snr & 0xFF;
    rxPayload[3] = (snr >> 8) & 0xFF;
    rxPayload[4] = signal_rssi & 0xFF;
    rxPayload[5] = (signal_rssi >> 8) & 0xFF;
    memcpy(rxPayload + 6, rxBuf, len);

    broadcastFrame(CMD_RX_PACKET, rxPayload, 6 + len);
    lastPacketTime = millis();
    startReceive();
}

// ─── Host command dispatch ──────────────────────────────────
void processHostCommand(uint8_t cmd, const uint8_t* payload, uint16_t len,
                        TransportSource src) {
    // Any successfully-processed host frame counts toward OTA sanity.
    OTAManager::notifyValidFrame();

    switch (cmd) {

    case CMD_TX_REQUEST: {
        if (len == 0 || len > MAX_LORA_PAYLOAD) {
            sendError(ERR_PAYLOAD_TOO_BIG, src);
            break;
        }
        // v0.5.7: non-blocking TX with our own timeout.
        // The previous radio.transmit() was synchronous and could wait
        // indefinitely when SX1262 lost the TX_DONE IRQ (observed after CAD
        // timeouts), which in turn blocked loop() long enough for the 30 s
        // task watchdog to reboot the firmware every minute.
        isTxActive = true;
        radio.standby();
        delay(1);

        dio1Flag = false;
        int state = radio.startTransmit((uint8_t*)payload, len);
        if (state != RADIOLIB_ERR_NONE) {
            isTxActive = false;
            radio.finishTransmit();
            sendError(ERR_TX_TIMEOUT, src);
            startReceive();
            break;
        }

        // Worst-case airtime for SF12/BW7.8k at 255 B ≈ 20 s; repeater uses
        // SF8-SF10 so 10 s is plenty. If DIO1 never fires the loop exits on
        // the deadline and we force the radio into a known-good state below.
        const uint32_t TX_TIMEOUT_MS = 10000;
        uint32_t txStart = millis();
        while (!dio1Flag && (millis() - txStart) < TX_TIMEOUT_MS) {
            esp_task_wdt_reset();   // keep watchdog happy while we poll
            delay(2);
        }

        bool txOk = dio1Flag;
        radio.finishTransmit();
        dio1Flag = false;
        isTxActive = false;
        lastPacketTime = millis();

        if (txOk) {
            status.tx_count++;
            uint32_t airtime_us = radio.getTimeOnAir(len);
            uint8_t resp[4];
            resp[0] = airtime_us & 0xFF;
            resp[1] = (airtime_us >> 8) & 0xFF;
            resp[2] = (airtime_us >> 16) & 0xFF;
            resp[3] = (airtime_us >> 24) & 0xFF;
            sendFrame(CMD_TX_DONE, resp, 4, src);
        } else {
            // Hard TX timeout — the SX1262 is likely stuck in a bad state.
            // Rebuild from scratch: standby → re-apply full config → RX.
            Serial.println("[TX] hard timeout — resetting radio state");
            radio.standby();
            delay(5);
            applyConfig(currentConfig);
            sendError(ERR_TX_TIMEOUT, src);
        }
        startReceive();
        break;
    }

    case CMD_CAD_REQUEST: {
        // v0.5.8: non-blocking CAD with our own timeout.
        // The previous radio.scanChannel() was synchronous and would block
        // until CAD_DONE IRQ arrived. When SX1262 dropped that IRQ (first
        // scan after setCAD, or generally unreliable behaviour at SF8/BW62k)
        // loopTask sat in scanChannel for tens of seconds without feeding
        // the task watchdog — reboot cycle every ~60 s.
        radio.standby();
        delay(1);

        dio1Flag = false;
        int state;
        if (cadCustom) {
            // v0.5.9: IRQ flags & mask MUST be set — zero-initialised cfg
            // made RadioLib call setDioIrqParams(0, 0), so CAD_DONE/DETECTED
            // never routed to DIO1 and our dio1Flag polling always timed
            // out. That turned every CAD into ERR_CAD_FAILED.
            ChannelScanConfig_t cfg = {};
            cfg.cad.symNum   = cadSymNum;
            cfg.cad.detPeak  = cadDetPeak;
            cfg.cad.detMin   = cadDetMin;
            cfg.cad.exitMode = cadExitMode;
            cfg.cad.timeout  = 0;
            cfg.cad.irqFlags = RADIOLIB_IRQ_CAD_DEFAULT_FLAGS;
            cfg.cad.irqMask  = RADIOLIB_IRQ_CAD_DEFAULT_MASK;
            state = radio.startChannelScan(cfg);
        } else {
            state = radio.startChannelScan();   // overload already sets flags
        }

        if (state != RADIOLIB_ERR_NONE) {
            sendError(ERR_CAD_FAILED, src);
            startReceive();
            break;
        }

        // 500 ms easily covers a legitimate CAD scan at any SF+symNum we use.
        const uint32_t CAD_TIMEOUT_MS = 500;
        uint32_t cadStart = millis();
        while (!dio1Flag && (millis() - cadStart) < CAD_TIMEOUT_MS) {
            esp_task_wdt_reset();
            delay(1);
        }

        if (!dio1Flag) {
            // CAD_DONE never fired — treat as failure and clean up the chip
            // before the next request. Don't block the repeater's LBT
            // forever; reporting failure lets the host decide.
            Serial.println("[CAD] IRQ timeout — resetting radio state");
            radio.standby();
            delay(5);
            applyConfig(currentConfig);
            sendError(ERR_CAD_FAILED, src);
            startReceive();
            break;
        }

        int scanResult = radio.getChannelScanResult();
        dio1Flag = false;
        uint8_t result[1];
        if (scanResult == RADIOLIB_LORA_DETECTED) {
            result[0] = 1;
        } else if (scanResult == RADIOLIB_CHANNEL_FREE) {
            result[0] = 0;
        } else {
            sendError(ERR_CAD_FAILED, src);
            startReceive();
            break;
        }
        sendFrame(CMD_CAD_RESP, result, 1, src);
        break;
    }

    case CMD_SET_CAD_PARAMS: {
        if (len != 4) {
            sendError(ERR_INVALID_CONFIG, src);
            break;
        }
        cadSymNum   = payload[0];
        cadDetPeak  = payload[1];
        cadDetMin   = payload[2];
        cadExitMode = payload[3];
        cadCustom   = true;

        // Ack before letting the chip settle. A blocking primer scan here
        // was attempted in an earlier v0.5.5 draft and itself hung — the
        // SX1262 can miss CAD_DONE during the regs-write window and leave
        // scanChannel() waiting forever. A short settle delay is enough
        // for the register write to commit; the first real CAD_REQUEST
        // from the host will then behave normally.
        sendFrame(CMD_CAD_PARAMS_RESP, payload, 4, src);
        delay(30);
        break;
    }

    case CMD_RX_START: {
        startReceive();
        sendFrame(CMD_RX_STARTED, nullptr, 0, src);
        break;
    }

    case CMD_SET_CONFIG: {
        if (len != sizeof(RadioConfig)) {
            sendError(ERR_INVALID_CONFIG, src);
            break;
        }
        memcpy(&currentConfig, payload, sizeof(RadioConfig));
        if (applyConfig(currentConfig)) {
            sendFrame(CMD_CONFIG_RESP, (uint8_t*)&currentConfig, sizeof(RadioConfig), src);
            startReceive();
        } else {
            sendError(ERR_INVALID_CONFIG, src);
        }
        break;
    }

    case CMD_GET_CONFIG: {
        sendFrame(CMD_CONFIG_RESP, (uint8_t*)&currentConfig, sizeof(RadioConfig), src);
        break;
    }

    case CMD_STATUS_REQ: {
        status.uptime_sec = millis() / 1000;
        status.radio_state = isTxActive ? 1 : 0;
        status.temp_c = (int8_t)temperatureRead();
        status.noise_floor_x10 = (int16_t)(noiseFloor * 10.0f);
        sendFrame(CMD_STATUS_RESP, (uint8_t*)&status, sizeof(StatusResp), src);
        break;
    }

    case CMD_NOISE_REQ: {
        int16_t nf = (int16_t)(noiseFloor * 10.0f);
        uint8_t resp[2];
        resp[0] = nf & 0xFF;
        resp[1] = (nf >> 8) & 0xFF;
        sendFrame(CMD_NOISE_RESP, resp, 2, src);
        break;
    }

    case CMD_GET_WIFI: {
        uint8_t buf[200];
        uint16_t n = buildWifiStatusPayload(buf);
        sendFrame(CMD_WIFI_STATUS, buf, n, src);
        break;
    }

    case CMD_SET_WIFI: {
        // Remote provisioning over USB — eliminates the need to physically
        // connect to the Heltec's AP portal.
        WifiManager::Config newCfg;
        if (!parseSetWifi(payload, len, newCfg)) {
            sendError(ERR_INVALID_WIFI, src);
            break;
        }

        // Ack with the pending config so the host can log it BEFORE reboot.
        WifiManager::saveConfig(newCfg);
        uint8_t buf[200];
        uint16_t n = buildWifiStatusPayload(buf);
        sendFrame(CMD_WIFI_STATUS, buf, n, src);

        if (src == TransportSource::USB) Serial.flush();
        delay(200);
        ESP.restart();
        break;  // unreached
    }

    case CMD_GET_VERSION: {
        const char* v = FW_VERSION;
        sendFrame(CMD_VERSION_RESP, (const uint8_t*)v, (uint16_t)strlen(v), src);
        break;
    }

    case CMD_PING: {
        sendFrame(CMD_PONG, nullptr, 0, src);
        break;
    }

    case CMD_WIFI_RESET: {
        sendFrame(CMD_WIFI_RESET, nullptr, 0, src);
        if (src == TransportSource::USB) Serial.flush();
        delay(200);
        WifiManager::factoryReset();   // does not return
        break;
    }

    default:
        sendError(ERR_INVALID_CMD, src);
        break;
    }
}

// ─── Serial-side parser callbacks ───────────────────────────
static void onSerialFrameOk(uint8_t cmd, const uint8_t* payload, uint16_t len,
                            TransportSource src) {
    lastUsbCmdMs = millis();
    processHostCommand(cmd, payload, len, src);
}

static void onSerialFrameErr(uint8_t err_code, TransportSource src) {
    if (err_code == ERR_CRC_MISMATCH) status.crc_errors++;
    sendError(err_code, src);
}

// ─── Setup ───────────────────────────────────────────────────
void setup() {
    // PRG held ≥3s at boot → wipe Wi-Fi NVS and reboot. Must come before
    // other init so button sampling is clean.
    WifiManager::checkResetButton();

    Serial.begin(921600);
    delay(500);

    oled.begin();
    oled.showBoot(FW_VERSION);

    int state = radio.begin();
    if (state != RADIOLIB_ERR_NONE) {
        oled.showError("SX1262 init fail!");
        while (Serial.availableForWrite() == 0) delay(10);
        sendError(ERR_RADIO_INIT, TransportSource::USB);
        // Do not enter OTA loop without a working radio — this firmware
        // would be rolled back automatically by the bootloader on reset.
        while (true) delay(1000);
    }

    radio.setTCXO(1.8);
    radio.setDio2AsRfSwitch(true);

    if (!applyConfig(currentConfig)) {
        oled.showError("Config fail!");
        sendError(ERR_INVALID_CONFIG, TransportSource::USB);
        while (true) delay(1000);
    }

    radio.setDio1Action(onDio1Rise);

    if (!startReceive()) {
        oled.showError("RX start fail!");
        while (true) delay(1000);
    }

    radioReady = true;
    oled.showStatus(0, 0, "---", "---", "BOOT", FW_VERSION);
    currentScreen = Screen::STATUS;
    oledWakeUntil = millis() + OLED_WAKE_DURATION_MS;

    // Wi-Fi must come up before we know our MAC-derived hostname.
    WifiManager::begin();
    deviceHostname = buildHostname();
    WiFi.setHostname(deviceHostname.c_str());

    if (WifiManager::isSTAConnected()) {
        const auto& wcfg = WifiManager::getConfig();
        TCPServer::begin(wcfg.tcpPort, wcfg.tcpToken);
        tcpStarted = true;

        OTAManager::begin(deviceHostname, wcfg.tcpToken);
        otaStarted = true;
    }

    // Arm the task watchdog LAST — everything above may legitimately take
    // many seconds (WiFi STA connect up to 30 s). From now on, any loop()
    // iteration that doesn't complete within LOOP_WDT_TIMEOUT_S triggers a
    // panic reboot. If the bootloader is OTA-aware, the rolled-back slot
    // would take over; on stock Arduino bootloader, the same image reboots.
    esp_task_wdt_init(LOOP_WDT_TIMEOUT_S, true);
    esp_task_wdt_add(NULL);

    Serial.printf("[BOOT] firmware %s ready (loop WDT %us)\n",
                  FW_VERSION, (unsigned)LOOP_WDT_TIMEOUT_S);
}

// ─── Noise floor sampling ────────────────────────────────────
void sampleNoiseFloor() {
    if (!radioReady || isTxActive) return;
    if (millis() - lastPacketTime < 500) return;
    if (dio1Flag) return;  // don't read RSSI while an RX packet is incoming
    if (millis() - lastNoiseSample < 10) return;
    lastNoiseSample = millis();

    if (noiseFloorCount < NUM_NOISE_FLOOR_SAMPLES) {
        float instRssi = radio.getRSSI();
        if (instRssi < (noiseFloor + NOISE_SAMPLING_THRESHOLD)) {
            noiseFloorCount++;
            noiseFloorSum += instRssi;
        }
    } else if (noiseFloorCount >= NUM_NOISE_FLOOR_SAMPLES && noiseFloorSum != 0.0f) {
        float newFloor = noiseFloorSum / NUM_NOISE_FLOOR_SAMPLES;
        if (newFloor < -150.0f) newFloor = -150.0f;
        if (newFloor > -50.0f)  newFloor = -50.0f;
        noiseFloor = newFloor;
        noiseFloorSum = 0.0f;
        noiseFloorCount = 0;
    }
}

// ─── Main loop ───────────────────────────────────────────────
void loop() {
    esp_task_wdt_reset();   // feed the loop watchdog every pass

    // DIO1 during TX is consumed by the TX handler's own wait loop; in
    // loop() we only act on it when the radio is in RX mode.
    if (dio1Flag && !isTxActive) {
        dio1Flag = false;
        handleLoRaRx();
    }

    while (Serial.available()) {
        uint8_t b = (uint8_t)Serial.read();
        frameparser_feed(serialParser, b, TransportSource::USB,
                         onSerialFrameOk, onSerialFrameErr);
    }

    if (tcpStarted) TCPServer::loop();
    if (otaStarted) OTAManager::loop();

    sampleNoiseFloor();
    WifiManager::loop();

    // Lazy TCP + OTA start if STA came up after boot
    if (!tcpStarted && WifiManager::isSTAConnected()) {
        const auto& wcfg = WifiManager::getConfig();
        TCPServer::begin(wcfg.tcpPort, wcfg.tcpToken);
        tcpStarted = true;
    }
    if (!otaStarted && WifiManager::isSTAConnected()) {
        const auto& wcfg = WifiManager::getConfig();
        OTAManager::begin(deviceHostname, wcfg.tcpToken);
        otaStarted = true;
    }

    // PRG short-tap: cycle SLEEP → STATUS → RADIO → DIAGNOSTICS → STATUS → …
    // (Factory reset on 3 s hold-at-boot is handled in setup()/checkResetButton.)
    if (digitalRead(0) == LOW && millis() > prgIgnoreUntil) {
        prgIgnoreUntil = millis() + PRG_DEBOUNCE_MS;
        oledWakeUntil  = millis() + OLED_WAKE_DURATION_MS;
        switch (currentScreen) {
            case Screen::SLEEP:
                oled.turnOn();
                currentScreen = Screen::STATUS;
                break;
            case Screen::STATUS:
                currentScreen = Screen::RADIO;
                break;
            case Screen::RADIO:
                currentScreen = Screen::DIAGNOSTICS;
                break;
            case Screen::DIAGNOSTICS:
                currentScreen = Screen::STATUS;
                break;
        }
        lastOledUpdate = 0;  // force immediate refresh on next render pass
    }

    if (currentScreen != Screen::SLEEP) {
        if ((int32_t)(millis() - oledWakeUntil) >= 0) {
            oled.turnOff();
            currentScreen = Screen::SLEEP;
        } else if (millis() - lastOledUpdate > 2000) {
            lastOledUpdate = millis();
            if (currentScreen == Screen::STATUS) {
                const char* stateTag;
                if (WifiManager::isAPActive())          stateTag = "AP";
                else if (WifiManager::isSTAConnected()) stateTag = "WiFi";
                else                                    stateTag = "...";
                oled.showStatus(status.rx_count, status.tx_count,
                                WifiManager::getSSID(),
                                WifiManager::getIPString(),
                                stateTag, FW_VERSION);
            } else if (currentScreen == Screen::RADIO) {
                oled.showRadioConfig(currentConfig.freq_hz,
                                     currentConfig.bandwidth_hz,
                                     currentConfig.sf,
                                     currentConfig.cr,
                                     currentConfig.power_dbm,
                                     currentConfig.syncword,
                                     currentConfig.preamble_len,
                                     FW_VERSION);
            } else {  // Screen::DIAGNOSTICS
                uint32_t uptime = millis() / 1000;
                String ip = TCPServer::getClientIP();
                uint32_t usb_idle = (lastUsbCmdMs == 0)
                    ? UINT32_MAX
                    : (millis() - lastUsbCmdMs) / 1000;
                oled.showDiagnostics(uptime, ip.c_str(), usb_idle,
                                     status.rx_count, status.tx_count,
                                     status.crc_errors, FW_VERSION);
            }
        }
    }
}
