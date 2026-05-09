// 3GPP / IETF SIP header helpers used by the IMS CSCFs.
//
// Spec map:
//   * Path                        — RFC 3327
//   * Service-Route               — RFC 3608
//   * P-Asserted-Identity         — RFC 3325
//   * P-Preferred-Identity        — RFC 3325
//   * Privacy                     — RFC 3323
//   * P-Visited-Network-ID        — RFC 3455 §4.3
//   * P-Access-Network-Info       — RFC 3455 §4.4
//   * P-Charging-Vector           — RFC 3455 §4.6
//   * P-Charging-Function-Addresses — RFC 3455 §4.5
//
// All of these are simple "add one well-known header" operations; the
// intelligence lives in the CSCFs that decide *when* to add them. Header
// rewriting is performed against the raw header line list produced by
// [splitMessage] in `proxy/sip_helpers.dart`, so behaviour stays identical
// to the rest of the proxy code.

import 'dart:math';

import 'package:dart_pbx/proxy/sip_helpers.dart' as h;

/// Inserts a Path header (RFC 3327) right after the request line. This is
/// done by the P-CSCF on REGISTER so that subsequent in-dialog requests
/// from the S-CSCF transit back through it.
void addPath(List<String> headers, String pathUri) {
  headers.insert(1, 'Path: <$pathUri>');
}

/// Returns the Path URIs (top-down) from a REGISTER 200 OK. The S-CSCF
/// records these so it can build a reverse route to the UE.
List<String> readPaths(List<String> headers) => _readUriHeader(headers, 'Path');

/// Inserts a Service-Route header (RFC 3608). Sent by the S-CSCF in the
/// 200 OK to REGISTER. The P-CSCF stores it and pre-loads it as a Route
/// header set on every subsequent originating request from that UE.
void addServiceRoute(List<String> headers, String routeUri) {
  headers.insert(1, 'Service-Route: <$routeUri>');
}

/// Returns the Service-Route URIs (top-down) from a 200 OK to REGISTER.
List<String> readServiceRoute(List<String> headers) =>
    _readUriHeader(headers, 'Service-Route');

/// Asserts the user's identity (RFC 3325). The P-CSCF strips any UE-
/// supplied P-Asserted-Identity / P-Preferred-Identity and replaces them
/// with the network-asserted IMPU.
void setPAssertedIdentity(List<String> headers, String aor, {String? telUri}) {
  removeHeader(headers, 'P-Asserted-Identity');
  removeHeader(headers, 'P-Preferred-Identity');
  final value = telUri == null ? '<$aor>' : '<$aor>, <$telUri>';
  headers.insert(1, 'P-Asserted-Identity: $value');
}

/// Adds a P-Visited-Network-ID header (RFC 3455 §4.3). Inserted by the
/// P-CSCF on REGISTER so the home network knows where the UE is roaming.
void addPVisitedNetworkId(List<String> headers, String networkId) {
  headers.insert(1, 'P-Visited-Network-ID: "$networkId"');
}

/// Adds a P-Charging-Vector header with a freshly minted ICID (RFC 3455
/// §4.6). The first IMS entity in the path generates the ICID; subsequent
/// hops echo it. We insert one if no Charging-Vector is present.
void ensureChargingVector(List<String> headers,
    {String? originatingIoi, String? terminatingIoi}) {
  for (final line in headers) {
    final lower = line.toLowerCase();
    if (lower.startsWith('p-charging-vector:')) return;
  }
  final icid = _generateIcid();
  final parts = <String>['icid-value="$icid"'];
  if (originatingIoi != null) parts.add('orig-ioi=$originatingIoi');
  if (terminatingIoi != null) parts.add('term-ioi=$terminatingIoi');
  headers.insert(1, 'P-Charging-Vector: ${parts.join('; ')}');
}

/// Adds a P-Charging-Function-Addresses header (RFC 3455 §4.5).
void addPChargingFunctionAddresses(List<String> headers,
    {required String ccf, String? ecf}) {
  final parts = <String>['ccf=$ccf'];
  if (ecf != null) parts.add('ecf=$ecf');
  headers.insert(1, 'P-Charging-Function-Addresses: ${parts.join('; ')}');
}

