import 'package:flutter_sip_ua/sip/audio/media_session.dart';
import 'package:flutter_sip_ua/sip/sdp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SDP', () {
    test('buildG711Offer advertises PCMU, telephone-event and rtcp', () {
      final sdp = buildG711Offer(
        username: '6001',
        localHost: '10.0.0.5',
        localPort: 40000,
        rtcpPort: 40001,
      );
      expect(sdp, contains('m=audio 40000 RTP/AVP 0 8 101'));
      expect(sdp, contains('a=rtpmap:0 PCMU/8000'));
      expect(sdp, contains('a=rtpmap:8 PCMA/8000'));
      expect(sdp, contains('a=rtpmap:101 telephone-event/8000'));
      expect(sdp, contains('a=fmtp:101 0-15'));
      expect(sdp, contains('a=rtcp:40001'));
      expect(sdp, contains('a=ptime:20'));
      expect(sdp, contains('a=sendrecv'));
      expect(sdp, contains('c=IN IP4 10.0.0.5'));
    });

    test('buildG711Offer respects direction and omits rtcp when null', () {
      final sdp = buildG711Offer(
        username: 'x',
        localHost: '0.0.0.0',
        localPort: 5004,
        direction: SdpDirection.sendonly,
      );
      expect(sdp, contains('a=sendonly'));
      expect(sdp, isNot(contains('a=rtcp:')));
    });

    test('parseSdpAudio reads a typical Asterisk PCMU offer', () {
      const body = '''v=0\r
o=root 1 1 IN IP4 192.168.1.10\r
s=-\r
c=IN IP4 192.168.1.10\r
t=0 0\r
m=audio 12000 RTP/AVP 0 8 101\r
a=rtpmap:0 PCMU/8000\r
a=rtpmap:8 PCMA/8000\r
a=rtpmap:101 telephone-event/8000\r
a=fmtp:101 0-16\r
a=rtcp:12001\r
a=ptime:20\r
a=sendrecv\r
''';
      final parsed = parseSdpAudio(body);
      expect(parsed, isNotNull);
      expect(parsed!.host, '192.168.1.10');
      expect(parsed.port, 12000);
      expect(parsed.codec, G711Variant.pcmu);
      expect(parsed.rtcpPort, 12001);
      expect(parsed.effectiveRtcpPort, 12001);
      expect(parsed.direction, SdpDirection.sendrecv);
      expect(parsed.telephoneEventPt, 101);
    });

    test('parseSdpAudio falls back to port+1 when a=rtcp is absent', () {
      const body = '''v=0
o=- 1 1 IN IP4 1.2.3.4
c=IN IP4 1.2.3.4
t=0 0
m=audio 30000 RTP/AVP 8
a=rtpmap:8 PCMA/8000
a=recvonly
''';
      final parsed = parseSdpAudio(body);
      expect(parsed, isNotNull);
      expect(parsed!.codec, G711Variant.pcma);
      expect(parsed.rtcpPort, isNull);
      expect(parsed.effectiveRtcpPort, 30001);
      expect(parsed.direction, SdpDirection.recvonly);
      expect(parsed.telephoneEventPt, isNull);
    });

    test('parseSdpAudio returns null on malformed bodies', () {
      expect(parseSdpAudio(''), isNull);
      expect(parseSdpAudio('v=0\r\nbroken'), isNull);
    });

    test('toEndpoint propagates rtcpPort and DTMF PT', () {
      final ep = SdpAudio(
        host: '1.1.1.1',
        port: 4000,
        codec: G711Variant.pcmu,
        rtcpPort: 4002,
        telephoneEventPt: 96,
      ).toEndpoint();
      expect(ep.rtcpPort, 4002);
      expect(ep.telephoneEventPt, 96);
    });

    test('parseSdpAudio captures telephone-event fmtp range', () {
      const body =
          'v=0\r\n'
          'o=- 1 1 IN IP4 1.2.3.4\r\n'
          'c=IN IP4 1.2.3.4\r\n'
          't=0 0\r\n'
          'm=audio 5000 RTP/AVP 8 101\r\n'
          'a=rtpmap:8 PCMA/8000\r\n'
          'a=rtpmap:101 telephone-event/8000\r\n'
          'a=fmtp:101 0-16\r\n';
      final parsed = parseSdpAudio(body);
      expect(parsed, isNotNull);
      expect(parsed!.telephoneEventPt, 101);
      expect(parsed.telephoneEventRange, '0-16');
    });

    test('buildG711Answer emits codec intersection only', () {
      // Peer offered PCMA + DTMF on PT 101 with an extended range.
      final remote = SdpAudio(
        host: '10.0.0.1',
        port: 30000,
        codec: G711Variant.pcma,
        telephoneEventPt: 101,
        telephoneEventRange: '0-16',
      );
      final answer = buildG711Answer(
        username: '7000',
        localHost: '10.0.0.5',
        localPort: 40000,
        remoteOffer: remote,
        rtcpPort: 40001,
      );
      // Only PCMA + DTMF, never PCMU.
      expect(answer, contains('m=audio 40000 RTP/AVP 8 101'));
      expect(answer, isNot(contains('a=rtpmap:0 PCMU/8000')));
      expect(answer, contains('a=rtpmap:8 PCMA/8000'));
      // Mirrored DTMF range from the offer.
      expect(answer, contains('a=fmtp:101 0-16'));
      expect(answer, contains('a=rtcp:40001'));
      expect(answer, contains('a=sendrecv'));
    });

    test('buildG711Offer with explicit sessionId / version is stable', () {
      final a = buildG711Offer(
        username: 'x',
        localHost: '1.1.1.1',
        localPort: 5000,
        sessionId: 12345,
        sessionVersion: 12345,
      );
      final b = buildG711Offer(
        username: 'x',
        localHost: '1.1.1.1',
        localPort: 5000,
        sessionId: 12345,
        sessionVersion: 12346,
      );
      expect(a, contains('o=x 12345 12345 IN IP4 1.1.1.1'));
      expect(b, contains('o=x 12345 12346 IN IP4 1.1.1.1'));
    });
  });
}
