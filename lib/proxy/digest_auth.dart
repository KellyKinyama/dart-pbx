// SIP digest authentication helpers (RFC 3261 §22.4 + RFC 2617).
//
// This module provides the *server* side of digest auth (challenger +
// verifier). It is independent of the existing client-side implementation in
// `lib/digest_authentication.dart` (which is unused) but follows the same
// algorithm so a UA built with that client will interoperate.
//
// Algorithm: MD5, qop=auth (the universal SIP profile).
//   HA1      = MD5(username:realm:password)
//   HA2      = MD5(method:digest-uri)
//   response = MD5(HA1:nonce:nc:cnonce:qop:HA2)
//
// Nonces are HMAC-bound to the realm and a server secret with a timestamp so
// the verifier can detect replay/expiry without any per-nonce server state.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'auth_store.dart';

/// Result of verifying an Authorization / Proxy-Authorization header.
enum AuthResult {
  /// Header was missing — caller should issue a challenge.
  missing,

  /// Header present but malformed, unknown user, wrong response, etc.
  /// Caller should issue a fresh challenge (or 403 Forbidden after retries).
  failed,

  /// Header was a valid auth response *but* the embedded nonce has expired.
  /// Caller should issue a challenge with `stale=true` (RFC 2617 §3.2.1).
  stale,

  /// Authentication succeeded.
  ok,
}

class DigestAuth {
  DigestAuth({
    required this.realm,
    String? secret,
    this.nonceLifetime = const Duration(minutes: 5),
  }) : _secret = secret ?? _randomSecret();

  /// Realm advertised on every challenge.
  final String realm;

  /// Per-process secret used to sign/verify nonces. Defaults to a random
  /// 32-byte value generated at construction (so nonces don't survive across
  /// restarts — acceptable for a small PBX).
  final String _secret;

  /// How long a nonce remains valid before the verifier returns
  /// [AuthResult.stale].
  final Duration nonceLifetime;

  // ---------------------------------------------------------------------------
  // Challenge generation
  // ---------------------------------------------------------------------------

  /// Returns a fresh `WWW-Authenticate` (registrar) header value.
  String challengeHeaderValue({bool stale = false}) =>
      _buildChallenge(stale: stale);

  /// Returns a fresh `Proxy-Authenticate` (proxy) header value with the same
  /// algorithm. Identical body, the difference is just in the header name and
  /// matching response status code (401 vs 407).
  String proxyChallengeHeaderValue({bool stale = false}) =>
      _buildChallenge(stale: stale);

  String _buildChallenge({required bool stale}) {
    final nonce = _makeNonce();
    final parts = <String>[
      'realm="$realm"',
      'qop="auth"',
      'nonce="$nonce"',
      'algorithm=MD5',
      if (stale) 'stale=true',
    ];
    return 'Digest ${parts.join(', ')}';
  }

  // ---------------------------------------------------------------------------
  // Verification
  // ---------------------------------------------------------------------------

  /// Verifies a raw `Authorization` / `Proxy-Authorization` header value (the
  /// portion *after* the `Digest ` prefix and the colon). Returns the auth
  /// outcome.
  ///
  /// The caller supplies the request [method] (upper-case) and the body for
  /// `qop=auth-int` support. We currently only support `qop=auth` so [body]
  /// is ignored.
  AuthResult verify({
    required String? headerValue,
    required String method,
    required CredentialsStore credentials,
    String? body,
  }) {
    if (headerValue == null || headerValue.trim().isEmpty) {
      return AuthResult.missing;
    }
    final params = parseAuthParams(headerValue);
    if (params == null) return AuthResult.failed;

    final username = _unquote(params['username']);
    final realmIn = _unquote(params['realm']);
    final nonce = _unquote(params['nonce']);
    final uri = _unquote(params['uri']);
    final response = _unquote(params['response']);
    final qop = params['qop']; // not quoted on response
    final cnonce = _unquote(params['cnonce']);
    final nc = params['nc'];
    if (username == null ||
        realmIn == null ||
        nonce == null ||
        uri == null ||
        response == null) {
      return AuthResult.failed;
    }
    if (realmIn != realm) return AuthResult.failed;

    final nonceState = _verifyNonce(nonce);
    if (nonceState == _NonceState.invalid) return AuthResult.failed;

    final ha1 = credentials.ha1For(username, realm);
    if (ha1 == null) return AuthResult.failed;

    final ha2 = _md5('$method:$uri');
    final String expected;
    if (qop == 'auth') {
      if (cnonce == null || nc == null) return AuthResult.failed;
      expected = _md5('$ha1:$nonce:$nc:$cnonce:auth:$ha2');
    } else if (qop == null || qop.isEmpty) {
      // Legacy RFC 2069 mode.
      expected = _md5('$ha1:$nonce:$ha2');
    } else {
      // qop=auth-int not supported.
      return AuthResult.failed;
    }

    if (!_timingSafeEqual(expected, response.toLowerCase())) {
      return AuthResult.failed;
    }
    return nonceState == _NonceState.expired ? AuthResult.stale : AuthResult.ok;
  }

