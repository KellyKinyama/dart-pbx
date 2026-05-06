// Stateful SIP proxy core (RFC 3261 §16) for INVITE-initiated dialogs.
//
// Responsibilities:
//   * Match every incoming request to a server transaction (creating one on
//     first sight) so retransmits are absorbed instead of duplicated.
//   * For each forwarded request, create a client transaction so responses
//     can be matched back even when forks/CSeqs change.
//   * Generate 100 Trying for INVITE requests we forward.
//   * Generate 487 Request Terminated for INVITEs we cancel via CANCEL.
//   * Absorb ACK to non-2xx in the originating INVITE server transaction;
//     forward ACK to 2xx end-to-end.
//   * Track dialogs by (Call-ID, local-tag, remote-tag) and clean them up on
//     BYE 200 OK.
//
// REGISTER and other one-shot transactions remain handled by the existing
// [RequestsHandler] for backwards compatibility — the proxy is invoked from
// within that handler for INVITE/ACK/CANCEL/BYE/in-dialog requests and for
// every response.

import 'dart:async';

import 'package:dart_pbx/logging.dart';
import 'package:dart_pbx/sip_client.dart';
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/sip_parser/sip_via.dart';
import 'package:dart_pbx/transports/transport.dart';

import 'auth_store.dart';
import 'dialog.dart';
import 'digest_auth.dart';
import 'sip_helpers.dart';
import 'transaction.dart';
import 'transaction_layer.dart';

class StatefulProxy {
  StatefulProxy({
    required this.clients,
    this.auth,
    this.credentials,
    this.upstream,
    this.resolveDestination,
  });

  /// Registered users by AOR. Looked up to find the destination transport.
  final Map<String, SipClient> clients;

  /// Optional digest authenticator. When non-null, INVITE requests without a
  /// valid `Proxy-Authorization` header are challenged with 407.
  final DigestAuth? auth;

  /// Credentials backing [auth]. Required when [auth] is set.
  final CredentialsStore? credentials;

  /// When set, every INVITE handled by the proxy is forwarded to this peer
  /// (typically a back-end Asterisk) regardless of whether the requested
  /// callee is locally registered. REGISTER stays local; only media-setup
  /// (INVITE / ACK / CANCEL / BYE / UPDATE) crosses the trunk.
  SipClient? upstream;

  /// Optional pre-routing hook. Called for every fresh INVITE before the
  /// upstream / AOR fallback. When it returns a [DestinationDecision], the
  /// proxy uses [DestinationDecision.client] as the target and invokes
  /// [DestinationDecision.onAnswered] / [DestinationDecision.onFailed] /
  /// [DestinationDecision.onHangup] as the call progresses. Returning null
  /// falls back to the standard upstream / AOR resolution.
  DestinationDecision? Function(SipMsg request)? resolveDestination;

  final TransactionLayer txLayer = TransactionLayer();
  final DialogLayer dialogLayer = DialogLayer();

  /// Server-generated To-tag per Call-ID for dialogs we either reject or
  /// terminate before a callee is reached (e.g. 404, 487). For a successfully
  /// forwarded INVITE the callee's own To-tag is used instead.
  final Map<String, String> _proxyToTags = {};

  /// Map from a server INVITE transaction id to the client transaction we
  /// spawned upstream toward the callee. Needed by CANCEL handling.
  final Map<String, InviteClientTransaction> _inviteSToC = {};

  // -------------------------------------------------------------------------
  // Public entry points
  // -------------------------------------------------------------------------

  /// Handle an incoming SIP request. Returns true when the proxy took
  /// ownership; false means the caller (legacy handler) should fall back to
  /// its own logic (e.g. REGISTER).
  bool handleRequest(SipMsg request, SipTransport transport) {
    final method = requestMethod(request);
    if (method == null) return false;

    switch (method) {
      case 'INVITE':
        _handleInvite(request, transport);
        return true;
      case 'ACK':
        _handleAck(request, transport);
        return true;
      case 'CANCEL':
        _handleCancel(request, transport);
        return true;
      case 'BYE':
        _handleBye(request, transport);
        return true;
      case 'UPDATE':
        _handleInDialogNonInvite(request, transport, method: 'UPDATE');
        return true;
      default:
        return false;
    }
  }

