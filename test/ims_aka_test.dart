// End-to-end IMS REGISTER with IMS-AKA (AKAv1-MD5 / RFC 3310).
//
// Provisions Alice via [HomeSubscriberServer.provisionAka] using the
// 3GPP TS 35.207 Test Set 1 K/OPc, then drives a full register flow
// against the collocated ImsCore: first REGISTER → 401 with AKA
// challenge, parse RAND/AUTN out of the nonce, run our own Milenage to
// get RES, build Authorization, second REGISTER → 200 OK.

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dart_pbx/ims/ims_core.dart';
import 'package:dart_pbx/ims/milenage.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

ImsCore buildAkaCore() {
  final core = ImsCore(
    host: '203.0.113.10',
    port: 5060,
    transport: 'UDP',
    realm: 'ims.local',
    visitedNetworkId: 'ims.local',
    scscfName: 'scscf.ims.local',
  );
  // TS 35.207 Test Set 1 — gives a deterministic K + OPc pair.
  final k = hexToBytes('465b5ce8b199b49faa5f0a2ee238a6bc');
  final opc = hexToBytes('cd63cb71954a9f4e48a5994e37a02baf');
  core.hss.provisionAka(
    impi: 'alice@ims.local',
    impus: ['sip:alice@ims.local'],
    k: k,
    opc: opc,
  );
  return core;
}

String registerMsg({
  String impu = 'sip:alice@ims.local',
  String? authorization,
  int cseq = 1,
}) {
  final lines = <String>[
    'REGISTER $impu SIP/2.0',
    'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-aka-$cseq;rport',
    'Max-Forwards: 70',
    'From: <$impu>;tag=ue-ft1',
    'To: <$impu>',
    'Call-ID: aka-call-1',
    'CSeq: $cseq REGISTER',
    'Contact: <sip:alice@198.51.100.10:60901;transport=UDP>',
    'Expires: 3600',
    if (authorization != null) 'Authorization: $authorization',
    'Content-Length: 0',
  ];
  return '${lines.join('\r\n')}\r\n\r\n';
}

void main() {
  test('full AKAv1-MD5 register flow against collocated ImsCore', () {
    final core = buildAkaCore();
    final t = FakeTransport(
      localAddr: '198.51.100.10',
      localPort: 60901,
      serverAddr: '203.0.113.10',
      serverPort: 5060,
    );

    // 1. UE → REGISTER (no Authorization).
    core.handle(registerMsg(), t);
    expect(t.sent, hasLength(1));
    final challenge = t.sent.single.raw;
    expect(challenge, startsWith('SIP/2.0 401 Unauthorized'));
    expect(challenge, contains('algorithm=AKAv1-MD5'));

    // 2. Pull RAND/AUTN out of the challenge nonce.
    final wwwLine = challenge.split('\r\n').firstWhere(
        (l) => l.toLowerCase().startsWith('www-authenticate:'),
        orElse: () => '');
    final value = wwwLine.substring(wwwLine.indexOf(':') + 1).trim();
    final nonceB64 = RegExp('nonce="([^"]+)"').firstMatch(value)!.group(1)!;
    final nonceBytes = base64.decode(nonceB64);
    expect(nonceBytes.length, 32);
    final rand = Uint8List.fromList(nonceBytes.sublist(0, 16));
    final autn = Uint8List.fromList(nonceBytes.sublist(16, 32));
    // SQN^AK is the first 6 bytes of AUTN. We need the original SQN to
    // verify MAC-A on a real handset; here we trust the AUTN and just
    // run f2 (RES) which only depends on RAND, not SQN.
    expect(autn.length, 16);

    // 3. SIM-side: run Milenage to obtain RES.
    final k = hexToBytes('465b5ce8b199b49faa5f0a2ee238a6bc');
    final opc = hexToBytes('cd63cb71954a9f4e48a5994e37a02baf');
    // Recover SQN from AUTN: SQN = (SQN XOR AK) XOR AK. AK = f5(K, RAND).
    // f5 doesn't depend on SQN, so we can compute it with any SQN.
    final tmp = Milenage(opc).run(
      k: k,
      rand: rand,
      sqn: Uint8List(6),
      amf: Uint8List(2),
    );
    final sqn = Uint8List(6);
    for (var i = 0; i < 6; i++) {
      sqn[i] = autn[i] ^ tmp.ak[i];
    }
    // Now run Milenage with the recovered SQN to get the real RES (which
    // doesn't depend on SQN either, but doing it this way mirrors what the
    // SIM does).
    final m = Milenage(opc).run(
      k: k,
      rand: rand,
      sqn: sqn,
      amf: Uint8List.fromList([autn[6], autn[7]]),
    );
    // MAC-A check (the SIM would refuse otherwise).
    for (var i = 0; i < 8; i++) {
      expect(m.macA[i], autn[8 + i], reason: 'MAC-A from AUTN must validate');
    }

    // 4. Build Authorization with passwd = RES (raw bytes).
    const impi = 'alice@ims.local';
    const realm = 'ims.local';
    const uri = 'sip:alice@ims.local';
    const nc = '00000001';
    const cnonce = '0a4f113b';
    const qop = 'auth';
    final ha1Input = BytesBuilder()
      ..add(utf8.encode('$impi:$realm:'))
      ..add(m.res);
    final ha1 = md5.convert(ha1Input.toBytes()).toString();
    final ha2 = md5.convert(utf8.encode('REGISTER:$uri')).toString();
    final response = md5
        .convert(utf8.encode('$ha1:$nonceB64:$nc:$cnonce:$qop:$ha2'))
        .toString();
    final authHeader =
        'Digest username="$impi", realm="$realm", nonce="$nonceB64", '
        'uri="$uri", response="$response", algorithm=AKAv1-MD5, '
        'cnonce="$cnonce", qop=$qop, nc=$nc';

    // 5. Second REGISTER → 200 OK.
    core.handle(registerMsg(authorization: authHeader, cseq: 2), t);
    expect(t.sent, hasLength(2));
    final ok = t.sent.last.raw;
    expect(ok, startsWith('SIP/2.0 200 OK'),
        reason: 'AKA response must be accepted; got: $ok');
    expect(ok, contains('P-Associated-URI'));

    // HSS state: Alice now assigned to scscf.ims.local.
    final sub = core.hss.subscriptionByImpu('sip:alice@ims.local');
    expect(sub, isNotNull);
    expect(sub!.assignedScscfName, equals('scscf.ims.local'));
  });
}
