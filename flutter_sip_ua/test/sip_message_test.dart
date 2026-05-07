import 'package:flutter_sip_ua/sip/sip_message.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SipMessage parse/encode', () {
    test('parses a REGISTER request', () {
      const raw =
          'REGISTER sip:pbx.local SIP/2.0\r\n'
          'Via: SIP/2.0/WS df7jal23ls0d.invalid;branch=z9hG4bKabc\r\n'
          'From: <sip:6001@pbx.local>;tag=tag1\r\n'
          'To: <sip:6001@pbx.local>\r\n'
          'Call-ID: call-1234\r\n'
          'CSeq: 1 REGISTER\r\n'
          'Contact: <sip:6001@host;transport=ws>\r\n'
          'Max-Forwards: 70\r\n'
          'Content-Length: 0\r\n'
          '\r\n';
      final m = SipMessage.parse(raw);
      expect(m.isRequest, isTrue);
      expect(m.method, 'REGISTER');
      expect(m.requestUri, 'sip:pbx.local');
      expect(m.callId, 'call-1234');
      expect(m.fromTag, 'tag1');
      expect(m.toTag, isNull);
      expect(m.cseqNumber, 1);
      expect(m.cseqMethod, 'REGISTER');
      expect(m.body, isEmpty);
    });

    test('parses a 200 OK with SDP body', () {
      const body =
          'v=0\r\no=- 1 1 IN IP4 1.2.3.4\r\ns=-\r\nc=IN IP4 1.2.3.4\r\n'
          't=0 0\r\nm=audio 4000 RTP/AVP 0\r\n';
      final raw =
          'SIP/2.0 200 OK\r\n'
          'Via: SIP/2.0/UDP 1.2.3.4:5060;branch=z\r\n'
          'From: <sip:a@x>;tag=t1\r\n'
          'To: <sip:b@x>;tag=t2\r\n'
          'CSeq: 5 INVITE\r\n'
          'Call-ID: c1\r\n'
          'Content-Type: application/sdp\r\n'
          'Content-Length: ${body.length}\r\n'
          '\r\n'
          '$body';
      final m = SipMessage.parse(raw);
      expect(m.isResponse, isTrue);
      expect(m.statusCode, 200);
      expect(m.reasonPhrase, 'OK');
      expect(m.toTag, 't2');
      expect(m.body, body);
    });

    test('encode round-trips with auto-added Content-Length', () {
      final m = SipMessage.request('OPTIONS', 'sip:pbx.local')
        ..addHeader('Via', 'SIP/2.0/UDP h;branch=z')
        ..addHeader('From', '<sip:a@x>;tag=q')
        ..addHeader('To', '<sip:b@x>')
        ..addHeader('Call-ID', 'cid')
        ..addHeader('CSeq', '1 OPTIONS');
      final wire = m.encode();
      expect(wire, contains('OPTIONS sip:pbx.local SIP/2.0\r\n'));
      expect(wire, contains('Content-Length: 0\r\n'));
      // Re-parse to confirm the body separator is correct.
      final round = SipMessage.parse(wire);
      expect(round.method, 'OPTIONS');
      expect(round.callId, 'cid');
    });

    test('setHeader replaces an existing header case-insensitively', () {
      final m = SipMessage.request('REGISTER', 'sip:x')
        ..addHeader('Call-ID', 'old');
      m.setHeader('call-id', 'new');
      expect(
        m.headers.where((h) => h.key.toLowerCase() == 'call-id'),
        hasLength(1),
      );
      expect(m.callId, 'new');
    });

    test('headersAll returns all duplicates (Via)', () {
      final m = SipMessage.request('INVITE', 'sip:x')
        ..addHeader('Via', 'SIP/2.0/UDP a;branch=z1')
        ..addHeader('Via', 'SIP/2.0/UDP b;branch=z2');
      expect(m.headersAll('Via'), hasLength(2));
    });

    test('removeHeader strips all matches', () {
      final m = SipMessage.request('INVITE', 'sip:x')
        ..addHeader('Route', '<sip:p1>')
        ..addHeader('route', '<sip:p2>');
      m.removeHeader('Route');
      expect(m.headersAll('Route'), isEmpty);
    });

    test('handles compact From/Call-ID forms (f, i)', () {
      const raw =
          'INVITE sip:x SIP/2.0\r\n'
          'f: <sip:a@x>;tag=qq\r\n'
          't: <sip:b@x>\r\n'
          'i: short-id\r\n'
          'CSeq: 1 INVITE\r\n'
          '\r\n';
      final m = SipMessage.parse(raw);
      expect(m.callId, 'short-id');
      expect(m.fromTag, 'qq');
    });
  });

  group('parseAuthHeader', () {
    test('parses a typical 401 challenge', () {
      const v =
          'Digest realm="pbx.local", nonce="abc123", '
          'qop="auth", algorithm=MD5, opaque="op1"';
      final p = parseAuthHeader(v);
      expect(p['realm'], 'pbx.local');
      expect(p['nonce'], 'abc123');
      expect(p['qop'], 'auth');
      expect(p['algorithm'], 'MD5');
      expect(p['opaque'], 'op1');
    });

    test('survives unquoted values and missing scheme prefix', () {
      const v = 'realm=local, nonce=n1, algorithm=MD5';
      final p = parseAuthHeader(v);
      expect(p['realm'], 'local');
      expect(p['nonce'], 'n1');
    });

    test('handles multiple qop options', () {
      const v = 'Digest realm="r", nonce="n", qop="auth,auth-int"';
      final p = parseAuthHeader(v);
      expect(p['qop'], 'auth,auth-int');
    });
  });

  group('extractUri', () {
    test('strips display name and angle brackets', () {
      expect(extractUri('"Alice" <sip:alice@x>;tag=q'), 'sip:alice@x');
    });

    test('handles addr-spec without brackets', () {
      expect(extractUri('sip:bob@example.com;tag=q'), 'sip:bob@example.com');
    });

    test('returns the raw value when no markers present', () {
      expect(extractUri('sip:x@y'), 'sip:x@y');
    });
  });
}
