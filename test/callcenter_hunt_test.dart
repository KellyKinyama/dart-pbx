// Integration tests for the call-center serial-hunt features:
//
//   * Per-attempt ring timeout (Queue.maxRingSeconds) auto-cancels upstream
//     and re-picks the next-longest-idle agent.
//   * On a non-2xx final from the first attempt, the proxy silently re-picks
//     without forwarding the failure to the caller.
//   * When all eligible agents have been tried, the caller is told 480.

import 'package:dart_pbx/handlers/requests_handlers.dart';
import 'package:dart_pbx/services/services.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

String _inviteFor(String queue, String fromHost, int fromPort,
    {String branch = 'z9hG4bKserial1'}) {
  return wire([
    'INVITE sip:$queue@pbx.example SIP/2.0',
    'Via: SIP/2.0/UDP $fromHost:$fromPort;branch=$branch;rport',
    'Max-Forwards: 70',
    'From: <sip:bob@pbx.example>;tag=b1',
    'To: <sip:$queue@pbx.example>',
    'Call-ID: serial-call-id',
    'CSeq: 1 INVITE',
    'Contact: <sip:bob@$fromHost:$fromPort>',
    'Content-Length: 0',
  ]);
}

void main() {
  group('Call-center serial hunt', () {
    test('ring timeout cancels first attempt and rings the next agent',
        () async {
      final services = ServiceRegistry()
        ..callcenter.registerQueue(Queue(id: 'support', maxRingSeconds: 0));
      // maxRingSeconds is in seconds; we override with a real-time duration
      // by directly constructing the queue with a very small value through
      // the agent state we control. Use 1 second and a real wait.
      // (We replace the queue with a 1-second timeout below.)
      services.callcenter
          .registerQueue(Queue(id: 'support', maxRingSeconds: 1));

      final tA = FakeTransport(localAddr: '10.0.0.1', localPort: 5060);
      final tB = FakeTransport(localAddr: '10.0.0.2', localPort: 5060);
      services.callcenter
          .addAgent(Agent(id: '1001', client: testClient('1001', tA)));
      services.callcenter
          .addAgent(Agent(id: '1002', client: testClient('1002', tB)));

      final handler = RequestsHandler(
        services: services,
        qualifyInterval: const Duration(days: 1),
      );

      services.callcenter.login('1001');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      services.callcenter.login('1002');

      final caller = FakeTransport(localAddr: '198.51.100.50', localPort: 5070);
      handler.handle(_inviteFor('support', '198.51.100.50', 5070), caller);

      // First INVITE went to 1001. Don't answer.
      expect(tA.sent.where((s) => s.raw.startsWith('INVITE')), hasLength(1));
      expect(tB.sent, isEmpty);

      // Wait past ringTimeout (1 s) for the proxy to re-pick.
      await Future<void>.delayed(const Duration(milliseconds: 1200));

      // Upstream CANCEL was sent to 1001.
      expect(tA.sent.any((s) => s.raw.startsWith('CANCEL')), isTrue,
          reason: 'expected CANCEL to first agent after ring timeout');
      // 1002 received the re-picked INVITE.
      expect(tB.sent.where((s) => s.raw.startsWith('INVITE')), hasLength(1),
          reason: 'expected serial hunt to ring the next agent');
      // Caller never saw 480 yet — still ringing on agent 2.
      expect(caller.sent.any((s) => s.raw.contains('480')), isFalse);
    });

    test('480 returned when every agent has been exhausted', () async {
      final services = ServiceRegistry()
        ..callcenter.registerQueue(Queue(id: 'support', maxRingSeconds: 1));

      // Only one agent, so re-pick will find nothing.
      final tA = FakeTransport(localAddr: '10.0.0.1', localPort: 5060);
      services.callcenter
          .addAgent(Agent(id: '1001', client: testClient('1001', tA)));

      final handler = RequestsHandler(
        services: services,
        qualifyInterval: const Duration(days: 1),
      );
      services.callcenter.login('1001');

      final caller = FakeTransport(localAddr: '198.51.100.50', localPort: 5070);
      handler.handle(_inviteFor('support', '198.51.100.50', 5070), caller);

      await Future<void>.delayed(const Duration(milliseconds: 1200));

      // CANCEL fired against the only agent.
      expect(tA.sent.any((s) => s.raw.startsWith('CANCEL')), isTrue);
      // Caller eventually got 480 Temporarily Unavailable.
      expect(caller.sent.any((s) => s.raw.contains('480')), isTrue,
          reason: 'expected 480 once the queue is exhausted');
    });
  });
}
