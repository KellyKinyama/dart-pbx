import 'dart:typed_data';

import 'package:flutter_sip_ua/sip/audio/rtp.dart';
import 'package:flutter_sip_ua/sip/audio/rtp_stats.dart';
import 'package:flutter_test/flutter_test.dart';

RtpPacket _pkt(int seq, int ts, {int ssrc = 0xCAFEBABE}) => RtpPacket(
  payloadType: 0,
  sequenceNumber: seq,
  timestamp: ts,
  ssrc: ssrc,
  payload: Uint8List(0),
  marker: false,
);

void main() {
  group('RtpStats', () {
    test('counts packets and tracks highest seq after probation', () {
      final s = RtpStats();
      // First two packets clear probation (MIN_SEQUENTIAL = 2).
      s.onReceived(_pkt(100, 0), 8000);
      s.onReceived(_pkt(101, 160), 8000);
      s.onReceived(_pkt(102, 320), 8000);
      s.onReceived(_pkt(103, 480), 8000);
      expect(s.remoteSsrc, 0xCAFEBABE);
      expect(s.extendedHighestSeq & 0xFFFF, 103);
      expect(s.cumulativeLost, 0);
    });

    test('detects lost packets after the gap', () {
      final s = RtpStats();
      // Probation.
      s.onReceived(_pkt(1, 0), 8000);
      s.onReceived(_pkt(2, 160), 8000);
      // Skip 3 and 4.
      s.onReceived(_pkt(5, 800), 8000);
      s.onReceived(_pkt(6, 960), 8000);
      // expected (max - base + 1) = 6 - 1 + 1 = 6, received = 4 → 2 lost.
      expect(s.cumulativeLost, 2);
    });

    test('fractionLost windows reset between calls', () {
      final s = RtpStats();
      s.onReceived(_pkt(1, 0), 8000);
      s.onReceived(_pkt(2, 160), 8000);
      s.onReceived(_pkt(4, 480), 8000); // lose seq 3
      // 1 lost out of 3 expected since the window opened → 256/3 ≈ 85.
      final f1 = s.fractionLostSinceLastReport();
      expect(f1, greaterThan(0));
      // Next call with no further loss should report zero.
      s.onReceived(_pkt(5, 640), 8000);
      final f2 = s.fractionLostSinceLastReport();
      expect(f2, 0);
    });

    test('SSRC change resets receiver state', () {
      final s = RtpStats();
      s.onReceived(_pkt(1, 0, ssrc: 1), 8000);
      s.onReceived(_pkt(2, 160, ssrc: 1), 8000);
      s.onReceived(_pkt(50, 8000, ssrc: 2), 8000);
      expect(s.remoteSsrc, 2);
      // After reset + first packet of new ssrc, the probation logic gates
      // counting; just make sure cumulativeLost isn't a huge negative.
      expect(s.cumulativeLost.abs(), lessThan(1000));
    });

    test('sender counters increment on onSent', () {
      final s = RtpStats();
      s.onSent(160, 0);
      s.onSent(160, 160);
      expect(s.sentPackets, 2);
      expect(s.sentOctets, 320);
      expect(s.lastSentRtpTimestamp, 160);
      expect(s.lastSendUnixMicros, isNonZero);
    });
  });
}
