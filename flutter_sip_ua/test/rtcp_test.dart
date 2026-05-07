import 'dart:typed_data';

import 'package:flutter_sip_ua/sip/audio/rtcp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RTCP', () {
    test('SR encodes and round-trips through parseRtcp', () {
      final sr = SenderReport(
        ssrc: 0x11223344,
        ntpSeconds: 0xC0FFEE00,
        ntpFraction: 0x80000000,
        rtpTimestamp: 12345,
        packetCount: 100,
        octetCount: 16000,
        reports: [
          ReportBlock(
            ssrc: 0xAABBCCDD,
            fractionLost: 0x10,
            cumulativeLost: 5,
            extendedHighestSeq: 0x00010050,
            jitter: 42,
            lastSr: 0xCAFEBABE,
            delaySinceLastSr: 0x00010000,
          ),
        ],
      );
      final bytes = sr.toBytes();
      // length must be a multiple of 4
      expect(bytes.length % 4, 0);
      // version=2, RC=1
      expect((bytes[0] >> 6) & 0x3, 2);
      expect(bytes[0] & 0x1F, 1);
      expect(bytes[1], rtcpPtSr);

      final parsed = parseRtcp(bytes);
      expect(parsed, hasLength(1));
      final p = parsed.single;
      expect(p, isA<RtcpSr>());
      final got = (p as RtcpSr).report;
      expect(got.ssrc, 0x11223344);
      expect(got.ntpSeconds, 0xC0FFEE00);
      expect(got.ntpFraction, 0x80000000);
      expect(got.rtpTimestamp, 12345);
      expect(got.packetCount, 100);
      expect(got.octetCount, 16000);
      expect(got.reports, hasLength(1));
      final rb = got.reports.single;
      expect(rb.ssrc, 0xAABBCCDD);
      expect(rb.fractionLost, 0x10);
      expect(rb.cumulativeLost, 5);
      expect(rb.extendedHighestSeq, 0x00010050);
      expect(rb.jitter, 42);
      expect(rb.lastSr, 0xCAFEBABE);
      expect(rb.delaySinceLastSr, 0x00010000);
    });

    test('RR with no report blocks parses cleanly', () {
      final rr = ReceiverReport(ssrc: 0xDEADBEEF).toBytes();
      expect(rr.length, 8);
      final parsed = parseRtcp(rr);
      expect(parsed.single, isA<RtcpRr>());
      expect((parsed.single as RtcpRr).report.ssrc, 0xDEADBEEF);
    });

    test('SDES CNAME is padded to a 4-byte boundary', () {
      final sdes = SourceDescription(
        chunks: [
          SdesChunk(ssrc: 1, cname: 'a@b'), // 3 chars
        ],
      ).toBytes();
      expect(sdes.length % 4, 0);
      // header(4) + chunk: ssrc(4)+type(1)+len(1)+'a@b'(3)+end(1)=10 → pad to 12
      expect(sdes.length, 4 + 12);
      expect(sdes[1], rtcpPtSdes);
    });

    test('BYE with reason round-trips', () {
      final bye = GoodBye(sources: [0x01020304], reason: 'bye').toBytes();
      expect(bye.length % 4, 0);
      expect(bye[1], rtcpPtBye);
      final parsed = parseRtcp(bye);
      expect(parsed.single, isA<RtcpBye>());
      final got = (parsed.single as RtcpBye).bye;
      expect(got.sources, [0x01020304]);
    });

    test('Compound packet (SR + SDES) parses both elements', () {
      final sr = SenderReport(
        ssrc: 7,
        ntpSeconds: 1,
        ntpFraction: 2,
        rtpTimestamp: 3,
        packetCount: 4,
        octetCount: 5,
      ).toBytes();
      final sdes = SourceDescription(
        chunks: [SdesChunk(ssrc: 7, cname: 'x@y')],
      ).toBytes();
      final compound = Uint8List(sr.length + sdes.length)
        ..setRange(0, sr.length, sr)
        ..setRange(sr.length, sr.length + sdes.length, sdes);
      final parsed = parseRtcp(compound);
      expect(parsed, hasLength(2));
      expect(parsed[0], isA<RtcpSr>());
      expect(parsed[1], isA<RtcpSdes>());
    });

    test('NTP conversion is consistent', () {
      // 1 January 1970 00:00:00 UTC → NTP seconds = 2208988800
      final ntp = unixMicrosToNtp(0);
      expect(ntp.seconds, 2208988800);
      expect(ntp.fraction, 0);
    });
  });
}
