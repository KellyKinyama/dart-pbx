// Integration test: inbound INVITE for a queue AOR is routed by the
// call-center module to the longest-idle agent's endpoint, ahead of any
// upstream / AOR fallback.

import 'package:dart_pbx/handlers/requests_handlers.dart';
import 'package:dart_pbx/services/services.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  test('queue INVITE rings the longest-idle agent', () async {
    final services = ServiceRegistry()
      ..callcenter.registerQueue(Queue(id: 'support'));

    // Two agents on different fake transports.
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

    // 1001 logs in first → has the oldest lastIdleAt → should be picked.
    services.callcenter.login('1001');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    services.callcenter.login('1002');

    final caller = FakeTransport(localAddr: '198.51.100.50', localPort: 5070);
    handler.handle(
      wire([
        'INVITE sip:support@pbx.example SIP/2.0',
        'Via: SIP/2.0/UDP 198.51.100.50:5070;branch=z9hG4bKq1;rport',
        'Max-Forwards: 70',
        'From: <sip:bob@pbx.example>;tag=b1',
        'To: <sip:support@pbx.example>',
        'Call-ID: q-call-id',
        'CSeq: 1 INVITE',
        'Contact: <sip:bob@198.51.100.50:5070>',
        'Content-Length: 0',
      ]),
      caller,
    );

    // 1001 received the call, 1002 did not.
    expect(tA.sent.where((s) => s.raw.startsWith('INVITE')), hasLength(1));
    expect(tB.sent, isEmpty);

    // Caller got 100 Trying.
    expect(caller.sent.any((s) => s.raw.contains('100 Trying')), isTrue);

    // Agent state advanced to ringing.
    expect(services.callcenter.agent('1001')!.state, AgentState.ringing);
  });
}
