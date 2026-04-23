// =============================================================
// frame_parser.h — byte-by-byte protocol frame parser
// One FrameParser instance per transport (Serial, TCP, ...).
// =============================================================
#pragma once

#include "protocol.h"
#include <stdint.h>

// Values named USB/TCP (not SERIAL) because Arduino.h defines SERIAL as a macro.
enum class TransportSource : uint8_t {
    USB = 0,
    TCP = 1,
};

struct FrameParser {
    enum State : uint8_t {
        WAIT_SYNC, READ_CMD, READ_LEN0, READ_LEN1,
        READ_PAYLOAD, READ_CRC0, READ_CRC1
    };
    State    state = WAIT_SYNC;
    uint8_t  cmd   = 0;
    uint16_t len   = 0;
    uint16_t idx   = 0;
    uint8_t  payload[MAX_LORA_PAYLOAD + 16];
    uint16_t crc   = 0;

    void reset() { state = WAIT_SYNC; }
};

// Callback invoked on a complete, CRC-valid frame.
typedef void (*FrameOkCb)(uint8_t cmd, const uint8_t* payload, uint16_t len, TransportSource src);
// Callback invoked on a parse/CRC error (err = ERR_* code).
typedef void (*FrameErrCb)(uint8_t err_code, TransportSource src);

// Feed one byte into the parser. Invokes callbacks when a frame completes.
void frameparser_feed(FrameParser& p, uint8_t b, TransportSource src,
                      FrameOkCb on_ok, FrameErrCb on_err);
