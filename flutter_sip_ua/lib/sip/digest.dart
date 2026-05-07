/// Client side of RFC 2617 / RFC 3261 §22.4 digest authentication.
///
/// Computes the `Authorization` (or `Proxy-Authorization`) header value in
/// response to a 401/407 challenge from the server. Algorithm matches the
/// server-side verifier in `lib/proxy/digest_auth.dart` of dart-pbx
/// (MD5, qop=auth).
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

class DigestChallenge {
  DigestChallenge({
    required this.realm,
    required this.nonce,
    this.qop,
    this.algorithm = 'MD5',
    this.opaque,
    this.stale = false,
  });

  factory DigestChallenge.fromParams(Map<String, String> p) => DigestChallenge(
    realm: p['realm'] ?? '',
    nonce: p['nonce'] ?? '',
    qop: p['qop'],
    algorithm: p['algorithm'] ?? 'MD5',
    opaque: p['opaque'],
    stale: (p['stale'] ?? '').toLowerCase() == 'true',
  );

  final String realm;
  final String nonce;
  final String? qop;
  final String algorithm;
  final String? opaque;
  final bool stale;
}

class DigestClient {
  DigestClient({Random? rng}) : _rng = rng ?? Random.secure();

  final Random _rng;
  int _nc = 0;

  /// Builds the value (without the leading `Digest `) for an Authorization
  /// header given a [challenge] and credentials. The caller writes:
  ///   Authorization: Digest <returned value>
  String authorize({
    required DigestChallenge challenge,
    required String username,
    required String password,
    required String method,
    required String uri,
  }) {
    final ha1 = _md5('$username:${challenge.realm}:$password');
    final ha2 = _md5('$method:$uri');
    String response;
    final parts = <String>[
      'username="$username"',
      'realm="${challenge.realm}"',
      'nonce="${challenge.nonce}"',
      'uri="$uri"',
      'algorithm=${challenge.algorithm}',
    ];

    final qop = _pickQop(challenge.qop);
    if (qop == 'auth') {
      _nc++;
      final ncHex = _nc.toRadixString(16).padLeft(8, '0');
      final cnonce = _cnonce();
      response = _md5('$ha1:${challenge.nonce}:$ncHex:$cnonce:auth:$ha2');
      parts
        ..add('qop=auth')
        ..add('nc=$ncHex')
        ..add('cnonce="$cnonce"');
    } else {
      response = _md5('$ha1:${challenge.nonce}:$ha2');
    }
    parts.add('response="$response"');
    if (challenge.opaque != null) {
      parts.add('opaque="${challenge.opaque}"');
    }
    return parts.join(', ');
  }

  String? _pickQop(String? qop) {
    if (qop == null || qop.isEmpty) return null;
    final options = qop.split(',').map((e) => e.trim().toLowerCase()).toList();
    if (options.contains('auth')) return 'auth';
    return null;
  }

  String _cnonce() {
    final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static String _md5(String s) => md5.convert(utf8.encode(s)).toString();
}
