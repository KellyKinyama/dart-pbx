// Unit tests for the call-center module.
//
// Validates:
//   * Longest-idle picker ordering (oldest lastIdleAt wins).
//   * Skill filtering when the queue requires one.
//   * State transitions: login / assign / answered / hangup / no-answer.
//   * Auto-pause after the configured number of consecutive misses.

import 'package:dart_pbx/services/callcenter.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('CallCenterService', () {
    late CallCenterService cc;
    late FakeTransport tA;
    late FakeTransport tB;
    late FakeTransport tC;

    setUp(() {
      cc = CallCenterService();
      tA = FakeTransport(localAddr: '10.0.0.1');
      tB = FakeTransport(localAddr: '10.0.0.2');
      tC = FakeTransport(localAddr: '10.0.0.3');
      cc.registerQueue(Queue(id: 'support', autoPauseAfterMissed: 2));
      cc.addAgent(Agent(id: 'a1', client: testClient('a1', tA)));
      cc.addAgent(Agent(id: 'a2', client: testClient('a2', tB)));
      cc.addAgent(Agent(id: 'a3', client: testClient('a3', tC)));
    });

    test('offline agents are not picked', () {
      expect(cc.pickLongestIdle('support'), isNull);
    });

    test('longest-idle agent wins', () async {
      cc.login('a1');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      cc.login('a2');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      cc.login('a3');

      expect(cc.pickLongestIdle('support')!.id, 'a1');

      // Assign a1 — next pick should be a2 (next-oldest idle).
      cc.assign('a1');
      expect(cc.pickLongestIdle('support')!.id, 'a2');
    });

    test('offerCall picks and assigns atomically', () {
      cc.login('a1');
      cc.login('a2');
      final picked = cc.offerCall('support')!;
      expect(picked.id, 'a1');
      expect(cc.agent('a1')!.state, AgentState.ringing);
      // a1 is no longer idle, so next offer goes to a2.
      expect(cc.offerCall('support')!.id, 'a2');
    });

    test('skill filter excludes non-matching agents', () {
      cc.registerQueue(Queue(id: 'tier2', requiredSkill: 'billing'));
      cc.addAgent(Agent(
        id: 'b1',
        client: testClient('b1', FakeTransport()),
        skills: {'billing'},
      ));
      cc.login('a1'); // no skills
      cc.login('b1'); // has billing
      expect(cc.pickLongestIdle('tier2')!.id, 'b1');
    });

    test('onAnswered moves agent into talking and resets misses', () {
      cc.login('a1');
      cc.assign('a1');
      cc.agent('a1')!.consecutiveNoAnswer = 5;
      cc.onAnswered('a1');
      final a = cc.agent('a1')!;
      expect(a.state, AgentState.talking);
      expect(a.callsAnswered, 1);
      expect(a.consecutiveNoAnswer, 0);
    });

    test('onHangup with zero wrap-up returns agent to idle immediately', () {
      cc.login('a1');
      cc.assign('a1');
      cc.onAnswered('a1');
      cc.onHangup('a1');
      expect(cc.agent('a1')!.state, AgentState.idle);
    });

    test('onNoAnswer auto-pauses after threshold', () {
      cc.login('a1');
      cc.assign('a1');
      cc.onNoAnswer('a1'); // miss 1: back to idle
      expect(cc.agent('a1')!.state, AgentState.idle);
      cc.assign('a1');
      cc.onNoAnswer('a1'); // miss 2 (threshold): auto-paused
      expect(cc.agent('a1')!.state, AgentState.wrapup);

      // While paused the agent is excluded from picks.
      cc.login('a2');
      expect(cc.pickLongestIdle('support')!.id, 'a2');

      // Manual unpause returns to idle but at the back of the longest-idle
      // queue (lastIdleAt updated to now).
      cc.unpause('a1');
      expect(cc.agent('a1')!.state, AgentState.idle);
    });

    test('logout removes agent from rotation', () {
      cc.login('a1');
      cc.logout('a1');
      expect(cc.pickLongestIdle('support'), isNull);
    });
  });
}
