// =============================================================
// tcp_server.cpp — single-client TCP protocol server with optional
// shared-token authentication.
// =============================================================
#include "tcp_server.h"
#include "protocol.h"
#include "frame_parser.h"

#include <WiFi.h>

// Forward decl — implemented in main.cpp; invoked for authorized frames.
extern void processHostCommand(uint8_t cmd, const uint8_t* payload,
                               uint16_t len, TransportSource src);

namespace TCPServer {

static WiFiServer* server         = nullptr;
static WiFiClient  client;
static String      requiredToken  = "";
static bool        authenticated  = false;
static FrameParser parser;

static bool requiresAuth() { return requiredToken.length() > 0; }

static void buildFrame(uint8_t* buf, uint16_t& outLen,
                       uint8_t cmd, const uint8_t* payload, uint16_t len) {
    uint16_t i = 0;
    buf[i++] = PROTO_SYNC;
    buf[i++] = cmd;
    buf[i++] = len & 0xFF;
    buf[i++] = (len >> 8) & 0xFF;
    if (len > 0 && payload) {
        memcpy(buf + i, payload, len);
        i += len;
    }
    uint16_t crc = crc16_ccitt(buf + 1, 3 + len);  // over CMD + LEN + PAYLOAD
    buf[i++] = crc & 0xFF;
    buf[i++] = (crc >> 8) & 0xFF;
    outLen = i;
}

static void sendToClient(uint8_t cmd, const uint8_t* payload, uint16_t len) {
    if (!client || !client.connected()) return;
    uint8_t buf[MAX_FRAME_SIZE];
    uint16_t flen = 0;
    buildFrame(buf, flen, cmd, payload, len);
    client.write(buf, flen);
}

static void sendErrorToClient(uint8_t err) {
    sendToClient(CMD_ERROR, &err, 1);
}

static void disconnectClient() {
    if (client) client.stop();
    authenticated = false;
    parser.reset();
}

static void onFrameOk(uint8_t cmd, const uint8_t* payload, uint16_t len, TransportSource src) {
    (void)src;  // always TCP here

    if (requiresAuth() && !authenticated) {
        if (cmd == CMD_AUTH) {
            if (len == requiredToken.length() &&
                memcmp(payload, requiredToken.c_str(), len) == 0) {
                authenticated = true;
                sendToClient(CMD_AUTH_OK, nullptr, 0);
            } else {
                sendErrorToClient(ERR_UNAUTHORIZED);
                delay(5);
                disconnectClient();
            }
        } else {
            sendErrorToClient(ERR_UNAUTHORIZED);
            delay(5);
            disconnectClient();
        }
        return;
    }

    // Authenticated (or no auth required)
    if (cmd == CMD_AUTH) {
        // Idempotent ack — client may always send AUTH.
        sendToClient(CMD_AUTH_OK, nullptr, 0);
        return;
    }

    processHostCommand(cmd, payload, len, TransportSource::TCP);
}

static void onFrameErr(uint8_t err_code, TransportSource src) {
    (void)src;
    sendErrorToClient(err_code);
}

void begin(uint16_t port, const String& token) {
    end();
    requiredToken = token;
    authenticated = false;
    parser.reset();
    server = new WiFiServer(port);
    server->begin();
    server->setNoDelay(true);
}

void end() {
    disconnectClient();
    if (server) {
        server->end();
        delete server;
        server = nullptr;
    }
}

void loop() {
    if (!server) return;

    // Accept incoming connection if no current client
    if (!client || !client.connected()) {
        if (client) disconnectClient();
        WiFiClient incoming = server->available();
        if (incoming) {
            client = incoming;
            client.setNoDelay(true);
            parser.reset();
            authenticated = false;
        }
    }

    // Read available bytes through the parser
    if (client && client.connected()) {
        while (client.available()) {
            uint8_t b = (uint8_t)client.read();
            frameparser_feed(parser, b, TransportSource::TCP, onFrameOk, onFrameErr);
        }
    }
}

bool isClientReady() {
    if (!client || !client.connected()) return false;
    return !requiresAuth() || authenticated;
}

String getClientIP() {
    if (!client || !client.connected()) return String();
    return client.remoteIP().toString();
}

void write(const uint8_t* data, size_t len) {
    if (!client || !client.connected()) return;
    client.write(data, len);
}

} // namespace TCPServer
