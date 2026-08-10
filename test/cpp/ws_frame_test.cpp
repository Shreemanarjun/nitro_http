// ─────────────────────────────────────────────────────────────────────────────
// RFC 6455 framing, with no sockets in sight.
//
// `WsSession` owns masking, length encoding and header validation because
// libcurl's WebSocket API is optional and experimental. That makes the framing
// ours to get right, and framing bugs are the kind that only show up against
// one particular peer, months later. So: the spec's own worked example byte for
// byte, every length form, and every rejection the parser promises.
// ─────────────────────────────────────────────────────────────────────────────

#include <gtest/gtest.h>

#include <cstdint>
#include <string>
#include <vector>

#include "WsSession.h"

using namespace nitrohttp;
using ParsedFrame = WsSession::ParsedFrame;

namespace {

std::vector<uint8_t> bytes(std::initializer_list<int> values) {
  std::vector<uint8_t> out;
  out.reserve(values.size());
  for (const int v : values) out.push_back(static_cast<uint8_t>(v));
  return out;
}

std::vector<uint8_t> payloadOf(size_t n) {
  std::vector<uint8_t> out(n);
  for (size_t i = 0; i < n; ++i) out[i] = static_cast<uint8_t>(i * 13 + 3);
  return out;
}

/// The extended-length form the second byte selects: 0, 2 or 8 extra bytes.
size_t extendedLengthBytes(uint8_t b1) {
  const uint8_t len = b1 & 0x7f;
  if (len == 126) return 2;
  if (len == 127) return 8;
  return 0;
}

/// A SERVER frame: same geometry as `encodeFrame` produces, minus the mask.
/// Servers must not mask (RFC 6455 §5.1), and `parseFrameHeader` only ever sees
/// server frames.
std::vector<uint8_t> serverFrame(int opcode, bool fin, uint64_t payloadLen) {
  std::vector<uint8_t> out;
  out.push_back(static_cast<uint8_t>((fin ? 0x80 : 0x00) | (opcode & 0x0f)));
  if (payloadLen < 126) {
    out.push_back(static_cast<uint8_t>(payloadLen));
  } else if (payloadLen <= 0xffff) {
    out.push_back(126);
    out.push_back(static_cast<uint8_t>((payloadLen >> 8) & 0xff));
    out.push_back(static_cast<uint8_t>(payloadLen & 0xff));
  } else {
    out.push_back(127);
    for (int i = 7; i >= 0; --i) {
      out.push_back(static_cast<uint8_t>((payloadLen >> (i * 8)) & 0xff));
    }
  }
  return out;
}

/// Rewrites a client frame as the server would have sent it: mask bit cleared,
/// mask key removed, payload unmasked. Used to round-trip `encodeFrame`'s
/// geometry back through `parseFrameHeader`.
std::vector<uint8_t> asServerFrame(const std::vector<uint8_t>& client) {
  const size_t extra = extendedLengthBytes(client[1]);
  const size_t headerEnd = 2 + extra;
  std::vector<uint8_t> out(client.begin(), client.begin() + static_cast<std::ptrdiff_t>(headerEnd));
  out[1] = static_cast<uint8_t>(out[1] & 0x7f);

  const uint8_t mask[4] = {client[headerEnd], client[headerEnd + 1],
                           client[headerEnd + 2], client[headerEnd + 3]};
  for (size_t i = headerEnd + 4; i < client.size(); ++i) {
    const size_t index = i - (headerEnd + 4);
    out.push_back(static_cast<uint8_t>(client[i] ^ mask[index & 3]));
  }
  return out;
}

}  // namespace

// ─── encodeFrame ─────────────────────────────────────────────────────────────

TEST(WsEncodeFrame, MatchesTheRfc6455MaskedHelloExample) {
  // RFC 6455 §5.7: "A single-frame masked text message" — mask 0x37fa213d.
  const std::string hello = "Hello";
  const std::vector<uint8_t> frame = WsSession::encodeFrame(
      wsopcode::kText, true, reinterpret_cast<const uint8_t*>(hello.data()),
      hello.size(), 0x37fa213du);
  const std::vector<uint8_t> expected =
      bytes({0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58});
  EXPECT_EQ(frame, expected);
}

TEST(WsEncodeFrame, UsesTheSevenBitLengthFormBelow126) {
  const std::vector<uint8_t> payload = payloadOf(125);
  const std::vector<uint8_t> frame = WsSession::encodeFrame(
      wsopcode::kBinary, true, payload.data(), payload.size(), 0x01020304u);
  ASSERT_EQ(frame.size(), 2u + 4u + 125u);
  EXPECT_EQ(frame[0], 0x82);
  EXPECT_EQ(frame[1], 0x80 | 125);
}