  /// Handle an incoming SIP response by feeding it into its client
  /// transaction (which then forwards it downstream after stripping our Via).
  bool handleResponse(SipMsg response, SipTransport transport) {
    final code = responseStatus(response);
    if (code == null) return false;

    final tx = txLayer.matchClient(response);
    if (tx == null) {
      // No matching client transaction. The CANCEL we sent upstream creates
      // a NonInviteClientTransaction whose 200 OK we don't need to forward
      // (the caller already saw 487). Silently absorb 2xx responses to
      // CANCEL/BYE/etc. instead of warning + forwarding statelessly.
      final cseq = cseqMethod(response);
      if (cseq == 'CANCEL' || cseq == 'BYE') {
        Log.debug('proxy',
            'absorbed orphan ${cseq.toString().toLowerCase()} response $code');
        return true;
      }
      _statelessForwardResponse(response);
      return true;
    }
    if (tx is InviteClientTransaction) {
      tx.onResponse(response.src ?? '', code);
    } else if (tx is NonInviteClientTransaction) {
      tx.onResponse(response.src ?? '', code);
    }
    return true;
  }

  // -------------------------------------------------------------------------
  // INVITE
  // -------------------------------------------------------------------------

  void _handleInvite(SipMsg request, SipTransport transport) {
    // Retransmit absorption.
    final existing = txLayer.matchServer(request);
    if (existing is InviteServerTransaction) {
      existing.onRequestRetransmit();
      return;
    }

    final via = topVia(request);
    final serverKey = TransactionLayer.serverKey(request);
    if (via == null || serverKey == null) return;

    // RFC 3261 §12.2.1: an INVITE with a To-tag is an in-dialog re-INVITE
    // (target refresh / SDP renegotiation / session refresh). Route through
    // the established dialog instead of treating it as a fresh call.
    if (request.To.Tag != null && request.To.Tag!.isNotEmpty) {
      final dialog = dialogLayer.findFromRequest(request);
      if (dialog != null) {
        _handleReInvite(request, transport, dialog, via, serverKey);
        return;
      }
      // No matching dialog → 481 (RFC 3261 §12.2.2).
      final downstreamSend = _downstreamSender(transport);
      final st = InviteServerTransaction(
        id: serverKey,
        branch: via.Branch ?? generateBranch(),
        send: downstreamSend,
        reliable: _isReliable(transport),
      );
      txLayer.addServer(st);
      st.sendResponse(
        buildResponse(request,
            code: 481,
            reason: 'Call/Transaction Does Not Exist',
            toTag: _toTagFor(request)),
        481,
      );
      return;
    }

    final downstreamSend = _downstreamSender(transport);
    final st = InviteServerTransaction(
      id: serverKey,
      branch: via.Branch ?? generateBranch(),
      send: downstreamSend,
      reliable: _isReliable(transport),
    );
    txLayer.addServer(st);

    // Proxy authentication (RFC 3261 §22.3). When configured, INVITE without
    // a valid Proxy-Authorization is rejected with 407. Forces the phone to
    // authenticate (and therefore register) before placing calls.
    if (auth != null && credentials != null) {
      final result = auth!.verify(
        headerValue: _findRawHeader(request.src ?? '', 'Proxy-Authorization'),
        method: 'INVITE',
        credentials: credentials!,
      );
      if (result != AuthResult.ok) {
        final stale = result == AuthResult.stale;
        final challenge = auth!.proxyChallengeHeaderValue(stale: stale);
        final body = buildResponse(request,
            code: 407,
            reason: 'Proxy Authentication Required',
            toTag: _toTagFor(request),
            extraHeaders: {'Proxy-Authenticate': challenge});
        st.sendResponse(body, 407);
        Log.warn(
            'auth',
            'INVITE from ${request.From.User} challenged with 407'
                ' (${result.name}) — caller must authenticate');
        return;
      }

      // Digest valid — but if the From AOR has no active registration in
      // usrloc, refuse the call. This prevents a phone with valid
      // credentials from skipping REGISTER and going straight to INVITE.
      final fromUser = request.From.User;
      if (fromUser != null && clients[fromUser] == null) {
        final challenge = auth!.proxyChallengeHeaderValue(stale: false);
        final body = buildResponse(request,
            code: 407,
            reason: 'Proxy Authentication Required',
            toTag: _toTagFor(request),
            extraHeaders: {'Proxy-Authenticate': challenge});
        st.sendResponse(body, 407);
        Log.warn(
            'auth',
            'INVITE from $fromUser rejected: AOR is not registered;'
                ' re-challenged so phone re-registers');
        return;
      }
    }

    // Locate destination. The optional [resolveDestination] hook (used by
    // the call-center module to pick the longest-idle agent) wins over
    // every other source. When it returns null we fall back to: explicit
    // upstream trunk (e.g. Asterisk) > local AOR registration.
    final decision = resolveDestination?.call(request);
    final calleeUser = request.To.User;
    final callee = decision?.client ??
        upstream ??
        (calleeUser == null ? null : clients[calleeUser]);
    if (callee == null) {
      final toTag = _toTagFor(request);
      st.sendResponse(
        buildResponse(request, code: 404, reason: 'Not Found', toTag: toTag),
        404,
      );
      decision?.onFailed?.call(404);
      return;
    }

    // 100 Trying right away (RFC 3261 §16.4).
    st.sendTrying(request);

    // Build the forwarded request once: prepend our own Via per-attempt,
    // decrement Max-Forwards once for the whole hunt.
    final raw = request.src ?? '';
    final parts = splitMessage(raw);
    final headersBase = List<String>.from(parts.headers);

    final mf = decrementMaxForwards(headersBase);
    if (mf == null) {
      st.sendResponse(
        buildResponse(request,
            code: 483, reason: 'Too Many Hops', toTag: _toTagFor(request)),
        483,
      );
      return;
    }

    // Record-Route ourselves so subsequent in-dialog requests come back here
    // (RFC 3261 §16.6.4). Done once for the entire hunt.
    final selfHost = transport.serverSocket.addr;
    final selfPort = transport.serverSocket.port;
    final selfProto = transport.serverSocket.transport.toUpperCase();
    final selfRouteUri = 'sip:$selfHost:$selfPort;transport=$selfProto;lr';
    addRecordRoute(headersBase, selfRouteUri);

    // Try a destination. On non-2xx final or ring-timeout we ask the
    // [DestinationDecision] for a [pickNext]; if one is returned we start
    // another attempt without telling the caller, achieving serial hunt.
    void attempt(DestinationDecision currentDecision) {
      final attemptCallee = currentDecision.client;
      final outBranch = generateBranch();
      final headers = List<String>.from(headersBase);
      prependVia(
        headers,
        'Via: SIP/2.0/$selfProto $selfHost:$selfPort;branch=$outBranch;rport',
      );
      final forwarded = joinMessage(headers, parts.body);

      final calleeTx = attemptCallee.transport;
      final upstreamSend = _upstreamSender(calleeTx);
      final ct = InviteClientTransaction(
        id: TransactionLayer.clientKeyFromOutbound(outBranch, 'INVITE'),
        branch: outBranch,
        send: upstreamSend,
        reliable: _isReliable(calleeTx),
        request: forwarded,
      );

      // Per-attempt state. `abandoned` is set when a ring-timeout fires;
      // any subsequent final response from this attempt is then dropped
      // instead of being forwarded to the caller.
      var abandoned = false;
      Timer? ringTimer;

      void cancelRingTimer() {
        ringTimer?.cancel();
        ringTimer = null;
      }

      ct.onProvisional = (raw, code) => _forwardResponse(raw, st);
      ct.onFinalResponse = (raw, code) {
        cancelRingTimer();
        if (abandoned) {
          // We already gave up on this attempt and started a new one. The
          // caller must not see this stale final.
          return;
        }
        if (code >= 200 && code < 300) {
          _forwardResponse(raw, st);
          currentDecision.onAnswered?.call();
          // Establish dialog with the callee's to-tag from the 200 OK.
          final parsed = SipMsg()..Parse(raw);
          final calleeToTag = parsed.To.Tag;
          if (calleeToTag != null) {
            // Route set per RFC 3261 §12.1.2.
            final rrParts = splitMessage(raw);
            final routeSet = readRecordRoutes(rrParts.headers);
            final callerUser = request.From.User;
            final caller = callerUser == null ? null : clients[callerUser];
            final dialog = dialogLayer.createFromInvite(
              request,
              calleeToTag,
              caller: caller,
              callee: attemptCallee,
              routeSet: routeSet,
            );
            dialog.state = DialogState.confirmed;
            dialog.onTerminated = () => currentDecision.onHangup?.call();
            // RFC 4028: arm session timer if the 2xx negotiated one.
            _armSessionTimer(dialog, rrParts.headers);
          }
          return;
        }

        // Non-success final. Fire onFailed first so the picker can
        // bookkeep, then ask for another attempt.
        currentDecision.onFailed?.call(code);
        final next = currentDecision.pickNext?.call();
        if (next != null) {
          // Don't forward the failure — caller stays in 100 Trying / 18x.
          attempt(next);
        } else {
          _forwardResponse(raw, st);
        }
      };

      txLayer.addClient(ct);
      _inviteSToC[st.id] = ct;
      ct.start();

      // Ring timeout: cancel upstream, treat as 408, try the next agent.
      final timeout = currentDecision.ringTimeout;
      if (timeout != null) {
        ringTimer = Timer(timeout, () {
          if (abandoned) return;
          abandoned = true;
          // Best-effort upstream CANCEL.
          try {
            ct.send(_buildCancelFor(ct));
          } catch (_) {}
          currentDecision.onFailed?.call(408);
          final next = currentDecision.pickNext?.call();
          if (next != null) {
            attempt(next);
          } else {
            // Tell caller the queue is empty.
            st.sendResponse(
              buildResponse(request,
                  code: 480,
                  reason: 'Temporarily Unavailable',
                  toTag: _toTagFor(request)),
              480,
            );
          }
        });
      }
    }

    // Kick off the first attempt. When no decision was supplied (plain
    // upstream / AOR routing) we synthesise a one-shot decision so the
    // attempt loop has a uniform entry point.
    final firstDecision = decision ?? DestinationDecision(client: callee);
    attempt(firstDecision);
  }

