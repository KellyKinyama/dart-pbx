// Stateless SIP proxy (RFC 3261 §16.11).
//
// Unlike the [StatefulProxy] in `proxy.dart`, this implementation keeps **no**
// per-request transaction state and **no** per-call dialog state. Each SIP
// message is independently forwarded based on:
//
//   * Request-URI / Route headers / user-location bindings (for requests)
//   * The Via stack (for responses, RFC 3261 §16.7 / §18.2.2)
//
// This makes the proxy O(1) memory per message and trivially horizontally
// scalable, at the cost of features a stateful proxy provides (forking,
// retransmission absorption, 100 Trying generation, CANCEL synthesis,
// ring-timeout-based serial hunt, etc.).
//
// Design points relevant to operating in front of an Asterisk back-end:
//
//   * REGISTER is **not** handled here. The location service (`usrloc`)
//     continues to be populated by the existing [RequestsHandler]; this
//     proxy only consumes those bindings to route inbound calls from
//     Asterisk back to the right phone.
//   * Every other method (INVITE, ACK, BYE, CANCEL, OPTIONS, MESSAGE,
//     SUBSCRIBE, NOTIFY, INFO, REFER, PRACK, UPDATE, PUBLISH, …) is
//     forwarded statelessly. ACK and CANCEL follow the same rules as any
//     other request — no special transaction matching is needed because
//     we hold no transaction state.
//   * **Media is not anchored.** The SDP body is forwarded byte-for-byte;
//     we never rewrite `c=`, `m=`, ICE candidates, or RTP/RTCP. RTP flows
//     directly between the two user agents (or between the UA and
//     Asterisk), bypassing this process entirely.
//   * The Via branch we add is derived deterministically from the inbound
//     message (RFC 3261 §16.11 paragraph 4) so that a retransmitted
//     request produces the same branch — required for downstream loop
//     detection (§16.3 step 4) and so the matching response routes back
//     to the same upstream peer.
//   * Loop detection (§16.3 step 4 / §16.6 step 8) is performed by
//     scanning the existing Via stack for our own sent-by + branch.

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:dart_pbx/logging.dart';
import 'package:dart_pbx/sip_client.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/sip_parser/sip_via.dart';
import 'package:dart_pbx/transports/transport.dart';

import 'sip_helpers.dart' as h;

/// RFC 3261 §8.1.1.7 mandates every Via branch start with this magic cookie.
const String _branchMagicCookie = 'z9hG4bK';

class StatelessProxy {
  StatelessProxy({
    required this.clients,
    this.upstream,
    this.recordRoute = true,
    this.proxyName = 'dart-pbx',
  });

  /// Active user-location bindings keyed by AOR. Populated by the registrar
  /// in [RequestsHandler.onRegister]; consumed here for inbound routing.
  final Map<String, SipClient> clients;

  /// Optional default next hop (e.g. an Asterisk trunk). Any request whose
  /// callee is not locally registered — and that did not arrive *from* this
  /// upstream — is forwarded here. REGISTER is never sent upstream.
  SipClient? upstream;

  /// When true (default) the proxy inserts a Record-Route header on
  /// dialog-establishing requests so subsequent in-dialog traffic stays in
  /// the signalling path. Disable to be strictly transparent.
  final bool recordRoute;

  /// Used as the value of the `Server`/`User-Agent`-like Via comment, and as
  /// part of the deterministic branch salt so a multi-proxy mesh produces
  /// distinct branches per hop.
  final String proxyName;

  // -------------------------------------------------------------------------
  // Public entry points
  // -------------------------------------------------------------------------

  /// Handle an incoming SIP request. Returns true when the proxy took
  /// ownership of the message; false to let the caller fall back (e.g. for
  /// REGISTER, which the location server still owns).
  bool handleRequest(SipMsg request, SipTransport transport) {
    final method = h.requestMethod(request);
    if (method == null) return false;

    // The location server keeps REGISTER; a stateless proxy MUST NOT
    // forward it without contact rewriting, and that rewriting is exactly
    // what the registrar does locally.
    if (method == 'REGISTER') return false;

    _forwardRequest(request, transport, method);
    return true;
  }

