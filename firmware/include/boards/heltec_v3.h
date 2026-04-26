// =============================================================
// boards/heltec_v3.h — Heltec WiFi LoRa 32 V3 (ESP32-S3 + bare SX1262)
//
// SX1262 sits directly on the same PCB as the ESP32-S3 with no external
// PA / LNA / RF switch. The SX1262's own RF switch is internal and
// controlled by DIO2; no external EN pin is needed.
// =============================================================
#pragma once

inline const BoardConfig BOARD = {
    .name        = "Heltec V3",
    .fw_suffix   = "heltec",
    .mdns_prefix = "heltec",

    // SX1262 control pins (default ESP32-S3 SPI bus is used implicitly)
    .pin_lora_nss  = 8,
    .pin_lora_rst  = 12,
    .pin_lora_busy = 13,
    .pin_lora_dio1 = 14,

    .rf_switch = {
        .en_pin            = -1,    // no external switch — SX1262 internal only
        .en_low_hold_ms    = 0,
        .rx_pin            = -1,
        .tx_pin            = -1,
        .dio2_as_rf_switch = true,  // DIO2 drives the SX1262's internal switch
    },

    // Built-in 0.96" SSD1306 OLED on Heltec V3
    .pin_i2c_sda      = 17,
    .pin_i2c_scl      = 18,
    .pin_i2c_oled_rst = 21,
    .pin_vext_enable_low = 36,        // P-MOSFET gating the 3V3 OLED rail

    .pin_user_button         = 0,    // PRG button on GPIO0
    .user_button_active_low  = true,

    .max_tx_power_dbm = 22,           // SX1262 spec ceiling

    .use_dio3_tcxo = true,
    .tcxo_voltage  = 1.8f,
};
