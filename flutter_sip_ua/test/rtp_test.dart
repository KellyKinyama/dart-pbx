import 'dart:typed_data';

import 'package:flutter_sip_ua/sip/audio/rtp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RTP', () {
    test('makeRtpPacket produces a 12-byte header + payload', () {
      final state = RtpState(
        ssrc: 0x12345678,
        payloadType: 0,
        initialSequenceNumber: 100,
      );
      final payload = Uint8List.fromList(List<int>.generate(160, (i) => i));
      final pkt = makeRtpPacket(state, payload, 0xCAFEBABE);
      expect(pkt.length, rtpHeaderSize + 160);
      // V=2, P=0, X=0, CC=0
      expect((pkt[0] >> 6) & 0x3, 2);
      expect(pkt[0] & 0x0F, 0);
      // M=0, PT=0
      expect(pkt[1], 0);
      // Sequence number
      expect((pkt[2] << 8) | pkt[3], 100);
      // Sequence advances after sending.
      expect(state.seq, 101);
    });

    test('parseRtp inverts makeRtpPacket exactly', () {
      final state = RtpState(
        ssrc: 0xAABBCCDD,
        payloadType: 8,
        initialSequenceNumber: 5000,
      );
      final payload = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      final wire = makeRtpPacket(state, payload, 0x1000, marker: true);
      final pkt = parseRtp(wire)!;
      expect(pkt.payloadType, 8);
      expect(pkt.sequenceNumber, 5000);
      expect(pkt.timestamp, 0x1000);
      expect(pkt.ssrc, 0xAABBCCDD);
      expect(pkt.marker, isTrue);
      expect(pkt.payload, payload);
    });

    test('parseRtp returns null on truncated buffers', () {
      expect(parseRtp(Uint8List(0)), isNull);
      expect(parseRtp(Uint8List(11)), isNull);
    });

    test('parseRtp rejects wrong RTP version', () {
      final buf = Uint8List(12);
      buf[0] = 0x40; // V=1
      expect(parseRtp(buf), isNull);
    });

    test('parseRtp skips CSRC list and header extensions', () {
      // Build by hand: V=2, X=1, CC=2; PT=0; seq=1; ts=2; ssrc=3;
      // 2 CSRCs + extension (profile=0, length=1 word → 4 ext bytes) + payload "P".
      final buf = Uint8List(12 + 8 + 4 + 4 + 1);
      buf[0] = (2 << 6) | (1 << 4) | 2; // V=2, X=1, CC=2
      buf[1] = 0;
      buf[2] = 0;
      buf[3] = 1;
      // ts
      buf[4] = 0;
      buf[5] = 0;
      buf[6] = 0;
      buf[7] = 2;
      // ssrc
      buf[8] = 0;
      buf[9] = 0;
      buf[10] = 0;
      buf[11] = 3;
      // CSRC #1, #2 (8 bytes of zeros)
      // Extension header: profile (2B) + length-in-words (2B = 1)
      buf[20] = 0xBE;
      buf[21] = 0xDE;
      buf[22] = 0;
      buf[23] = 1;
      // 4 extension bytes of zeros
      // Payload single 0x50
      buf[28] = 0x50;
      final pkt = parseRtp(buf)!;
      expect(pkt.payload, Uint8List.fromList([0x50]));
      expect(pkt.sequenceNumber, 1);
      expect(pkt.ssrc, 3);
    });

    test('marker bit and payload type are encoded together correctly', () {
      final s = RtpState(ssrc: 1, payloadType: 96);
      final pkt = makeRtpPacket(s, Uint8List(1), 0, marker: true);
      // marker bit is the high bit of byte 1; PT=96 lives in the low 7 bits.
      expect(pkt[1], 0x80 | 96);
    });

    test('sequence number wraps at 0xFFFF', () {
      final s = RtpState(
        ssrc: 1,
        payloadType: 0,
        initialSequenceNumber: 0xFFFF,
      );
      makeRtpPacket(s, Uint8List(1), 0);
      expect(s.seq, 0);
    });

    test('payloadType outside 0..127 throws', () {
      expect(
        () => RtpState(ssrc: 1, payloadType: 200),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
