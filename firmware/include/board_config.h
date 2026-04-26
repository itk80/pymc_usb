// =============================================================
// board_config.h — Per-board hardware abstraction
//
// Each supported board ships a header in boards/ that instantiates a
// `BoardConfig` constant called `BOARD`. main.cpp / oled_display.cpp /
// ota_manager.cpp pull pin numbers and policies from BOARD.* instead
// of using hard-coded #defines, so adding a new board is a one-file job.
//
// Board selection happens at compile time via a `-DBOARD_<name>` flag
// in platformio.ini's build_flags. Exactly one must be defined.
// =============================================================
#pragma once

#include <stdint.h>

// ─── RF switch policy ───────────────────────────────────────
// Different SX1262 carrier boards control the RF switch / PA / LNA
// in different ways. This struct lets each board declare its policy
// without firmware changes elsewhere.
//
//   en_pin            GPIO that gates the entire RF switch (the "EN"
//                     column of the E22 datasheet truth table). The
//                     firmware drives it LOW for `en_low_hold_ms`
//                     during boot to let the module power up cleanly,
//                     then raises it HIGH and never lowers it again.
//                     Set to -1 if the board has no external switch
//                     (e.g. bare SX1262 on Heltec V3 — the SX1262's
//                     own RF switch is fully internal).
//
//   en_low_hold_ms    Boot-time hold duration for `en_pin` LOW. Ebyte
//                     E22-P modules need ≥5000 ms for the LDOs and
//                     PA bias to settle before EN goes HIGH; ignored
//                     when en_pin == -1.
//
//   rx_pin / tx_pin   GPIOs that RadioLib should auto-toggle on each
//                     transmit/receive (LOW/HIGH per direction).
//                     Use these for boards with two separate MCU-driven
//                     switch lines. Leave at -1 to skip.
//
//   dio2_as_rf_switch When true, configure SX1262 to drive its DIO2
//                     pin HIGH during TX. On boards where DIO2 is
//                     wired (PCB trace) to the module's T/R CTRL pin
//                     this gives auto TX-path switching with zero MCU
//                     involvement. Heltec V3 uses DIO2 for the
//                     SX1262's internal switch; Ikoka Stick wires
//                     DIO2 ↔ TXEN externally.
struct RfSwitchPolicy {
    int8_t   en_pin;
    uint16_t en_low_hold_ms;
    int8_t   rx_pin;
    int8_t   tx_pin;
    bool     dio2_as_rf_switch;
};

// ─── Full per-board config ──────────────────────────────────
struct BoardConfig {
    const char* name;            // Display name on the OLED splash
    const char* fw_suffix;       // Appended to FW_VERSION (e.g. "ikoka")
    const char* mdns_prefix;     // mDNS hostname stem; final form is
                                 // "<prefix>-<mac3>.local"

    // SX1262 SPI + control pins. SCK/MISO/MOSI come from the board's
    // default SPI bus (Arduino SPI.begin() picks them up); we only
    // need the chip-specific ones explicitly.
    int8_t pin_lora_nss;
    int8_t pin_lora_rst;
    int8_t pin_lora_busy;
    int8_t pin_lora_dio1;        // DIO1 → MCU (IRQ line)

    RfSwitchPolicy rf_switch;

    // I2C bus for the SSD1306 OLED (same driver across all boards).
    int8_t pin_i2c_sda;
    int8_t pin_i2c_scl;
    int8_t pin_i2c_oled_rst;     // -1 if the OLED has no reset line

    // Heltec V3 routes its 3.3 V VEXT rail (which powers the OLED)
    // through a P-MOSFET enabled by a LOW level on GPIO 36; Ikoka
    // and other boards power the OLED straight from 3V3 and leave
    // this at -1 so the firmware skips the dance.
    int8_t pin_vext_enable_low;

    // PRG / user button. active_low = pressed pulls LOW.
    int8_t pin_user_button;
    bool   user_button_active_low;

    // Hardware RF ceiling. Firmware clamps any requested TX power to
    // this value; lets the host config drive everything below.
    int8_t max_tx_power_dbm;

    // SX1262 TCXO control. All Ebyte/Heltec carrier boards use a
    // 32 MHz TCXO powered by SX1262 DIO3 at 1.8 V.
    bool  use_dio3_tcxo;
    float tcxo_voltage;
};

extern const BoardConfig BOARD;

// ─── Board selection ────────────────────────────────────────
#if defined(BOARD_HELTEC_V3)
#  include "boards/heltec_v3.h"
#elif defined(BOARD_IKOKA_STICK)
#  include "boards/ikoka_stick.h"
#else
#  error "No board selected — add -DBOARD_HELTEC_V3 or -DBOARD_IKOKA_STICK to platformio.ini build_flags"
#endif
