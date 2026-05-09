// IMS Core — collocated P-CSCF + I-CSCF + S-CSCF + HSS.
//
// This is the integration glue that makes the four components behave as
// one IMS network element. It owns:
//
//   * One [HomeSubscriberServer] (Cx, Sh).
//   * One or more [Scscf]s, indexed by name (the I-CSCF address resolves
//     S-CSCF names to handlers).
//   * One [Icscf].
//   * One [Pcscf].
//
// On the wire there is exactly one transport (UDP/TCP/TLS/WS) listening
// for SIP traffic from UEs and (optionally) for off-net traffic from a
// peer SBC / Asterisk. The Core's [handle] function is what each
// transport calls; it routes the message to the right CSCF based on the
// topmost Route header (when present) or its origin (UE vs. network).
//
// Off-net routing is delegated to a caller-supplied callback so deployers
// can plug in an Asterisk back-end, an upstream SBC, a BGCF, or simply
// reject with 404. This mirrors how the existing [StatefulProxy] and
// [StatelessProxy] in this project let you wire an Asterisk trunk.

import 'package:dart_pbx/logging.dart';
import 'package:dart_pbx/proxy/digest_auth.dart';
import 'package:dart_pbx/sip_client.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/transports/transport.dart';

import 'bgcf.dart';
import 'hss.dart';
import 'icscf.dart';
import 'pcscf.dart';
import 'scscf.dart';

class ImsCore {
  ImsCore({
    required this.host,
    required this.port,
    required this.transport,
    required this.realm,
    required this.visitedNetworkId,
    this.scscfName = 'scscf.local',
    this.offNetGateway,
    Bgcf? bgcf,
  })  : bgcf = bgcf,
        hss = HomeSubscriberServer(
          realm: realm,
          scscfPool: [scscfName],
        ) {
    _scscf = Scscf(
      name: scscfName,
      host: host,
      port: port,
      transport: transport,
      hss: hss,
      auth: DigestAuth(realm: realm),
      replyLocal: _onResponseFromInternal,
      routeToTerminating: _routeToTerminating,
      routeToOffNet: _routeToOffNet,
    );
    _icscf = Icscf(
      hss: hss,
      toScscf: _routeToScscf,
      replyLocal: _onResponseFromInternal,
    );
    _pcscf = Pcscf(
      host: host,
      port: port,
      transport: transport,
      visitedNetworkId: visitedNetworkId,
      proxyName: 'pcscf',
      toIcscf: (msg, inbound) => _icscf.onRequest(msg, inbound),
      toScscf: (msg, inbound) => _scscf.onRequest(msg, inbound),
    );
  }

  /// Listening address (used in Path/Service-Route/Record-Route URIs).
  final String host;
  final int port;
  final String transport;

  /// IMS realm — the value that appears in IMPI/IMPU URIs and in digest
  /// challenges.
  final String realm;

  /// P-Visited-Network-ID emitted by the P-CSCF on REGISTER.
  final String visitedNetworkId;

  /// Logical name of the (single) S-CSCF in this deployment.
  final String scscfName;

  /// When set, off-net calls (callee not provisioned in the HSS) are
  /// forwarded here. Typical wiring points this at an Asterisk trunk
  /// acting as the BGCF/MGCF for PSTN breakout.
  SipClient? offNetGateway;

  /// Optional BGCF (TS 24.229 §5.6) used to pick a trunk for off-net
  /// requests and to scrub IMS-private headers before the request leaves
  /// the trust domain. When null, off-net calls are forwarded raw via
  /// [offNetGateway] (legacy behaviour).
  Bgcf? bgcf;

  late final Pcscf _pcscf;
  late final Icscf _icscf;
  late final Scscf _scscf;

  final HomeSubscriberServer hss;

  Pcscf get pcscf => _pcscf;
  Icscf get icscf => _icscf;
  Scscf get scscf => _scscf;

  /// Inbound transport currently being processed. Set by [handle] for the
  /// duration of one message dispatch so internal CSCFs can reach back to
  /// the wire (e.g. to send a 401 challenge to a UE that has no binding
  /// yet). Synchronous SIP processing makes this safe.
  SipTransport? _activeInbound;

  // -------------------------------------------------------------------------
  // Inbound dispatch — called by the transport layer
  // -------------------------------------------------------------------------

  /// Single entry point for every SIP datagram received by any transport
  /// bound to this IMS Core. The Core decides whether the message is from
  /// a UE or from the network and dispatches accordingly.
  void handle(String raw, SipTransport inbound) {
    if (raw.trim().isEmpty) return;
    final msg = SipMsg()..Parse(raw);
    _activeInbound = inbound;
    try {
      // Responses always walk back via the Via stack handled by the P-CSCF.
      if (msg.Req.Method == null || msg.Req.Method!.isEmpty) {
        _pcscf.onResponseFromUe(msg, inbound);
        return;
      }

      // Heuristic: requests coming from the off-net gateway (Asterisk /
      // SBC) are terminating — they should enter the chain at the I-CSCF
      // (which does an LIR to find the S-CSCF for the called IMPU).
      final off = offNetGateway;
      if (off != null &&
          off.transport.socket.addr == inbound.socket.addr &&
          off.transport.socket.port == inbound.socket.port) {
        Log.debug('ims.core', 'request from off-net → I-CSCF');
        _icscf.onRequest(msg, inbound);
        return;
      }
      // Otherwise it's a UE — go through the P-CSCF.
      _pcscf.onRequestFromUe(msg, inbound);
    } finally {
      _activeInbound = null;
    }
  }

  // -------------------------------------------------------------------------
  // Internal Mw bridges
  // -------------------------------------------------------------------------