TEST(WsEncodeFrame, UsesTheSixteenBitLengthFormFrom126To65535) {
  for (const size_t n : {size_t{126}, size_t{1000}, size_t{65535}}) {
    const std::vector<uint8_t> payload = payloadOf(n);
    const std::vector<uint8_t> frame = WsSession::encodeFrame(
        wsopcode::kBinary, true, payload.data(), n, 0x0a0b0c0du);
    ASSERT_EQ(frame.size(), 2u + 2u + 4u + n) << "n = " << n;
    EXPECT_EQ(frame[1], 0x80 | 126) << "n = " << n;
    const size_t decoded = (static_cast<size_t>(frame[2]) << 8) | frame[3];
    EXPECT_EQ(decoded, n);
  }
}

TEST(WsEncodeFrame, UsesTheSixtyFourBitLengthFormAbove65535) {
  const size_t n = 65536;
  const std::vector<uint8_t> payload = payloadOf(n);
  const std::vector<uint8_t> frame = WsSession::encodeFrame(
      wsopcode::kBinary, true, payload.data(), n, 0x11223344u);
  ASSERT_EQ(frame.size(), 2u + 8u + 4u + n);
  EXPECT_EQ(frame[1], 0x80 | 127);
  uint64_t decoded = 0;
  for (int i = 0; i < 8; ++i) decoded = (decoded << 8) | frame[2 + i];
  EXPECT_EQ(decoded, static_cast<uint64_t>(n));
  // The 64-bit form is big-endian with the high bit clear.
  EXPECT_EQ(frame[2], 0x00);
  EXPECT_EQ(frame[3], 0x00);
}

TEST(WsEncodeFrame, AlwaysSetsTheClientMaskBit) {
  const int opcodes[] = {static_cast<int>(wsopcode::kText),
                         static_cast<int>(wsopcode::kBinary),
                         static_cast<int>(wsopcode::kContinuation),
                         static_cast<int>(wsopcode::kClose),
                         static_cast<int>(wsopcode::kPing),
                         static_cast<int>(wsopcode::kPong)};
  for (const int opcode : opcodes) {
    for (const size_t n : {size_t{0}, size_t{1}, size_t{125}}) {
      const std::vector<uint8_t> payload = payloadOf(n);
      const std::vector<uint8_t> frame =
          WsSession::encodeFrame(opcode, true, payload.data(), n, 0xdeadbeefu);
      ASSERT_GE(frame.size(), 6u);
      EXPECT_NE(frame[1] & 0x80, 0)
          << "opcode " << opcode << " length " << n
          << ": RFC 6455 §5.3 requires every client frame to be masked";
      // A zero-length frame still carries the four mask bytes.
      EXPECT_EQ(frame.size(), 2u + 4u + n);
    }
  }
}

TEST(WsEncodeFrame, MasksThePayloadWithTheSuppliedKey) {
  const std::vector<uint8_t> payload = payloadOf(300);
  const uint32_t key = 0xa1b2c3d4u;
  const std::vector<uint8_t> frame =
      WsSession::encodeFrame(wsopcode::kBinary, true, payload.data(),
                             payload.size(), key);
  const uint8_t mask[4] = {0xa1, 0xb2, 0xc3, 0xd4};
  ASSERT_EQ(frame.size(), 2u + 2u + 4u + payload.size());
  for (size_t i = 0; i < 4; ++i) EXPECT_EQ(frame[4 + i], mask[i]);
  for (size_t i = 0; i < payload.size(); ++i) {
    EXPECT_EQ(frame[8 + i], static_cast<uint8_t>(payload[i] ^ mask[i & 3]))
        << "at payload byte " << i;
  }
}

TEST(WsEncodeFrame, ClampsAControlFramePayloadTo125Bytes) {
  const std::vector<uint8_t> payload = payloadOf(400);
  for (const int64_t opcode :
       {wsopcode::kClose, wsopcode::kPing, wsopcode::kPong}) {
    const std::vector<uint8_t> frame = WsSession::encodeFrame(
        opcode, true, payload.data(), payload.size(), 0x00000000u);
    ASSERT_EQ(frame.size(), 2u + 4u + 125u) << "opcode " << opcode;
    EXPECT_EQ(frame[1], 0x80 | 125) << "opcode " << opcode;
    EXPECT_EQ(frame[0], static_cast<uint8_t>(0x80 | opcode));
  }
}

TEST(WsEncodeFrame, ClearsTheFinBitForAContinuedFragment) {
  const std::vector<uint8_t> payload = payloadOf(4);
  const std::vector<uint8_t> frame = WsSession::encodeFrame(
      wsopcode::kText, false, payload.data(), payload.size(), 0u);
  EXPECT_EQ(frame[0], 0x01);
}