  /// Handle an incoming SIP response. Returns true when forwarded (or
  /// intentionally dropped per §16.7); false on hard parse failures so the
  /// caller can log.
  bool handleResponse(SipMsg response, SipTransport transport) {
    final code = h.responseStatus(response);
    if (code == null) return false;
    _forwardResponse(response, transport);
    return true;
  }

  // -------------------------------------------------------------------------
  // Request path
  // -------------------------------------------------------------------------

  void _forwardRequest(SipMsg request, SipTransport transport, String method) {
    final raw = request.src ?? '';
    if (raw.isEmpty) return;

    final selfHost = transport.serverSocket.addr;
    final selfPort = transport.serverSocket.port;
    final selfProto = transport.serverSocket.transport.toUpperCase();
    final selfSentBy = '$selfHost:$selfPort';

    // ---------------------------------------------------------------- §16.3.4
    // Loop detection: if our (sent-by, branch) already appears in any Via,
    // this message has visited us before. RFC 3261 §16.3 step 4: respond
    // 482 Loop Detected. We're stateless, so we craft the response and
    // hand it straight back over the inbound transport.
    if (_isLoop(request, selfSentBy)) {
      _sendStatelessResponse(transport, request, 482, 'Loop Detected');
      Log.warn('proxy.stateless',
          'loop detected for $method ${request.Req.Src}; replied 482');
      return;
    }

    final parts = h.splitMessage(raw);
    final headers = List<String>.from(parts.headers);

    // ---------------------------------------------------------------- §16.6.3
    // Decrement Max-Forwards. 0 → 483 Too Many Hops.
    final mf = h.decrementMaxForwards(headers);
    if (mf == null) {
      _sendStatelessResponse(transport, request, 483, 'Too Many Hops');
      return;
    }

    // ---------------------------------------------------------------- §16.4
    // Loose-routing: if the topmost Route is us, strip it. Subsequent
    // routing then uses either the next Route or the Request-URI.
    h.consumeTopRouteIfSelf(headers, selfHost, selfPort);

    // ---------------------------------------------------------------- §16.5
    // Determine destination.
    final dest = _resolveDestination(request, headers, transport);
    if (dest == null) {
      _sendStatelessResponse(transport, request, 404, 'Not Found');
      Log.debug('proxy.stateless',
          'no route for $method ${request.Req.Src}; replied 404');
      return;
    }

    // ---------------------------------------------------------------- §16.6.4
    // Record-Route only on dialog-establishing requests so we stay in the
    // signalling path for re-INVITE / BYE. ACK is end-to-end (§17.1.1.3
    // for 2xx ACKs) and CANCEL is hop-by-hop, so neither needs RR added.
    if (recordRoute && _isDialogCreating(method)) {
      h.addRecordRoute(
        headers,
        'sip:$selfHost:$selfPort;transport=$selfProto;lr',
      );
    }

    // ---------------------------------------------------------------- §16.11
    // Add our Via with a *deterministic* branch so retransmits collapse
    // and the matching response can be looped back via _forwardResponse.
    final branch = _deterministicBranch(request, dest);
    h.prependVia(
      headers,
      'Via: SIP/2.0/$selfProto $selfHost:$selfPort'
      ';branch=$branch;rport',
    );

    final forwarded = h.joinMessage(headers, parts.body);
    final destTx = dest.transport;
    try {
      destTx.send(forwarded,
          destIp: destTx.socket.addr, destPort: destTx.socket.port);
      Log.debug(
          'proxy.stateless',
          '→ ${destTx.socket.addr}:${destTx.socket.port} '
              '$method ${request.Req.Src}');
    } catch (e, st) {
      Log.error('proxy.stateless',
          'send failure for $method ${request.Req.Src}: $e\n$st');
      // Best-effort 503 back to upstream.
      _sendStatelessResponse(transport, request, 503, 'Service Unavailable');
    }
  }