/// Reads (and removes) the P-Access-Network-Info header value supplied by
/// the UE (RFC 3455 §4.4). RFC 3325 §9.1 says the P-CSCF MUST strip this
/// before forwarding outside the trust domain. Returns null when absent.
String? popPAccessNetworkInfo(List<String> headers) {
  for (var i = 0; i < headers.length; i++) {
    final line = headers[i];
    final lower = line.toLowerCase();
    if (lower.startsWith('p-access-network-info:')) {
      final colon = line.indexOf(':');
      headers.removeAt(i);
      return line.substring(colon + 1).trim();
    }
  }
  return null;
}

/// Removes every header with [name] (case-insensitive). Mirrors the
/// existing `proxy/sip_helpers.dart` helper but mutates the list in place.
void removeHeader(List<String> headers, String name) {
  final lower = name.toLowerCase();
  headers.removeWhere((line) {
    final l = line.toLowerCase();
    return l.startsWith('$lower:') || l.startsWith('$lower ');
  });
}

/// Pushes one or more Route headers in front of any existing Route, in the
/// order given (the first URI in [routeUris] becomes the topmost Route).
/// Used by the P-CSCF to load the stored Service-Route on outbound
/// requests, per RFC 3608 §5.3.
void prependRouteSet(List<String> headers, List<String> routeUris) {
  for (final uri in routeUris.reversed) {
    headers.insert(1, 'Route: <$uri>');
  }
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

List<String> _readUriHeader(List<String> headers, String name) {
  final out = <String>[];
  final lower = name.toLowerCase();
  for (final line in headers) {
    final l = line.toLowerCase();
    if (!(l.startsWith('$lower:') || l.startsWith('$lower '))) continue;
    final colon = line.indexOf(':');
    if (colon < 0) continue;
    final value = line.substring(colon + 1);
    for (final entry in _splitCommaOutsideBrackets(value)) {
      final trimmed = entry.trim();
      final lt = trimmed.indexOf('<');
      final gt = trimmed.lastIndexOf('>');
      if (lt >= 0 && gt > lt) {
        out.add(trimmed.substring(lt + 1, gt));
      } else if (trimmed.isNotEmpty) {
        out.add(trimmed);
      }
    }
  }
  return out;
}

List<String> _splitCommaOutsideBrackets(String value) {
  final out = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    if (c == '<') {
      depth++;
    } else if (c == '>') {
      depth--;
    } else if (c == ',' && depth == 0) {
      out.add(value.substring(start, i));
      start = i + 1;
    }
  }
  out.add(value.substring(start));
  return out;
}

final Random _rng = Random.secure();
String _generateIcid() {
  const alphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  final buf = StringBuffer();
  for (var i = 0; i < 24; i++) {
    buf.write(alphabet[_rng.nextInt(alphabet.length)]);
  }
  return buf.toString();
}

/// Convenience: pull the user portion out of a SIP/SIPS URI like
/// `<sip:alice@home.example.org;transport=UDP>`. Returns null if it can't.
String? sipUserOf(String uri) {
  var s = uri;
  final lt = s.indexOf('<');
  if (lt >= 0) {
    final gt = s.indexOf('>', lt);
    if (gt > lt) s = s.substring(lt + 1, gt);
  }
  final colon = s.indexOf(':');
  if (colon < 0) return null;
  s = s.substring(colon + 1);
  final at = s.indexOf('@');
  if (at < 0) return null;
  return s.substring(0, at);
}

/// Returns the AOR form `sip:user@host` of a Contact / To / From URI.
String aorOf(String uri, {required String defaultRealm}) {
  final user = sipUserOf(uri);
  if (user == null) return uri;
  return 'sip:$user@$defaultRealm';
}

/// Re-export of the local helper so callers don't need to import
/// proxy/sip_helpers solely for splitting.
({List<String> headers, String body}) splitMessage(String raw) =>
    h.splitMessage(raw);
String joinMessage(List<String> headers, String body) =>
    h.joinMessage(headers, body);
