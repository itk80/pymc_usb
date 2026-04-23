// =============================================================
// frame_parser.cpp — state-machine implementation
// =============================================================
#include "frame_parser.h"

void frameparser_feed(FrameParser& p, uint8_t b, TransportSource src,
                      FrameOkCb on_ok, FrameErrCb on_err) {
    switch (p.state) {
    case FrameParser::WAIT_SYNC:
        if (b == PROTO_SYNC) p.state = FrameParser::READ_CMD;
        break;

    case FrameParser::READ_CMD:
        p.cmd   = b;
        p.state = FrameParser::READ_LEN0;
        break;

    case FrameParser::READ_LEN0:
        p.len   = b;
        p.state = FrameParser::READ_LEN1;
        break;

    case FrameParser::READ_LEN1:
        p.len  |= (uint16_t)b << 8;
        p.idx   = 0;
        if (p.len > sizeof(p.payload)) {
            if (on_err) on_err(ERR_PAYLOAD_TOO_BIG, src);
            p.state = FrameParser::WAIT_SYNC;
        } else if (p.len == 0) {
            p.state = FrameParser::READ_CRC0;
        } else {
            p.state = FrameParser::READ_PAYLOAD;
        }
        break;

    case FrameParser::READ_PAYLOAD:
        p.payload[p.idx++] = b;
        if (p.idx >= p.len) p.state = FrameParser::READ_CRC0;
        break;

    case FrameParser::READ_CRC0:
        p.crc   = b;
        p.state = FrameParser::READ_CRC1;
        break;

    case FrameParser::READ_CRC1: {
        p.crc  |= (uint16_t)b << 8;
        p.state = FrameParser::WAIT_SYNC;

        // CRC over CMD + LEN + PAYLOAD
        uint8_t hdr[3] = { p.cmd, (uint8_t)(p.len & 0xFF), (uint8_t)((p.len >> 8) & 0xFF) };
        uint16_t computed = 0xFFFF;
        for (int i = 0; i < 3; i++) {
            computed ^= (uint16_t)hdr[i] << 8;
            for (uint8_t j = 0; j < 8; j++)
                computed = (computed & 0x8000) ? (computed << 1) ^ 0x1021 : computed << 1;
        }
        for (uint16_t i = 0; i < p.len; i++) {
            computed ^= (uint16_t)p.payload[i] << 8;
            for (uint8_t j = 0; j < 8; j++)
                computed = (computed & 0x8000) ? (computed << 1) ^ 0x1021 : computed << 1;
        }

        if (computed == p.crc) {
            if (on_ok) on_ok(p.cmd, p.payload, p.len, src);
        } else {
            if (on_err) on_err(ERR_CRC_MISMATCH, src);
        }
        break;
    }
    }
}