  void _routeToScscf(String scscfName, SipMsg request, SipTransport inbound) {
    if (scscfName != _scscf.name) {
      // Single-S-CSCF deployment: anything else is misconfiguration.
      Log.warn('ims.core', 'unknown S-CSCF "$scscfName"; using local');
    }
    _scscf.onRequest(request, inbound);
  }

  void _routeToTerminating(String impu, SipMsg request, SipTransport inbound) {
    // Locate the served UE's binding on the P-CSCF and deliver.
    if (_pcscf.lookup(impu) == null) {
      // No P-CSCF binding for this IMPU here. In a multi-P-CSCF
      // deployment we'd route via the Path header to the correct
      // P-CSCF; in collocated mode this means the user is unreachable.
      Log.warn('ims.core',
          'terminating $impu: no P-CSCF binding (user unreachable)');
      // The S-CSCF already added Record-Route and a Route from Path; in
      // a real network the request would now hop to a different P-CSCF.
      // For our single-process deployment we give up.
      _routeToOffNet(request, inbound);
      return;
    }
    _pcscf.deliverToUe(request, targetAor: impu);
  }

  void _routeToOffNet(SipMsg request, SipTransport inbound) {
    final b = bgcf;
    final off = offNetGateway;
    if (b != null && off != null) {
      final ok = b.forward(request, send: (raw, {destIp, destPort}) {
        off.transport.send(raw, destIp: destIp, destPort: destPort);
      });
      if (ok) return;
      // BGCF found no matching trunk — reject with 404 below.
      _reject404(request);
      return;
    }
    if (off == null) {
      Log.warn('ims.core',
          'no off-net gateway; rejecting ${request.Req.Method} → 404');
      _reject404(request);
      return;
    }
    final tx = off.transport;
    tx.send(request.src ?? '',
        destIp: tx.socket.addr, destPort: tx.socket.port);
    Log.debug('ims.core',
        '→ off-net ${tx.socket.addr}:${tx.socket.port} ${request.Req.Method}');
  }

  void _reject404(SipMsg request) {
    _onResponseFromInternal(SipMsg()
      ..Parse('SIP/2.0 404 Not Found\r\n'
          'Via: ${request.Via.isEmpty ? '' : (request.Via.first.Src ?? '')}\r\n'
          'From: ${request.From.Src ?? ''}\r\n'
          'To: ${request.To.Src ?? ''};tag=ims-${DateTime.now().microsecondsSinceEpoch}\r\n'
          'Call-ID: ${request.CallId.Value ?? ''}\r\n'
          'CSeq: ${request.Cseq.Id ?? '1'} ${request.Cseq.Method ?? request.Req.Method}\r\n'
          'Content-Length: 0\r\n\r\n'));
  }

  /// Funnel for responses generated *inside* the IMS Core (challenges,
  /// 404s, REGISTER 200 OKs). Distinguishes REGISTER 200 OKs (need
  /// Service-Route stashing on the P-CSCF) from everything else.
  void _onResponseFromInternal(SipMsg response) {
    final cseq = response.Cseq.Method?.toUpperCase();
    final code = int.tryParse(response.Req.StatusCode ?? '');
    if (cseq == 'REGISTER' && code == 200) {
      final aor = _aorOfTo(response);
      // Find UE transport for this AOR — we use the P-CSCF's pre-existing
      // binding if one exists (re-REGISTER), else the Via received= /
      // rport= of the request. Since we just authenticated, the request
      // is still in scope: we approximate by walking the topmost Via.
      if (aor == null) {
        _pcscf.onResponseFromNetwork(response);
        return;
      }
      final binding = _pcscf.lookup(aor);
      final ueTransport = binding?.transport ?? _activeInbound;
      if (ueTransport == null) {
        _pcscf.onResponseFromNetwork(response);
        return;
      }
      final contactUri = _extractContactUri(response) ?? aor;
      final expires = _grantedExpires(response) ?? 3600;
      _pcscf.on200OkRegister(response, ueTransport,
          aor: aor, contactUri: contactUri, expires: expires);
      return;
    }
    // Other internal responses just walk back through the Via stack.
    final inbound = _activeInbound;
    if (inbound != null) {
      // Synchronous responses (digest challenges, 4xx) generated inside
      // the IMS while still processing a UE request go straight back to
      // the UE so the P-CSCF doesn't have to peek through the Via stack.
      final raw = response.src ?? '';
      inbound.send(raw,
          destIp: inbound.socket.addr, destPort: inbound.socket.port);
      return;
    }
    _pcscf.onResponseFromNetwork(response);
  }

  // -------------------------------------------------------------------------
  // Misc helpers
  // -------------------------------------------------------------------------

  String? _aorOfTo(SipMsg msg) {
    final user = msg.To.User;
    final host = msg.To.Host;
    if (user == null || host == null) return null;
    return 'sip:$user@$host';
  }

  String? _extractContactUri(SipMsg msg) {
    final user = msg.Contact.User ?? msg.To.User;
    final host = msg.Contact.Host;
    final port = msg.Contact.Port;
    if (user == null || host == null) return null;
    final portPart = port == null ? '' : ':$port';
    return 'sip:$user@$host$portPart';
  }

  int? _grantedExpires(SipMsg msg) {
    final c = int.tryParse(msg.Contact.Expires ?? '');
    if (c != null) return c;
    final raw = msg.src ?? '';
    for (final line in raw.split('\r\n')) {
      final l = line.toLowerCase();
      if (l.startsWith('expires:')) {
        return int.tryParse(line.substring(line.indexOf(':') + 1).trim());
      }
    }
    return null;
  }

  /// Returns IMPUs currently registered through this IMS Core.
  Iterable<String> get registeredImpus => _scscf.registeredImpus;
}