  // -------------------------------------------------------------------------
  // ACK
  // -------------------------------------------------------------------------

  void _handleAck(SipMsg request, SipTransport transport) {
    // ACK to non-2xx matches the original INVITE server transaction (RFC 3261
    // §17.2.3 — ACK uses the same branch as the INVITE) and is absorbed
    // there. ACK to 2xx is a brand-new transaction in its own right and must
    // be forwarded end-to-end via the established dialog.
    final st = txLayer.matchServer(request);
    if (st is InviteServerTransaction) {
      final absorbed = st.onAck();
      if (absorbed) {
        Log.debug('proxy', 'absorbed ACK for ${st.id}');
        return;
      }
    }

    // Resolve destination through the dialog when possible (handles cases
    // where the To.User isn't a registered AOR, e.g. PSTN gateways).
    final dialog = dialogLayer.findFromRequest(request);
    SipClient? dest;
    final originUser = request.From.User;
    if (dialog != null && originUser != null) {
      dest = dialog.peerOf(originUser);
    }
    dest ??= request.To.User == null ? null : clients[request.To.User!];
    if (dest == null) return;

    // Loose-routing fix-up: if our own URI is the topmost Route, consume it.
    final raw = request.src;
    if (raw == null) return;
    final parts = splitMessage(raw);
    final headers = List<String>.from(parts.headers);
    consumeTopRouteIfSelf(
        headers, transport.serverSocket.addr, transport.serverSocket.port);
    _upstreamSender(dest.transport)(joinMessage(headers, parts.body));
  }

