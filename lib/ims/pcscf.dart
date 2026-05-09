// Proxy-CSCF (P-CSCF) — first SIP hop for the UE on the Gm reference point.
//
// Spec map:
//   * 3GPP TS 23.228 §4.6 (architecture)
//   * 3GPP TS 24.229 §5.2 (P-CSCF procedures)
//   * RFC 3327 (Path), RFC 3608 (Service-Route)
//   * RFC 3325 (P-Asserted-Identity, P-Preferred-Identity, Privacy)
//   * RFC 3455 (P-Visited-Network-ID, P-Access-Network-Info,
//                P-Charging-Vector, P-Charging-Function-Addresses)
//
// The P-CSCF is what every IMS UE registers with first; in a roaming
// scenario it sits in the visited network. In our collocated single-
// instance deployment all three CSCFs share one process, so the "Mw"
// interface between P/I/S is a Dart callback rather than a SIP hop. Only
// the P-CSCF puts a Via on the wire — the I-CSCF and S-CSCF mutate the
// message in place and pass it on. This is exactly how the OpenIMSCore /
// Kamailio "single CSCF" reference deployments behave; splitting the
// CSCFs across processes later is a matter of replacing the in-process
// callbacks with real SIP forwarding.
//
// Responsibilities implemented here:
//   * On REGISTER from UE → add Path, P-Visited-Network-ID, ICID, hand to
//     I-CSCF.
//   * On 200 OK to REGISTER from S-CSCF → record the Service-Route for
//     the AOR, strip Path, deliver to the UE.
//   * On any other request from the UE → enforce the previously-recorded
//     Service-Route as a preloaded Route set (RFC 3608 §5.3), assert the
//     IMPU as P-Asserted-Identity (RFC 3325), strip UE-supplied
//     P-Preferred-Identity / P-Access-Network-Info, then hand to the
//     S-CSCF (which the Service-Route points to).
//   * On a request *from* the network targeting one of our registered
//     UEs → deliver to the UE's transport binding.
//   * On responses from the network → pop our Via, send to the next.

import 'dart:async';

import 'package:dart_pbx/logging.dart';
import 'package:dart_pbx/proxy/sip_helpers.dart' as h;
import 'package:dart_pbx/sip_client.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/transports/transport.dart';

import 'ims_headers.dart' as ih;

/// Per-AOR P-CSCF state (Service-Route + transport binding).
class _PcscfBinding {
  _PcscfBinding({
    required this.transport,
    required this.contactUri,
    required this.serviceRoute,
    required this.expiresAt,
  });
  SipTransport transport;
  String contactUri;
  List<String> serviceRoute;
  DateTime expiresAt;
}

class Pcscf {
  Pcscf({
    required this.host,
    required this.port,
    required this.transport,
    required this.visitedNetworkId,
    required this.toIcscf,
    required this.toScscf,
    required this.proxyName,
  });

  /// Host & port advertised in Path / Record-Route / Via.
  final String host;
  final int port;

  /// The protocol token used in Path/Record-Route URIs (UDP/TCP/TLS/WS/WSS).
  final String transport;

  /// Visited-Network identifier (RFC 3455 §4.3).
  final String visitedNetworkId;

  /// Internal Mw callbacks. The P-CSCF hands originating REGISTERs to the
  /// I-CSCF and other originating requests directly to the S-CSCF (since
  /// the Service-Route already names the S-CSCF).
  void Function(SipMsg request, SipTransport inbound) toIcscf;
  void Function(SipMsg request, SipTransport inbound) toScscf;

  /// Used as a sent-by tag for our Via and as the proxy-name salt for
  /// any deterministic branches we might compute later.
  final String proxyName;

  /// AOR → binding. Populated from the 200 OK to REGISTER.
  final Map<String, _PcscfBinding> _bindings = {};

  /// Outstanding ICIDs by Call-ID so we can echo P-Charging-Vector
  /// consistently across the dialog.
  final Map<String, String> _icidByCallId = {};

