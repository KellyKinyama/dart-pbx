/// RFC 7741 — RTP payload format for VP8.
///
/// Pure-Dart packetizer / depacketizer. Splits an encoded VP8 frame into
/// RTP-sized payloads (each prefixed with the VP8 payload descriptor) and
/// reassembles them on the receive side.
///
/// We implement the mandatory bits of the descriptor:
///
/// ```text
///  0 1 2 3 4 5 6 7
/// +-+-+-+-+-+-+-+-+
/// |X|R|N|S|R| PID | (required)
/// +-+-+-+-+-+-+-+-+
/// ```
///
/// `X` = 0 (no extensions emitted; we accept and skip them on parse).
/// `S` = 1 on the first packet of a frame.
/// `PID` = 0 (we don't use temporal partitions on send).
///
/// Receivers reassemble by buffering payloads until the marker bit on the
/// RTP packet (set on the last fragment of the frame).
library;

import 'dart:typed_data';

/// Default safe payload size that fits a VP8 fragment + descriptor inside
/// a typical 1200-byte RTP/UDP MTU. Subtract 12-byte RTP header + 1-byte
/// descriptor = 1187, rounded down for safety.
const int defaultVp8MaxPayload = 1180;

/// Result of packetizing one VP8 frame.
class Vp8RtpFragment {
  Vp8RtpFragment({
    required this.payload,
    required this.marker,
    required this.startOfFrame,
  });

  /// Payload bytes including the 1-byte VP8 descriptor.
  final Uint8List payload;

  /// True iff this is the last fragment of the frame.
  final bool marker;

  /// True iff this is the first fragment of the frame.
  final bool startOfFrame;
}

/// Split [frame] into RFC 7741 fragments.
///
/// `frame` must be a complete VP8 compressed frame as emitted by an encoder.
List<Vp8RtpFragment> packetizeVp8(
  Uint8List frame, {
  int maxPayloadSize = defaultVp8MaxPayload,
}) {
  if (frame.isEmpty) return const [];
  // 1 byte for the descriptor.
  final maxBody = maxPayloadSize - 1;
  if (maxBody <= 0) {
    throw ArgumentError.value(
      maxPayloadSize,
      'maxPayloadSize',
      'must leave room for the 1-byte VP8 descriptor',
    );
  }

  final fragments = <Vp8RtpFragment>[];
  var offset = 0;
  var first = true;
  while (offset < frame.length) {
    final size = (frame.length - offset) < maxBody
        ? frame.length - offset
        : maxBody;
    final out = Uint8List(1 + size);
    // Descriptor: only S bit (0x10) on the first fragment.
    out[0] = first ? 0x10 : 0x00;
    out.setRange(1, 1 + size, frame, offset);
    final end = offset + size >= frame.length;
    fragments.add(
      Vp8RtpFragment(payload: out, marker: end, startOfFrame: first),
    );
    offset += size;
    first = false;
  }
  return fragments;
}

/// Stateful reassembler. Feed it inbound RTP payloads (with their marker
/// bit and timestamp) and it will emit complete VP8 frames.
class Vp8Depacketizer {
  final List<Uint8List> _bodies = [];
  int? _currentTimestamp;
  bool _haveStart = false;
  int _droppedFrames = 0;

  int get droppedFrames => _droppedFrames;

  /// Feed one RTP payload (the bytes after the 12-byte RTP header) plus
  /// the packet's `marker` bit and `timestamp`. Returns a complete VP8
  /// frame when the last fragment arrives, otherwise null.
  Uint8List? add({
    required Uint8List payload,
    required bool marker,
    required int timestamp,
  }) {
    if (payload.isEmpty) return null;
    final body = _stripDescriptor(payload);
    if (body == null) return null;

    // Timestamp change without a marker means we lost the tail of the
    // previous frame. Drop the partial buffer.
    if (_currentTimestamp != null && _currentTimestamp != timestamp) {
      if (_bodies.isNotEmpty) _droppedFrames++;
      _bodies.clear();
      _haveStart = false;
    }
    _currentTimestamp = timestamp;

    final descriptor = payload[0];
    final isStart = (descriptor & 0x10) != 0;
    if (isStart) {
      if (_bodies.isNotEmpty) {
        // A new start with old buffered data → previous frame was lost.
        _droppedFrames++;
        _bodies.clear();
      }
      _haveStart = true;
    } else if (!_haveStart) {
      // Mid-frame fragment with no start seen → useless.
      return null;
    }

    _bodies.add(body);
    if (!marker) return null;

    // Marker → frame is complete. Reassemble.
    final total = _bodies.fold<int>(0, (a, b) => a + b.length);
    final out = Uint8List(total);
    var off = 0;
    for (final b in _bodies) {
      out.setRange(off, off + b.length, b);
      off += b.length;
    }
    _bodies.clear();
    _haveStart = false;
    _currentTimestamp = null;
    return out;
  }

  /// Strip the descriptor (and any X-bit extension headers) and return the
  /// VP8 body slice, or null if the descriptor is malformed.
  static Uint8List? _stripDescriptor(Uint8List p) {
    if (p.isEmpty) return null;
    final d = p[0];
    var off = 1;
    if ((d & 0x80) != 0) {
      // X bit set: extended control bits (1 byte).
      if (off >= p.length) return null;
      final x = p[off++];
      // I bit (PictureID) — 1 or 2 bytes (M bit selects width).
      if ((x & 0x80) != 0) {
        if (off >= p.length) return null;
        final i0 = p[off++];
        if ((i0 & 0x80) != 0) {
          // M bit set: 15-bit PictureID, second byte follows.
          if (off >= p.length) return null;
          off++;
        }
      }
      // L bit (TL0PICIDX) — 1 byte.
      if ((x & 0x40) != 0) {
        if (off >= p.length) return null;
        off++;
      }
      // T or K bits (TID/KEYIDX) — 1 byte combined.
      if ((x & 0x30) != 0) {
        if (off >= p.length) return null;
        off++;
      }
    }
    if (off > p.length) return null;
    return Uint8List.sublistView(p, off);
  }
}
