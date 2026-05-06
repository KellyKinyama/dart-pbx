import 'package:dart_pbx/services/dispatcher.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:test/test.dart';

Destination dest(String id, {int priority = 0}) {
  return Destination(
    id: id,
    address: sockaddr_in(
        '10.0.0.$id'.replaceAll(RegExp(r'[^0-9.]'), ''), 5060, 'udp'),
    send: (_) {},
    priority: priority,
  );
}

void main() {
  group('roundRobin', () {
    test('cycles through active members', () {
      final s = DispatcherService()
        ..addDestination(1, dest('1'))
        ..addDestination(1, dest('2'))
        ..addDestination(1, dest('3'));
      final picks = [
        s.select(1)?.id,
        s.select(1)?.id,
        s.select(1)?.id,
        s.select(1)?.id,
      ];
      expect(picks, ['1', '2', '3', '1']);
    });

    test('skips destinations marked down', () {
      final s = DispatcherService();
      final a = dest('1');
      final b = dest('2');
      final c = dest('3');
      s
        ..addDestination(1, a)
        ..addDestination(1, b)
        ..addDestination(1, c);
      s.markDown(b);
      final picks = <String?>[];
      for (var i = 0; i < 4; i++) {
        picks.add(s.select(1)?.id);
      }
      expect(picks, everyElement(isNot(equals('2'))));
    });

    test('returns null when nothing is alive', () {
      final s = DispatcherService();
      final a = dest('1');
      s.addDestination(1, a);
      s.markDown(a);
      expect(s.select(1), isNull);
    });
  });

  group('hashCallId', () {
    test('same key always picks the same destination', () {
      final s = DispatcherService();
      s.ensureSet(7, algorithm: DispatcherAlgorithm.hashCallId);
      s
        ..addDestination(7, dest('1'))
        ..addDestination(7, dest('2'))
        ..addDestination(7, dest('3'));
      final first = s.select(7, hashKey: 'abc-call-id')!.id;
      for (var i = 0; i < 5; i++) {
        expect(s.select(7, hashKey: 'abc-call-id')!.id, first);
      }
    });
  });

  group('priority', () {
    test('always returns the lowest-priority active destination', () {
      final s = DispatcherService();
      s.ensureSet(9, algorithm: DispatcherAlgorithm.priority);
      final hi = dest('1', priority: 10);
      final mid = dest('2', priority: 5);
      final lo = dest('3', priority: 1);
      s
        ..addDestination(9, hi)
        ..addDestination(9, mid)
        ..addDestination(9, lo);
      expect(s.select(9)!.id, '3');
      s.markDown(lo);
      expect(s.select(9)!.id, '2');
      s.markDown(mid);
      expect(s.select(9)!.id, '1');
    });
  });

  group('state transitions', () {
    test('markUp clears failures', () {
      final s = DispatcherService();
      final a = dest('1');
      s.addDestination(1, a);
      s.markDown(a);
      expect(a.state, DispatcherState.down);
      expect(a.consecutiveFailures, 1);
      s.markUp(a);
      expect(a.state, DispatcherState.up);
      expect(a.consecutiveFailures, 0);
    });
  });
}