  /// Transport binding for an AOR (used by the network side to deliver
  /// a request to the UE). Returns null when the AOR is not registered
  /// here.
  SipClient? lookup(String aor) {
    final b = _bindings[aor];
    if (b == null) return null;
    if (DateTime.now().isAfter(b.expiresAt)) {
      _bindings.remove(aor);
      return null;
    }
    return SipClient(aor, b.transport, contactUri: b.contactUri);
  }

  String get pathUri => 'sip:pcscf@$host:$port;transport=$transport;lr';

  String get recordRouteUri => 'sip:$host:$port;transport=$transport;lr';

  // -------------------------------------------------------------------------
  // From UE
  // -------------------------------------------------------------------------

  /// Entry point for every SIP request arriving from a UE on the Gm
  /// reference point.
  void onRequestFromUe(SipMsg request, SipTransport ueTransport) {
    final method = request.Req.Method?.toUpperCase();
    if (method == null) return;

    final raw = request.src ?? '';
    final parts = h.splitMessage(raw);
    final headers = List<String>.from(parts.headers);

    // RFC 3261 §16.6.3
    final mf = h.decrementMaxForwards(headers);
    if (mf == null) {
      _replyLocal(ueTransport, request, 483, 'Too Many Hops');
      return;
    }

    // P-CSCF inserts its own Via (RFC 3261 §16.6.5). Subsequent CSCFs in
    // collocated mode do *not* add Vias because they don't talk to the
    // wire.
    final branch = h.generateBranch();
    h.prependVia(
      headers,
      'Via: SIP/2.0/${transport.toUpperCase()} '
      '$host:$port;branch=$branch;rport',
    );

    // Record-Route on dialog-establishing requests so subsequent
    // in-dialog traffic comes back through us (TS 24.229 §5.2.7.3).
    if (_isDialogCreating(method)) {
      h.addRecordRoute(headers, recordRouteUri);
    }

    // Charging vector (RFC 3455 §4.6) — generate an ICID once per dialog.
    final callId = request.CallId.Value;
    if (callId != null) {
      _icidByCallId.putIfAbsent(callId, () => _newIcid());
    }
    ih.ensureChargingVector(headers);

    // RFC 3325 §9.1: the P-CSCF MUST strip P-Access-Network-Info before
    // forwarding outside the trust domain. We always strip it here and
    // re-emit it inside the trust domain only when needed.
    ih.popPAccessNetworkInfo(headers);
    ih.removeHeader(headers, 'P-Preferred-Identity');

    if (method == 'REGISTER') {
      // Path (RFC 3327): tells the registrar (S-CSCF) to record us so
      // future requests for this UE traverse the P-CSCF.
      ih.addPath(headers, pathUri);
      ih.addPVisitedNetworkId(headers, visitedNetworkId);

      final rebuilt = h.joinMessage(headers, parts.body);
      final mutated = SipMsg()..Parse(rebuilt);
      _markInbound(mutated, ueTransport);
      Log.debug('ims.pcscf', 'REGISTER from ${request.From.User} → I-CSCF');
      toIcscf(mutated, ueTransport);
      return;
    }

    // Non-REGISTER originating: enforce the stored Service-Route by
    // pre-loading it as Route headers (RFC 3608 §5.3). If we have no
    // binding yet this UE is not registered — reject with 403 per
    // TS 24.229 §5.2.6.3, *unless* this is an emergency request, in
    // which case TS 24.229 §5.2.10.2 lets it pass through anyway.
    final aor = _aorFromFrom(request);
    final binding = aor == null ? null : _bindings[aor];
    final isEmergency =
        (request.Req.Src ?? '').toLowerCase().contains('urn:service:sos');
    if (binding == null && !isEmergency) {
      _replyLocal(ueTransport, request, 403, 'Forbidden — Not Registered');
      Log.warn(
          'ims.pcscf', 'originating $method from unregistered AOR $aor → 403');
      return;
    }
    if (binding != null) {
      ih.prependRouteSet(headers, binding.serviceRoute);
    }
    // Network-asserted identity (RFC 3325): we trust our own binding when
    // present; for emergency-from-unregistered we can't assert, so omit.
    if (aor != null && binding != null) {
      ih.setPAssertedIdentity(headers, aor);
    }

    final rebuilt = h.joinMessage(headers, parts.body);
    final mutated = SipMsg()..Parse(rebuilt);
    _markInbound(mutated, ueTransport);
    Log.debug('ims.pcscf', 'originating $method from $aor → S-CSCF');
    toScscf(mutated, ueTransport);
  }

