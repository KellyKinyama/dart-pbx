import 'dart:typed_data';

import 'package:flutter_sip_ua/sip/video/vp8_rtp.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _ramp(int n) =>
    Uint8List.fromList(List<int>.generate(n, (i) => i & 0xFF));

void main() {
  group('VP8 packetizer (RFC 7741)', () {
    test('frame smaller than MTU produces a single fragment with M bit', () {
      final frame = _ramp(500);
      final frags = packetizeVp8(frame, maxPayloadSize: 1180);
      expect(frags, hasLength(1));
      expect(frags.single.marker, isTrue);
      expect(frags.single.startOfFrame, isTrue);
      // First payload byte is the descriptor with the S bit set.
      expect(frags.single.payload[0] & 0x10, 0x10);
      expect(frags.single.payload.length, 1 + 500);
    });

    test('large frame is split and only the first fragment has S=1', () {
      final frame = _ramp(3500);
      final frags = packetizeVp8(frame, maxPayloadSize: 1180);
      expect(frags.length, greaterThan(1));
      expect(frags.first.payload[0] & 0x10, 0x10);
      for (final f in frags.skip(1)) {
        expect(f.payload[0] & 0x10, 0);
      }
      // Marker is set only on the last fragment.
      expect(frags.first.marker, isFalse);
      expect(frags.last.marker, isTrue);
      // Sum of body bytes equals the frame size.
      final total = frags.fold<int>(0, (a, f) => a + f.payload.length - 1);
      expect(total, frame.length);
    });

    test('empty frame yields no fragments', () {
      expect(packetizeVp8(Uint8List(0)), isEmpty);
    });

    test('rejects a maxPayloadSize that leaves no room for the descriptor', () {
      expect(
        () => packetizeVp8(_ramp(10), maxPayloadSize: 1),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('VP8 depacketizer', () {
    test('round-trips a single-fragment frame', () {
      final frame = _ramp(400);
      final fragments = packetizeVp8(frame, maxPayloadSize: 1180);
      final dep = Vp8Depacketizer();
      Uint8List? out;
      var ts = 1000;
      for (final f in fragments) {
        out = dep.add(payload: f.payload, marker: f.marker, timestamp: ts);
      }
      expect(out, isNotNull);
      expect(out, frame);
      expect(dep.droppedFrames, 0);
    });

    test('round-trips a multi-fragment frame in order', () {
      final frame = _ramp(4096);
      final fragments = packetizeVp8(frame, maxPayloadSize: 600);
      expect(fragments.length, greaterThan(1));
      final dep = Vp8Depacketizer();
      Uint8List? out;
      const ts = 90000;
      for (final f in fragments) {
        out = dep.add(payload: f.payload, marker: f.marker, timestamp: ts);
      }
      expect(out, isNotNull);
      expect(out, frame);
    });

    test('drops a frame whose start fragment is missing', () {
      final frame = _ramp(1200);
      final fragments = packetizeVp8(frame, maxPayloadSize: 400);
      final dep = Vp8Depacketizer();
      // Skip the first fragment.
      for (final f in fragments.skip(1)) {
        final r = dep.add(payload: f.payload, marker: f.marker, timestamp: 1);
        expect(r, isNull);
      }
    });

    test('timestamp jump without marker drops the partial frame', () {
      final f1 = packetizeVp8(_ramp(800), maxPayloadSize: 300);
      final f2 = packetizeVp8(_ramp(400));
      final dep = Vp8Depacketizer();
      // Feed only the first fragment of frame 1, then start frame 2.
      dep.add(payload: f1.first.payload, marker: false, timestamp: 100);
      final out = dep.add(
        payload: f2.first.payload,
        marker: f2.first.marker,
        timestamp: 200,
      );
      expect(out, isNotNull);
      expect(dep.droppedFrames, greaterThanOrEqualTo(1));
    });

    test('skips X-bit extension headers (PictureID + TL0PICIDX)', () {
      // Build a synthetic single-fragment payload by hand:
      //   descriptor: X=1, S=1            → 0x90
      //   ext byte:   I=1, L=1            → 0xC0
      //   PictureID:  M=0, 7-bit          → 0x42
      //   TL0PICIDX:                     → 0x07
      //   body bytes: 0xAA 0xBB 0xCC
      final payload = Uint8List.fromList([
        0x90,
        0xC0,
        0x42,
        0x07,
        0xAA,
        0xBB,
        0xCC,
      ]);
      final dep = Vp8Depacketizer();
      final out = dep.add(payload: payload, marker: true, timestamp: 1);
      expect(out, Uint8List.fromList([0xAA, 0xBB, 0xCC]));
    });

    test('handles 15-bit PictureID (M bit set)', () {
      // descriptor X=1,S=1=0x90; ext I=1=0x80; PID hi M=1=0x80, lo=0x12;
      // body 0x42
      final payload = Uint8List.fromList([0x90, 0x80, 0x80, 0x12, 0x42]);
      final dep = Vp8Depacketizer();
      final out = dep.add(payload: payload, marker: true, timestamp: 1);
      expect(out, Uint8List.fromList([0x42]));
    });
  });
}
