// Breakout Gateway Control Function (BGCF) — TS 24.229 §5.6.
//
// The BGCF picks an outbound trunk for sessions whose terminating side
// is not in the IMS. It sits between the S-CSCF and the actual gateway
// (an IBCF for IMS-to-IMS or a media gateway / PSTN softswitch like
// Asterisk for IMS-to-PSTN). In our deployment "off-net" usually means
// "Asterisk", so the BGCF's route table maps domains and Tel URI
// prefixes to one or more trunk URIs.
//
// Responsibilities implemented here:
//
//   * Pick a trunk based on the Request-URI domain (sip / tel) or a
//     numeric prefix on the user portion.
//   * Strip private IMS-only headers before handing the request to the
//     trunk (P-Asserted-Identity, P-Charging-*, P-Visited-Network-ID,
//     P-Access-Network-Info, History-Info, P-Profile-Key). These are
//     trust-domain artifacts that should not leak outside the home net.
//   * Add a Record-Route pointing back at the BGCF so 18x/2xx responses
//     traverse it (and we can apply the same header-strip in reverse on
//     responses if needed in the future).
//   * Synthesise a 404 (or 503 if all trunks are down) when no route.

import 'package:dart_pbx/logging.dart';
import 'package:dart_pbx/proxy/sip_helpers.dart' as h;
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/transports/transport.dart';

/// One outbound trunk known to the BGCF.
class BgcfTrunk {
  BgcfTrunk({
    required this.name,
    required this.host,
    required this.port,
    this.transport = 'UDP',
    this.priority = 100,
  });

  /// Friendly identifier, used in logs and Record-Route.
  final String name;
  final String host;
  final int port;
  final String transport;

  /// Lower = higher priority (used when multiple trunks match).
  final int priority;

  String get sipUri => 'sip:$host:$port;transport=$transport;lr';
}

/// A route rule: when a request matches, send it via [trunk].
class BgcfRoute {
  BgcfRoute({
    required this.trunk,
    this.domain,
    this.numberPrefix,
    this.scheme,
  });

  /// Trunk to use for matching requests.
  final BgcfTrunk trunk;

  /// Match Request-URI host (case-insensitive). Null = any.
  final String? domain;

  /// Match the user portion starting with this string (e.g. `+1` for
  /// North-American numbers, `00` for international, `911` for
  /// emergency). Null = any.
  final String? numberPrefix;

  /// Match the URI scheme (sip, sips, tel). Null = any.
  final String? scheme;

  bool matches({
    required String? uriScheme,
    required String? uriUser,
    required String? uriHost,
  }) {
    if (scheme != null &&
        (uriScheme == null ||
            scheme!.toLowerCase() != uriScheme.toLowerCase())) {
      return false;
    }
    if (domain != null) {
      if (uriHost == null) return false;
      if (uriHost.toLowerCase() != domain!.toLowerCase()) return false;
    }
    if (numberPrefix != null) {
      if (uriUser == null) return false;
      if (!uriUser.startsWith(numberPrefix!)) return false;
    }
    return true;
  }
}

class Bgcf {
  Bgcf({
    required this.host,
    required this.port,
    required this.transport,
    List<BgcfRoute>? routes,
    BgcfTrunk? defaultTrunk,
  })  : _routes = (routes ?? const []).toList()
          ..sort((a, b) => a.trunk.priority.compareTo(b.trunk.priority)),
        _defaultTrunk = defaultTrunk;

  /// BGCF own listening address (used in Record-Route).
  final String host;
  final int port;
  final String transport;

  final List<BgcfRoute> _routes;
  final BgcfTrunk? _defaultTrunk;

  /// IMS-internal headers stripped before handing the request to a
  /// non-IMS trunk. Per 3GPP TS 24.229 §4.4 / §5.10.
  static const _privateImsHeaders = <String>[
    'P-Asserted-Identity',
    'P-Preferred-Identity',
    'P-Visited-Network-ID',
    'P-Access-Network-Info',
    'P-Charging-Vector',
    'P-Charging-Function-Addresses',
    'P-Profile-Key',
    'P-Served-User',
    'P-Early-Media',
    'History-Info',
    'Privacy',
    'Service-Route',
  ];