  // -------------------------------------------------------------------------
  // CANCEL
  // -------------------------------------------------------------------------

  void _handleCancel(SipMsg request, SipTransport transport) {
    // CANCEL is a non-INVITE server transaction in its own right (§9.2). It
    // also references the matching INVITE server transaction by branch.
    final viaBranch = topVia(request)?.Branch;
    if (viaBranch == null) return;

    // Build the CANCEL server transaction key (it has its own branch === the
    // INVITE branch per §9.1) and find the INVITE server transaction.
    final inviteKey = '$viaBranch;${sentBy(topVia(request)!)};INVITE';
    final inviteTx = txLayer.serverTransactions
        .whereType<InviteServerTransaction>()
        .where((t) => t.id == inviteKey)
        .cast<InviteServerTransaction?>()
        .firstWhere((_) => true, orElse: () => null);

    final downstreamSend = _downstreamSender(transport);
    final cancelKey = TransactionLayer.serverKey(request);
    if (cancelKey != null) {
      final ct = NonInviteServerTransaction(
        id: cancelKey,
        branch: viaBranch,
        method: 'CANCEL',
        send: downstreamSend,
        reliable: _isReliable(transport),
      );
      txLayer.addServer(ct);
      // 200 OK to the CANCEL itself.
      ct.sendResponse(
          buildResponse(request,
              code: 200, reason: 'OK', toTag: _toTagFor(request)),
          200);
    }

    if (inviteTx != null) {
      // Generate 487 to the original INVITE.
      inviteTx.sendResponse(
        buildResponse(request,
            code: 487, reason: 'Request Terminated', toTag: _toTagFor(request)),
        487,
      );
      // Cancel the upstream INVITE leg by sending CANCEL to the callee.
      final ict = _inviteSToC.remove(inviteTx.id);
      if (ict != null) {
        // Best-effort: synthesise a CANCEL with the same branch as the
        // outbound INVITE (RFC 3261 §9.1).
        final cancel = _buildCancelFor(ict);
        ict.send(cancel);
      }
    }
  }

