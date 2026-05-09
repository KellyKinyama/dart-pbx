// BGCF unit tests — TS 24.229 §5.6.
//
// We test the BGCF in isolation (no transports, no S-CSCF) by feeding it
// raw SIP messages and capturing what it would have written to the
// trunk. This keeps the matrix of routing rules small and focused.

import 'package:dart_pbx/ims/bgcf.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:test/test.dart';

SipMsg _req(String requestUri) {
  final raw = 'INVITE $requestUri SIP/2.0\r\n'
      'Via: SIP/2.0/UDP scscf.local:5060;branch=z9hG4bK-bgcf-1\r\n'
      'From: <sip:alice@ims.local>;tag=a\r\n'
      'To: <$requestUri>\r\n'
      'Call-ID: bgcf-test-1\r\n'
      'CSeq: 1 INVITE\r\n'
      'Max-Forwards: 70\r\n'
      'P-Asserted-Identity: <sip:alice@ims.local>\r\n'
      'P-Charging-Vector: icid-value=42\r\n'
      'P-Visited-Network-ID: ims.local\r\n'
      'Privacy: none\r\n'
      'Service-Route: <sip:scscf.local;lr>\r\n'
      'Contact: <sip:alice@10.0.0.1:5060>\r\n'
      'Content-Length: 0\r\n\r\n';
  return SipMsg()..Parse(raw);
}

class _Sent {
  _Sent(this.raw, this.host, this.port);
  final String raw;
  final String? host;
  final int? port;
}

void main() {
  group('BGCF routing', () {
    final pstn = BgcfTrunk(
        name: 'pstn', host: '10.50.0.10', port: 5060, transport: 'UDP');
    final intl = BgcfTrunk(
        name: 'international',
        host: '10.50.0.20',
        port: 5060,
        transport: 'UDP',
        priority: 50);
    final fallback = BgcfTrunk(
        name: 'asterisk', host: '127.0.0.1', port: 5080, transport: 'UDP');

    Bgcf newBgcf() => Bgcf(
          host: '10.0.0.1',
          port: 5060,
          transport: 'UDP',
          routes: [
            BgcfRoute(trunk: intl, scheme: 'tel', numberPrefix: '+'),
            BgcfRoute(trunk: pstn, scheme: 'tel'),
            BgcfRoute(trunk: pstn, domain: 'pstn.example.com'),
          ],
          defaultTrunk: fallback,
        );

    test('routes tel:+E164 to international trunk by prefix priority', () {
      final b = newBgcf();
      final t = b.selectTrunk(_req('tel:+14155551212'));
      expect(t, isNotNull);
      expect(t!.name, equals('international'));
    });

    test('routes plain tel: number to PSTN trunk', () {
      final b = newBgcf();
      final t = b.selectTrunk(_req('tel:4155551212'));
      expect(t, isNotNull);
      expect(t!.name, equals('pstn'));
    });

    test('routes by Request-URI domain', () {
      final b = newBgcf();
      final t = b.selectTrunk(_req('sip:bob@pstn.example.com'));
      expect(t, isNotNull);
      expect(t!.name, equals('pstn'));
    });

    test('falls back to default trunk when nothing matches', () {
      final b = newBgcf();
      final t = b.selectTrunk(_req('sip:carol@some.other.org'));
      expect(t, isNotNull);
      expect(t!.name, equals('asterisk'));
    });

    test('returns null when no route and no default', () {
      final b = Bgcf(
        host: '10.0.0.1',
        port: 5060,
        transport: 'UDP',
        routes: [BgcfRoute(trunk: pstn, domain: 'pstn.example.com')],
      );
      expect(b.selectTrunk(_req('sip:bob@nowhere.example.org')), isNull);
    });

    test('forward strips private IMS headers and adds Record-Route', () {
      final b = newBgcf();
      final sent = <_Sent>[];
      final ok = b.forward(_req('sip:bob@pstn.example.com'),
          send: (raw, {destIp, destPort}) =>
              sent.add(_Sent(raw, destIp, destPort)));
      expect(ok, isTrue);
      expect(sent, hasLength(1));
      final out = sent.first;
      expect(out.host, equals('10.50.0.10'));
      expect(out.port, equals(5060));
      // Private IMS headers must be gone before the trunk sees them.
      expect(out.raw, isNot(contains('P-Asserted-Identity')));
      expect(out.raw, isNot(contains('P-Charging-Vector')));
      expect(out.raw, isNot(contains('P-Visited-Network-ID')));
      expect(out.raw, isNot(contains('Privacy:')));
      expect(out.raw, isNot(contains('Service-Route')));
      // BGCF must Record-Route itself for response symmetry.
      expect(out.raw, contains('Record-Route:'));
      expect(out.raw, contains('bgcf@10.0.0.1:5060'));
    });

    test('forward returns false and sends nothing when no route', () {
      final b = Bgcf(
        host: '10.0.0.1',
        port: 5060,
        transport: 'UDP',
        routes: [BgcfRoute(trunk: pstn, domain: 'pstn.example.com')],
      );
      final sent = <_Sent>[];
      final ok = b.forward(_req('sip:bob@nowhere.example.org'),
          send: (raw, {destIp, destPort}) =>
              sent.add(_Sent(raw, destIp, destPort)));
      expect(ok, isFalse);
      expect(sent, isEmpty);
    });
  });
}
