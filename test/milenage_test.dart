// 3GPP TS 35.207 Milenage test vectors. Verifies our AES-based Milenage
// implementation against the standard test sets.

import 'package:dart_pbx/ims/milenage.dart';
import 'package:test/test.dart';

void main() {
  group('Milenage TS 35.207 Test Set 1', () {
    final k = hexToBytes('465b5ce8b199b49faa5f0a2ee238a6bc');
    final rand = hexToBytes('23553cbe9637a89d218ae64dae47bf35');
    final sqn = hexToBytes('ff9bb4d0b607');
    final amf = hexToBytes('b9b9');
    final op = hexToBytes('cdc202d5123e20f62b6d676ac72cb318');
    final expectedOpc = hexToBytes('cd63cb71954a9f4e48a5994e37a02baf');

    test('OPc derivation', () {
      final opc = Milenage.deriveOpc(k, op);
      expect(bytesToHex(opc), bytesToHex(expectedOpc));
    });

    test('f1..f5 outputs', () {
      final m = Milenage(expectedOpc);
      final out = m.run(k: k, rand: rand, sqn: sqn, amf: amf);
      expect(bytesToHex(out.macA), '4a9ffac354dfafb3', reason: 'f1 / MAC-A');
      expect(bytesToHex(out.res), 'a54211d5e3ba50bf', reason: 'f2 / RES');
      expect(bytesToHex(out.ck), 'b40ba9a3c58b2a05bbf0d987b21bf8cb',
          reason: 'f3 / CK');
      expect(bytesToHex(out.ik), 'f769bcd751044604127672711c6d3441',
          reason: 'f4 / IK');
      expect(bytesToHex(out.ak), 'aa689c648370', reason: 'f5 / AK');
    });
  });
}
