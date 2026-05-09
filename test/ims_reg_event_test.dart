// RFC 3680 reg-event package — SUBSCRIBE/NOTIFY for registration state.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dart_pbx/ims/ims_core.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/transports/transport.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

ImsCore buildCore() {
  final c = ImsCore(
    host: '203.0.113.10',
    port: 5060,
    transport: 'UDP',
    realm: 'ims.local',
    visitedNetworkId: 'ims.local',
    scscfName: 'scscf.ims.local',
  );
  c.hss.provision(
    impi: 'alice@ims.local',
    impus: ['sip:alice@ims.local'],
    password: 'pw-alice',
  );
  return c;
}

String _md5(String s) => md5.convert(utf8.encode(s)).toString();

String digestResponseFor({
  required String challenge,
  String impi = 'alice@ims.local',
  String password = 'pw-alice',
  String realm = 'ims.local',
  String method = 'REGISTER',
  String uri = 'sip:alice@ims.local',
}) {
  final nonce = RegExp('nonce="([^"]+)"').firstMatch(challenge)!.group(1)!;
  const nc = '00000001';
  const cnonce = '0a4f113b';
  final ha1 = _md5('$impi:$realm:$password');
  final ha2 = _md5('$method:$uri');
  final response = _md5('$ha1:$nonce:$nc:$cnonce:auth:$ha2');
  return 'Digest username="$impi", realm="$realm", nonce="$nonce", '
      'uri="$uri", response="$response", qop=auth, nc=$nc, '
      'cnonce="$cnonce", algorithm=MD5';
}

void registerAlice(ImsCore core, FakeTransport t) {
  String reg({String? auth, int cseq = 1}) => wire([
        'REGISTER sip:alice@ims.local SIP/2.0',
        'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-r$cseq;rport',
        'Max-Forwards: 70',
        'From: <sip:alice@ims.local>;tag=ft',
        'To: <sip:alice@ims.local>',
        'Call-ID: reg-c1',
        'CSeq: $cseq REGISTER',
        'Contact: <sip:alice@198.51.100.10:60901;transport=UDP>',
        'Expires: 3600',
        if (auth != null) 'Authorization: $auth',
        'Content-Length: 0',
      ]);
  core.handle(reg(), t);
  final challenge = t.sent.last.raw;
  final auth = digestResponseFor(challenge: challenge);
  core.handle(reg(auth: auth, cseq: 2), t);
}

void main() {
  test(
      'UE SUBSCRIBE for reg event gets 200 OK and an immediate '
      'reginfo+xml NOTIFY', () {
    final core = buildCore();
    final t = FakeTransport(
        localAddr: '198.51.100.10',
        localPort: 60901,
        serverAddr: '203.0.113.10',
        serverPort: 5060);
    registerAlice(core, t);
    expect(t.sent.last.raw, startsWith('SIP/2.0 200 OK'));
    t.sent.clear();

    // SUBSCRIBE for own AOR — must traverse the preloaded Service-Route
    // (`;orig`) so S-CSCF processes it as originating-side.
    final sub = wire([
      'SUBSCRIBE sip:alice@ims.local SIP/2.0',
      'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-sub1;rport',
      'Max-Forwards: 70',
      'Route: <sip:scscf.ims.local@203.0.113.10:5060;transport=UDP;lr;orig>',
      'From: <sip:alice@ims.local>;tag=sub-ft',
      'To: <sip:alice@ims.local>',
      'Call-ID: sub-c1',
      'CSeq: 1 SUBSCRIBE',
      'Contact: <sip:alice@198.51.100.10:60901;transport=UDP>',
      'Event: reg',
      'Expires: 600',
      'Accept: application/reginfo+xml',
      'Content-Length: 0',
    ]);
    core.handle(sub, t);

    // Expect at least: 200 OK to SUBSCRIBE + a NOTIFY back to the UE.
    final responses = t.sent.map((s) => s.raw).toList();
    final ok = responses.firstWhere(
        (r) =>
            r.startsWith('SIP/2.0 200 OK') && r.contains('CSeq: 1 SUBSCRIBE'),
        orElse: () => '');
    expect(ok, isNotEmpty,
        reason: '200 OK to SUBSCRIBE missing; sent=$responses');

    final notify =
        responses.firstWhere((r) => r.startsWith('NOTIFY '), orElse: () => '');
    expect(notify, isNotEmpty, reason: 'NOTIFY missing; sent=$responses');
    expect(notify, contains('Event: reg'));
    expect(notify, contains('Subscription-State: active'));
    expect(notify, contains('Content-Type: application/reginfo+xml'));
    expect(notify, contains('<reginfo'));
    expect(notify, contains('aor="sip:alice@ims.local"'));
    expect(notify, contains('state="active"'));
  });

  test('subsequent REGISTER triggers a fresh NOTIFY with version+1', () {
    final core = buildCore();
    final t = FakeTransport(
        localAddr: '198.51.100.10',
        localPort: 60901,
        serverAddr: '203.0.113.10',
        serverPort: 5060);
    registerAlice(core, t);
    t.sent.clear();

    final sub = wire([
      'SUBSCRIBE sip:alice@ims.local SIP/2.0',
      'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-sub2;rport',
      'Max-Forwards: 70',
      'Route: <sip:scscf.ims.local@203.0.113.10:5060;transport=UDP;lr;orig>',
      'From: <sip:alice@ims.local>;tag=sub-ft2',
      'To: <sip:alice@ims.local>',
      'Call-ID: sub-c2',
      'CSeq: 1 SUBSCRIBE',
      'Contact: <sip:alice@198.51.100.10:60901;transport=UDP>',
      'Event: reg',
      'Expires: 600',
      'Content-Length: 0',
    ]);
    core.handle(sub, t);
    final initialNotify = t.sent
        .map((s) => s.raw)
        .firstWhere((r) => r.startsWith('NOTIFY '), orElse: () => '');
    expect(initialNotify, contains('version="1"'));
    t.sent.clear();

    // Re-REGISTER → state-change → fan-out NOTIFY with version=2.
    String reg(int cseq, [String? auth]) => wire([
          'REGISTER sip:alice@ims.local SIP/2.0',
          'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-rr$cseq;rport',
          'Max-Forwards: 70',
          'From: <sip:alice@ims.local>;tag=ft',
          'To: <sip:alice@ims.local>',
          'Call-ID: re-reg-c1',
          'CSeq: $cseq REGISTER',
          'Contact: <sip:alice@198.51.100.10:60901;transport=UDP>',
          'Expires: 3600',
          if (auth != null) 'Authorization: $auth',
          'Content-Length: 0',
        ]);
    core.handle(reg(1), t);
    final challenge = t.sent.last.raw;
    final auth = digestResponseFor(challenge: challenge);
    core.handle(reg(2, auth), t);

    final notifies =
        t.sent.map((s) => s.raw).where((r) => r.startsWith('NOTIFY ')).toList();
    expect(notifies, isNotEmpty,
        reason: 'a NOTIFY must fan out on re-REGISTER');
    expect(notifies.last, contains('version="2"'));
  });
}