  // -------------------------------------------------------------------------
  // From the network (S-CSCF / I-CSCF / external)
  // -------------------------------------------------------------------------

  /// Called by the I-CSCF / S-CSCF (or by the wire transport when a
  /// terminating request arrives) when a request is destined for one of
  /// our locally-registered UEs.
  void deliverToUe(SipMsg request, {String? targetAor}) {
    final aor = targetAor ?? _aorFromTo(request);
    if (aor == null) return;
    final binding = _bindings[aor];
    if (binding == null) {
      Log.warn('ims.pcscf', 'no binding for terminating AOR $aor');
      return;
    }
    final raw = request.src ?? '';
    final parts = h.splitMessage(raw);
    final headers = List<String>.from(parts.headers);

    // P-CSCF inserts a Via pointing at itself so that the response from
    // the UE walks back through us.
    final branch = h.generateBranch();
    h.prependVia(
      headers,
      'Via: SIP/2.0/${transport.toUpperCase()} '
      '$host:$port;branch=$branch;rport',
    );

    if (_isDialogCreating(request.Req.Method?.toUpperCase() ?? '')) {
      h.addRecordRoute(headers, recordRouteUri);
    }

    final wire = h.joinMessage(headers, parts.body);
    binding.transport.send(wire,
        destIp: binding.transport.socket.addr,
        destPort: binding.transport.socket.port);
    Log.debug('ims.pcscf',
        '→ UE ${binding.transport.socket.addr}:${binding.transport.socket.port} ${request.Req.Method} $aor');
  }

  /// Invoked when a SIP response arrives — pop our Via and forward back
  /// to the next Via (RFC 3261 §16.7).
  void onResponseFromUe(SipMsg response, SipTransport ueTransport) =>
      _forwardResponse(response);

  /// Called by the S-CSCF / I-CSCF in collocated mode when a response
  /// emitted in-process needs to walk down the network side back to the
  /// originating side. Because in collocated mode the I/S-CSCFs do not
  /// add Vias, the response simply needs to go through us.
  void onResponseFromNetwork(SipMsg response) => _forwardResponse(response);

  /// Special hook for the 200 OK to REGISTER: the S-CSCF builds the
  /// Service-Route, the P-CSCF records it for the AOR before stripping
  /// Path / Service-Route from the response that reaches the UE.
  void on200OkRegister(SipMsg ok, SipTransport ueTransport,
      {required String aor, required String contactUri, required int expires}) {
    final raw = ok.src ?? '';
    final parts = h.splitMessage(raw);
    final headers = List<String>.from(parts.headers);

    final serviceRoute = ih.readServiceRoute(headers);
    _bindings[aor] = _PcscfBinding(
      transport: ueTransport,
      contactUri: contactUri,
      serviceRoute: serviceRoute,
      expiresAt: DateTime.now().add(Duration(seconds: expires)),
    );

    // Strip Path and Service-Route before sending to the UE (RFC 3327
    // §5.3 / RFC 3608 §5.2 — informational headers, not required by the
    // UE; some UAs reject unknown headers).
    ih.removeHeader(headers, 'Path');
    ih.removeHeader(headers, 'Service-Route');

    // Pop the P-CSCF Via we added on the request side.
    h.popTopVia(headers);

    final wire = h.joinMessage(headers, parts.body);
    ueTransport.send(wire,
        destIp: ueTransport.socket.addr, destPort: ueTransport.socket.port);
    Log.debug('ims.pcscf',
        '200 OK REGISTER → UE ${ueTransport.socket.addr}:${ueTransport.socket.port} (Service-Route ×${serviceRoute.length})');
  }

