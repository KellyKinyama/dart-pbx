// Integration-ish tests for the REGISTER flow exposed by RequestsHandler.

import 'package:dart_pbx/handlers/requests_handlers.dart';
import 'package:dart_pbx/proxy/digest_auth.dart';
import 'package:dart_pbx/services/services.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

String register({
  String aor = '6002',
  int expires = 3600,
  String? authorization,
}) {
  final lines = <String>[
    'REGISTER sip:proxy.example:5060;transport=UDP SIP/2.0',
    'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-r1;rport',
    'Max-Forwards: 70',
    'Contact: <sip:$aor@198.51.100.10:60901;transport=UDP>',
    'To: <sip:$aor@proxy.example:5060;transport=UDP>',
    'From: <sip:$aor@proxy.example:5060;transport=UDP>;tag=ft-1',
    'Call-ID: cid-r-1',
    'CSeq: 1 REGISTER',
    'Expires: $expires',
    if (authorization != null) 'Authorization: $authorization',
    'Content-Length: 0',
  ];
  return wire(lines);
}

void main() {
  group('REGISTER without auth', () {
    test('200 OK is sent and binding is stored', () {
      final h = RequestsHandler(
        services: ServiceRegistry(
          registrarPolicy:
              RegistrarPolicy(minExpires: 60, defaultExpires: 3600),
        ),
        qualifyInterval: const Duration(days: 1),
      );
      final t = FakeTransport();
      h.handle(register(), t);
      expect(t.sent, isNotEmpty);
      expect(t.lastSent, startsWith('SIP/2.0 200 OK'));
      expect(h.usrloc.exists('6002'), isTrue);
      expect(h.usrloc.lookup('6002')!.expiresAt, isNotNull);
    });

    test('rport gets the source port and received gets the source IP', () {
      final h = RequestsHandler(
        qualifyInterval: const Duration(days: 1),
      );
      final t = FakeTransport(localAddr: '203.0.113.55', localPort: 33333);
      h.handle(register(), t);
      expect(t.lastSent, contains('rport=33333'));
      expect(t.lastSent, contains('received=203.0.113.55'));
    });

    test('expires=0 unregisters', () {
      final h = RequestsHandler(qualifyInterval: const Duration(days: 1));
      final t = FakeTransport();
      h.handle(register(), t);
      expect(h.usrloc.exists('6002'), isTrue);
      h.handle(register(expires: 0), t);
      expect(h.usrloc.exists('6002'), isFalse);
    });

    test('expires below minimum gets 423 Interval Too Brief', () {
      final h = RequestsHandler(
        services: ServiceRegistry(
          registrarPolicy:
              RegistrarPolicy(minExpires: 90, defaultExpires: 3600),
        ),
        qualifyInterval: const Duration(days: 1),
      );
      final t = FakeTransport();
      h.handle(register(expires: 30), t);
      expect(t.lastSent, contains('SIP/2.0 423 Interval Too Brief'));
      expect(t.lastSent, contains('Min-Expires: 90'));
      expect(h.usrloc.exists('6002'), isFalse);
    });
  });

  group('REGISTER with digest auth', () {
    test('first REGISTER without Authorization gets 401 challenge', () {
      final auth = AuthService(
        digest: DigestAuth(realm: 'pbx.example', secret: 's'),
        credentials: InMemoryCredentialsStore(realm: 'pbx.example')
          ..put('6002', password: 'pw'),
      );
      final h = RequestsHandler(
        services: ServiceRegistry(auth: auth),
        qualifyInterval: const Duration(days: 1),
      );
      final t = FakeTransport();
      h.handle(register(), t);
      expect(t.lastSent, contains('SIP/2.0 401 Unauthorized'));
      expect(t.lastSent, contains('WWW-Authenticate: Digest'));
      expect(t.lastSent, contains('realm="pbx.example"'));
      expect(h.usrloc.exists('6002'), isFalse);
    });

    test('REGISTER with bogus Authorization is rejected as 401', () {
      final auth = AuthService(
        digest: DigestAuth(realm: 'pbx.example', secret: 's'),
        credentials: InMemoryCredentialsStore(realm: 'pbx.example')
          ..put('6002', password: 'pw'),
      );
      final h = RequestsHandler(
        services: ServiceRegistry(auth: auth),
        qualifyInterval: const Duration(days: 1),
      );
      final t = FakeTransport();
      h.handle(
          register(
              authorization:
                  'Digest username="6002", realm="pbx.example", nonce="garbage", '
                  'uri="sip:pbx.example", response="00000000000000000000000000000000", '
                  'qop=auth, nc=00000001, cnonce="x", algorithm=MD5'),
          t);
      expect(t.lastSent, contains('SIP/2.0 401 Unauthorized'));
      expect(h.usrloc.exists('6002'), isFalse);
    });
  });
}
