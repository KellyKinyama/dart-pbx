// IMS AKAv1-MD5 (RFC 3310) — server side.
//
// This is the authentication scheme actually used by 3GPP IMS handsets
// (VoLTE / VoNR). It is a *digest* exchange (RFC 2617 form), but the shared
// secret is not a static password — it is the RES output of the AKA
// algorithm run inside the (U)SIM/ISIM, and the nonce carries the AKA
// challenge (RAND || AUTN) the SIM needs to produce that RES.
//
// Flow:
//   1. S-CSCF asks the HSS for an Authentication Vector
//        AV = (RAND, AUTN, XRES, CK, IK)         (Cx MAR/MAA)
//      AUTN = (SQN XOR AK) || AMF || MAC-A.
//   2. S-CSCF sends 401 with WWW-Authenticate:
//        Digest realm="...", nonce=base64(RAND||AUTN),
//               algorithm=AKAv1-MD5, qop="auth"
//   3. UE pushes RAND/AUTN to the SIM. SIM verifies MAC, returns RES, CK, IK.
//   4. UE re-sends REGISTER with Authorization computed exactly as in RFC
//      2617 *but* using `passwd = RES` (raw bytes, not hex) as the secret in
//      HA1 = MD5(username : realm : RES_bytes_as_iso8859).
//   5. S-CSCF recovers the (RAND, AUTN, XRES) from the nonce, computes the
//      same HA1 using XRES, and checks the response.
//
// Re-sync (AUTS) is recognised at parse time and surfaced to the caller so
// the HSS can advance SQN; the actual SQN-MS recovery is left to the HSS.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../proxy/digest_auth.dart' show DigestAuth;
import 'milenage.dart';

/// One IMS authentication vector. Produced by the HSS, consumed by the
/// S-CSCF to challenge a UE.
class AuthVector {
  AuthVector({
    required this.rand,
    required this.autn,
    required this.xres,
    required this.ck,
    required this.ik,
  });

  final Uint8List rand; // 16 bytes
  final Uint8List autn; // 16 bytes  = (SQN XOR AK) || AMF || MAC-A
  final Uint8List xres; //  8 bytes  (Milenage f2)
  final Uint8List ck; // 16 bytes
  final Uint8List ik; // 16 bytes

  /// Builds the `nonce` parameter value for an AKAv1-MD5 challenge:
  /// base64( RAND (16) || AUTN (16) ).
  String get nonceB64 {
    final buf = Uint8List(32)
      ..setRange(0, 16, rand)
      ..setRange(16, 32, autn);
    return base64.encode(buf);
  }

  /// Generate an AV for the given subscriber.
  ///
  /// [sqn] is the 48-bit sequence number the HSS keeps per IMPI; the caller
  /// is responsible for incrementing it (TS 33.102 §6.3.2). [amf] defaults
  /// to two zero bytes which is fine for non-emergency, non-resync use.
  static AuthVector generate({
    required Uint8List k,
    required Uint8List opc,
    required Uint8List rand,
    required Uint8List sqn,
    Uint8List? amf,
  }) {
    final amfBytes = amf ?? Uint8List(2);
    final m = Milenage(opc).run(k: k, rand: rand, sqn: sqn, amf: amfBytes);
    // AUTN = (SQN XOR AK) || AMF || MAC-A      — TS 33.102 §6.3.2
    final autn = Uint8List(16);
    for (var i = 0; i < 6; i++) {
      autn[i] = sqn[i] ^ m.ak[i];
    }
    autn.setRange(6, 8, amfBytes);
    autn.setRange(8, 16, m.macA);
    return AuthVector(
      rand: Uint8List.fromList(rand),
      autn: autn,
      xres: m.res,
      ck: m.ck,
      ik: m.ik,
    );
  }
}

/// Result of verifying a UE's Authorization header against a stored AV.
enum AkaResult {
  /// Header missing or unparseable — challenge.
  missing,

  /// Header valid format but bad response, unknown nonce, etc. — challenge.
  failed,

  /// UE returned `auts` (resynchronisation token). HSS must run AUTS
  /// processing and issue a fresh AV with the recovered SQN_MS.
  resync,

  /// Authentication succeeded.
  ok,
}

class AkaVerification {
  AkaVerification(this.result, {this.av, this.auts, this.rand, this.impi});

  final AkaResult result;
  final AuthVector? av;
  final Uint8List? auts; // 14 bytes when [result] == resync
  final Uint8List? rand; // RAND we challenged with (for resync flow)
  final String? impi;
}

/// Server-side AKAv1-MD5 helper. Stateless from the protocol point of view
/// but holds an in-memory map from outstanding nonces to AVs so the verifier
/// can reconstruct XRES when the UE answers.
class AkaAuth {
  AkaAuth({
    required this.realm,
    Duration? avLifetime,
  }) : avLifetime = avLifetime ?? const Duration(minutes: 5);

  final String realm;
  final Duration avLifetime;
  final Random _rng = Random.secure();

