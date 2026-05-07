import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_sip_ua/sip/digest.dart';
import 'package:flutter_sip_ua/sip/sip_message.dart';
import 'package:flutter_test/flutter_test.dart';

String _md5(String s) => md5.convert(utf8.encode(s)).toString();

void main() {
  group('DigestClient', () {
    test('qop=auth response matches the RFC 2617 formula', () {
      final client = DigestClient(rng: Random(0));
      final challenge = DigestChallenge(
        realm: 'pbx.local',
        nonce: 'abc123',
        qop: 'auth',
        algorithm: 'MD5',
      );
      final auth = client.authorize(
        challenge: challenge,
        username: '6001',
        password: '6001',
        method: 'REGISTER',
        uri: 'sip:pbx.local',
      );

      // Pull params back out of the produced header value.
      final p = parseAuthHeader('Digest $auth');
      expect(p['username'], '6001');
      expect(p['realm'], 'pbx.local');
      expect(p['nonce'], 'abc123');
      expect(p['uri'], 'sip:pbx.local');
      expect(p['qop'], 'auth');
      expect(p['nc'], '00000001');
      expect(p['cnonce'], isNotEmpty);

      final ha1 = _md5('6001:pbx.local:6001');
      final ha2 = _md5('REGISTER:sip:pbx.local');
      final expected = _md5('$ha1:abc123:${p['nc']}:${p['cnonce']}:auth:$ha2');
      expect(p['response'], expected);
    });

    test('legacy RFC 2069 (no qop) response matches', () {
      final client = DigestClient(rng: Random(0));
      final challenge = DigestChallenge(realm: 'r', nonce: 'n');
      final auth = client.authorize(
        challenge: challenge,
        username: 'u',
        password: 'p',
        method: 'INVITE',
        uri: 'sip:x',
      );
      final p = parseAuthHeader('Digest $auth');
      expect(p['qop'], isNull);
      expect(p['nc'], isNull);
      expect(p['cnonce'], isNull);
      final ha1 = _md5('u:r:p');
      final ha2 = _md5('INVITE:sip:x');
      expect(p['response'], _md5('$ha1:n:$ha2'));
    });

    test('nc increments across consecutive auth() calls', () {
      final client = DigestClient(rng: Random(0));
      final challenge = DigestChallenge(realm: 'r', nonce: 'n', qop: 'auth');
      final a1 = parseAuthHeader(
        'Digest ${client.authorize(challenge: challenge, username: 'u', password: 'p', method: 'REGISTER', uri: 'sip:r')}',
      );
      final a2 = parseAuthHeader(
        'Digest ${client.authorize(challenge: challenge, username: 'u', password: 'p', method: 'REGISTER', uri: 'sip:r')}',
      );
      expect(a1['nc'], '00000001');
      expect(a2['nc'], '00000002');
    });

    test('echoes opaque when the server sent one', () {
      final client = DigestClient(rng: Random(0));
      final challenge = DigestChallenge(
        realm: 'r',
        nonce: 'n',
        qop: 'auth',
        opaque: 'OP',
      );
      final p = parseAuthHeader(
        'Digest ${client.authorize(challenge: challenge, username: 'u', password: 'p', method: 'INVITE', uri: 'sip:r')}',
      );
      expect(p['opaque'], 'OP');
    });

    test('falls back to RFC 2069 when qop offers only auth-int', () {
      final client = DigestClient(rng: Random(0));
      final challenge = DigestChallenge(
        realm: 'r',
        nonce: 'n',
        qop: 'auth-int',
      );
      final p = parseAuthHeader(
        'Digest ${client.authorize(challenge: challenge, username: 'u', password: 'p', method: 'INVITE', uri: 'sip:r')}',
      );
      expect(p['qop'], isNull);
      expect(p['nc'], isNull);
    });

    test('DigestChallenge.fromParams reads stale flag', () {
      final c = DigestChallenge.fromParams({
        'realm': 'r',
        'nonce': 'n',
        'stale': 'TRUE',
      });
      expect(c.stale, isTrue);
    });
  });
}
