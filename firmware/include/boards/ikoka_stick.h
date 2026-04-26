// =============================================================
// boards/ikoka_stick.h — Ikoka Stick (XIAO ESP32-S3 + Ebyte E22-P868M30S)
//
// Hardware ref: https://github.com/ndoo/ikoka-stick-meshtastic-device
// LoRa front end: Ebyte E22-P868M30S (SX1262 + PA + LNA, 30 dBm / 1 W).
//
// E22 RF switch wiring on the Ikoka PCB (E22 datasheet §4.2):
//   Pin 6 (RXEN, "EN" in truth table)  → MCU GPIO 6 — held HIGH for life,
//                                                     never toggled. Boots
//                                                     LOW for 5000 ms so
//                                                     the LDOs settle, then
//                                                     latches HIGH.
//   Pin 7 (TXEN, "T/R CTRL")           → board trace to module pin 8 (DIO2);
//                                                     SX1262 drives it HIGH
//                                                     during TX automatically
//                                                     when setDio2AsRfSwitch
//                                                     (true) is enabled.
// =============================================================
#pragma once

inline const BoardConfig BOARD = {
    .name        = "Ikoka Stick",
    .fw_suffix   = "ikoka",
    .mdns_prefix = "ikoka",

    // SX1262 control pins (XIAO default SPI: SCK=D8/GPIO7, MISO=D9/GPIO8,
    // MOSI=D10/GPIO9 — all match the Ikoka schematic)
    .pin_lora_nss  = 5,    // D4
    .pin_lora_rst  = 3,    // D2
    .pin_lora_busy = 4,    // D3
    .pin_lora_dio1 = 2,    // D1

    .rf_switch = {
        .en_pin            = 6,     // RXEN, GPIO6 / D5 — see header note
        .en_low_hold_ms    = 5000,  // E22-P modules need ≥5 s LOW after boot
        .rx_pin            = -1,
        .tx_pin            = -1,
        .dio2_as_rf_switch = true,  // DIO2 → TXEN trace on the Ikoka PCB
    },

    // External SSD1306 OLED on the I2C breakout (no reset line)
    .pin_i2c_sda      = 43,   // D6
    .pin_i2c_scl      = 44,   // D7
    .pin_i2c_oled_rst = -1,
    .pin_vext_enable_low = -1,        // OLED powered directly from XIAO 3V3

    .pin_user_button        = 1,    // D0
    .user_button_active_low = true,

    // E22-P868M30S can deliver up to 30 dBm. Firmware caps requests
    // here; downstream (host config) is responsible for keeping inside
    // the regional ETSI / FCC limits for the chosen frequency band.
    .max_tx_power_dbm = 30,

    .use_dio3_tcxo = true,
    .tcxo_voltage  = 1.8f,
};
