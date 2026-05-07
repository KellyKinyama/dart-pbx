/// Minimal RFC 3550 RTP packet builder + parser — pure Dart.
///
/// Trimmed port of `KellyKinyama/dart-rtp-packet` (`lib/src/rtp.dart`),
/// keeping only what an audio-only G.711 sender/receiver needs:
///
///   * fixed 12-byte header
///   * single-payload packet (no fragmentation; G.711 frames at 20ms are
///     ~160 bytes, well under any MTU)
///   * sequence + timestamp + SSRC bookkeeping in [RtpState]
///
/// SRTP, RTCP, header extensions and FU-A fragmentation are intentionally
/// omitted — they don't apply to plain SIP/G.711 calls.
library;

import 'dart:typed_data';

const int rtpVersion = 2;
const int rtpHeaderSize = 12;

/// Mutable per-stream state. One instance per outbound RTP stream.
class RtpState {
  RtpState({
    required this.ssrc,
    required this.payloadType,
    int? initialSequenceNumber,
  }) : assert(
         payloadType >= 0 && payloadType <= 127,
         'payloadType must be 0..127 (RFC 3551)',
       ),
       seq =
           (initialSequenceNumber ??
               (DateTime.now().millisecondsSinceEpoch & 0xFFFF)) &
           0xFFFF;

  final int ssrc;
  final int payloadType;
  int seq;
}

/// Builds an RTP packet (RFC 3550 §5.1). Returns the wire bytes ready for
/// `RawDatagramSocket.send`. Increments [state.seq] by one.
Uint8List makeRtpPacket(
  RtpState state,
  Uint8List payload,
  int rtpTimestamp, {
  bool marker = false,
}) {
  final seq = state.seq;
  final buf = Uint8List(rtpHeaderSize + payload.length);

  buf[0] = (rtpVersion << 6);
  buf[1] = (marker ? 0x80 : 0) | (state.payloadType & 0x7F);

  buf[2] = (seq >> 8) & 0xFF;
  buf[3] = seq & 0xFF;

  buf[4] = (rtpTimestamp >> 24) & 0xFF;
  buf[5] = (rtpTimestamp >> 16) & 0xFF;
  buf[6] = (rtpTimestamp >> 8) & 0xFF;
  buf[7] = rtpTimestamp & 0xFF;

  buf[8] = (state.ssrc >> 24) & 0xFF;
  buf[9] = (state.ssrc >> 16) & 0xFF;
  buf[10] = (state.ssrc >> 8) & 0xFF;
  buf[11] = state.ssrc & 0xFF;

  if (payload.isNotEmpty) {
    buf.setRange(rtpHeaderSize, rtpHeaderSize + payload.length, payload);
  }

  state.seq = (state.seq + 1) & 0xFFFF;
  return buf;
}

/// Decoded inbound RTP packet.
class RtpPacket {
  RtpPacket({
    required this.payloadType,
    required this.sequenceNumber,
    required this.timestamp,
    required this.ssrc,
    required this.payload,
    required this.marker,
  });

  final int payloadType;
  final int sequenceNumber;
  final int timestamp;
  final int ssrc;
  final Uint8List payload;
  final bool marker;
}

/// Parses an inbound RTP datagram. Returns null if the buffer is too short
/// or the version isn't 2. Skips past CSRC list and any header extension.
RtpPacket? parseRtp(Uint8List data) {
  if (data.length < rtpHeaderSize) return null;
  final b0 = data[0];
  final b1 = data[1];
  if (((b0 >> 6) & 0x03) != rtpVersion) return null;

  final cc = b0 & 0x0F;
  final hasExt = (b0 & 0x10) != 0;
  final marker = ((b1 >> 7) & 1) == 1;
  final payloadType = b1 & 0x7F;

  final seq = (data[2] << 8) | data[3];
  final ts = (data[4] << 24) | (data[5] << 16) | (data[6] << 8) | data[7];
  final ssrc = (data[8] << 24) | (data[9] << 16) | (data[10] << 8) | data[11];

  var headerLen = rtpHeaderSize + cc * 4;
  if (hasExt) {
    if (data.length < headerLen + 4) return null;
    final words = (data[headerLen + 2] << 8) | data[headerLen + 3];
    headerLen += 4 + words * 4;
  }
  if (data.length < headerLen) return null;
  final payload = Uint8List.sublistView(data, headerLen);

  return RtpPacket(
    payloadType: payloadType,
    sequenceNumber: seq,
    timestamp: ts,
    ssrc: ssrc,
    payload: payload,
    marker: marker,
  );
}