  // ---------------------------------------------------------------------------
  // Nonce: format = base64url( "<unixMillis>:<hmac>" )
  // hmac = first 16 bytes of MD5(secret + ":" + unixMillis + ":" + realm)
  // ---------------------------------------------------------------------------

  String _makeNonce() {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final mac = _md5('$_secret:$ts:$realm').substring(0, 32);
    return base64Url.encode(utf8.encode('$ts:$mac'));
  }

  _NonceState _verifyNonce(String nonce) {
    String decoded;
    try {
      decoded = utf8.decode(base64Url.decode(nonce));
    } catch (_) {
      return _NonceState.invalid;
    }
    final colon = decoded.indexOf(':');
    if (colon <= 0) return _NonceState.invalid;
    final tsStr = decoded.substring(0, colon);
    final mac = decoded.substring(colon + 1);
    final ts = int.tryParse(tsStr);
    if (ts == null) return _NonceState.invalid;
    final expectedMac = _md5('$_secret:$ts:$realm').substring(0, 32);
    if (!_timingSafeEqual(mac, expectedMac)) return _NonceState.invalid;
    final age = DateTime.now().millisecondsSinceEpoch - ts;
    if (age > nonceLifetime.inMilliseconds) return _NonceState.expired;
    return _NonceState.fresh;
  }

  // ---------------------------------------------------------------------------
  // Parameter parsing — handles `name="quoted, with comma" , name=token`.
  // ---------------------------------------------------------------------------

  /// Parses a `Digest k=v, k="v", ...` parameter list. Returns null if the
  /// value doesn't begin with the `Digest` scheme. Quoted values keep their
  /// surrounding quotes — call [_unquote] to strip them.
  static Map<String, String>? parseAuthParams(String headerValue) {
    var s = headerValue.trim();
    final lower = s.toLowerCase();
    if (!lower.startsWith('digest')) return null;
    s = s.substring(6).trim();
    final out = <String, String>{};
    var i = 0;
    while (i < s.length) {
      // Skip whitespace and commas.
      while (i < s.length && (s[i] == ' ' || s[i] == ',' || s[i] == '\t')) {
        i++;
      }
      if (i >= s.length) break;

      // Read name.
      final nameStart = i;
      while (i < s.length && s[i] != '=' && s[i] != ',') {
        i++;
      }
      final name = s.substring(nameStart, i).trim().toLowerCase();
      if (i >= s.length || s[i] != '=') {
        // Bare token without value; ignore.
        continue;
      }
      i++; // consume '='

      // Read value: quoted string or token.
      String value;
      if (i < s.length && s[i] == '"') {
        i++;
        final valStart = i;
        while (i < s.length && s[i] != '"') {
          if (s[i] == '\\' && i + 1 < s.length) i++;
          i++;
        }
        value = '"${s.substring(valStart, i)}"';
        if (i < s.length) i++; // consume closing quote
      } else {
        final valStart = i;
        while (i < s.length && s[i] != ',') {
          i++;
        }
        value = s.substring(valStart, i).trim();
      }
      out[name] = value;
    }
    return out;
  }

  static String? _unquote(String? v) {
    if (v == null) return null;
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      return v.substring(1, v.length - 1);
    }
    return v;
  }
}

enum _NonceState { invalid, fresh, expired }

String _md5(String input) => md5.convert(utf8.encode(input)).toString();

bool _timingSafeEqual(String a, String b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

String _randomSecret() {
  final r = Random.secure();
  final bytes = List<int>.generate(32, (_) => r.nextInt(256));
  return base64Url.encode(bytes);
}

/// Convenience: pre-compute HA1 for a (user, realm, password) triple. Storing
/// HA1 instead of the plaintext password is the recommended deployment per
/// RFC 2617 §4.13.
String computeHa1(String username, String realm, String password) =>
    _md5('$username:$realm:$password');
