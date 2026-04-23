// =============================================================
// protocol.h — Wire protocol for LoRa Modem serial/TCP communication
// v0.5.4 — + CMD_SET_CAD_PARAMS / CMD_CAD_PARAMS_RESP
//          (wire format unchanged; new commands are optional)
// =============================================================
#pragma once

#include <stdint.h>

// Frame sync byte
#define PROTO_SYNC          0xAA

// ─── Command bytes: Host (RPi) → Modem (Heltec) ─────────────
#define CMD_TX_REQUEST      0x01    // Send LoRa packet (payload = raw bytes)
#define CMD_SET_CONFIG      0x10    // Set radio parameters
#define CMD_GET_CONFIG      0x11    // Request current config
#define CMD_STATUS_REQ      0x20    // Request status
#define CMD_NOISE_REQ       0x22    // Request noise floor value
#define CMD_CAD_REQUEST     0x30    // Perform CAD (Listen Before Talk)
#define CMD_RX_START        0x31    // (Re)start RX continuous mode
#define CMD_SET_CAD_PARAMS  0x34    // v0.5.4 — Set CAD thresholds (symbols, peak, min, exit_mode)
#define CMD_SET_WIFI        0x41    // v0.5 — Provision Wi-Fi from USB (save NVS + reboot to STA)
#define CMD_AUTH            0x50    // Authenticate TCP client (payload = token bytes)
#define CMD_WIFI_RESET      0x60    // Wipe Wi-Fi config from NVS and reboot into AP mode
#define CMD_GET_WIFI        0x61    // v0.5 — Query Wi-Fi/OTA status (mode, IP, SSID, hostname)
#define CMD_GET_VERSION     0x70    // v0.5.3 — Query firmware version string
#define CMD_PING            0xFF    // Heartbeat ping

// ─── Command bytes: Modem (Heltec) → Host (RPi) ─────────────
#define CMD_TX_DONE         0x02    // TX complete (payload = airtime_us, 4B LE)
#define CMD_TX_FAIL         0x03    // TX failed
#define CMD_RX_PACKET       0x04    // Received LoRa packet
#define CMD_CONFIG_RESP     0x12    // Config response
#define CMD_STATUS_RESP     0x21    // Status response
#define CMD_NOISE_RESP      0x23    // Noise floor value (int16 LE, dBm × 10)
#define CMD_CAD_RESP        0x32    // CAD result (1 byte: 0=clear, 1=busy)
#define CMD_RX_STARTED      0x33    // RX mode (re)started confirmation
#define CMD_CAD_PARAMS_RESP 0x35    // v0.5.4 — CAD thresholds ack (echoes applied values)
#define CMD_AUTH_OK         0x51    // Auth accepted
#define CMD_WIFI_STATUS     0x62    // v0.5 — Wi-Fi/OTA status response
#define CMD_VERSION_RESP    0x71    // v0.5.3 — Firmware version (ASCII, no NUL)
#define CMD_ERROR           0xFE    // Error
#define CMD_PONG            0xFF    // Heartbeat pong

// ─── Error codes ─────────────────────────────────────────────
#define ERR_CRC_MISMATCH    0x01
#define ERR_INVALID_CMD     0x02
#define ERR_RADIO_BUSY      0x03
#define ERR_TX_TIMEOUT      0x04
#define ERR_PAYLOAD_TOO_BIG 0x05
#define ERR_INVALID_CONFIG  0x06
#define ERR_CAD_FAILED      0x07
#define ERR_RADIO_INIT      0x08
#define ERR_UNAUTHORIZED    0x09    // TCP client did not authenticate
#define ERR_INVALID_WIFI    0x0A    // SET_WIFI payload malformed

// Max payload sizes
#define MAX_LORA_PAYLOAD    255
#define MAX_FRAME_SIZE      (1 + 1 + 2 + MAX_LORA_PAYLOAD + 6 + 2)

