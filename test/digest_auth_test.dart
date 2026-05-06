import 'package:dart_pbx/proxy/auth_store.dart';
import 'package:dart_pbx/proxy/digest_auth.dart';
import 'package:test/test.dart';
import 'package:crypto/crypto.dart';
import 'dart:convert';

String md5Hex(String s) => md5.convert(utf8.encode(s)).toString();

/// Builds an Authorization header value for the given parameters using
/// qop=auth (RFC 2617).
String makeAuthHeader({
  required String username,
  required String realm,
  required String nonce,
  required String uri,
  required String method,
  required String password,
  String cnonce = 'cn-1',
  String nc = '00000001',
}) {
  final ha1 = md5Hex('$username:$realm:$password');
  final ha2 = md5Hex('$method:$uri');
  final response = md5Hex('$ha1:$nonce:$nc:$cnonce:auth:$ha2');
  return 'Digest username="$username", realm="$realm", nonce="$nonce", '
      'uri="$uri", response="$response", qop=auth, nc=$nc, cnonce="$cnonce", '
      'algorithm=MD5';
}

String extractNonce(String challenge) {
  final params = DigestAuth.parseAuthParams(challenge)!;
  return params['nonce']!.replaceAll('"', '');
}

void main() {
  group('challenge', () {
    final auth = DigestAuth(realm: 'pbx.example', secret: 'unit-test-secret');

    test('contains realm, qop, nonce and algorithm', () {
      final c = auth.challengeHeaderValue();
      expect(c, startsWith('Digest '));
      expect(c, contains('realm="pbx.example"'));
      expect(c, contains('qop="auth"'));
      expect(c, contains('algorithm=MD5'));
      expect(c, contains('nonce='));
      expect(c, isNot(contains('stale=true')));
    });

    test('marks stale when requested', () {
      final c = auth.challengeHeaderValue(stale: true);
      expect(c, contains('stale=true'));
    });

    test('proxyChallengeHeaderValue uses the same body as challengeHeaderValue',
        () {
      // Different nonces but same parameter set — sanity check both work.
      final ww = auth.challengeHeaderValue();
      final pp = auth.proxyChallengeHeaderValue();
      expect(ww, contains('algorithm=MD5'));
      expect(pp, contains('algorithm=MD5'));
    });
  });

  group('verify', () {
    final realm = 'pbx.example';
    final auth = DigestAuth(realm: realm, secret: 'unit-test-secret');
    final store = InMemoryCredentialsStore(realm: realm)
      ..put('alice', password: 'wonderland');

    test('returns missing when header is null or empty', () {
      expect(
          auth.verify(
              headerValue: null, method: 'REGISTER', credentials: store),
          AuthResult.missing);
      expect(
          auth.verify(
              headerValue: '   ', method: 'REGISTER', credentials: store),
          AuthResult.missing);
    });

    test('accepts a valid response', () {
      final nonce = extractNonce(auth.challengeHeaderValue());
      final hdr = makeAuthHeader(
        username: 'alice',
        realm: realm,
        nonce: nonce,
        uri: 'sip:pbx.example',
        method: 'REGISTER',
        password: 'wonderland',
      );
      expect(
          auth.verify(headerValue: hdr, method: 'REGISTER', credentials: store),
          AuthResult.ok);
    });

    test('rejects wrong password as failed', () {
      final nonce = extractNonce(auth.challengeHeaderValue());
      final hdr = makeAuthHeader(
        username: 'alice',
        realm: realm,
        nonce: nonce,
        uri: 'sip:pbx.example',
        method: 'REGISTER',
        password: 'WRONG',
      );
      expect(
          auth.verify(headerValue: hdr, method: 'REGISTER', credentials: store),
          AuthResult.failed);
    });

    test('rejects unknown user as failed', () {
      final nonce = extractNonce(auth.challengeHeaderValue());
      final hdr = makeAuthHeader(
        username: 'mallory',
        realm: realm,
        nonce: nonce,
        uri: 'sip:pbx.example',
        method: 'REGISTER',
        password: 'whatever',
      );
      expect(
          auth.verify(headerValue: hdr, method: 'REGISTER', credentials: store),
          AuthResult.failed);
    });

    test('returns stale for an expired but well-formed nonce', () {
      final shortLived = DigestAuth(
          realm: realm,
          secret: 'unit-test-secret',
          nonceLifetime: const Duration(milliseconds: 1));
      final nonce = extractNonce(shortLived.challengeHeaderValue());
      // Wait past the lifetime.
      return Future.delayed(const Duration(milliseconds: 20), () {
        final hdr = makeAuthHeader(
          username: 'alice',
          realm: realm,
          nonce: nonce,
          uri: 'sip:pbx.example',
          method: 'REGISTER',
          password: 'wonderland',
        );
        expect(
            shortLived.verify(
                headerValue: hdr, method: 'REGISTER', credentials: store),
            AuthResult.stale);
      });
    });

    test('different secret rejects nonce as failed (forged)', () {
      final attacker = DigestAuth(realm: realm, secret: 'attacker-secret');
      final forgedNonce = extractNonce(attacker.challengeHeaderValue());
      final hdr = makeAuthHeader(
        username: 'alice',
        realm: realm,
        nonce: forgedNonce,
        uri: 'sip:pbx.example',
        method: 'REGISTER',
        password: 'wonderland',
      );
      expect(
          auth.verify(headerValue: hdr, method: 'REGISTER', credentials: store),
          AuthResult.failed);
    });

    test('storing HA1 directly works the same as plaintext password', () {
      final s = InMemoryCredentialsStore(realm: realm)
        ..put('bob', ha1: computeHa1('bob', realm, 'builder'));
      final nonce = extractNonce(auth.challengeHeaderValue());
      final hdr = makeAuthHeader(
        username: 'bob',
        realm: realm,
        nonce: nonce,
        uri: 'sip:pbx.example',
        method: 'REGISTER',
        password: 'builder',
      );
      expect(auth.verify(headerValue: hdr, method: 'REGISTER', credentials: s),
          AuthResult.ok);
    });
  });

  group('parseAuthParams', () {
    test('parses quoted and token values, ignores commas inside quotes', () {
      final out = DigestAuth.parseAuthParams(
          'Digest username="al, ice", nonce="abc==", qop=auth, nc=00000002');
      expect(out, isNotNull);
      expect(out!['username'], '"al, ice"');
      expect(out['nonce'], '"abc=="');
      expect(out['qop'], 'auth');
      expect(out['nc'], '00000002');
    });

    test('returns null when scheme is not Digest', () {
      expect(DigestAuth.parseAuthParams('Basic dXNlcjpwYXNz'), isNull);
    });
  });
}
