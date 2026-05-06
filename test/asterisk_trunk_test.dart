// Integration tests for the Asterisk-trunk topology:
//
//   * REGISTER is handled locally (location + auth) and is never forwarded.
//   * INVITE for any AOR (registered or not) is proxied to the upstream
//     (Asterisk) when one is configured.
//   * The forwarded INVITE has our Via on top, decremented Max-Forwards, and
//     a Record-Route pointing back at us so in-dialog requests follow the
//     same path.

import 'package:dart_pbx/handlers/requests_handlers.dart';
import 'package:dart_pbx/services/services.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('Asterisk upstream trunking', () {
    late RequestsHandler handler;
    late FakeTransport upstreamTx;

    setUp(() {
      handler = RequestsHandler(
        services: ServiceRegistry(),
        qualifyInterval: const Duration(days: 1),
      );
      upstreamTx = FakeTransport(
        localAddr: '10.0.0.99', // Asterisk address
        localPort: 5060,
        serverAddr: '203.0.113.1', // our address (from upstream's perspective)
        serverPort: 5060,
      );
      handler.setUpstream(testClient('asterisk', upstreamTx));
    });

    test('REGISTER stays local — upstream never sees it', () {
      final caller = FakeTransport(
        localAddr: '198.51.100.10',
        localPort: 12345,
      );
      final register = wire([
        'REGISTER sip:pbx.example SIP/2.0',
        'Via: SIP/2.0/UDP 198.51.100.10:12345;branch=z9hG4bKreg1;rport',
        'Max-Forwards: 70',
        'From: <sip:alice@pbx.example>;tag=a1',
        'To: <sip:alice@pbx.example>',
        'Call-ID: reg-call-id',
        'CSeq: 1 REGISTER',
        'Contact: <sip:alice@198.51.100.10:12345>',
        'Expires: 3600',
        'Content-Length: 0',
      ]);
      handler.handle(register, caller);

      expect(upstreamTx.sent, isEmpty,
          reason: 'REGISTER must not be proxied to Asterisk');
      expect(caller.sent, isNotEmpty, reason: 'Local registrar must answer');
      expect(caller.sent.first.raw, contains('200 OK'));
      expect(handler.usrloc.exists('alice'), isTrue);
    });

    test('INVITE for a registered local user is still routed to upstream', () {
      // Register alice locally first.
      final alicePhone = FakeTransport(
        localAddr: '198.51.100.10',
        localPort: 12345,
      );
      handler.handle(
        wire([
          'REGISTER sip:pbx.example SIP/2.0',
          'Via: SIP/2.0/UDP 198.51.100.10:12345;branch=z9hG4bKreg1;rport',
          'Max-Forwards: 70',
          'From: <sip:alice@pbx.example>;tag=a1',
          'To: <sip:alice@pbx.example>',
          'Call-ID: reg-call-id',
          'CSeq: 1 REGISTER',
          'Contact: <sip:alice@198.51.100.10:12345>',
          'Expires: 3600',
          'Content-Length: 0',
        ]),
        alicePhone,
      );
      // Drop the REGISTER 200 OK from the captured list.
      alicePhone.sent.clear();

      final bobPhone = FakeTransport(
        localAddr: '198.51.100.20',
        localPort: 23456,
      );
      handler.handle(
        wire([
          'INVITE sip:alice@pbx.example SIP/2.0',
          'Via: SIP/2.0/UDP 198.51.100.20:23456;branch=z9hG4bKinv1;rport',
          'Max-Forwards: 70',
          'From: Bob <sip:bob@pbx.example>;tag=b1',
          'To: Alice <sip:alice@pbx.example>',
          'Call-ID: inv-call-id',
          'CSeq: 1 INVITE',
          'Contact: <sip:bob@198.51.100.20:23456>',
          'Content-Length: 0',
        ]),
        bobPhone,
      );

      // Asterisk receives the forwarded INVITE.
      expect(upstreamTx.sent, isNotEmpty,
          reason: 'INVITE must be sent to upstream Asterisk');
      final forwarded = upstreamTx.sent.first.raw;
      final m = parse(forwarded);
      expect(m.Req.Method, 'INVITE');
      // Our Via is on top, original Via is preserved underneath.
      expect(m.Via.length, greaterThanOrEqualTo(2));
      expect(m.Via.first.Host, '203.0.113.1');
      expect(m.Via.last.Branch, 'z9hG4bKinv1');
      // Max-Forwards was decremented from 70 to 69.
      expect(m.MaxFwd.Value, '69');
      // Record-Route points back at us so in-dialog requests follow the path.
      expect(forwarded, contains('Record-Route:'));
      expect(forwarded, contains('203.0.113.1'));

      // Caller got 100 Trying from the proxy.
      expect(bobPhone.sent.any((s) => s.raw.contains('100 Trying')), isTrue);
    });

    test('INVITE for an unregistered AOR is also forwarded to upstream', () {
      final caller = FakeTransport(
        localAddr: '198.51.100.30',
        localPort: 34567,
      );
      handler.handle(
        wire([
          'INVITE sip:9001@pbx.example SIP/2.0',
          'Via: SIP/2.0/UDP 198.51.100.30:34567;branch=z9hG4bKinv2;rport',
          'Max-Forwards: 70',
          'From: <sip:bob@pbx.example>;tag=b1',
          'To: <sip:9001@pbx.example>',
          'Call-ID: inv-pstn-call-id',
          'CSeq: 1 INVITE',
          'Contact: <sip:bob@198.51.100.30:34567>',
          'Content-Length: 0',
        ]),
        caller,
      );

      expect(upstreamTx.sent, hasLength(1));
      expect(parse(upstreamTx.sent.first.raw).Req.Method, 'INVITE');
      // No 404 was sent back — Asterisk owns the dialplan.
      expect(caller.sent.any((s) => s.raw.contains('404')), isFalse);
    });

    test('with no upstream configured, unknown AORs still get 404', () {
      final h2 = RequestsHandler(
        services: ServiceRegistry(),
        qualifyInterval: const Duration(days: 1),
      );
      final caller = FakeTransport();
      h2.handle(
        wire([
          'INVITE sip:nobody@pbx.example SIP/2.0',
          'Via: SIP/2.0/UDP 198.51.100.10:12345;branch=z9hG4bKnf;rport',
          'Max-Forwards: 70',
          'From: <sip:bob@pbx.example>;tag=b1',
          'To: <sip:nobody@pbx.example>',
          'Call-ID: nf-call-id',
          'CSeq: 1 INVITE',
          'Contact: <sip:bob@198.51.100.10:12345>',
          'Content-Length: 0',
        ]),
        caller,
      );
      expect(caller.sent.any((s) => s.raw.contains('404')), isTrue);
    });
  });
}