// ─── parseFrameHeader: incompleteness ────────────────────────────────────────

TEST(WsParseFrameHeader, EveryShortPrefixReportsIncomplete) {
  struct Case {
    int opcode;
    uint64_t length;
    size_t headerBytes;
  };
  const Case cases[] = {
      {static_cast<int>(wsopcode::kBinary), 5, 2},
      {static_cast<int>(wsopcode::kBinary), 1000, 4},
      {static_cast<int>(wsopcode::kBinary), 70000, 10},
  };
  for (const Case& c : cases) {
    const std::vector<uint8_t> header = serverFrame(c.opcode, true, c.length);
    ASSERT_EQ(header.size(), c.headerBytes);
    for (size_t prefix = 0; prefix < c.headerBytes; ++prefix) {
      const ParsedFrame f = WsSession::parseFrameHeader(header.data(), prefix);
      EXPECT_FALSE(f.complete)
          << "length " << c.length << " prefix " << prefix;
      EXPECT_FALSE(f.protocolError)
          << "a short read is not a protocol error";
    }
    const ParsedFrame full =
        WsSession::parseFrameHeader(header.data(), header.size());
    EXPECT_TRUE(full.complete);
    EXPECT_FALSE(full.protocolError);
    EXPECT_EQ(full.headerBytes, c.headerBytes);
    EXPECT_EQ(full.payloadBytes, static_cast<size_t>(c.length));
  }
}

TEST(WsParseFrameHeader, ANullOrEmptyBufferIsIncompleteNotAnError) {
  const ParsedFrame f = WsSession::parseFrameHeader(nullptr, 0);
  EXPECT_FALSE(f.complete);
  EXPECT_FALSE(f.protocolError);
}

// ─── parseFrameHeader: protocol errors ───────────────────────────────────────

TEST(WsParseFrameHeader, ReservedBitsAreAProtocolError) {
  for (const uint8_t rsv : {0x10, 0x20, 0x40, 0x70}) {
    std::vector<uint8_t> frame = serverFrame(wsopcode::kText, true, 5);
    frame[0] = static_cast<uint8_t>(frame[0] | rsv);
    const ParsedFrame f = WsSession::parseFrameHeader(frame.data(), frame.size());
    EXPECT_TRUE(f.complete) << "a verdict, not a shortage of bytes";
    EXPECT_TRUE(f.protocolError) << "RSV bits set: 0x" << std::hex << int(rsv);
    EXPECT_NE(f.errorText, nullptr);
  }
}

TEST(WsParseFrameHeader, AMaskedServerFrameIsAProtocolError) {
  std::vector<uint8_t> frame = serverFrame(wsopcode::kText, true, 5);
  frame[1] = static_cast<uint8_t>(frame[1] | 0x80);
  const ParsedFrame f = WsSession::parseFrameHeader(frame.data(), frame.size());
  EXPECT_TRUE(f.complete);
  EXPECT_TRUE(f.protocolError);
  EXPECT_TRUE(f.masked);
}

TEST(WsParseFrameHeader, AFragmentedControlFrameIsAProtocolError) {
  for (const int64_t opcode :
       {wsopcode::kClose, wsopcode::kPing, wsopcode::kPong}) {
    const std::vector<uint8_t> frame =
        serverFrame(static_cast<int>(opcode), /*fin=*/false, 4);
    const ParsedFrame f = WsSession::parseFrameHeader(frame.data(), frame.size());
    EXPECT_TRUE(f.complete);
    EXPECT_TRUE(f.protocolError) << "opcode " << opcode;
  }
}

TEST(WsParseFrameHeader, AnOversizedControlFrameIsAProtocolError) {
  for (const int64_t opcode :
       {wsopcode::kClose, wsopcode::kPing, wsopcode::kPong}) {
    const std::vector<uint8_t> frame =
        serverFrame(static_cast<int>(opcode), true, 126);
    const ParsedFrame f = WsSession::parseFrameHeader(frame.data(), frame.size());
    EXPECT_TRUE(f.complete);
    EXPECT_TRUE(f.protocolError) << "opcode " << opcode;
  }
  // 125 is the limit and must still be accepted.
  const std::vector<uint8_t> ok = serverFrame(wsopcode::kPing, true, 125);
  const ParsedFrame f = WsSession::parseFrameHeader(ok.data(), ok.size());
  EXPECT_TRUE(f.complete);
  EXPECT_FALSE(f.protocolError);
  EXPECT_EQ(f.payloadBytes, 125u);
}

