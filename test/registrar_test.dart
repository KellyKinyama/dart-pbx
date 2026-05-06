import 'package:dart_pbx/proxy/registrar.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('RegistrarPolicy.grantExpires', () {
    final p =
        RegistrarPolicy(defaultExpires: 3600, minExpires: 60, maxExpires: 7200);

    test('contact-expires takes precedence over header-expires', () {
      expect(p.grantExpires(contactExpires: 120, headerExpires: 600), 120);
    });

    test('falls back to header-expires when contact is missing', () {
      expect(p.grantExpires(contactExpires: null, headerExpires: 90), 90);
    });

    test('falls back to default when both missing', () {
      expect(p.grantExpires(contactExpires: null, headerExpires: null), 3600);
    });

    test('zero passes through (unregister)', () {
      expect(p.grantExpires(contactExpires: 0, headerExpires: 3600), 0);
    });

    test('returns null when below minimum', () {
      expect(p.grantExpires(contactExpires: 30, headerExpires: null), isNull);
    });

    test('clamps to maximum', () {
      expect(p.grantExpires(contactExpires: 99999, headerExpires: null), 7200);
    });
  });

  group('RegistrarMaintainer', () {
    test('removes expired bindings on tick', () async {
      final t = FakeTransport();
      final clients = {
        'old': testClient('old', t)
          ..expiresAt = DateTime.now().subtract(const Duration(seconds: 1)),
        'fresh': testClient('fresh', t)
          ..expiresAt = DateTime.now().add(const Duration(minutes: 5)),
      };
      var qualified = 0;
      final m = RegistrarMaintainer(
        clients: clients,
        // Reply immediately so 'fresh' isn't evicted by the missed-qualify guard.
        qualify: (c) {
          qualified++;
          RegistrarMaintainer.onQualifyResponse(c);
        },
        interval: const Duration(milliseconds: 5),
      )..start();

      await Future<void>.delayed(const Duration(milliseconds: 80));
      m.stop();
      expect(clients.containsKey('old'), isFalse);
      expect(clients.containsKey('fresh'), isTrue);
      expect(qualified, greaterThanOrEqualTo(1));
    });

    test('evicts a client after maxMissedQualify rounds with no response',
        () async {
      final t = FakeTransport();
      final clients = {'silent': testClient('silent', t)};
      // Never call onQualifyResponse, so missedQualifyCount keeps growing.
      final m = RegistrarMaintainer(
        clients: clients,
        qualify: (_) {/* silently drop */},
        interval: const Duration(milliseconds: 5),
        maxMissedQualify: 2,
      )..start();

      await Future<void>.delayed(const Duration(milliseconds: 50));
      m.stop();
      expect(clients.containsKey('silent'), isFalse);
    });

    test('onQualifyResponse resets miss count', () async {
      final t = FakeTransport();
      final c = testClient('keepalive', t);
      final clients = {'keepalive': c};
      final m = RegistrarMaintainer(
        clients: clients,
        qualify: (cl) {
          // Simulate immediate UA reply.
          RegistrarMaintainer.onQualifyResponse(cl);
        },
        interval: const Duration(milliseconds: 5),
        maxMissedQualify: 2,
      )..start();

      await Future<void>.delayed(const Duration(milliseconds: 50));
      m.stop();
      expect(clients.containsKey('keepalive'), isTrue);
      expect(c.missedQualifyCount, 0);
    });
  });
}
