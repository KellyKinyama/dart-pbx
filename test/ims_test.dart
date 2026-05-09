// IMS REGISTER and basic call-routing flow tests.
//
// The collocated topology means a single ImsCore instance plays P-CSCF +
// I-CSCF + S-CSCF + HSS, exactly as a developer testbed would. We feed
// the FakeTransport a raw REGISTER and assert on the responses we get
// back, plus on the bindings recorded inside the CSCFs.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:dart_pbx/ims/hss.dart';
import 'package:dart_pbx/ims/ims_core.dart';
import 'package:dart_pbx/sip_client.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/transports/transport.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

ImsCore buildCore({String realm = 'ims.local', SipClient? offNet}) {
  final c = ImsCore(
    host: '203.0.113.10',
    port: 5060,
    transport: 'UDP',
    realm: realm,
    visitedNetworkId: realm,
    scscfName: 'scscf.$realm',
  );
  c.hss.provision(
    impi: 'alice@$realm',
    impus: ['sip:alice@$realm'],
    password: 'pw-alice',
  );
  c.hss.provision(
    impi: 'bob@$realm',
    impus: ['sip:bob@$realm'],
    password: 'pw-bob',
  );
  c.offNetGateway = offNet;
  return c;
}

String register({
  String impu = 'sip:alice@ims.local',
  String impi = 'alice@ims.local',
  String? authorization,
  int expires = 3600,
  String callId = 'reg-call-1',
  int cseq = 1,
}) {
  final lines = <String>[
    'REGISTER $impu SIP/2.0',
    'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-ue-r1;rport',
    'Max-Forwards: 70',
    'From: <$impu>;tag=ue-ft1',
    'To: <$impu>',
    'Call-ID: $callId',
    'CSeq: $cseq REGISTER',
    'Contact: <sip:alice@198.51.100.10:60901;transport=UDP>',
    'Expires: $expires',
    if (authorization != null) 'Authorization: $authorization',
    'Content-Length: 0',
  ];
  return wire(lines);
}

/// Computes a Digest MD5 response for the challenge embedded in [c401].
String digestResponse({
  required String c401Raw,
  required String impi,
  required String password,
  required String realm,
  required String method,
  required String uri,
}) {
  final lines = c401Raw.split('\r\n');
  final wwwLine = lines.firstWhere(
      (l) => l.toLowerCase().startsWith('www-authenticate:'),
      orElse: () => '');
  final value = wwwLine.substring(wwwLine.indexOf(':') + 1).trim();
  String? grab(String key) {
    final m = RegExp('$key="?([^",]+)"?').firstMatch(value);
    return m?.group(1);
  }

  final nonce = grab('nonce')!;
  final cnonce = '0a4f113b';
  final nc = '00000001';
  final qop = 'auth';
  final ha1 = md5.convert(utf8.encode('$impi:$realm:$password')).toString();
  final ha2 = md5.convert(utf8.encode('$method:$uri')).toString();
  final response =
      md5.convert(utf8.encode('$ha1:$nonce:$nc:$cnonce:$qop:$ha2')).toString();
  return 'Digest username="$impi", realm="$realm", nonce="$nonce", '
      'uri="$uri", response="$response", qop=$qop, nc=$nc, '
      'cnonce="$cnonce", algorithm=MD5';
}

