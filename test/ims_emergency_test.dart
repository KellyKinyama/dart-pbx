// Emergency REGISTER and emergency call routing tests
// (TS 24.229 §5.1.6 / §5.4.1.2.2 / §5.4.3.2; RFC 5031 emergency URN).
//
// The trigger we recognise is the `;sos` Contact parameter (and, for
// non-REGISTER requests, the `urn:service:sos` Request-URI). Putting the
// URN itself in From/To is not exercised because our SIP parser only
// supports sip:/sips: URIs there — which is fine: real handsets put the
// URN in the Request-URI, not the To.

import 'package:dart_pbx/ims/ims_core.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

ImsCore buildCore({String realm = 'ims.local'}) {
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
  return c;
}

void main() {
  group('Emergency REGISTER (TS 24.229 §5.4.1.2.2)', () {
    test(
        'unauthenticated UE with sos Contact param is registered '
        'without a 401 challenge', () {
      final core = buildCore();
      final t = FakeTransport(
          localAddr: '198.51.100.99',
          localPort: 60901,
          serverAddr: '203.0.113.10',
          serverPort: 5060);
      // Anonymous UE — IMPU is not provisioned in the HSS. The `;sos`
      // parameter on Contact tells the IMS this is an emergency
      // registration, so I-CSCF skips UAR and S-CSCF skips authentication.
      final raw = wire([
        'REGISTER sip:anonymous@ims.local SIP/2.0',
        'Via: SIP/2.0/UDP 198.51.100.99:60901;branch=z9hG4bK-sos1;rport',
        'Max-Forwards: 70',
        'From: <sip:anonymous@ims.local>;tag=sos-ft',
        'To: <sip:anonymous@ims.local>',
        'Call-ID: sos-call-1',
        'CSeq: 1 REGISTER',
        'Contact: <sip:anonymous@198.51.100.99:60901;transport=UDP>;sos',
        'Expires: 600',
        'Content-Length: 0',
      ]);
      core.handle(raw, t);

      expect(t.sent, hasLength(1),
          reason: 'emergency REGISTER should be answered with 200 OK '
              'directly, no challenge');
      final ok = t.sent.single.raw;
      expect(ok, startsWith('SIP/2.0 200 OK'),
          reason: 'unauth emergency REGISTER must succeed; got: $ok');
      expect(ok, isNot(contains('WWW-Authenticate')));
    });

    test('emergency REGISTER expires capped to 600s', () {
      final core = buildCore();
      final t = FakeTransport(
          localAddr: '198.51.100.99',
          localPort: 60901,
          serverAddr: '203.0.113.10',
          serverPort: 5060);
      // UE asks for 7200; emergency policy clamps to 600.
      final raw = wire([
        'REGISTER sip:anonymous@ims.local SIP/2.0',
        'Via: SIP/2.0/UDP 198.51.100.99:60901;branch=z9hG4bK-sos2;rport',
        'Max-Forwards: 70',
        'From: <sip:anonymous@ims.local>;tag=sos-ft',
        'To: <sip:anonymous@ims.local>',
        'Call-ID: sos-call-2',
        'CSeq: 1 REGISTER',
        'Contact: <sip:anonymous@198.51.100.99:60901;transport=UDP>;sos',
        'Expires: 7200',
        'Content-Length: 0',
      ]);
      core.handle(raw, t);
      final ok = t.sent.single.raw;
      expect(ok, startsWith('SIP/2.0 200 OK'));
      expect(ok, contains('Expires: 600'),
          reason: 'emergency expires must be capped to 600s; got: $ok');
    });

    test(
        'authenticated emergency REGISTER still requires the digest '
        'challenge (known IMPU)', () {
      final core = buildCore();
      final t = FakeTransport(
          localAddr: '198.51.100.10',
          localPort: 60901,
          serverAddr: '203.0.113.10',
          serverPort: 5060);
      // Alice is provisioned. With `;sos` the binding is emergency, but
      // because she has credentials the network still authenticates her.
      final raw = wire([
        'REGISTER sip:alice@ims.local SIP/2.0',
        'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-sos3;rport',
        'Max-Forwards: 70',
        'From: <sip:alice@ims.local>;tag=ft',
        'To: <sip:alice@ims.local>',
        'Call-ID: c-sos3',
        'CSeq: 1 REGISTER',
        'Contact: <sip:alice@198.51.100.10:60901;transport=UDP>;sos',
        'Expires: 3600',
        'Content-Length: 0',
      ]);
      core.handle(raw, t);
      final r = t.sent.single.raw;
      expect(r, startsWith('SIP/2.0 401 Unauthorized'));
    });
  });

  group('Emergency INVITE (TS 24.229 §5.4.3.2)', () {
    test(
        'INVITE to urn:service:sos goes to off-net (E-CSCF/PSAP), '
        'bypassing iFC and the terminating routing lookup', () {
      var offNetCount = 0;
      SipMsg? offNetReq;
      final core = buildCore();
      core.scscf.routeToOffNet = (req, inb) {
        offNetCount++;
        offNetReq = req;
      };
      final t = FakeTransport(
          localAddr: '198.51.100.10',
          localPort: 60901,
          serverAddr: '203.0.113.10',
          serverPort: 5060);
      // Keep To as sip: so the parser can handle it; the URN that matters
      // for routing is the Request-URI (RFC 5031).
      core.handle(
        wire([
          'INVITE urn:service:sos SIP/2.0',
          'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-sosinv;rport',
          'Max-Forwards: 70',
          'From: <sip:alice@ims.local>;tag=ft',
          'To: <sip:emergency@ims.local>',
          'Call-ID: sos-c1',
          'CSeq: 1 INVITE',
          'Contact: <sip:alice@198.51.100.10:60901;transport=UDP>',
          'Content-Length: 0',
        ]),
        t,
      );

      expect(offNetCount, 1,
          reason: 'emergency INVITE must be handed to off-net (E-CSCF/PSAP)');
      expect(offNetReq?.Req.Src, contains('urn:service:sos'));
    });
  });
}
