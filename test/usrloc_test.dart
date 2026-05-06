import 'package:dart_pbx/services/usrloc.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  test('save / lookup / remove round-trip', () {
    final s = UsrLocService();
    final t = FakeTransport();
    final c = testClient('alice', t);
    s.save(c);
    expect(s.exists('alice'), isTrue);
    expect(s.lookup('alice'), same(c));
    expect(s.count, 1);
    expect(s.all().map((e) => e.number), ['alice']);

    expect(s.remove('alice'), isTrue);
    expect(s.exists('alice'), isFalse);
    expect(s.remove('alice'), isFalse);
  });

  test('save replaces an existing binding (re-REGISTER)', () {
    final s = UsrLocService();
    final t = FakeTransport();
    s.save(testClient('alice', t));
    final newer = testClient('alice', t);
    s.save(newer);
    expect(s.lookup('alice'), same(newer));
    expect(s.count, 1);
  });
}