  String get _recordRouteUri => 'sip:bgcf@$host:$port;transport=$transport;lr';

  /// Selects the trunk for [request]. Returns null when no route matches
  /// (caller should generate 404).
  BgcfTrunk? selectTrunk(SipMsg request) {
    final reqLine = request.Req.Src ?? '';
    final parsed = _parseRequestUri(reqLine);
    for (final r in _routes) {
      if (r.matches(
          uriScheme: parsed.scheme,
          uriUser: parsed.user,
          uriHost: parsed.host)) {
        return r.trunk;
      }
    }
    return _defaultTrunk;
  }

  /// Forwards [request] to the selected trunk via [send]. Returns true on
  /// success, false when no route is available (caller may then generate
  /// the 404 itself).
  bool forward(
    SipMsg request, {
    required void Function(String raw, {String? destIp, int? destPort}) send,
  }) {
    final trunk = selectTrunk(request);
    if (trunk == null) {
      Log.warn(
          'ims.bgcf', 'no route for ${request.Req.Method} ${request.Req.Src}');
      return false;
    }

    final raw = request.src ?? '';
    final parts = h.splitMessage(raw);
    final headers = List<String>.from(parts.headers);

    // Strip private IMS headers before they leave the trust domain.
    for (final name in _privateImsHeaders) {
      headers.removeWhere((line) {
        final l = line.toLowerCase();
        return l.startsWith('${name.toLowerCase()}:') ||
            l.startsWith('${name.toLowerCase()} ');
      });
    }

    // Record-Route ourselves so responses retrace the path.
    h.addRecordRoute(headers, _recordRouteUri);

    final outRaw = h.joinMessage(headers, parts.body);
    Log.debug('ims.bgcf',
        '${request.Req.Method} → trunk ${trunk.name} (${trunk.host}:${trunk.port})');
    send(outRaw, destIp: trunk.host, destPort: trunk.port);
    return true;
  }
}

/// Parsed Request-URI bits we care about for routing.
class _RequestUri {
  _RequestUri(this.scheme, this.user, this.host);
  final String? scheme;
  final String? user;
  final String? host;
}

_RequestUri _parseRequestUri(String requestLine) {
  // Request-Line = METHOD SP Request-URI SP SIP/2.0
  final firstSp = requestLine.indexOf(' ');
  if (firstSp < 0) return _RequestUri(null, null, null);
  final lastSp = requestLine.lastIndexOf(' ');
  if (lastSp <= firstSp) return _RequestUri(null, null, null);
  final uri = requestLine.substring(firstSp + 1, lastSp).trim();

  final colon = uri.indexOf(':');
  if (colon < 0) return _RequestUri(null, null, null);
  final scheme = uri.substring(0, colon).toLowerCase();
  final rest = uri.substring(colon + 1);

  if (scheme == 'tel') {
    // tel:+1234567890;params
    final semi = rest.indexOf(';');
    final number = (semi < 0 ? rest : rest.substring(0, semi)).trim();
    return _RequestUri(scheme, number, null);
  }

  // sip[s]:user@host[:port][;params][?headers]
  // Strip any URI parameters / headers first.
  var body = rest;
  final qm = body.indexOf('?');
  if (qm >= 0) body = body.substring(0, qm);
  final sm = body.indexOf(';');
  if (sm >= 0) body = body.substring(0, sm);

  final at = body.indexOf('@');
  if (at < 0) {
    // No user portion: the whole body is host[:port].
    final colon2 = body.indexOf(':');
    final host = colon2 < 0 ? body : body.substring(0, colon2);
    return _RequestUri(scheme, null, host);
  }
  final user = body.substring(0, at);
  final hostPart = body.substring(at + 1);
  final colon2 = hostPart.indexOf(':');
  final host = colon2 < 0 ? hostPart : hostPart.substring(0, colon2);
  return _RequestUri(scheme, user, host);
}
