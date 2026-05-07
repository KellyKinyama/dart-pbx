import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_sip_ua/sip/audio/g711.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('G.711 μ-law', () {
    test('encode/decode silence stays near zero', () {
      final pcm = Int16List(160);
      final back = G711.decodeUlaw(G711.encodeUlaw(pcm));
      for (final s in back) {
        expect(s.abs(), lessThan(8));
      }
    });

    test('decodeUlaw is symmetric around the sign bit', () {
      for (var b = 0; b < 256; b++) {
        expect(G711.ulaw2linear(b).abs(), G711.ulaw2linear(b ^ 0x80).abs());
      }
    });

    test('a half-scale 1 kHz sine round-trips with bounded error', () {
      final pcm = Int16List(160);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = (16000 * sin(2 * pi * 1000 * i / 8000)).round();
      }
      final round = G711.decodeUlaw(G711.encodeUlaw(pcm));
      var maxErr = 0;
      for (var i = 0; i < pcm.length; i++) {
        final e = (pcm[i] - round[i]).abs();
        if (e > maxErr) maxErr = e;
      }
      expect(maxErr, lessThan(1000));
    });

    test('produces byte values in 0..255 for a full-range ramp', () {
      final pcm = Int16List.fromList(
        List<int>.generate(160, (i) => (i - 80) * 400),
      );
      final ulaw = G711.encodeUlaw(pcm);
      expect(ulaw.every((b) => b >= 0 && b <= 255), isTrue);
    });
  });

  group('G.711 A-law', () {
    test('encode/decode silence stays near zero', () {
      final pcm = Int16List(160);
      final back = G711.decodeAlaw(G711.encodeAlaw(pcm));
      for (final s in back) {
        expect(s.abs(), lessThan(16));
      }
    });

    test('decodeAlaw is symmetric around the sign bit', () {
      for (var b = 0; b < 256; b++) {
        expect(G711.alaw2linear(b).abs(), G711.alaw2linear(b ^ 0x80).abs());
      }
    });

    test('encodes a 20 ms frame as 160 bytes', () {
      final pcm = Int16List(160);
      for (var i = 0; i < pcm.length; i++) {
        pcm[i] = (8000 * sin(2 * pi * 440 * i / 8000)).round();
      }
      final alaw = G711.encodeAlaw(pcm);
      expect(alaw, hasLength(160));
      expect(alaw, isA<Uint8List>());
    });
  });
}
