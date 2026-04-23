// =============================================================
// tcp_server.h — TCP LoRa-modem protocol server (Wi-Fi STA)
// Accepts one client; optional shared-token auth required before
// non-AUTH commands are processed.
// =============================================================
#pragma once

#include <Arduino.h>
#include <stdint.h>

namespace TCPServer {

// Start (or restart) the server. Call after WiFi STA is up.
// If token.length() > 0, clients must send CMD_AUTH with matching
// payload before any other command is accepted.
void begin(uint16_t port, const String& token);

// Stop accepting connections and drop the current client.
void end();

// Service accepts + incoming bytes. Call every loop().
void loop();

// True when a client is connected AND (authenticated OR no token required).
bool isClientReady();

// Dotted quad of the connected client, or empty string when no client.
String getClientIP();

// Queue bytes to connected client; no-op if no client.
void write(const uint8_t* data, size_t len);

} // namespace TCPServer
