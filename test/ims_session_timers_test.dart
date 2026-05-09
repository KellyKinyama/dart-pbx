// RFC 4028 (Session-Timers) proxy enforcement and RFC 3262 (PRACK)
// pass-through behavior at the S-CSCF.
//
// Unit tests on the S-CSCF in isolation — its callback surface is wired
// to capturing closures rather than going through the full IMS Core
// stack, so we can drive any method without the P-CSCF "must be
// registered" gate getting in the way.

import 'package:dart_pbx/ims/hss.dart';
import 'package:dart_pbx/ims/scscf.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

class _Capture {
  final List<SipMsg> replies = [];
  final List<SipMsg> terminating = [];
  final List<SipMsg> offNet = [];
}

(Scscf, _Capture) buildScscf() {
  final hss = HomeSubscriberServer(
    realm: 'ims.local',
    scscfPool: ['scscf.ims.local'],
  );
  hss.provision(
      impi: 'alice@ims.local', impus: ['sip:alice@ims.local'], password: 'pw');
  hss.provision(
      impi: 'bob@ims.local', impus: ['sip:bob@ims.local'], password: 'pw');
  final cap = _Capture();
  final scscf = Scscf(
    name: 'scscf.ims.local',
    host: '203.0.113.10',
    port: 5060,
    transport: 'UDP',
    hss: hss,
    replyLocal: cap.replies.add,
    routeToTerminating: (impu, req, inb) => cap.terminating.add(req),
    routeToOffNet: (req, inb) => cap.offNet.add(req),
  );
  return (scscf, cap);
}

String invite({required int? sessionExpires, required int? minSe}) {
  final lines = <String>[
    'INVITE sip:bob@ims.local SIP/2.0',
    'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-inv-st;rport',
    'Max-Forwards: 70',
    'From: <sip:alice@ims.local>;tag=ft',
    'To: <sip:bob@ims.local>',
    'Call-ID: st-c1',
    'CSeq: 1 INVITE',
    'Contact: <sip:alice@198.51.100.10:60901;transport=UDP>',
    'Supported: timer, 100rel',
    if (sessionExpires != null)
      'Session-Expires: $sessionExpires;refresher=uac',
    if (minSe != null) 'Min-SE: $minSe',
    'Content-Length: 0',
  ];
  return wire(lines);
}

void main() {
  final t = FakeTransport(
      localAddr: '198.51.100.10',
      localPort: 60901,
      serverAddr: '203.0.113.10',
      serverPort: 5060);

  group('Session-Timers (RFC 4028)', () {
    test('Session-Expires below operator minimum → 422 with Min-SE', () {
      final (scscf, cap) = buildScscf();
      scscf.onRequest(
          SipMsg()..Parse(invite(sessionExpires: 30, minSe: null)), t);
      expect(cap.replies, hasLength(1));
      final r = cap.replies.single.src ?? '';
      expect(r, startsWith('SIP/2.0 422 Session Interval Too Small'));
      expect(r, contains('Min-SE: 90'));
      expect(cap.terminating, isEmpty);
      expect(cap.offNet, isEmpty);
    });

    test('Min-SE inserted on forward when missing', () {
      final (scscf, cap) = buildScscf();
      final parsed = SipMsg()..Parse(invite(sessionExpires: 1800, minSe: null));
      scscf.onRequest(parsed, t);
      // No 422 generated.
      for (final m in cap.replies) {
        expect(m.src ?? '', isNot(startsWith('SIP/2.0 422')));
      }
      // Min-SE was injected into the request itself.
      expect(parsed.src, contains('Min-SE: 90'));
    });

    test('Session-Expires equal to the minimum is accepted', () {
      final (scscf, cap) = buildScscf();
      scscf.onRequest(
          SipMsg()..Parse(invite(sessionExpires: 90, minSe: 90)), t);
      for (final m in cap.replies) {
        expect(m.src ?? '', isNot(startsWith('SIP/2.0 422')));
      }
    });
  });

  group('PRACK / 100rel pass-through (RFC 3262)', () {
    test('PRACK is not 422-rejected and not Min-SE-decorated', () {
      final (scscf, cap) = buildScscf();
      final raw = wire([
        'PRACK sip:bob@ims.local SIP/2.0',
        'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-prack;rport',
        'Max-Forwards: 70',
        'From: <sip:alice@ims.local>;tag=ft',
        'To: <sip:bob@ims.local>;tag=remote-tag',
        'Call-ID: prack-c1',
        'CSeq: 2 PRACK',
        'RAck: 1 1 INVITE',
        'Content-Length: 0',
      ]);
      final parsed = SipMsg()..Parse(raw);
      scscf.onRequest(parsed, t);
      for (final m in cap.replies) {
        final r = m.src ?? '';
        expect(r, isNot(startsWith('SIP/2.0 422')));
      }
      // Min-SE injection only applies to INVITE.
      expect(parsed.src, isNot(contains('Min-SE')));
    });

    test('Require: 100rel survives forwarding', () {
      final (scscf, _) = buildScscf();
      final raw = wire([
        'INVITE sip:bob@ims.local SIP/2.0',
        'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-100rel;rport',
        'Max-Forwards: 70',
        'From: <sip:alice@ims.local>;tag=ft',
        'To: <sip:bob@ims.local>',
        'Call-ID: rel-c1',
        'CSeq: 1 INVITE',
        'Contact: <sip:alice@198.51.100.10:60901;transport=UDP>',
        'Require: 100rel',
        'Supported: timer',
        'Session-Expires: 1800;refresher=uac',
        'Min-SE: 90',
        'Content-Length: 0',
      ]);
      final parsed = SipMsg()..Parse(raw);
      scscf.onRequest(parsed, t);
      expect(parsed.src, contains('Require: 100rel'));
    });
  });
}