  String _buildCancelFor(InviteClientTransaction inviteCt) {
    final parts = splitMessage(inviteCt.request);
    final lines = parts.headers;
    if (lines.isEmpty) return inviteCt.request;
    // Replace request line method INVITE → CANCEL.
    lines[0] = lines[0].replaceFirst(RegExp(r'^INVITE\b'), 'CANCEL');
    // Update CSeq method.
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].toLowerCase().startsWith('cseq:')) {
        lines[i] = lines[i].replaceFirst(
            RegExp(r'INVITE\s*$', caseSensitive: false), 'CANCEL');
        break;
      }
    }
    // Drop the body and zero Content-Length.
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].toLowerCase().startsWith('content-length:')) {
        lines[i] = 'Content-Length: 0';
      }
    }
    return joinMessage(lines, '');
  }

  // -------------------------------------------------------------------------
  // BYE
  // -------------------------------------------------------------------------

  void _handleBye(SipMsg request, SipTransport transport) {
    // Match (or create) a non-INVITE server transaction.
    final via = topVia(request);
    final serverKey = TransactionLayer.serverKey(request);
    if (via == null || serverKey == null) return;

    final existing = txLayer.matchServer(request);
    if (existing is NonInviteServerTransaction) {
      existing.onRequestRetransmit();
      return;
    }

    final downstreamSend = _downstreamSender(transport);
    final st = NonInviteServerTransaction(
      id: serverKey,
      branch: via.Branch ?? generateBranch(),
      method: 'BYE',
      send: downstreamSend,
      reliable: _isReliable(transport),
    );
    txLayer.addServer(st);

    // Resolve dialog and remote peer.
    final dialog = dialogLayer.findFromRequest(request);
    SipClient? dest;
    final originUser = request.From.User;
    if (dialog != null && originUser != null) {
      dest = dialog.peerOf(originUser);
      // CSeq monotonicity (RFC 3261 §12.2.2). Out-of-order in-dialog request
      // → 500 Server Internal Error.
      final n = cseqNumber(request);
      if (n != null && n <= dialog.remoteSeq && dialog.remoteSeq != 0) {
        st.sendResponse(
          buildResponse(request,
              code: 500,
              reason: 'Server Internal Error',
              toTag: _toTagFor(request)),
          500,
        );
        return;
      }
      if (n != null) dialog.remoteSeq = n;
    }
    dest ??= request.To.User == null ? null : clients[request.To.User!];
    if (dest == null) {
      st.sendResponse(
        buildResponse(request,
            code: 481,
            reason: 'Call/Transaction Does Not Exist',
            toTag: _toTagFor(request)),
        481,
      );
      return;
    }

    // Loose-routing fix-up + Via + Max-Forwards.
    final parts = splitMessage(request.src ?? '');
    final headers = List<String>.from(parts.headers);
    consumeTopRouteIfSelf(
        headers, transport.serverSocket.addr, transport.serverSocket.port);
    final mf = decrementMaxForwards(headers);
    if (mf == null) {
      st.sendResponse(
        buildResponse(request,
            code: 483, reason: 'Too Many Hops', toTag: _toTagFor(request)),
        483,
      );
      return;
    }

    final outBranch = generateBranch();
    final selfHost = transport.serverSocket.addr;
    final selfPort = transport.serverSocket.port;
    final selfProto = transport.serverSocket.transport.toUpperCase();
    prependVia(
      headers,
      'Via: SIP/2.0/$selfProto $selfHost:$selfPort;branch=$outBranch;rport',
    );

    final forwarded = joinMessage(headers, parts.body);
    final upstreamSend = _upstreamSender(dest.transport);
    final ct = NonInviteClientTransaction(
      id: TransactionLayer.clientKeyFromOutbound(outBranch, 'BYE'),
      branch: outBranch,
      method: 'BYE',
      send: upstreamSend,
      reliable: _isReliable(dest.transport),
      request: forwarded,
    );
    ct.onFinalResponse = (raw, code) {
      _forwardResponse(raw, st);
      // Tear down the dialog on 2xx.
      if (code >= 200 && code < 300) {
        final parsed = SipMsg()..Parse(raw);
        final d = dialogLayer.findFromResponse(parsed);
        if (d != null) {
          d.state = DialogState.terminated;
          d.cancelSessionTimer();
          d.onTerminated?.call();
          dialogLayer.remove(d);
        }
      }
    };
    ct.onProvisional = (raw, code) => _forwardResponse(raw, st);
    txLayer.addClient(ct);
    ct.start();
  }

  // -------------------------------------------------------------------------
  // Plumbing
  // -------------------------------------------------------------------------

  /// Forwards a response upstream-to-downstream after stripping our own Via.
  /// Feeds the result into the matching server transaction so retransmits are
  /// handled correctly.
  void _forwardResponse(String raw, Transaction serverTx) {
    final parts = splitMessage(raw);
    final headers = List<String>.from(parts.headers);
    popTopVia(headers); // remove our hop's Via
    final out = joinMessage(headers, parts.body);
    final code = _statusCode(headers.isEmpty ? '' : headers[0]) ?? 0;
    if (serverTx is InviteServerTransaction) {
      serverTx.sendResponse(out, code);
    } else if (serverTx is NonInviteServerTransaction) {
      serverTx.sendResponse(out, code);
    }
  }

  void _statelessForwardResponse(SipMsg response) {
    final parts = splitMessage(response.src ?? '');
    final headers = List<String>.from(parts.headers);
    popTopVia(headers);
    if (headers.length < 2) return;
    // After popping there should still be at least one Via — that's the next
    // downstream hop. We can't reliably reach it from here without a full
    // routing table; drop with a log.
    Log.warn('proxy',
        'dropping stateless response (no client transaction): ${headers[0]}');
  }

  int? _statusCode(String statusLine) {
    final parts = statusLine.split(' ');
    if (parts.length < 2) return null;
    return int.tryParse(parts[1]);
  }

  String _toTagFor(SipMsg request) {
    final callId = request.CallId.Value;
    if (callId == null) return generateTag();
    return _proxyToTags.putIfAbsent(callId, generateTag);
  }

  bool _isReliable(SipTransport tx) {
    final p = tx.serverSocket.transport.toLowerCase();
    return p == 'tcp' || p == 'tls' || p == 'ws' || p == 'wss';
  }

  /// Finds the *raw* value (everything after the first colon) of the named
  /// header in the wire-form message, returning null when absent. Case-
  /// insensitive on the header name.
  static String? _findRawHeader(String raw, String name) {
    final headers = raw.split('\r\n');
    final needle = name.toLowerCase();
    for (final h in headers) {
      final colon = h.indexOf(':');
      if (colon <= 0) continue;
      if (h.substring(0, colon).trim().toLowerCase() == needle) {
        return h.substring(colon + 1).trim();
      }
    }
    return null;
  }

  TxSendFn _downstreamSender(SipTransport transport) {
    final isUdp = transport.serverSocket.transport.toLowerCase() == 'udp';
    return (String raw) {
      if (isUdp) {
        transport.send(raw,
            destIp: transport.socket.addr, destPort: transport.socket.port);
      } else {
        transport.send(raw);
      }
    };
  }

  TxSendFn _upstreamSender(SipTransport transport) {
    final isUdp = transport.serverSocket.transport.toLowerCase() == 'udp';
    return (String raw) {
      if (isUdp) {
        transport.send(raw,
            destIp: transport.socket.addr, destPort: transport.socket.port);
      } else {
        transport.send(raw);
      }
    };
  }

  // -------------------------------------------------------------------------
  // In-dialog re-INVITE (RFC 3261 §14) and UPDATE (RFC 3311).
  //
  // Both methods stay inside an existing dialog. We route them to the dialog
  // peer (rather than the AOR map) and, for INVITE, refresh the session
  // timer when the 2xx carries a new Session-Expires.
  // -------------------------------------------------------------------------

  void _handleReInvite(
    SipMsg request,
    SipTransport transport,
    Dialog dialog,
    sipVia via,
    String serverKey,
  ) {
    final downstreamSend = _downstreamSender(transport);
    final st = InviteServerTransaction(
      id: serverKey,
      branch: via.Branch ?? generateBranch(),
      send: downstreamSend,
      reliable: _isReliable(transport),
    );
    txLayer.addServer(st);

    // CSeq monotonicity (§12.2.2).
    final n = cseqNumber(request);
    if (n != null && dialog.remoteSeq != 0 && n <= dialog.remoteSeq) {
      st.sendResponse(
        buildResponse(request,
            code: 500,
            reason: 'Server Internal Error',
            toTag: dialog.id.remoteTag),
        500,
      );
      return;
    }
    if (n != null) dialog.remoteSeq = n;

    // Resolve peer through the dialog.
    final originUser = request.From.User;
    final dest = originUser == null ? null : dialog.peerOf(originUser);
    if (dest == null) {
      st.sendResponse(
        buildResponse(request,
            code: 481,
            reason: 'Call/Transaction Does Not Exist',
            toTag: dialog.id.remoteTag),
        481,
      );
      return;
    }

    st.sendTrying(request);

    // Forward: strip self-Route, add Via, decrement Max-Forwards. We do NOT
    // add Record-Route again — the route set was locked in at dialog setup.
    final parts = splitMessage(request.src ?? '');
    final headers = List<String>.from(parts.headers);
    consumeTopRouteIfSelf(
        headers, transport.serverSocket.addr, transport.serverSocket.port);
    final mf = decrementMaxForwards(headers);
    if (mf == null) {
      st.sendResponse(
        buildResponse(request,
            code: 483, reason: 'Too Many Hops', toTag: dialog.id.remoteTag),
        483,
      );
      return;
    }
    final outBranch = generateBranch();
    final selfHost = transport.serverSocket.addr;
    final selfPort = transport.serverSocket.port;
    final selfProto = transport.serverSocket.transport.toUpperCase();
    prependVia(
      headers,
      'Via: SIP/2.0/$selfProto $selfHost:$selfPort;branch=$outBranch;rport',
    );
    final forwarded = joinMessage(headers, parts.body);

    final ct = InviteClientTransaction(
      id: TransactionLayer.clientKeyFromOutbound(outBranch, 'INVITE'),
      branch: outBranch,
      send: _upstreamSender(dest.transport),
      reliable: _isReliable(dest.transport),
      request: forwarded,
    );
    ct.onProvisional = (raw, code) => _forwardResponse(raw, st);
    ct.onFinalResponse = (raw, code) {
      _forwardResponse(raw, st);
      if (code >= 200 && code < 300) {
        // Target refresh: update remote target from new Contact (§12.2.1.3).
        final parsed = SipMsg()..Parse(raw);
        final newContact = parsed.Contact.Src;
        if (newContact != null && newContact.isNotEmpty) {
          dialog.remoteTarget = newContact;
        }
        // RFC 4028: refresh session timer from the new 2xx.
        final rrParts = splitMessage(raw);
        _armSessionTimer(dialog, rrParts.headers);
      }
    };
    txLayer.addClient(ct);
    _inviteSToC[st.id] = ct;
    ct.start();
  }

  /// Generic in-dialog non-INVITE forwarder (UPDATE, INFO, NOTIFY, …).
  void _handleInDialogNonInvite(
    SipMsg request,
    SipTransport transport, {
    required String method,
  }) {
    final via = topVia(request);
    final serverKey = TransactionLayer.serverKey(request);
    if (via == null || serverKey == null) return;

    final existing = txLayer.matchServer(request);
    if (existing is NonInviteServerTransaction) {
      existing.onRequestRetransmit();
      return;
    }

    final downstreamSend = _downstreamSender(transport);
    final st = NonInviteServerTransaction(
      id: serverKey,
      branch: via.Branch ?? generateBranch(),
      method: method,
      send: downstreamSend,
      reliable: _isReliable(transport),
    );
    txLayer.addServer(st);

    final dialog = dialogLayer.findFromRequest(request);
    if (dialog == null) {
      st.sendResponse(
        buildResponse(request,
            code: 481,
            reason: 'Call/Transaction Does Not Exist',
            toTag: _toTagFor(request)),
        481,
      );
      return;
    }

    final n = cseqNumber(request);
    if (n != null && dialog.remoteSeq != 0 && n <= dialog.remoteSeq) {
      st.sendResponse(
        buildResponse(request,
            code: 500,
            reason: 'Server Internal Error',
            toTag: dialog.id.remoteTag),
        500,
      );
      return;
    }
    if (n != null) dialog.remoteSeq = n;

    final originUser = request.From.User;
    final dest = originUser == null ? null : dialog.peerOf(originUser);
    if (dest == null) {
      st.sendResponse(
        buildResponse(request,
            code: 481,
            reason: 'Call/Transaction Does Not Exist',
            toTag: dialog.id.remoteTag),
        481,
      );
      return;
    }

    final parts = splitMessage(request.src ?? '');
    final headers = List<String>.from(parts.headers);
    consumeTopRouteIfSelf(
        headers, transport.serverSocket.addr, transport.serverSocket.port);
    final mf = decrementMaxForwards(headers);
    if (mf == null) {
      st.sendResponse(
        buildResponse(request,
            code: 483, reason: 'Too Many Hops', toTag: dialog.id.remoteTag),
        483,
      );
      return;
    }
    final outBranch = generateBranch();
    final selfHost = transport.serverSocket.addr;
    final selfPort = transport.serverSocket.port;
    final selfProto = transport.serverSocket.transport.toUpperCase();
    prependVia(
      headers,
      'Via: SIP/2.0/$selfProto $selfHost:$selfPort;branch=$outBranch;rport',
    );
    final forwarded = joinMessage(headers, parts.body);

    final ct = NonInviteClientTransaction(
      id: TransactionLayer.clientKeyFromOutbound(outBranch, method),
      branch: outBranch,
      method: method,
      send: _upstreamSender(dest.transport),
      reliable: _isReliable(dest.transport),
      request: forwarded,
    );
    ct.onProvisional = (raw, code) => _forwardResponse(raw, st);
    ct.onFinalResponse = (raw, code) {
      _forwardResponse(raw, st);
      if (method == 'UPDATE' && code >= 200 && code < 300) {
        // RFC 4028: UPDATE may also carry a fresh Session-Expires.
        final rrParts = splitMessage(raw);
        _armSessionTimer(dialog, rrParts.headers);
      }
    };
    txLayer.addClient(ct);
    ct.start();
  }

  // -------------------------------------------------------------------------
  // RFC 4028 Session Timer (monitor mode).
  // -------------------------------------------------------------------------

  void _armSessionTimer(Dialog dialog, List<String> responseHeaders) {
    final raw = _findHeaderInList(responseHeaders, 'Session-Expires') ??
        _findHeaderInList(responseHeaders, 'x');
    if (raw == null) return;
    final params = raw.split(';');
    final secs = int.tryParse(params.first.trim());
    if (secs == null || secs <= 0) return;
    String? refresher;
    for (final p in params.skip(1)) {
      final kv = p.trim();
      if (kv.toLowerCase().startsWith('refresher=')) {
        refresher = kv.substring('refresher='.length).toLowerCase();
      }
    }
    dialog.sessionExpires = secs;
    dialog.sessionRefresher = refresher;
    dialog.cancelSessionTimer();
    dialog.sessionTimer = Timer(Duration(seconds: secs), () {
      _onSessionTimerExpired(dialog);
    });
  }

  void _onSessionTimerExpired(Dialog dialog) {
    if (dialog.state == DialogState.terminated) return;
    Log.warn('session-timer', 'expired for dialog ${dialog.id}; tearing down');
    final caller = dialog.caller;
    final callee = dialog.callee;
    if (caller != null) _sendBye(dialog, caller, fromCaller: false);
    if (callee != null) _sendBye(dialog, callee, fromCaller: true);
    dialog.state = DialogState.terminated;
    dialog.onTerminated?.call();
    dialogLayer.remove(dialog);
  }

  /// Sends a minimal in-dialog BYE to [target]. [fromCaller] flips the
  /// From/To headers so the request looks like it came from the *other* leg.
  void _sendBye(Dialog dialog, SipClient target, {required bool fromCaller}) {
    final transport = target.transport;
    final selfHost = transport.serverSocket.addr;
    final selfPort = transport.serverSocket.port;
    final selfProto = transport.serverSocket.transport.toUpperCase();
    final branch = generateBranch();
    final cseq = ++dialog.localSeq;
    final dest = dialog.remoteTarget.isNotEmpty
        ? dialog.remoteTarget
        : 'sip:${target.number}@$selfHost';

    // From/To selection: the request must look like it originated at the
    // peer of [target]. We approximate by using the dialog's local/remote
    // URIs flipped accordingly.
    final fromUri = fromCaller ? dialog.localUri : dialog.remoteUri;
    final toUri = fromCaller ? dialog.remoteUri : dialog.localUri;
    final fromTag = fromCaller ? dialog.id.localTag : dialog.id.remoteTag;
    final toTag = fromCaller ? dialog.id.remoteTag : dialog.id.localTag;

    final lines = <String>[
      'BYE $dest SIP/2.0',
      'Via: SIP/2.0/$selfProto $selfHost:$selfPort;branch=$branch;rport',
      'Max-Forwards: 70',
      'From: <sip:$fromUri>;tag=$fromTag',
      'To: <sip:$toUri>;tag=$toTag',
      'Call-ID: ${dialog.id.callId}',
      'CSeq: $cseq BYE',
      'Reason: SIP;cause=408;text="Session timer expired"',
      'User-Agent: dart-pbx',
      'Content-Length: 0',
      '',
      '',
    ];
    _upstreamSender(transport)(lines.join('\r\n'));
  }

  static String? _findHeaderInList(List<String> headers, String name) {
    final needle = name.toLowerCase();
    for (final h in headers) {
      final colon = h.indexOf(':');
      if (colon <= 0) continue;
      if (h.substring(0, colon).trim().toLowerCase() == needle) {
        return h.substring(colon + 1).trim();
      }
    }
    return null;
  }
}