// ─── Frame format ────────────────────────────────────────────
//
//  ┌──────┬──────┬───────┬──────────────────┬───────┐
//  │ SYNC │ CMD  │  LEN  │     PAYLOAD      │  CRC  │
//  │ 0xAA │ 1B   │ 2B LE │   0..255 bytes   │ 2B LE │
//  └──────┴──────┴───────┴──────────────────┴───────┘
//
//  CRC-16/CCITT over CMD + LEN + PAYLOAD (excludes SYNC)
//
// ─── RX_PACKET payload ──────────────────────────────────────
//
//  ┌──────┬──────┬────────────┬──────────────────────┐
//  │ RSSI │  SNR │ SIG_RSSI   │     LoRa data        │
//  │ 2B   │  2B  │    2B      │      N bytes          │
//  │int16 │int16 │   int16    │                       │
//  └──────┴──────┴────────────┴──────────────────────┘
//
// ─── TX_DONE payload (4 bytes) ──────────────────────────────
//
//  ┌───────────┐
//  │ AIRTIME   │
//  │  4B LE    │  microseconds
//  └───────────┘
//
// ─── SET_CONFIG payload (14 bytes) ──────────────────────────
//
//  ┌──────────┬────────┬────┬────┬───────┬──────────┬────────┐
//  │ FREQ_HZ  │  BW_HZ │ SF │ CR │ POWER │ SYNCWORD │PREAMBL │
//  │  4B LE   │ 4B LE  │ 1B │ 1B │  1B   │   2B LE  │  1B    │
//  └──────────┴────────┴────┴────┴───────┴──────────┴────────┘
//
// ─── SET_WIFI payload (variable) ────────────────────────────
//
//  ssid_len(1B) | ssid(N)
//  pass_len(1B) | pass(M)
//  port(2B LE)
//  token_len(1B) | token(K)
//
//  Modem ACKs with WIFI_STATUS (new pending config), then reboots.
//
// ─── WIFI_STATUS payload (variable) ─────────────────────────
//
//  mode(1B)            // 0=offline, 1=STA_connecting, 2=STA_connected, 3=AP_config
//  ip(4B BE)           // dotted quad; 0.0.0.0 when offline
//  port(2B LE)         // current TCP port
//  ssid_len(1B) | ssid(N)
//  host_len(1B) | hostname(M)   // mDNS name (e.g. "heltec-ab12cd"), no ".local" suffix
//

// Config structure — packed, little-endian
struct __attribute__((packed)) RadioConfig {
    uint32_t freq_hz;       // e.g. 868000000
    uint32_t bandwidth_hz;  // e.g. 125000
    uint8_t  sf;            // 5-12
    uint8_t  cr;            // 5-8 (4/5 .. 4/8)
    int8_t   power_dbm;     // -9 .. 22
    uint16_t syncword;      // LoRa sync word byte (e.g. 0x12=private, 0x34=public)
    uint8_t  preamble_len;  // e.g. 16 (MeshCore default)
};

// Status response structure
struct __attribute__((packed)) StatusResp {
    uint32_t uptime_sec;
    uint32_t rx_count;
    uint32_t tx_count;
    uint32_t crc_errors;
    int16_t  last_rssi;
    int16_t  last_snr;         // × 10
    int16_t  noise_floor_x10;  // averaged noise floor in dBm × 10
    int8_t   temp_c;           // ESP32 die temperature
    uint8_t  radio_state;      // 0=idle/rx, 1=tx, 2=error
};

// CRC-16/CCITT (polynomial 0x1021, init 0xFFFF)
static inline uint16_t crc16_ccitt(const uint8_t *data, uint16_t len) {
    uint16_t crc = 0xFFFF;
    for (uint16_t i = 0; i < len; i++) {
        crc ^= (uint16_t)data[i] << 8;
        for (uint8_t j = 0; j < 8; j++) {
            if (crc & 0x8000)
                crc = (crc << 1) ^ 0x1021;
            else
                crc <<= 1;
        }
    }
    return crc;
}