TEST(WsParseFrameHeader, ReservedOpcodesAreAProtocolError) {
  for (const int opcode : {0x3, 0x4, 0x5, 0x6, 0x7, 0xb, 0xc, 0xd, 0xe, 0xf}) {
    const std::vector<uint8_t> frame = serverFrame(opcode, true, 0);
    const ParsedFrame f = WsSession::parseFrameHeader(frame.data(), frame.size());
    EXPECT_TRUE(f.complete);
    EXPECT_TRUE(f.protocolError) << "opcode 0x" << std::hex << opcode;
  }
}

TEST(WsParseFrameHeader, ASixtyFourBitLengthWithTheHighBitSetIsAProtocolError) {
  std::vector<uint8_t> frame = serverFrame(wsopcode::kBinary, true, 70000);
  ASSERT_EQ(frame.size(), 10u);
  frame[2] = 0x80;  // RFC 6455 §5.2: the most significant bit MUST be 0
  const ParsedFrame f = WsSession::parseFrameHeader(frame.data(), frame.size());
  EXPECT_TRUE(f.complete);
  EXPECT_TRUE(f.protocolError);
  EXPECT_NE(f.errorText, nullptr);
}

TEST(WsParseFrameHeader, AcceptsEveryDataAndControlOpcodeItKnows) {
  const int64_t opcodes[] = {wsopcode::kContinuation, wsopcode::kText,
                             wsopcode::kBinary, wsopcode::kClose,
                             wsopcode::kPing, wsopcode::kPong};
  for (const int64_t opcode : opcodes) {
    const std::vector<uint8_t> frame =
        serverFrame(static_cast<int>(opcode), true, 10);
    const ParsedFrame f = WsSession::parseFrameHeader(frame.data(), frame.size());
    ASSERT_TRUE(f.complete) << "opcode " << opcode;
    EXPECT_FALSE(f.protocolError) << "opcode " << opcode;
    EXPECT_EQ(f.opcode, opcode);
    EXPECT_TRUE(f.fin);
    EXPECT_FALSE(f.masked);
    EXPECT_EQ(f.headerBytes, 2u);
    EXPECT_EQ(f.payloadBytes, 10u);
  }
}

TEST(WsParseFrameHeader, ANonFinalDataFrameIsFine) {
  const std::vector<uint8_t> frame = serverFrame(wsopcode::kText, false, 3);
  const ParsedFrame f = WsSession::parseFrameHeader(frame.data(), frame.size());
  ASSERT_TRUE(f.complete);
  EXPECT_FALSE(f.protocolError);
  EXPECT_FALSE(f.fin);
}

// ─── Geometry round trip ─────────────────────────────────────────────────────

TEST(WsFrameGeometry, EncodeAndParseAgreeAtEveryLengthBoundary) {
  const size_t sizes[] = {0, 1, 125, 126, 127, 65535, 65536};
  for (const size_t n : sizes) {
    const std::vector<uint8_t> payload = payloadOf(n);
    const std::vector<uint8_t> client = WsSession::encodeFrame(
        wsopcode::kBinary, true, payload.data(), n, 0x5a5a5a5au);

    const size_t extra = extendedLengthBytes(client[1]);
    ASSERT_EQ(client.size(), 2u + extra + 4u + n) << "n = " << n;

    const std::vector<uint8_t> server = asServerFrame(client);
    const ParsedFrame f =
        WsSession::parseFrameHeader(server.data(), server.size());
    ASSERT_TRUE(f.complete) << "n = " << n;
    EXPECT_FALSE(f.protocolError) << "n = " << n;
    EXPECT_TRUE(f.fin);
    EXPECT_EQ(f.opcode, wsopcode::kBinary);
    EXPECT_EQ(f.headerBytes, 2u + extra) << "n = " << n;
    EXPECT_EQ(f.payloadBytes, n) << "n = " << n;
    ASSERT_EQ(server.size(), f.headerBytes + f.payloadBytes);

    // Unmasking recovered the original bytes, so the mask round-tripped too.
    const std::vector<uint8_t> recovered(
        server.begin() + static_cast<std::ptrdiff_t>(f.headerBytes),
        server.end());
    EXPECT_EQ(recovered, payload) << "n = " << n;
  }
}

TEST(WsFrameGeometry, TheLengthFormSwitchesExactlyAtTheSpecBoundaries) {
  const std::vector<uint8_t> payload = payloadOf(65536);
  struct Case {
    size_t n;
    size_t extra;
  };
  const Case cases[] = {{0, 0},     {125, 0},   {126, 2},
                        {65535, 2}, {65536, 8}};
  for (const Case& c : cases) {
    const std::vector<uint8_t> frame = WsSession::encodeFrame(
        wsopcode::kBinary, true, payload.data(), c.n, 0u);
    EXPECT_EQ(extendedLengthBytes(frame[1]), c.extra) << "n = " << c.n;
  }
}
