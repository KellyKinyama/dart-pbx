import 'package:dart_pbx/proxy/dialog.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  test('DialogId equality and hashCode are by value', () {
    final a = DialogId('cid', 'lt', 'rt');
    final b = DialogId('cid', 'lt', 'rt');
    final c = DialogId('cid', 'lt', 'OTHER');
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(c)));
  });

  test('DialogLayer.add / find by request both tag orderings', () {
    final layer = DialogLayer();
    final id = DialogId('cid-1', 'caller-tag', 'callee-tag');
    final d = Dialog(
      id: id,
      localUri: 'alice@x',
      remoteUri: 'bob@x',
      remoteTarget: 'sip:bob@1.2.3.4',
    );
    layer.add(d);

    final fromCaller = parse(wire([
      'BYE sip:x@h SIP/2.0',
      'Via: SIP/2.0/UDP h:5060',
      'Call-ID: cid-1',
      'From: <sip:a@h>;tag=caller-tag',
      'To: <sip:b@h>;tag=callee-tag',
      'CSeq: 2 BYE',
      'Content-Length: 0',
    ]));
    expect(layer.findFromRequest(fromCaller), same(d));

    final fromCallee = parse(wire([
      'BYE sip:x@h SIP/2.0',
      'Via: SIP/2.0/UDP h:5060',
      'Call-ID: cid-1',
      'From: <sip:b@h>;tag=callee-tag',
      'To: <sip:a@h>;tag=caller-tag',
      'CSeq: 2 BYE',
      'Content-Length: 0',
    ]));
    expect(layer.findFromRequest(fromCallee), same(d));
  });

  test('peerOf flips between caller and callee', () {
    final t = FakeTransport();
    final caller = testClient('alice', t);
    final callee = testClient('bob', t);
    final d = Dialog(
      id: DialogId('c', 'l', 'r'),
      localUri: 'alice@x',
      remoteUri: 'bob@x',
      remoteTarget: 'sip:bob@1.2.3.4',
      caller: caller,
      callee: callee,
    );
    expect(d.peerOf('alice'), same(callee));
    expect(d.peerOf('bob'), same(caller));
    expect(d.peerOf('eve'), isNull);
  });

  test('cancelSessionTimer is idempotent', () {
    final d = Dialog(
      id: DialogId('c', 'l', 'r'),
      localUri: 'a',
      remoteUri: 'b',
      remoteTarget: 'sip:b',
    );
    d.cancelSessionTimer();
    d.cancelSessionTimer();
    expect(d.sessionTimer, isNull);
  });
}
