#!/usr/bin/env python3
"""
test_modem.py — Validation tool for Heltec LoRa Modem firmware v0.3
Run on Mac/RPi to verify serial protocol communication.

Usage:
    python3 test_modem.py [/dev/cu.usbserial-0001]
    python3 test_modem.py [/dev/ttyUSB0]

Requirements:
    pip install pyserial
"""

import sys
import struct
import time
import serial

# ─── Protocol constants ──────────────────────────────────────
PROTO_SYNC      = 0xAA
CMD_TX_REQUEST  = 0x01
CMD_TX_DONE     = 0x02
CMD_RX_PACKET   = 0x04
CMD_SET_CONFIG  = 0x10
CMD_GET_CONFIG  = 0x11
CMD_CONFIG_RESP = 0x12
CMD_STATUS_REQ  = 0x20
CMD_STATUS_RESP = 0x21
CMD_NOISE_REQ   = 0x22
CMD_NOISE_RESP  = 0x23
CMD_CAD_REQUEST = 0x30
CMD_RX_START    = 0x31
CMD_CAD_RESP    = 0x32
CMD_RX_STARTED  = 0x33
CMD_ERROR       = 0xFE
CMD_PING        = 0xFF


def crc16_ccitt(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if (crc & 0x8000) else (crc << 1)
            crc &= 0xFFFF
    return crc


def build_frame(cmd: int, payload: bytes = b"") -> bytes:
    length = len(payload)
    hdr = struct.pack("<BH", cmd, length)
    crc = crc16_ccitt(hdr + payload)
    return bytes([PROTO_SYNC]) + hdr + payload + struct.pack("<H", crc)


def send_frame(ser, cmd, payload=b""):
    """Send frame with proper flush and small delay."""
    frame = build_frame(cmd, payload)
    ser.write(frame)
    ser.flush()
    time.sleep(0.05)  # give modem time to process


def read_frame(ser, timeout=3.0):
    """Read one frame. Returns (cmd, payload) or None."""
    ser.timeout = timeout
    start = time.time()
    while time.time() - start < timeout:
        b = ser.read(1)
        if len(b) == 0:
            return None
        if b[0] == PROTO_SYNC:
            break
    else:
        return None

    hdr = ser.read(3)
    if len(hdr) < 3:
        return None
    cmd = hdr[0]
    length = struct.unpack("<H", hdr[1:3])[0]
    payload = ser.read(length) if length > 0 else b""
    if len(payload) < length:
        return None
    crc_bytes = ser.read(2)
    if len(crc_bytes) < 2:
        return None

    recv_crc = struct.unpack("<H", crc_bytes)[0]
    comp_crc = crc16_ccitt(hdr + payload)
    if recv_crc != comp_crc:
        print(f"  ⚠ CRC mismatch: recv=0x{recv_crc:04X} comp=0x{comp_crc:04X}")
        return None
    return (cmd, payload)


def drain(ser):
    """Drain any leftover bytes in serial buffer."""
    ser.reset_input_buffer()
    time.sleep(0.1)
    if ser.in_waiting:
        ser.read(ser.in_waiting)


def test_ping(ser):
    print("\n─── PING ───")
    drain(ser)
    send_frame(ser, CMD_PING)
    r = read_frame(ser)
    if r and r[0] == CMD_PING:  # PONG = same cmd byte 0xFF
        print("  ✓ PONG received")
        return True
    print("  ✗ No PONG")
    return False


def test_get_config(ser):
    print("\n─── GET_CONFIG ───")
    drain(ser)
    send_frame(ser, CMD_GET_CONFIG)
    r = read_frame(ser)
    if r and r[0] == CMD_CONFIG_RESP and len(r[1]) >= 14:
        freq, bw, sf, cr, power, sw, pre = struct.unpack("<IIBBbHB", r[1][:14])
        print(f"  ✓ Freq:     {freq/1e6:.3f} MHz")
        print(f"    BW:       {bw/1000} kHz")
        print(f"    SF:       {sf}")
        print(f"    CR:       4/{cr}")
        print(f"    Power:    {power} dBm")
        print(f"    Syncword: 0x{sw:04X}")
        print(f"    Preamble: {pre}")
        return True
    print("  ✗ No CONFIG_RESP")
    return False


def test_set_config(ser, freq=869618000, bw=62500, sf=8, cr=8,
                    power=22, sw=0x12, pre=16):
    print(f"\n─── SET_CONFIG ({freq/1e6:.3f}MHz SF{sf} BW{bw/1000}kHz CR4/{cr}) ───")
    drain(ser)
    payload = struct.pack("<IIBBbHB", freq, bw, sf, cr, power, sw, pre)
    send_frame(ser, CMD_SET_CONFIG, payload)
    r = read_frame(ser, timeout=5.0)  # config apply takes longer
    if r and r[0] == CMD_CONFIG_RESP:
        print("  ✓ Config applied and confirmed")
        return True
    if r and r[0] == CMD_ERROR:
        print(f"  ✗ Error: 0x{r[1][0]:02X}" if r[1] else "  ✗ Error")
    else:
        print("  ✗ No response")
    return False


def test_status(ser):
    print("\n─── STATUS ───")
    drain(ser)
    send_frame(ser, CMD_STATUS_REQ)
    r = read_frame(ser)
    if r and r[0] == CMD_STATUS_RESP and len(r[1]) >= 24:
        up, rx, tx, crc_e, rssi, snr, noise, temp, state = struct.unpack(
            "<IIIIhhhbB", r[1][:24]
        )
        print(f"  ✓ Uptime:     {up}s")
        print(f"    RX count:   {rx}")
        print(f"    TX count:   {tx}")
        print(f"    CRC errors: {crc_e}")
        print(f"    Last RSSI:  {rssi} dBm")
        print(f"    Last SNR:   {snr/10:.1f} dB")
        print(f"    Noise floor:{noise/10:.1f} dBm")
        print(f"    Temp:       {temp}°C")
        print(f"    State:      {['IDLE/RX','TX','ERROR'][min(state,2)]}")
        return True
    print("  ✗ No STATUS_RESP")
    return False


def test_noise_floor(ser):
    print("\n─── NOISE FLOOR ───")
    drain(ser)
    send_frame(ser, CMD_NOISE_REQ)
    r = read_frame(ser)
    if r and r[0] == CMD_NOISE_RESP and len(r[1]) >= 2:
        nf = struct.unpack("<h", r[1][:2])[0]
        print(f"  ✓ Noise floor: {nf/10:.1f} dBm")
        return True
    print("  ✗ No NOISE_RESP")
    return False


def test_cad(ser):
    print("\n─── CAD (Channel Activity Detection) ───")
    drain(ser)
    send_frame(ser, CMD_CAD_REQUEST)
    r = read_frame(ser, timeout=3.0)
    if r and r[0] == CMD_CAD_RESP and len(r[1]) >= 1:
        busy = r[1][0] != 0
        print(f"  ✓ Channel: {'BUSY' if busy else 'CLEAR'}")
        # Restore RX after CAD
        drain(ser)
        send_frame(ser, CMD_RX_START)
        r2 = read_frame(ser, timeout=2.0)
        if r2 and r2[0] == CMD_RX_STARTED:
            print("  ✓ RX restored")
        return True
    if r and r[0] == CMD_ERROR:
        print(f"  ✗ CAD error: 0x{r[1][0]:02X}" if r[1] else "  ✗ CAD error")
    else:
        print("  ✗ No CAD_RESP")
    return False


def test_tx(ser, data=b"Hello MeshCore!"):
    print(f"\n─── TX ({len(data)} bytes) ───")
    drain(ser)
    send_frame(ser, CMD_TX_REQUEST, data)
    r = read_frame(ser, timeout=10.0)
    if r and r[0] == CMD_TX_DONE:
        if len(r[1]) >= 4:
            airtime_us = struct.unpack("<I", r[1][:4])[0]
            print(f"  ✓ TX_DONE — airtime: {airtime_us/1000:.1f} ms")
        else:
            print("  ✓ TX_DONE")
        return True
    if r and r[0] == CMD_ERROR:
        print(f"  ✗ TX error: 0x{r[1][0]:02X}" if r[1] else "  ✗ TX error")
    else:
        print("  ✗ No TX_DONE")
    return False


def listen_rx(ser, duration=30):
    print(f"\n─── Listening for RX packets ({duration}s) ───")
    start = time.time()
    count = 0
    while time.time() - start < duration:
        r = read_frame(ser, timeout=1.0)
        if r and r[0] == CMD_RX_PACKET and len(r[1]) >= 6:
            count += 1
            rssi = struct.unpack("<h", r[1][0:2])[0]
            snr = struct.unpack("<h", r[1][2:4])[0]
            sig_rssi = struct.unpack("<h", r[1][4:6])[0]
            data = r[1][6:]
            print(f"  📡 RX #{count}: {len(data)}B  "
                  f"RSSI={rssi}  SNR={snr/10:.1f}  sigRSSI={sig_rssi}")
            print(f"     HEX: {data.hex()}")
            try:
                print(f"     TXT: {data.decode('utf-8', errors='replace')}")
            except Exception:
                pass
    print(f"  Total: {count} packets in {duration}s")


def main():
    port = sys.argv[1] if len(sys.argv) > 1 else "/dev/ttyUSB0"
    baud = 921600

    print(f"══════════════════════════════════════════")
    print(f"  Heltec LoRa Modem Test Tool v0.3")
    print(f"  Port: {port}  Baud: {baud}")
    print(f"══════════════════════════════════════════")

    try:
        ser = serial.Serial(port, baud, timeout=2)
        time.sleep(2.0)  # wait for ESP32 boot
        ser.reset_input_buffer()
    except Exception as e:
        print(f"Cannot open {port}: {e}")
        sys.exit(1)

    # Run all tests
    test_ping(ser)
    test_get_config(ser)
    test_status(ser)
    test_noise_floor(ser)
    test_set_config(ser)
    test_get_config(ser)   # verify config was applied
    test_cad(ser)
    test_tx(ser, b"\x01\x02\x03TEST_MESHCORE")
    test_status(ser)

    # Listen for incoming packets
    print("\nPress Ctrl+C to stop RX listener...")
    try:
        listen_rx(ser, duration=300)
    except KeyboardInterrupt:
        print("\nStopped.")

    ser.close()


if __name__ == "__main__":
    main()
