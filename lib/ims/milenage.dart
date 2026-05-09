// 3GPP TS 35.205 / 35.206 — Milenage authentication algorithm set.
//
// Milenage is the example AKA algorithm specified by 3GPP. It is used by
// every commercial USIM/ISIM and by the HSS to derive the authentication
// vector (RAND, AUTN, XRES, CK, IK) used in IMS AKAv1-MD5 (RFC 3310).
//
// Inputs (TS 35.206 §3):
//   K   — 128-bit subscriber key (stored on the (U)SIM and in the HSS)
//   RAND— 128-bit random challenge (HSS-generated)
//   SQN — 48-bit sequence number (HSS-side counter)
//   AMF — 16-bit Authentication Management Field
//   OP  — 128-bit operator variant key (per-operator constant)
//   OPc — 128-bit derived key = E_K(OP) XOR OP (TS 35.206 §4.1).
//         Many HSS deployments store OPc directly so OP never leaves the
//         operator's secure environment.
//
// Outputs:
//   f1 (MAC-A)  — 64-bit network-authentication MAC
//   f1* (MAC-S) — 64-bit re-synch MAC (resync flow)
//   f2 (RES)    — 64-bit response (the value the UE returns; XRES on the
//                 HSS side is the same value computed in advance)
//   f3 (CK)     — 128-bit cipher key
//   f4 (IK)     — 128-bit integrity key
//   f5 (AK)     — 48-bit anonymity key (XOR'd with SQN inside AUTN)
//
// Verified against TS 35.207 Test Set 1.

import 'dart:typed_data';

import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/api.dart';

/// Result of one Milenage run for a (K, OPc, RAND, SQN, AMF) tuple.
class MilenageOutputs {
  MilenageOutputs({
    required this.macA,
    required this.macS,
    required this.res,
    required this.ck,
    required this.ik,
    required this.ak,
    required this.akStar,
  });

  final Uint8List macA; // 8 bytes  (f1)
  final Uint8List macS; // 8 bytes  (f1*)
  final Uint8List res; // 8 bytes  (f2)
  final Uint8List ck; // 16 bytes (f3)
  final Uint8List ik; // 16 bytes (f4)
  final Uint8List ak; // 6 bytes  (f5)
  final Uint8List akStar; // 6 bytes  (f5*, re-sync)
}

class Milenage {
  /// Per-operator OPc. In production this is computed once from OP and K
  /// and stored. Use [deriveOpc] to compute it from OP if needed.
  final Uint8List opc;

  Milenage(this.opc) {
    if (opc.length != 16) {
      throw ArgumentError('OPc must be 16 bytes');
    }
  }

  /// Computes OPc = E_K(OP) XOR OP (TS 35.206 §4.1).
  static Uint8List deriveOpc(Uint8List k, Uint8List op) {
    if (k.length != 16) throw ArgumentError('K must be 16 bytes');
    if (op.length != 16) throw ArgumentError('OP must be 16 bytes');
    final encOp = _aesEncrypt(k, op);
    return _xor(encOp, op);
  }

