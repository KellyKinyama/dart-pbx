import 'package:flutter_sip_ua/sip/audio/media_session.dart';
import 'package:flutter_sip_ua/sip/sdp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SDP video', () {
    test('buildAvOffer emits both m=audio and m=video sections', () {
      final body = buildAvOffer(
        username: '6001',
        localHost: '10.0.0.5',
        audioPort: 40000,
        videoPort: 41000,
        audioRtcpPort: 40001,
        videoRtcpPort: 41001,
      );
      expect(body, contains('m=audio 40000 RTP/AVP 0 8 101'));
      expect(body, contains('m=video 41000 RTP/AVP 96'));
      expect(body, contains('a=rtpmap:96 VP8/90000'));
      expect(body, contains('a=rtcp:40001'));
      expect(body, contains('a=rtcp:41001'));
    });

    test('buildAvOffer omits m=video when videoPort is null', () {
      final body = buildAvOffer(
        username: 'x',
        localHost: '0.0.0.0',
        audioPort: 4000,
      );
      expect(body, isNot(contains('m=video')));
    });

    test('parseSdp returns both audio and video', () {
      const sdp = '''v=0\r
o=- 1 1 IN IP4 1.2.3.4\r
s=-\r
c=IN IP4 1.2.3.4\r
t=0 0\r
m=audio 30000 RTP/AVP 0 8\r
a=rtpmap:0 PCMU/8000\r
a=rtpmap:8 PCMA/8000\r
a=sendrecv\r
m=video 30100 RTP/AVP 96\r
a=rtpmap:96 VP8/90000\r
a=rtcp:30101\r
a=sendrecv\r
''';
      final offer = parseSdp(sdp);
      expect(offer.audio, isNotNull);
      expect(offer.audio!.codec, G711Variant.pcmu);
      expect(offer.video, isNotNull);
      expect(offer.video!.host, '1.2.3.4');
      expect(offer.video!.port, 30100);
      expect(offer.video!.payloadType, 96);
      expect(offer.video!.codec, SdpVideoCodec.vp8);
      expect(offer.video!.rtcpPort, 30101);
      expect(offer.video!.effectiveRtcpPort, 30101);
    });

    test('parseSdp handles audio-only bodies', () {
      const sdp = '''v=0
o=- 1 1 IN IP4 1.1.1.1
c=IN IP4 1.1.1.1
t=0 0
m=audio 5000 RTP/AVP 0
a=rtpmap:0 PCMU/8000
''';
      final offer = parseSdp(sdp);
      expect(offer.audio, isNotNull);
      expect(offer.video, isNull);
    });

    test('video falls back to port+1 for RTCP when a=rtcp absent', () {
      const sdp = '''v=0
o=- 1 1 IN IP4 1.1.1.1
c=IN IP4 1.1.1.1
t=0 0
m=audio 5000 RTP/AVP 0
m=video 6000 RTP/AVP 96
a=rtpmap:96 VP8/90000
''';
      final v = parseSdp(sdp).video!;
      expect(v.rtcpPort, isNull);
      expect(v.effectiveRtcpPort, 6001);
    });
  });
}