/// Routing decision returned by [StatefulProxy.resolveDestination]. Carries
/// both the chosen [SipClient] and lifecycle callbacks the caller (typically
/// the call-center) wants to receive for the resulting INVITE transaction.
class DestinationDecision {
  DestinationDecision({
    required this.client,
    this.onAnswered,
    this.onFailed,
    this.onHangup,
    this.ringTimeout,
    this.pickNext,
  });

  /// Endpoint to ring for this attempt.
  final SipClient client;

  /// Fired when the upstream answers with a 2xx final response.
  final void Function()? onAnswered;

  /// Fired when this attempt ends in any non-2xx final or in a no-answer
  /// timeout (synthetic 408). Always fires before [pickNext] is consulted.
  final void Function(int statusCode)? onFailed;

  /// Fired when the dialog established by this attempt eventually terminates
  /// (BYE 2xx or session-timer expiry).
  final void Function()? onHangup;

  /// If set, the proxy starts a per-attempt timer when the INVITE goes out.
  /// When the timer fires before any final response, the proxy cancels the
  /// attempt upstream, fires [onFailed] with a synthetic 408, and consults
  /// [pickNext] for a re-pick. When null, the attempt rings indefinitely.
  final Duration? ringTimeout;

  /// Optional callback invoked after [onFailed]. Returning a fresh decision
  /// causes the proxy to start another INVITE attempt to that destination
  /// without telling the caller about the previous failure. Returning null
  /// means "give up — let the caller see the failure".
  final DestinationDecision? Function()? pickNext;
}
