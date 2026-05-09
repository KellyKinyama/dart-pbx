// Third-party REGISTER (TS 24.229 §5.4.1.7).
//
// When a UE successfully registers, the S-CSCF must generate one
// REGISTER per matching iFC and send it to the corresponding AS so the
// AS learns the user's registration state.

import 'package:dart_pbx/ims/hss.dart';
import 'package:dart_pbx/ims/ims_core.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:test/test.dart';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'support/fakes.dart';

void main() {
  test(
      'S-CSCF fires one third-party REGISTER per matching iFC after a '
      'successful UE REGISTER', () {
    final core = ImsCore(
      host: '203.0.113.10',
      port: 5060,
      transport: 'UDP',
      realm: 'ims.local',
      visitedNetworkId: 'ims.local',
      scscfName: 'scscf.ims.local',
    );
    // Two ASes both interested in REGISTER + one AS only interested in
    // INVITE — so the count must be exactly 2.
    final ifcs = <InitialFilterCriteria>[
      InitialFilterCriteria(
        priority: 1,
        applicationServer: 'sip:presence@as.example.com',
        method: 'REGISTER',
      ),
      InitialFilterCriteria(
        priority: 2,
        applicationServer: 'sip:mmtel@as.example.com',
        method: 'REGISTER',
      ),
      InitialFilterCriteria(
        priority: 3,
        applicationServer: 'sip:routing@as.example.com',
        method: 'INVITE',
      ),
    ];
    core.hss.provision(
      impi: 'alice@ims.local',
      impus: ['sip:alice@ims.local'],
      password: 'pw-alice',
      profiles: {
        'sip:alice@ims.local': ServiceProfile(ifcs: ifcs),
      },
    );

    final tpr = <SipMsg>[];
    core.scscf.thirdPartyRegister = tpr.add;

    final t = FakeTransport(
        localAddr: '198.51.100.10',
        localPort: 60901,
        serverAddr: '203.0.113.10',
        serverPort: 5060);

    String register({String? auth, int cseq = 1}) => wire([
          'REGISTER sip:alice@ims.local SIP/2.0',
          'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-r$cseq;rport',
          'Max-Forwards: 70',
          'From: <sip:alice@ims.local>;tag=ft',
          'To: <sip:alice@ims.local>',
          'Call-ID: tpr-c1',
          'CSeq: $cseq REGISTER',
          'Contact: <sip:alice@198.51.100.10:60901;transport=UDP>',
          'Expires: 3600',
          if (auth != null) 'Authorization: $auth',
          'Content-Length: 0',
        ]);

    // Round 1: 401 challenge — no third-party REGISTER yet.
    core.handle(register(), t);
    expect(tpr, isEmpty,
        reason: 'no 3rd-party REGISTER should fire before the UE auths');

    // Use the digest helper from the existing IMS test would create a
    // cross-file dep; reproduce a minimal valid digest here. Easier: just
    // grab nonce and compute MD5 inline.
    final challenge = t.sent.single.raw;
    final nonce = RegExp('nonce="([^"]+)"').firstMatch(challenge)!.group(1)!;
    const realm = 'ims.local';
    const impi = 'alice@ims.local';
    const uri = 'sip:alice@ims.local';
    const nc = '00000001';
    const cnonce = '0a4f113b';
    final ha1 = _md5('$impi:$realm:pw-alice');
    final ha2 = _md5('REGISTER:$uri');
    final response = _md5('$ha1:$nonce:$nc:$cnonce:auth:$ha2');
    final authHeader =
        'Digest username="$impi", realm="$realm", nonce="$nonce", '
        'uri="$uri", response="$response", qop=auth, nc=$nc, '
        'cnonce="$cnonce", algorithm=MD5';

    core.handle(register(auth: authHeader, cseq: 2), t);

    // Two iFCs match REGISTER → exactly two third-party REGISTERs.
    expect(tpr, hasLength(2),
        reason: 'one 3rd-party REGISTER per matching iFC');
    final targets = tpr.map((m) => m.Req.Src).toList();
    expect(targets, contains(contains('presence@as.example.com')));
    expect(targets, contains(contains('mmtel@as.example.com')));
    expect(targets.where((s) => s?.contains('routing@as.example.com') ?? false),
        isEmpty,
        reason: 'AS only interested in INVITE must not be notified');

    // The To header must carry the IMPU (the user being registered).
    for (final m in tpr) {
      expect(m.To.User, equals('alice'));
      expect(m.To.Host, equals('ims.local'));
    }
  });
}

String _md5(String s) => md5.convert(utf8.encode(s)).toString();
