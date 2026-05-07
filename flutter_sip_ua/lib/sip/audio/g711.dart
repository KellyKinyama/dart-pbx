/// G.711 μ-law and A-law codec — pure Dart.
///
/// Port of the CCITT reference implementation as used by
/// `ipcjs/g711_flutter` (`lib/src/g711.dart`). Provides 16-bit linear PCM
/// to/from 8-bit μ-law (PCMU, payload type 0) or A-law (PCMA, payload
/// type 8).
library;

import 'dart:typed_data';

class G711 {
  G711._();

  // CCITT G.711 constants.
  static const int _signBit = 0x80;
  static const int _quantMask = 0x0F;
  static const int _segShift = 4;
  static const int _segMask = 0x70;
  static const int _bias = 0x84;
  static const int _clip = 8159;

  static const List<int> _segAend = [
    0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, //
  ];
  static const List<int> _segUend = [
    0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF, //
  ];

  static int _search(int val, List<int> table) {
    for (var i = 0; i < table.length; i++) {
      if (val <= table[i]) return i;
    }
    return table.length;
  }

  // ---------------------------------------------------------------------------
  // μ-law
  // ---------------------------------------------------------------------------

  /// Encode a single 16-bit signed PCM sample as 8-bit μ-law.
  static int linear2ulaw(int pcmVal) {
    var v = pcmVal >> 2;
    int mask;
    if (v < 0) {
      v = -v;
      mask = 0x7F;
    } else {
      mask = 0xFF;
    }
    if (v > _clip) v = _clip;
    v += _bias >> 2;

    final seg = _search(v, _segUend);
    if (seg >= 8) return (0x7F ^ mask) & 0xFF;
    final uval = (seg << 4) | ((v >> (seg + 1)) & 0x0F);
    return (uval ^ mask) & 0xFF;
  }

  /// Decode an 8-bit μ-law byte to a 16-bit signed PCM sample.
  static int ulaw2linear(int uVal) {
    var u = (~uVal) & 0xFF;
    var t = ((u & _quantMask) << 3) + _bias;
    t <<= (u & _segMask) >> _segShift;
    return (u & _signBit) != 0 ? (_bias - t) : (t - _bias);
  }

  // ---------------------------------------------------------------------------
  // A-law
  // ---------------------------------------------------------------------------

  /// Encode a single 16-bit signed PCM sample as 8-bit A-law.
  static int linear2alaw(int pcmVal) {
    var v = pcmVal >> 3;
    int mask;
    if (v >= 0) {
      mask = 0xD5;
    } else {
      mask = 0x55;
      v = -v - 1;
    }
    final seg = _search(v, _segAend);
    if (seg >= 8) return (0x7F ^ mask) & 0xFF;
    int aval = seg << _segShift;
    if (seg < 2) {
      aval |= (v >> 1) & _quantMask;
    } else {
      aval |= (v >> seg) & _quantMask;
    }
    return (aval ^ mask) & 0xFF;
  }

  /// Decode an 8-bit A-law byte to a 16-bit signed PCM sample.
  static int alaw2linear(int aVal) {
    var a = aVal ^ 0x55;
    var t = (a & _quantMask) << 4;
    final seg = (a & _segMask) >> _segShift;
    switch (seg) {
      case 0:
        t += 8;
        break;
      case 1:
        t += 0x108;
        break;
      default:
        t += 0x108;
        t <<= seg - 1;
    }
    return (a & _signBit) != 0 ? t : -t;
  }

  // ---------------------------------------------------------------------------
  // Buffer helpers
  // ---------------------------------------------------------------------------

  /// Encode a buffer of 16-bit signed PCM (host-order Int16) into μ-law.
  static Uint8List encodeUlaw(Int16List pcm) {
    final out = Uint8List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      out[i] = linear2ulaw(pcm[i]);
    }
    return out;
  }

  /// Encode a buffer of 16-bit signed PCM into A-law.
  static Uint8List encodeAlaw(Int16List pcm) {
    final out = Uint8List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      out[i] = linear2alaw(pcm[i]);
    }
    return out;
  }

  /// Decode μ-law back to Int16 PCM.
  static Int16List decodeUlaw(Uint8List ulaw) {
    final out = Int16List(ulaw.length);
    for (var i = 0; i < ulaw.length; i++) {
      out[i] = ulaw2linear(ulaw[i]);
    }
    return out;
  }

  /// Decode A-law back to Int16 PCM.
  static Int16List decodeAlaw(Uint8List alaw) {
    final out = Int16List(alaw.length);
    for (var i = 0; i < alaw.length; i++) {
      out[i] = alaw2linear(alaw[i]);
    }
    return out;
  }
}
