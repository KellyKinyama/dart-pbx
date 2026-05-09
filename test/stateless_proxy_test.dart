// Tests for the stateless RFC 3261 §16.11 proxy.

import 'package:dart_pbx/proxy/stateless_proxy.dart';
import 'package:dart_pbx/sip_client.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/transports/transport.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

String invite({
  String callee = '6002',
  String from = '6001',
  String callId = 'cid-stateless-1',
  String fromTag = 'ft1',
  String? toTag,
  String body = '',
}) {
  final lines = <String>[
    'INVITE sip:$callee@proxy.example:5060;transport=UDP SIP/2.0',
    'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-orig;rport',
    'Max-Forwards: 70',
    'Contact: <sip:$from@198.51.100.10:60901;transport=UDP>',
    'To: <sip:$callee@proxy.example:5060;transport=UDP>'
        '${toTag == null ? '' : ';tag=$toTag'}',
    'From: <sip:$from@proxy.example:5060;transport=UDP>;tag=$fromTag',
    'Call-ID: $callId',
    'CSeq: 1 INVITE',
    'Content-Length: ${body.length}',
  ];
  return '${lines.join('\r\n')}\r\n\r\n$body';
}

String ringingResponse({String callee = '6002'}) {
  final lines = <String>[
    'SIP/2.0 180 Ringing',
    // top via = the one our proxy added (deterministic, but here we just
    // simulate any branch — the proxy only checks its sent-by host:port)
    'Via: SIP/2.0/UDP 203.0.113.1:5060;branch=z9hG4bK-proxy-injected;rport',
    'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-orig'
        ';received=198.51.100.10;rport=60901',
    'To: <sip:$callee@proxy.example:5060;transport=UDP>;tag=callee-tag',
    'From: <sip:6001@proxy.example:5060;transport=UDP>;tag=ft1',
    'Call-ID: cid-stateless-1',
    'CSeq: 1 INVITE',
    'Content-Length: 0',
  ];
  return wire(lines);
}