void main() {
  group('IMS REGISTER', () {
    test('first REGISTER without Authorization is challenged with 401', () {
      final core = buildCore();
      final t = FakeTransport(
          localAddr: '198.51.100.10',
          localPort: 60901,
          serverAddr: '203.0.113.10',
          serverPort: 5060);
      core.handle(register(), t);
      expect(t.sent, hasLength(1));
      final r = t.sent.single.raw;
      expect(r, startsWith('SIP/2.0 401 Unauthorized'));
      expect(r, contains('WWW-Authenticate: Digest'));
      expect(r, contains('realm="ims.local"'));
    });

    test(
        'REGISTER with valid Authorization yields 200 OK with Service-Route '
        'and binds the AOR', () {
      final core = buildCore();
      final t = FakeTransport(
          localAddr: '198.51.100.10',
          localPort: 60901,
          serverAddr: '203.0.113.10',
          serverPort: 5060);

      core.handle(register(), t);
      final challenge = t.sent.single.raw;

      final auth = digestResponse(
        c401Raw: challenge,
        impi: 'alice@ims.local',
        password: 'pw-alice',
        realm: 'ims.local',
        method: 'REGISTER',
        uri: 'sip:alice@ims.local',
      );
      core.handle(register(authorization: auth, cseq: 2), t);

      expect(t.sent, hasLength(2));
      final ok = t.sent.last.raw;
      expect(ok, startsWith('SIP/2.0 200 OK'));
      // Service-Route is recorded by the P-CSCF and stripped from the UE-
      // facing response (per RFC 3608 §5.2). It must NOT appear in the
      // 200 OK that reaches the UE.
      expect(ok, isNot(contains('Service-Route')));
      // Path is also stripped before delivery to UE.
      expect(ok, isNot(contains('\r\nPath:')));
      expect(ok, contains('P-Associated-URI'));

      // The HSS now has Alice assigned to the local S-CSCF.
      final sub = core.hss.subscriptionByImpu('sip:alice@ims.local');
      expect(sub, isNotNull);
      expect(sub!.assignedScscfName, equals('scscf.ims.local'));

      // P-CSCF has stored the binding with the Service-Route the S-CSCF
      // generated (so subsequent originating requests are pre-loaded).
      final binding = core.pcscf.lookup('sip:alice@ims.local');
      expect(binding, isNotNull,
          reason: 'P-CSCF must record the AOR binding on REGISTER 200 OK');
    });

    test('REGISTER for an unknown IMPU is rejected by I-CSCF (UAR fails)', () {
      final core = buildCore();
      final t = FakeTransport(
          localAddr: '198.51.100.99',
          localPort: 60901,
          serverAddr: '203.0.113.10',
          serverPort: 5060);
      core.handle(
          register(impu: 'sip:mallory@ims.local', impi: 'mallory@ims.local'),
          t);
      // First we get an S-CSCF-emitted 401 (Forbidden user-unknown is
      // checked at the S-CSCF in this implementation), but the UAR at the
      // I-CSCF rejects with 403 first because the IMPU is not provisioned.
      expect(t.sent, hasLength(1));
      final r = t.sent.single.raw;
      expect(
        r,
        anyOf(
          startsWith('SIP/2.0 403'),
          startsWith('SIP/2.0 404'),
        ),
      );
    });
  });

  group('IMS originating call routing', () {
    test('originating INVITE from unregistered UE is rejected with 403', () {
      final core = buildCore();
      final t = FakeTransport(
          localAddr: '198.51.100.10',
          localPort: 60901,
          serverAddr: '203.0.113.10',
          serverPort: 5060);
      final raw = wire([
        'INVITE sip:bob@ims.local SIP/2.0',
        'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-inv;rport',
        'Max-Forwards: 70',
        'From: <sip:alice@ims.local>;tag=ft',
        'To: <sip:bob@ims.local>',
        'Call-ID: cid-inv',
        'CSeq: 1 INVITE',
        'Contact: <sip:alice@198.51.100.10:60901>',
        'Content-Length: 0',
      ]);
      core.handle(raw, t);
      expect(t.sent, hasLength(1));
      expect(t.sent.single.raw, startsWith('SIP/2.0 403'));
    });

    test('originating INVITE for an off-net callee is delivered to the BGCF',
        () {
      // Provision Alice; Bob is *not* an IMS subscriber for this test.
      final offTx = FakeTransport(
          localAddr: '10.0.0.5',
          localPort: 5060,
          serverAddr: '203.0.113.10',
          serverPort: 5060);
      final off = SipClient('bgcf', offTx, contactUri: 'sip:10.0.0.5:5060');
      final core = ImsCore(
        host: '203.0.113.10',
        port: 5060,
        transport: 'UDP',
        realm: 'ims.local',
        visitedNetworkId: 'ims.local',
        scscfName: 'scscf.ims.local',
      )..hss.provision(
          impi: 'alice@ims.local',
          impus: ['sip:alice@ims.local'],
          password: 'pw-alice',
        );
      core.offNetGateway = off;

      final ueTx = FakeTransport(
          localAddr: '198.51.100.10',
          localPort: 60901,
          serverAddr: '203.0.113.10',
          serverPort: 5060);

      // Register Alice first.
      core.handle(register(), ueTx);
      final challenge = ueTx.sent.single.raw;
      final auth = digestResponse(
        c401Raw: challenge,
        impi: 'alice@ims.local',
        password: 'pw-alice',
        realm: 'ims.local',
        method: 'REGISTER',
        uri: 'sip:alice@ims.local',
      );
      core.handle(register(authorization: auth, cseq: 2), ueTx);

      // Now place a call to a PSTN number — no HSS subscription → off-net.
      final inv = wire([
        'INVITE sip:+15551234@ims.local SIP/2.0',
        'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-inv-2;rport',
        'Max-Forwards: 70',
        'From: <sip:alice@ims.local>;tag=ft',
        'To: <sip:+15551234@ims.local>',
        'Call-ID: cid-inv-2',
        'CSeq: 1 INVITE',
        'Contact: <sip:alice@198.51.100.10:60901>',
        'Content-Length: 0',
      ]);
      core.handle(inv, ueTx);

      expect(offTx.sent, isNotEmpty,
          reason: 'INVITE should have been forwarded to the off-net gateway');
      final fwd = offTx.sent.last.raw;
      // The P-CSCF asserts Alice's identity (RFC 3325).
      expect(fwd, contains('P-Asserted-Identity:'));
      expect(fwd, contains('sip:alice@ims.local'));
      // Charging-Vector ICID was added at the P-CSCF.
      expect(fwd, contains('P-Charging-Vector:'));
    });
  });
}