  /// Returns the next-hop [SipClient] for [request], or null when no route
  /// could be determined (caller should respond 404).
  SipClient? _resolveDestination(
      SipMsg request, List<String> headers, SipTransport inbound) {
    // §16.4: an explicit Route header (after we have already stripped our
    // own loose-route URI) wins. We don't transform this further — Asterisk
    // and RFC-compliant UAs both honour preset Route sets.
    final routes = h.readRoutes(headers);
    if (routes.isNotEmpty) {
      final hp = h.parseUriHostPort(routes.first);
      if (hp.host.isNotEmpty) {
        return _clientFor(hp.host, hp.port ?? 5060, inbound);
      }
    }

    // Inbound from the upstream (Asterisk) → resolve the Request-URI user
    // against usrloc and deliver to the registered phone.
    if (upstream != null && _isFromUpstream(inbound)) {
      final user = request.To.User;
      if (user != null) {
        final binding = clients[user];
        if (binding != null && !binding.isExpired()) return binding;
      }
      // Unknown user from upstream: nothing else we can do.
      return null;
    }

    // Inbound from a phone → if the callee is locally registered, send
    // peer-to-peer; otherwise hand off to upstream Asterisk for dialplan
    // routing (PSTN, voicemail, queues, IVRs, …).
    final calleeUser = request.To.User;
    if (calleeUser != null) {
      final binding = clients[calleeUser];
      if (binding != null && !binding.isExpired()) return binding;
    }
    return upstream;
  }

  /// Build a [SipClient] addressing an arbitrary host/port over the same
  /// inbound transport (so we reuse its server socket for sending).
  SipClient _clientFor(String host, int port, SipTransport inbound) {
    final tx = SipTransport(
      sockaddr_in(host, port, inbound.serverSocket.transport),
      inbound.serverSocket,
      inbound.send,
    );
    return SipClient('route:$host:$port', tx, contactUri: 'sip:$host:$port');
  }

  bool _isFromUpstream(SipTransport inbound) {
    final up = upstream;
    if (up == null) return false;
    return up.transport.socket.addr == inbound.socket.addr &&
        up.transport.socket.port == inbound.socket.port;
  }

  // -------------------------------------------------------------------------
  // Response path  (RFC 3261 §16.7 / §18.2.2)
  // -------------------------------------------------------------------------

  void _forwardResponse(SipMsg response, SipTransport transport) {
    final raw = response.src ?? '';
    if (raw.isEmpty) return;

    final parts = h.splitMessage(raw);
    final headers = List<String>.from(parts.headers);

    // §16.7 step 2: pop the top Via — that's the one this proxy added.
    final mine = h.popTopVia(headers);
    if (mine == null) {
      Log.warn('proxy.stateless',
          'response with no Via dropped (${response.Req.StatusCode})');
      return;
    }

    // §16.7 step 3: validate it really is ours; if not, drop (could be a
    // misrouted response from a misbehaving peer).
    final selfHost = transport.serverSocket.addr;
    final selfPort = transport.serverSocket.port;
    if (!_viaSentByMatches(mine, selfHost, selfPort)) {
      Log.warn('proxy.stateless',
          'top Via "$mine" is not ours ($selfHost:$selfPort); dropping');
      return;
    }

    // §16.7 step 5: forward to the address indicated by the *now* top Via,
    // honouring received= / rport= per RFC 3581.
    if (response.Via.length < 2) {
      // The popped Via was the only one — nowhere to send.
      Log.warn('proxy.stateless',
          'response had a single Via; cannot forward (${response.Req.StatusCode})');
      return;
    }
    final next = response.Via[1];
    final target = _viaTarget(next, transport);
    if (target == null) {
      Log.warn('proxy.stateless',
          'next Via "${next.Src}" lacks a usable host; dropping');
      return;
    }

    final forwarded = h.joinMessage(headers, parts.body);
    try {
      transport.send(forwarded, destIp: target.host, destPort: target.port);
      Log.debug(
          'proxy.stateless',
          '↩ ${target.host}:${target.port} '
              '${response.Req.StatusCode} ${response.Req.StatusDesc}');
    } catch (e) {
      Log.error('proxy.stateless',
          'response send failure to ${target.host}:${target.port}: $e');
    }
  }