  /// Runs Milenage. Returns f1..f5 as defined in TS 35.206 §4.
  MilenageOutputs run({
    required Uint8List k,
    required Uint8List rand,
    required Uint8List sqn, // 6 bytes
    required Uint8List amf, // 2 bytes
  }) {
    if (k.length != 16) throw ArgumentError('K must be 16 bytes');
    if (rand.length != 16) throw ArgumentError('RAND must be 16 bytes');
    if (sqn.length != 6) throw ArgumentError('SQN must be 6 bytes');
    if (amf.length != 2) throw ArgumentError('AMF must be 2 bytes');

    // TEMP = E_K(RAND XOR OPc)
    final temp = _aesEncrypt(k, _xor(rand, opc));

    // IN1 = SQN || AMF || SQN || AMF  (16 bytes)
    final in1 = Uint8List(16);
    in1.setRange(0, 6, sqn);
    in1.setRange(6, 8, amf);
    in1.setRange(8, 14, sqn);
    in1.setRange(14, 16, amf);

    // Constants c1..c5 (TS 35.206 §4.1). c1 is the all-zero block; c2..c5
    // place small integers in the last byte.
    final c1 = Uint8List(16);
    final c2 = Uint8List(16)..[15] = 1;
    final c3 = Uint8List(16)..[15] = 2;
    final c4 = Uint8List(16)..[15] = 4;
    final c5 = Uint8List(16)..[15] = 8;

    // Rotation amounts (in bits): r1=64, r2=0, r3=32, r4=64, r5=96.
    // Per TS 35.206 §4.1 the rotation is "toward the most significant
    // bit". With byte 0 as MSB, that's a left-rotation: the byte at
    // position [byteRot] ends up at position 0. Implementation matches
    // the 3GPP reference C code in Annex 3 (Open5GS / OAI).
    Uint8List rot(Uint8List b, int bits) {
      final byteRot = (bits ~/ 8) % 16;
      final out = Uint8List(16);
      for (var i = 0; i < 16; i++) {
        out[i] = b[(i + byteRot) % 16];
      }
      return out;
    }

    // OUT1 = E_K(TEMP XOR rot(IN1 XOR OPc, r1) XOR c1) XOR OPc
    final out1Input = _xor(_xor(temp, rot(_xor(in1, opc), 64)), c1);
    final out1 = _xor(_aesEncrypt(k, out1Input), opc);

    // OUT2 = E_K(rot(TEMP XOR OPc, r2) XOR c2) XOR OPc
    final out2 = _xor(
      _aesEncrypt(k, _xor(rot(_xor(temp, opc), 0), c2)),
      opc,
    );

    // OUT3 = E_K(rot(TEMP XOR OPc, r3) XOR c3) XOR OPc
    final out3 = _xor(
      _aesEncrypt(k, _xor(rot(_xor(temp, opc), 32), c3)),
      opc,
    );

    // OUT4 = E_K(rot(TEMP XOR OPc, r4) XOR c4) XOR OPc
    final out4 = _xor(
      _aesEncrypt(k, _xor(rot(_xor(temp, opc), 64), c4)),
      opc,
    );

    // OUT5 = E_K(rot(TEMP XOR OPc, r5) XOR c5) XOR OPc
    final out5 = _xor(
      _aesEncrypt(k, _xor(rot(_xor(temp, opc), 96), c5)),
      opc,
    );

    return MilenageOutputs(
      macA: Uint8List.fromList(out1.sublist(0, 8)),
      macS: Uint8List.fromList(out1.sublist(8, 16)),
      // TS 35.206 §4.1: f2 (RES) = OUT2[8..15],  f5 (AK) = OUT2[0..5].
      // Both are extracted from OUT2 — the AK is *not* derived from OUT5.
      // OUT5 is reserved for f5* (the AK used in the re-synchronisation
      // procedure).
      res: Uint8List.fromList(out2.sublist(8, 16)),
      ck: out3,
      ik: out4,
      ak: Uint8List.fromList(out2.sublist(0, 6)),
      akStar: Uint8List.fromList(out5.sublist(0, 6)),
    );
  }
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

Uint8List _aesEncrypt(Uint8List key, Uint8List block) {
  final cipher = AESEngine()..init(true, KeyParameter(key));
  final out = Uint8List(16);
  cipher.processBlock(block, 0, out, 0);
  return out;
}

Uint8List _xor(Uint8List a, Uint8List b) {
  final out = Uint8List(a.length);
  for (var i = 0; i < a.length; i++) {
    out[i] = a[i] ^ b[i];
  }
  return out;
}

/// Convenience: parse a hex string ("aabbcc..." or "aa bb cc...") to bytes.
Uint8List hexToBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'\s'), '');
  if (clean.length.isOdd) {
    throw ArgumentError('odd-length hex string');
  }
  final out = Uint8List(clean.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(clean.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Convenience: format bytes as lowercase hex with no separator.
String bytesToHex(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}