void main() {
  group('StatelessProxy request forwarding', () {
    test('routes to a locally registered AOR when callee is registered', () {
      final inbound = FakeTransport(
          localAddr: '198.51.100.10',
          localPort: 60901,
          serverAddr: '203.0.113.1',
          serverPort: 5060);
      final calleeTx = FakeTransport(
          localAddr: '198.51.100.20',
          localPort: 5060,
          serverAddr: '203.0.113.1',
          serverPort: 5060);
      final clients = {'6002': testClient('6002', calleeTx)};

      final proxy = StatelessProxy(clients: clients);
      final req = parse(invite());
      proxy.handleRequest(req, inbound);

      expect(calleeTx.sent, hasLength(1));
      final sent = calleeTx.sent.single;
      expect(sent.destIp, '198.51.100.20');
      expect(sent.destPort, 5060);
      // Must have prepended our own Via with magic cookie.
      expect(sent.raw, contains('Via: SIP/2.0/UDP 203.0.113.1:5060'));
      expect(sent.raw, contains('branch=z9hG4bK-'));
      // Original Via must still be present.
      expect(sent.raw, contains('z9hG4bK-orig'));
      // Record-Route was added (default-on for INVITE).
      expect(sent.raw, contains('Record-Route: <sip:203.0.113.1:5060'));
      // Max-Forwards decremented.
      expect(sent.raw, contains('Max-Forwards: 69'));
      // Body left untouched (media is proxied, not anchored).
      expect(sent.raw, isNot(contains('rtpengine')));
    });

    test('forwards to upstream Asterisk when callee is unknown', () {
      final inbound =
          FakeTransport(localAddr: '198.51.100.10', localPort: 60901);
      final astTx = FakeTransport(
          localAddr: '10.0.0.5',
          localPort: 5060,
          serverAddr: '203.0.113.1',
          serverPort: 5060);
      final upstream =
          SipClient('asterisk', astTx, contactUri: 'sip:10.0.0.5:5060');
      final proxy = StatelessProxy(clients: {}, upstream: upstream);

      proxy.handleRequest(parse(invite(callee: '999-pstn')), inbound);

      expect(astTx.sent, hasLength(1));
      expect(astTx.sent.single.destIp, '10.0.0.5');
      expect(astTx.sent.single.destPort, 5060);
    });

    test('returns 404 when no destination can be resolved', () {
      final inbound = FakeTransport();
      final proxy = StatelessProxy(clients: {});
      proxy.handleRequest(parse(invite()), inbound);
      expect(inbound.sent, hasLength(1));
      expect(inbound.sent.single.raw, startsWith('SIP/2.0 404 Not Found'));
    });

    test('REGISTER is rejected (returns false; left to registrar)', () {
      final inbound = FakeTransport();
      final proxy = StatelessProxy(clients: {});
      final raw = wire([
        'REGISTER sip:proxy.example:5060;transport=UDP SIP/2.0',
        'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-r;rport',
        'Max-Forwards: 70',
        'To: <sip:6001@proxy.example>',
        'From: <sip:6001@proxy.example>;tag=ft',
        'Call-ID: r1',
        'CSeq: 1 REGISTER',
        'Content-Length: 0',
      ]);
      expect(proxy.handleRequest(parse(raw), inbound), isFalse);
      expect(inbound.sent, isEmpty);
    });

    test('Max-Forwards 0 yields 483 Too Many Hops', () {
      final inbound = FakeTransport();
      final calleeTx = FakeTransport(localAddr: '198.51.100.20');
      final proxy =
          StatelessProxy(clients: {'6002': testClient('6002', calleeTx)});
      final raw = wire([
        'INVITE sip:6002@proxy.example:5060 SIP/2.0',
        'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-x;rport',
        'Max-Forwards: 0',
        'To: <sip:6002@proxy.example>',
        'From: <sip:6001@proxy.example>;tag=ft',
        'Call-ID: cid-mf',
        'CSeq: 1 INVITE',
        'Content-Length: 0',
      ]);
      proxy.handleRequest(parse(raw), inbound);
      expect(calleeTx.sent, isEmpty);
      expect(inbound.sent.single.raw, startsWith('SIP/2.0 483 Too Many Hops'));
    });

    test('detects loops via own sent-by in Via stack and replies 482', () {
      final inbound =
          FakeTransport(serverAddr: '203.0.113.1', serverPort: 5060);
      final calleeTx = FakeTransport(localAddr: '198.51.100.20');
      final proxy =
          StatelessProxy(clients: {'6002': testClient('6002', calleeTx)});
      final raw = wire([
        'INVITE sip:6002@proxy.example:5060 SIP/2.0',
        // Our own sent-by already in the stack → loop.
        'Via: SIP/2.0/UDP 203.0.113.1:5060;branch=z9hG4bK-prev',
        'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-orig;rport',
        'Max-Forwards: 70',
        'To: <sip:6002@proxy.example>',
        'From: <sip:6001@proxy.example>;tag=ft',
        'Call-ID: cid-loop',
        'CSeq: 1 INVITE',
        'Content-Length: 0',
      ]);
      proxy.handleRequest(parse(raw), inbound);
      expect(calleeTx.sent, isEmpty);
      expect(inbound.sent.single.raw, startsWith('SIP/2.0 482 Loop Detected'));
    });

    test('deterministic branch: same request → same branch', () {
      final inbound = FakeTransport();
      final calleeTx = FakeTransport(localAddr: '198.51.100.20');
      final proxy =
          StatelessProxy(clients: {'6002': testClient('6002', calleeTx)});

      proxy.handleRequest(parse(invite()), inbound);
      proxy.handleRequest(parse(invite()), inbound);

      expect(calleeTx.sent, hasLength(2));
      String topBranch(String raw) {
        final via = raw.split('\r\n').firstWhere((l) => l.startsWith('Via:'));
        final m = RegExp(r'branch=([^;\s]+)').firstMatch(via)!;
        return m.group(1)!;
      }

      expect(topBranch(calleeTx.sent[0].raw),
          equals(topBranch(calleeTx.sent[1].raw)));
    });
  });

  group('StatelessProxy response forwarding', () {
    test('pops own Via and sends to received=/rport= of next Via', () {
      final transport =
          FakeTransport(serverAddr: '203.0.113.1', serverPort: 5060);
      final proxy = StatelessProxy(clients: {});

      proxy.handleResponse(parse(ringingResponse()), transport);

      expect(transport.sent, hasLength(1));
      final sent = transport.sent.single;
      expect(sent.destIp, '198.51.100.10'); // received=
      expect(sent.destPort, 60901); // rport=
      // Our injected Via must have been removed.
      expect(sent.raw, isNot(contains('z9hG4bK-proxy-injected')));
      expect(sent.raw, contains('z9hG4bK-orig'));
      expect(sent.raw, startsWith('SIP/2.0 180 Ringing'));
    });

    test('drops a response whose top Via is not ours', () {
      final transport =
          FakeTransport(serverAddr: '203.0.113.1', serverPort: 5060);
      final proxy = StatelessProxy(clients: {});
      final raw = wire([
        'SIP/2.0 200 OK',
        // Top Via belongs to some other proxy.
        'Via: SIP/2.0/UDP 192.0.2.99:5060;branch=z9hG4bK-foreign',
        'Via: SIP/2.0/UDP 198.51.100.10:60901;branch=z9hG4bK-orig',
        'To: <sip:6002@proxy.example>;tag=cb',
        'From: <sip:6001@proxy.example>;tag=ft',
        'Call-ID: cid-x',
        'CSeq: 1 INVITE',
        'Content-Length: 0',
      ]);
      proxy.handleResponse(parse(raw), transport);
      expect(transport.sent, isEmpty);
    });
  });
}