  // nonce (the base64 string we put on the wire) → pending AV + timestamp.
  final Map<String, _PendingAv> _pending = {};

  /// Builds the `WWW-Authenticate` header value for an AKAv1-MD5 challenge.
  /// Caller has already obtained [av] from the HSS.
  String challengeHeaderValue(AuthVector av, {bool stale = false}) {
    final nonce = av.nonceB64;
    _pending[nonce] = _PendingAv(av, DateTime.now());
    _gc();
    final parts = <String>[
      'realm="$realm"',
      'qop="auth"',
      'nonce="$nonce"',
      'algorithm=AKAv1-MD5',
      // ck/ik are NOT carried on the wire (RFC 3310 §3.2): they are derived
      // by the SIM and consumed by the IPsec/TLS layer between UE and
      // P-CSCF. We expose them via [AkaVerification] for that purpose.
      if (stale) 'stale=true',
    ];
    return 'Digest ${parts.join(', ')}';
  }

  /// Verifies an `Authorization` header value. The value is the portion
  /// after the `Digest ` prefix and the colon (same as [DigestAuth.verify]).
  AkaVerification verify({
    required String? headerValue,
    required String method,
  }) {
    if (headerValue == null || headerValue.trim().isEmpty) {
      return AkaVerification(AkaResult.missing);
    }
    final params = DigestAuth.parseAuthParams(headerValue);
    if (params == null) return AkaVerification(AkaResult.failed);

    final username = _unquote(params['username']);
    final realmIn = _unquote(params['realm']);
    final nonce = _unquote(params['nonce']);
    final uri = _unquote(params['uri']);
    final response = _unquote(params['response']);
    final qop = params['qop'];
    final cnonce = _unquote(params['cnonce']);
    final nc = params['nc'];
    final autsB64 = _unquote(params['auts']);

    if (username == null || realmIn == null || nonce == null || uri == null) {
      return AkaVerification(AkaResult.failed);
    }
    if (realmIn != realm) return AkaVerification(AkaResult.failed);

    final pending = _pending[nonce];
    if (pending == null) return AkaVerification(AkaResult.failed);
    if (DateTime.now().difference(pending.issuedAt) > avLifetime) {
      _pending.remove(nonce);
      return AkaVerification(AkaResult.failed);
    }

    // Resynchronisation flow (RFC 3310 §3.4): UE returns `auts` instead of
    // computing a normal response.
    if (autsB64 != null && autsB64.isNotEmpty) {
      Uint8List? auts;
      try {
        auts = Uint8List.fromList(base64.decode(autsB64));
      } catch (_) {
        return AkaVerification(AkaResult.failed);
      }
      _pending.remove(nonce);
      return AkaVerification(
        AkaResult.resync,
        auts: auts,
        rand: pending.av.rand,
        impi: username,
      );
    }

    if (response == null) return AkaVerification(AkaResult.failed);

    // RFC 3310 §3.4: passwd in HA1 is the RES *as a binary string*. We feed
    // bytes of "username:realm:" concatenated with the raw RES octets to
    // MD5 — exactly what every reference implementation (Asterisk,
    // Kamailio, Open5GS) does.
    final ha1Input = BytesBuilder()
      ..add(utf8.encode('$username:$realm:'))
      ..add(pending.av.xres);
    final ha1 = _hex(md5.convert(ha1Input.toBytes()).bytes);

    final ha2 = _md5('$method:$uri');
    final String expected;
    if (qop == 'auth') {
      if (cnonce == null || nc == null) {
        return AkaVerification(AkaResult.failed);
      }
      expected = _md5('$ha1:$nonce:$nc:$cnonce:auth:$ha2');
    } else if (qop == null || qop.isEmpty) {
      expected = _md5('$ha1:$nonce:$ha2');
    } else {
      return AkaVerification(AkaResult.failed);
    }

    if (!_timingSafeEqual(expected, response.toLowerCase())) {
      return AkaVerification(AkaResult.failed);
    }
    // Single-use: a successful AV is consumed.
    _pending.remove(nonce);
    return AkaVerification(
      AkaResult.ok,
      av: pending.av,
      impi: username,
    );
  }

  /// Random 16-byte RAND. Helper for HSS unit tests.
  Uint8List newRand() {
    final b = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      b[i] = _rng.nextInt(256);
    }
    return b;
  }

  void _gc() {
    final cutoff = DateTime.now().subtract(avLifetime);
    _pending.removeWhere((_, v) => v.issuedAt.isBefore(cutoff));
  }

  static String? _unquote(String? v) {
    if (v == null) return null;
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      return v.substring(1, v.length - 1);
    }
    return v;
  }
}

class _PendingAv {
  _PendingAv(this.av, this.issuedAt);
  final AuthVector av;
  final DateTime issuedAt;
}

String _md5(String input) => md5.convert(utf8.encode(input)).toString();

String _hex(List<int> bytes) {
  const h = '0123456789abcdef';
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(h[(b >> 4) & 0xf]);
    sb.write(h[b & 0xf]);
  }
  return sb.toString();
}

bool _timingSafeEqual(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}