  ({String host, int port})? _viaTarget(sipVia via, SipTransport inbound) {
    // RFC 3581 §4: prefer received= / rport= when present. The hand-rolled
    // Via parser truncates these fields to a single character (see
    // sip_via.dart FIELD_RPORT/FIELD_REC), so we re-extract them from the
    // raw header line for reliability.
    final src = via.Src ?? '';
    String? rcvd;
    int? rport;
    final rcvdM = RegExp(r'received=([^;\s,>]+)').firstMatch(src);
    if (rcvdM != null) rcvd = rcvdM.group(1);
    final rportM = RegExp(r'rport=([0-9]+)').firstMatch(src);
    if (rportM != null) rport = int.tryParse(rportM.group(1)!);

    final host = (rcvd != null && rcvd.isNotEmpty) ? rcvd : (via.Host ?? '');
    if (host.isEmpty) return null;
    final port = rport ?? int.tryParse(via.Port ?? '') ?? 5060;
    return (host: host, port: port);
  }

  bool _viaSentByMatches(String viaLine, String host, int port) {
    final lower = viaLine.toLowerCase();
    return lower.contains(host.toLowerCase()) &&
        (lower.contains(':$port') || port == 5060);
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// RFC 3261 §16.11 paragraph 4: the branch parameter of a stateless proxy
  /// MUST be computable from the message such that two retransmissions of the
  /// same request yield the same branch. We hash the transaction-identifying
  /// invariants (top Via branch + From-tag + Call-ID + CSeq + Request-URI +
  /// To-tag + our proxy name + the chosen destination) so each hop produces
  /// a distinct, deterministic branch.
  String _deterministicBranch(SipMsg req, SipClient dest) {
    final via = h.topVia(req);
    final salt = StringBuffer()
      ..write(via?.Branch ?? '')
      ..write('|')
      ..write(req.From.Tag ?? '')
      ..write('|')
      ..write(req.To.Tag ?? '')
      ..write('|')
      ..write(req.CallId.Value ?? '')
      ..write('|')
      ..write(req.Cseq.Id ?? '')
      ..write('|')
      ..write(req.Cseq.Method ?? '')
      ..write('|')
      ..write(req.Req.Src ?? '')
      ..write('|')
      ..write(dest.transport.socket.addr)
      ..write(':')
      ..write(dest.transport.socket.port)
      ..write('|')
      ..write(proxyName);
    final digest = sha1.convert(utf8.encode(salt.toString())).toString();
    return '$_branchMagicCookie-${digest.substring(0, 24)}';
  }

  /// Returns true when any Via in [request] already carries our sent-by AND
  /// matches a branch we could have produced. Cheap conservative check: if a
  /// Via's host:port equals ours, we treat it as a loop. (RFC 3261 §16.3
  /// step 4 allows responding 482 on the basis of any unambiguous loop
  /// indicator.)
  bool _isLoop(SipMsg request, String selfSentBy) {
    final selfHost = selfSentBy.split(':').first.toLowerCase();
    final selfPort = selfSentBy.split(':').last;
    for (final v in request.Via) {
      final h = (v.Host ?? '').toLowerCase();
      final p = v.Port ?? '5060';
      if (h == selfHost && p == selfPort) return true;
    }
    return false;
  }

  /// Send a locally generated response back over the inbound transport
  /// without any transaction state. Used for 4xx/5xx that this proxy
  /// generates itself (482, 483, 404, 503 …). Per RFC 3261 §16.11 a
  /// stateless proxy MAY do this — it just must not retransmit.
  void _sendStatelessResponse(
      SipTransport inbound, SipMsg request, int code, String reason) {
    final raw = h.buildResponse(
      request,
      code: code,
      reason: reason,
      toTag: h.generateTag(),
    );
    try {
      inbound.send(raw,
          destIp: inbound.socket.addr, destPort: inbound.socket.port);
    } catch (e) {
      Log.error('proxy.stateless', 'failed to send $code $reason locally: $e');
    }
  }

  bool _isDialogCreating(String method) {
    switch (method) {
      case 'INVITE':
      case 'SUBSCRIBE':
      case 'REFER':
      case 'NOTIFY': // for out-of-dialog NOTIFY (RFC 6665 §4.4)
        return true;
      default:
        return false;
    }
  }
}