  /// Removes a UE binding (called when REGISTER expires or de-registers).
  void unbind(String aor) => _bindings.remove(aor);

  // -------------------------------------------------------------------------
  // Internals
  // -------------------------------------------------------------------------

  void _forwardResponse(SipMsg response) {
    final raw = response.src ?? '';
    if (raw.isEmpty) return;
    final parts = h.splitMessage(raw);
    final headers = List<String>.from(parts.headers);
    final mine = h.popTopVia(headers);
    if (mine == null) {
      Log.warn('ims.pcscf', 'response with no Via dropped');
      return;
    }
    if (response.Via.length < 2) {
      Log.warn('ims.pcscf', 'response had a single Via; cannot forward');
      return;
    }
    final next = response.Via[1];
    final dest = _viaTarget(next);
    if (dest == null) {
      Log.warn('ims.pcscf', 'next Via lacks usable host; dropping');
      return;
    }
    final wire = h.joinMessage(headers, parts.body);
    transportSendOverInbound(dest.host, dest.port, wire);
    Log.debug('ims.pcscf',
        '↩ response ${response.Req.StatusCode} → ${dest.host}:${dest.port}');
  }

  /// Sends [wire] to [host]:[port] using *any* of our existing UE
  /// transports' send closure. We intentionally pick a transport with the
  /// same protocol so e.g. UDP responses don't accidentally go over WS.
  void transportSendOverInbound(String host, int port, String wire) {
    SipTransport? pick;
    for (final b in _bindings.values) {
      if (b.transport.serverSocket.transport.toLowerCase() ==
          transport.toLowerCase()) {
        pick = b.transport;
        break;
      }
    }
    pick ??= _bindings.values.isEmpty ? null : _bindings.values.first.transport;
    if (pick == null) {
      Log.warn('ims.pcscf', 'no transport available to send to $host:$port');
      return;
    }
    pick.send(wire, destIp: host, destPort: port);
  }

  void _replyLocal(
      SipTransport ueTransport, SipMsg request, int code, String reason) {
    final raw = h.buildResponse(
      request,
      code: code,
      reason: reason,
      toTag: h.generateTag(),
    );
    ueTransport.send(raw,
        destIp: ueTransport.socket.addr, destPort: ueTransport.socket.port);
  }

  void _markInbound(SipMsg msg, SipTransport ueTransport) {
    msg.transport = ueTransport.socket;
  }

  ({String host, int port})? _viaTarget(dynamic via) {
    final src = via.Src as String? ?? '';
    String host = via.Host as String? ?? '';
    int? port = int.tryParse((via.Port as String?) ?? '');
    final rcvdM = RegExp(r'received=([^;\s,>]+)').firstMatch(src);
    if (rcvdM != null) host = rcvdM.group(1)!;
    final rportM = RegExp(r'rport=([0-9]+)').firstMatch(src);
    if (rportM != null) port = int.tryParse(rportM.group(1)!);
    if (host.isEmpty) return null;
    return (host: host, port: port ?? 5060);
  }

  String? _aorFromFrom(SipMsg request) {
    final user = request.From.User;
    final hostP = request.From.Host;
    if (user == null || hostP == null) return null;
    return 'sip:$user@$hostP';
  }

  String? _aorFromTo(SipMsg request) {
    final user = request.To.User;
    final hostP = request.To.Host;
    if (user == null || hostP == null) return null;
    return 'sip:$user@$hostP';
  }

  bool _isDialogCreating(String method) {
    switch (method) {
      case 'INVITE':
      case 'SUBSCRIBE':
      case 'REFER':
        return true;
      default:
        return false;
    }
  }

  String _newIcid() {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return '$proxyName-$ts';
  }
}
