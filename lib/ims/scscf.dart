// Serving-CSCF (S-CSCF) — TS 24.229 §5.4.
//
// The S-CSCF is the central node of the IMS signalling plane. It:
//
//   * Authenticates REGISTER (digest-MD5 here; real IMS uses AKAv1-MD5
//     with credentials from an ISIM via Cx MAR/MAA).
//   * Maintains the registration binding for each IMPU.
//   * Builds the Service-Route header returned in 200 OK to REGISTER.
//   * Applies originating Initial Filter Criteria on outbound requests.
//   * Applies terminating iFC on inbound requests for users it serves.
//   * Routes terminating requests back through the Path of the served UE.
//
// Auth scope: this implementation supports digest-MD5 (RFC 2617) which is
// what TR 33.978 ("Early IMS security") and TISPAN/CableLabs profiles
// permit. Full AKAv1-MD5 (TS 33.203) requires Cx MAR with vector tuples
// from the HSS and ISIM-side computation; the architecture here would
// support it by replacing [DigestAuth] with an AKA verifier and feeding
// the AV through `Authentication-Info`.

import 'package:dart_pbx/logging.dart';
import 'package:dart_pbx/proxy/digest_auth.dart';
import 'package:dart_pbx/proxy/sip_helpers.dart' as h;
import 'package:dart_pbx/sip_parser/sip.dart';
import 'package:dart_pbx/sip_parser/sip_message_types.dart';
import 'package:dart_pbx/transports/transport.dart';

import 'aka.dart';
import 'hss.dart';
import 'ims_headers.dart' as ih;

/// One registration binding from the S-CSCF's point of view.
class _ScscfBinding {
  _ScscfBinding({
    required this.impu,
    required this.impi,
    required this.contactUri,
    required this.path,
    required this.expiresAt,
    this.emergency = false,
  });
  final String impu;
  final String impi;
  final String contactUri;

  /// Path header values copied from the REGISTER (RFC 3327 §5.2). Used
  /// as a preloaded Route set on terminating requests so they walk back
  /// to the right P-CSCF.
  final List<String> path;
  DateTime expiresAt;

  /// True when this binding was created via an emergency REGISTER
  /// (TS 24.229 §5.4.1.2.2). Emergency bindings are short-lived, may not
  /// be used for non-emergency originating requests, and are unauthenticated
  /// when the network policy allows it.
  final bool emergency;
}

/// Result of running the iFC engine on a request.
class IfcMatch {
  IfcMatch(this.applicationServer, this.defaultHandling);
  final String applicationServer;
  final DefaultHandling defaultHandling;
}

class Scscf {
  Scscf({
    required this.name,
    required this.host,
    required this.port,
    required this.transport,
    required this.hss,
    required this.replyLocal,
    required this.routeToTerminating,
    required this.routeToOffNet,
    DigestAuth? auth,
    AkaAuth? aka,
  })  : auth = auth ?? DigestAuth(realm: hss.realm),
        aka = aka ?? AkaAuth(realm: hss.realm);

  /// Logical name of this S-CSCF as known to the HSS.
  final String name;

  /// Reachable address used in Service-Route / Record-Route / itself.
  final String host;
  final int port;
  final String transport;

  final HomeSubscriberServer hss;

  /// Send a final response back through the chain (collocated:
  /// IMS Core → P-CSCF → UE).
  void Function(SipMsg response) replyLocal;

  /// Hand a fully-routed terminating request to the IMS Core. The Core
  /// looks up the served UE's P-CSCF binding (in collocated mode the
  /// only one) and delivers it via [Pcscf.deliverToUe].
  void Function(String impu, SipMsg request, SipTransport inbound)
      routeToTerminating;

  /// Off-net (BGCF / IBCF / PSTN gateway) routing for non-IMS callees.
  /// Implementations may forward to an Asterisk back-end, an upstream SBC,
  /// or generate 404 if no breakout is configured.
  void Function(SipMsg request, SipTransport inbound) routeToOffNet;

  /// Sink for third-party REGISTERs the S-CSCF generates on behalf of a
  /// served UE (TS 24.229 §5.4.1.7). Default is a no-op so deployments
  /// without ASes don't need to wire anything.
  void Function(SipMsg request) thirdPartyRegister = ((SipMsg _) {});

  final DigestAuth auth;

  /// AKAv1-MD5 verifier (RFC 3310). Only used for IMPIs provisioned with
  /// ISIM key material via [HomeSubscriberServer.provisionAka].
  final AkaAuth aka;

  /// IMPU → binding (one Contact per IMPU is fine for v1; real IMS allows
  /// multiple contacts per AOR and forking).
  final Map<String, _ScscfBinding> _bindings = {};

  String get serviceRouteUri =>
      'sip:$name@$host:$port;transport=$transport;lr;orig';

  String get recordRouteUri => 'sip:$name@$host:$port;transport=$transport;lr';

  // -------------------------------------------------------------------------
  // REGISTER
  // -------------------------------------------------------------------------

  void onRequest(SipMsg request, SipTransport inbound) {
    final method = request.Req.Method?.toUpperCase();
    if (method == null) return;
    if (method == 'REGISTER') {
      _handleRegister(request, inbound);
      return;
    }
    _handleInitial(request, inbound, method);
  }

  void _handleRegister(SipMsg request, SipTransport inbound) {
    final emergency = _isEmergencyRegister(request);

    final impu = _impuOfTo(request);
    if (impu == null) {
      _reject(request, 400, 'Bad Request');
      return;
    }

    // Emergency REGISTER (TS 24.229 §5.4.1.2.2): if the network supports
    // unauthenticated emergency registration, the S-CSCF skips Cx MAR and
    // accepts the registration immediately, creating a short-lived
    // emergency binding. Authenticated emergency REGISTER (subscriber is
    // known) goes through the normal auth path but the resulting binding
    // is still flagged as emergency.
    final sub = hss.subscriptionByImpu(impu);
    final isAuthenticatedEmergency = emergency && sub != null;
    final isUnauthenticatedEmergency = emergency && sub == null;

    if (sub == null && !isUnauthenticatedEmergency) {
      _reject(request, 403, 'Forbidden — User Unknown');
      return;
    }
    final impi = sub?.impi ?? _syntheticEmergencyImpi(request);

    final authHeader = _findRawHeader(request.src ?? '', 'Authorization');
    if (!isUnauthenticatedEmergency) {
      if (sub != null && hss.isAka(impi)) {
        if (!_handleAkaRegister(request, impi, authHeader)) return;
      } else {
        if (!_handleDigestRegister(request, authHeader)) return;
      }
    } else {
      Log.debug('ims.scscf',
          'emergency REGISTER (unauthenticated) IMPU=$impu IMPI=$impi');
    }

    // Authorization passed (or skipped for unauthenticated emergency).
    // Cx SAR — formally claim the subscription when known.
    if (sub != null) {
      hss.serverAssignment(impi: impi, scscfName: name);
    }

    // Compute granted expires (capped to 1h here; a real S-CSCF would
    // honour Service-Profile policy).
    final headerExpires =
        int.tryParse(_findRawHeader(request.src ?? '', 'Expires') ?? '');
    final contactExpires = int.tryParse(request.Contact.Expires ?? '');
    final granted = (contactExpires ?? headerExpires ?? 3600).clamp(0, 7200);

    // Emergency bindings are capped to 600s per TS 24.229 (typical operator
    // policy: emergency registration must be re-issued frequently).
    final cappedGranted = emergency ? granted.clamp(0, 600) : granted;

    final paths = ih.readPaths(_headersOf(request));
    final contactUri = _extractContactUri(request);

    if (cappedGranted == 0) {
      _bindings.remove(impu);
      if (sub != null) {
        hss.serverAssignment(impi: impi, scscfName: name, deregister: true);
      }
    } else if (contactUri != null) {
      _bindings[impu] = _ScscfBinding(
        impu: impu,
        impi: impi,
        contactUri: contactUri,
        path: paths,
        expiresAt: DateTime.now().add(Duration(seconds: cappedGranted)),
        emergency: emergency,
      );
    }

    final extra = <String, String>{};
    if (cappedGranted > 0) {
      extra['Service-Route'] = '<$serviceRouteUri>';
    }
    if (sub != null) {
      extra['P-Associated-URI'] = sub.impus.map((u) => '<$u>').join(', ');
    } else {
      // Unauthenticated emergency: the only public ID is the one in the To.
      extra['P-Associated-URI'] = '<$impu>';
    }
    // Advertise the granted lifetime (RFC 3261 §10.2.4). Also lets the
    // emergency cap surface on the wire.
    extra['Expires'] = '$cappedGranted';

    final raw = h.buildResponse(
      request,
      code: 200,
      reason: SipMessageTypes.OK.split(' ').sublist(2).join(' '),
      toTag: h.generateTag(),
      extraHeaders: extra,
    );
    // Re-emit Path so the P-CSCF can stash + strip it (RFC 3327 §5.3).
    final lines = raw.split('\r\n');
    final rebuilt = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      rebuilt.write(lines[i]);
      rebuilt.write('\r\n');
      if (i == 0) {
        for (final p in paths) {
          rebuilt.write('Path: <$p>\r\n');
        }
      }
    }
    Log.debug(
        'ims.scscf',
        'REGISTER OK IMPU=$impu IMPI=$impi expires=$cappedGranted '
            'emergency=$emergency paths=${paths.length}');
    replyLocal(SipMsg()..Parse(rebuilt.toString()));

    // Third-party REGISTER (TS 24.229 §5.4.1.7): for each iFC of the
    // registering user matching the REGISTER method, fire a fresh
    // REGISTER on behalf of the UE so the AS learns of the (de)reg.
    if (sub != null) {
      _fireThirdPartyRegisters(
        sub: sub,
        impu: impu,
        granted: cappedGranted,
        originalRequest: request,
      );
    }

    // Fan-out reg-event NOTIFYs (RFC 3680) to anyone subscribed to this
    // AOR's registration state.
    _notifyRegSubscribers(impu);
  }

  void _fireThirdPartyRegisters({
    required ImsSubscription sub,
    required String impu,
    required int granted,
    required SipMsg originalRequest,
  }) {
    final profile = sub.profiles[impu];
    if (profile == null) return;
    final fired = <String>{}; // de-dup per AS within one trigger
    for (final ifc in profile.ifcs) {
      if (ifc.method == null || ifc.method!.toUpperCase() != 'REGISTER') {
        continue;
      }
      if (!fired.add(ifc.applicationServer)) continue;
      final r = _buildThirdPartyRegister(
        asUri: ifc.applicationServer,
        impu: impu,
        expires: granted,
        callId: 'tpr-${DateTime.now().microsecondsSinceEpoch}-${fired.length}',
      );
      Log.debug('ims.scscf',
          '3rd-party REGISTER → ${ifc.applicationServer} for $impu (expires=$granted)');
      thirdPartyRegister(r);
    }
  }

  /// Builds the third-party REGISTER on-the-wire form. The body field of
  /// `multipart/mixed` carrying the original REGISTER + 200 OK (TS 24.229
  /// §5.4.1.7) is omitted in this minimal implementation; ASes that need
  /// it can be added later.
  SipMsg _buildThirdPartyRegister({
    required String asUri,
    required String impu,
    required int expires,
    required String callId,
  }) {
    final scscfUri = 'sip:$name@$host:$port;transport=$transport';
    final branch = 'z9hG4bK-tpr-${callId.hashCode.toUnsigned(32)}';
    final lines = <String>[
      'REGISTER $asUri SIP/2.0',
      'Via: SIP/2.0/$transport $host:$port;branch=$branch;rport',
      'Max-Forwards: 70',
      'From: <$scscfUri>;tag=${h.generateTag()}',
      'To: <$impu>',
      'Call-ID: $callId',
      'CSeq: 1 REGISTER',
      'Contact: <$scscfUri>',
      'Expires: $expires',
      'P-Asserted-Identity: <$scscfUri>',
      'Content-Length: 0',
    ];
    final raw = '${lines.join('\r\n')}\r\n\r\n';
    return SipMsg()..Parse(raw);
  }

  // -------------------------------------------------------------------------
  // RFC 3680 reg-event package
  // -------------------------------------------------------------------------

  /// Active subscriptions to the `reg` event package, keyed by AOR.
  final Map<String, List<_RegSubscription>> _regSubs = {};

  /// Per-AOR monotonically increasing version number for reginfo NOTIFYs
  /// (RFC 3680 §5.2 requires the receiver to discard out-of-order docs).
  final Map<String, int> _regVersion = {};

  void _handleRegEventSubscribe(
      SipMsg request, SipTransport inbound, String? aor) {
    if (aor == null) {
      _reject(request, 400, 'Bad Request — Missing AOR');
      return;
    }
    final expiresHdr =
        int.tryParse(_findRawHeader(request.src ?? '', 'Expires') ?? '');
    final expires = (expiresHdr ?? 3600).clamp(0, 7200);
    final fromTag = request.From.Tag ?? '';
    final toTag = h.generateTag();
    final callId = request.CallId.Value ?? '';

    // 200 OK to the SUBSCRIBE.
    final extra = <String, String>{'Expires': '$expires'};
    final okRaw = h.buildResponse(
      request,
      code: 200,
      reason: SipMessageTypes.OK.split(' ').sublist(2).join(' '),
      toTag: toTag,
      extraHeaders: extra,
    );
    replyLocal(SipMsg()..Parse(okRaw));

    if (expires == 0) {
      // Unsubscribe — drop matching dialog and emit a final NOTIFY.
      _regSubs[aor]
          ?.removeWhere((s) => s.callId == callId && s.fromTag == fromTag);
      return;
    }

    // Stash the subscription dialog.
    final contactUri = _extractContactUri(request) ?? aor;
    final sub = _RegSubscription(
      aor: aor,
      callId: callId,
      fromTag: fromTag,
      toTag: toTag,
      remoteContact: contactUri,
      remoteUri: 'sip:${request.From.User}@${request.From.Host}',
      expiresAt: DateTime.now().add(Duration(seconds: expires)),
      transport: inbound,
      cseq: 0,
    );
    _regSubs.putIfAbsent(aor, () => []).add(sub);

    // Immediate NOTIFY (RFC 3265 §3.1.4.2 / RFC 3680 §4).
    _emitRegNotify(sub, state: 'active', expires: expires);
  }

  // -------------------------------------------------------------------------
  // RFC 4028 — Session-Timers proxy enforcement
  // -------------------------------------------------------------------------

  /// Operator minimum session refresh interval (RFC 4028 §4 default 90s).
  static const int minSessionExpires = 90;

  /// Returns true when the request is OK to forward, false when a 422
  /// has been sent and processing must stop.
  bool _enforceSessionTimers(SipMsg request) {
    final raw = request.src ?? '';
    final seHeader = _findRawHeader(raw, 'Session-Expires') ??
        _findRawHeader(raw, 'x'); // RFC 4028 compact form
    if (seHeader != null) {
      final seVal = _firstIntToken(seHeader);
      if (seVal != null && seVal < minSessionExpires) {
        // 422 Session Interval Too Small (RFC 4028 §6).
        final raw422 = h.buildResponse(
          request,
          code: 422,
          reason: 'Session Interval Too Small',
          toTag: h.generateTag(),
          extraHeaders: {'Min-SE': '$minSessionExpires'},
        );
        Log.debug(
            'ims.scscf', 'Session-Expires=$seVal < $minSessionExpires → 422');
        replyLocal(SipMsg()..Parse(raw422));
        return false;
      }
    }
    // Insert Min-SE if missing so the UAS sees a coherent floor
    // (RFC 4028 §5).
    if (_findRawHeader(raw, 'Min-SE') == null) {
      final parts = h.splitMessage(raw);
      final headers = List<String>.from(parts.headers);
      headers.add('Min-SE: $minSessionExpires');
      final rebuilt = h.joinMessage(headers, parts.body);
      // Mutate the request in-place so downstream sees the new header.
      request.Parse(rebuilt);
    }
    return true;
  }

  int? _firstIntToken(String s) {
    final m = RegExp(r'\d+').firstMatch(s);
    return m == null ? null : int.tryParse(m.group(0)!);
  }

  /// Detects the SUBSCRIBE Event header. Returns the package name (lower
  /// case) without parameters, or null when the header is absent.
  String? _eventPackage(SipMsg request) {
    final value = _findRawHeader(request.src ?? '', 'Event') ??
        _findRawHeader(request.src ?? '', 'o'); // RFC 3265 compact form
    if (value == null) return null;
    final semi = value.indexOf(';');
    return (semi < 0 ? value : value.substring(0, semi)).trim().toLowerCase();
  }

  /// Sends a NOTIFY for [sub] with current registration info.
  void _emitRegNotify(_RegSubscription sub,
      {required String state, required int expires}) {
    sub.cseq++;
    final version = (_regVersion[sub.aor] ?? 0) + 1;
    _regVersion[sub.aor] = version;
    final body = _buildReginfo(sub.aor, version: version);
    final scscfUri = 'sip:$name@$host:$port;transport=$transport';
    final lines = <String>[
      'NOTIFY ${sub.remoteContact} SIP/2.0',
      'Via: SIP/2.0/$transport $host:$port;'
          'branch=z9hG4bK-ntfy-${DateTime.now().microsecondsSinceEpoch};rport',
      'Max-Forwards: 70',
      'From: <${sub.aor}>;tag=${sub.toTag}',
      'To: <${sub.remoteUri}>;tag=${sub.fromTag}',
      'Call-ID: ${sub.callId}',
      'CSeq: ${sub.cseq} NOTIFY',
      'Contact: <$scscfUri>',
      'Event: reg',
      'Subscription-State: $state${state == 'active' ? ';expires=$expires' : ''}',
      'Content-Type: application/reginfo+xml',
      'Content-Length: ${body.length}',
      '',
      body,
    ];
    final raw = lines.join('\r\n');
    final msg = SipMsg()..Parse(raw);
    Log.debug('ims.scscf',
        'NOTIFY reg → ${sub.remoteContact} state=$state version=$version');
    routeToTerminating(sub.aor, msg, sub.transport);
  }

  /// Fan-out NOTIFY to all subscribers of a given AOR. Called whenever
  /// registration state for [aor] changes.
  void _notifyRegSubscribers(String aor) {
    final subs = _regSubs[aor];
    if (subs == null) return;
    final now = DateTime.now();
    subs.removeWhere((s) => s.expiresAt.isBefore(now));
    for (final s in subs) {
      final remaining = s.expiresAt.difference(now).inSeconds;
      _emitRegNotify(s, state: 'active', expires: remaining);
    }
  }

  /// Minimal reginfo+xml document (RFC 3680 §5).
  String _buildReginfo(String aor, {required int version}) {
    final binding = _bindings[aor];
    final regState = binding == null ? 'terminated' : 'active';
    final contactBlock = binding == null
        ? ''
        : '''
    <contact id="c1" state="active" event="registered">
      <uri>${_xmlEscape(binding.contactUri)}</uri>
    </contact>''';
    return '''<?xml version="1.0"?>
<reginfo xmlns="urn:ietf:params:xml:ns:reginfo" version="$version" state="full">
  <registration aor="${_xmlEscape(aor)}" id="r1" state="$regState">$contactBlock
  </registration>
</reginfo>''';
  }

  static String _xmlEscape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  // -------------------------------------------------------------------------
  // REGISTER auth — split between plain digest and IMS-AKA.
  // -------------------------------------------------------------------------

  /// Returns true if the request should proceed (auth OK), false if a 401
  /// challenge has been sent and processing must stop.
  bool _handleDigestRegister(SipMsg request, String? authHeader) {
    final result = auth.verify(
      headerValue: authHeader,
      method: 'REGISTER',
      credentials: hss.credentials,
    );
    if (result == AuthResult.ok) return true;
    final stale = result == AuthResult.stale;
    final challenge = auth.challengeHeaderValue(stale: stale);
    final raw = h.buildResponse(
      request,
      code: 401,
      reason: 'Unauthorized',
      toTag: h.generateTag(),
      extraHeaders: {'WWW-Authenticate': challenge},
    );
    replyLocal(SipMsg()..Parse(raw));
    return false;
  }

  bool _handleAkaRegister(SipMsg request, String impi, String? authHeader) {
    final verification = aka.verify(
      headerValue: authHeader,
      method: 'REGISTER',
    );
    switch (verification.result) {
      case AkaResult.ok:
        return true;

      case AkaResult.resync:
        // UE detected SQN out of range. Recover SQN_MS from AUTS, then
        // issue a fresh AV (TS 33.102 §6.3.5 + RFC 3310 §3.3).
        final ok = hss.resync(
          impi: impi,
          rand: verification.rand!,
          auts: verification.auts!,
        );
        Log.debug('ims.scscf',
            'AKA resync IMPI=$impi macSValid=$ok — issuing fresh challenge');
        _issueAkaChallenge(request, impi);
        return false;

      case AkaResult.missing:
      case AkaResult.failed:
        _issueAkaChallenge(request, impi);
        return false;
    }
  }

  void _issueAkaChallenge(SipMsg request, String impi) {
    // Cx MAR/MAA — fetch one fresh AV.
    final avs = hss.multimediaAuth(impi: impi, n: 1);
    if (avs == null || avs.isEmpty) {
      _reject(request, 403, 'Forbidden — Authentication Vector Unavailable');
      return;
    }
    final challenge = aka.challengeHeaderValue(avs.first);
    final raw = h.buildResponse(
      request,
      code: 401,
      reason: 'Unauthorized',
      toTag: h.generateTag(),
      extraHeaders: {'WWW-Authenticate': challenge},
    );
    replyLocal(SipMsg()..Parse(raw));
  }

  // -------------------------------------------------------------------------

  // -------------------------------------------------------------------------
  // Initial / re-INVITE etc.
  // -------------------------------------------------------------------------

  void _handleInitial(SipMsg request, SipTransport inbound, String method) {
    final fromImpu = _impuOf(request.From.User, request.From.Host);
    final toImpu = _impuOf(request.To.User, request.To.Host);

    // SUBSCRIBE for the `reg` event package (RFC 3680 / TS 24.229
    // §5.4.2.1) is terminated locally by the S-CSCF — it is the
    // authoritative source for registration state.
    if (method == 'SUBSCRIBE' && _eventPackage(request) == 'reg') {
      _handleRegEventSubscribe(request, inbound, toImpu ?? fromImpu);
      return;
    }

    // Session-Timers (RFC 4028 §6): for new INVITEs the proxy enforces
    // an operator-minimum Session-Expires. If the UAC asked for less,
    // reject with 422 carrying our Min-SE. Otherwise, insert Min-SE if
    // missing so the UAS sees a coherent value.
    if (method == 'INVITE') {
      if (!_enforceSessionTimers(request)) return;
    }

    // Emergency call (TS 24.229 §5.4.3.2) — Request-URI is `urn:service:sos`
    // or the From IMPU has an active emergency binding. Skip iFC, skip
    // terminating lookup; the off-net gateway plays the role of the E-CSCF
    // / PSAP breakout.
    if (_isEmergencyRequest(request, fromImpu)) {
      Log.debug('ims.scscf', 'emergency $method → off-net (E-CSCF/PSAP)');
      routeToOffNet(request, inbound);
      return;
    }

    // Originating side: presence of the `orig` parameter in the topmost
    // Route (the Service-Route the P-CSCF preloaded) or absence of Route
    // means originating processing per TS 24.229 §5.4.3.2.
    final orig = _topRouteHasOrig(request);

    if (orig && fromImpu != null) {
      final sub = hss.subscriptionByImpu(fromImpu);
      if (sub == null) {
        _reject(request, 403, 'Forbidden — Originating User Unknown');
        return;
      }
      // Emergency-only bindings must not initiate non-emergency sessions
      // (TS 24.229 §5.4.3.2). The check above already routed the
      // legitimate emergency case; reaching here means a normal request.
      final binding = _bindings[fromImpu];
      if (binding != null && binding.emergency) {
        _reject(request, 403,
            'Forbidden — Emergency Registration Limited to Emergency Calls');
        return;
      }
      final profile = sub.profiles[fromImpu];
      if (profile != null && profile.barred) {
        _reject(request, 403, 'Forbidden — IMPU Barred');
        return;
      }
      final ifc = _matchIfc(request, profile, SessionCase.originating);
      if (ifc != null) {
        Log.debug(
            'ims.scscf', 'orig iFC matched → AS ${ifc.applicationServer}');
        _forwardToAs(request, inbound, ifc);
        return;
      }
      // No more originating triggers → terminating routing.
    }

    if (toImpu == null) {
      _reject(request, 404, 'Not Found');
      return;
    }
    final termSub = hss.subscriptionByImpu(toImpu);
    if (termSub == null) {
      // Off-net — hand to BGCF/IBCF.
      Log.debug('ims.scscf', 'terminating $toImpu off-net → BGCF');
      routeToOffNet(request, inbound);
      return;
    }
    final termProfile = termSub.profiles[toImpu];
    if (termProfile != null && termProfile.barred) {
      _reject(request, 404, 'Not Found');
      return;
    }
    final termIfc = _matchIfc(request, termProfile, SessionCase.terminating);
    if (termIfc != null) {
      Log.debug(
          'ims.scscf', 'term iFC matched → AS ${termIfc.applicationServer}');
      _forwardToAs(request, inbound, termIfc);
      return;
    }
    final binding = _bindings[toImpu];
    if (binding == null) {
      _reject(request, 480, 'Temporarily Unavailable');
      return;
    }
    // Preload the served UE's Path as Route so the request walks back
    // through its P-CSCF (RFC 3327 §5.3).
    final raw = request.src ?? '';
    final parts = h.splitMessage(raw);
    final headers = List<String>.from(parts.headers);
    if (binding.path.isNotEmpty) {
      ih.prependRouteSet(headers, binding.path);
    }
    h.addRecordRoute(headers, recordRouteUri);
    final wire = h.joinMessage(headers, parts.body);
    final mutated = SipMsg()..Parse(wire);
    routeToTerminating(toImpu, mutated, inbound);
  }

  // -------------------------------------------------------------------------
  // iFC engine (very small; see [InitialFilterCriteria])
  // -------------------------------------------------------------------------

  IfcMatch? _matchIfc(
      SipMsg request, ServiceProfile? profile, SessionCase sessionCase) {
    if (profile == null) return null;
    final method = request.Req.Method?.toUpperCase();
    if (method == null) return null;
    final reqLine = request.Req.Src ?? '';
    for (final ifc in profile.ifcs) {
      if (ifc.sessionCase != sessionCase) continue;
      if (ifc.method != null && ifc.method!.toUpperCase() != method) continue;
      if (ifc.requestUriRegex != null &&
          !ifc.requestUriRegex!.hasMatch(reqLine)) {
        continue;
      }
      return IfcMatch(ifc.applicationServer, ifc.defaultHandling);
    }
    return null;
  }

  void _forwardToAs(SipMsg request, SipTransport inbound, IfcMatch match) {
    // TS 24.229 §5.4.3.2: insert the AS as a Route header above the
    // Service-Route, with `lr` and (for originating) `orig`. The AS will
    // either pass-thru or B2BUA us back; we Record-Route ourselves so we
    // see the response.
    final raw = request.src ?? '';
    final parts = h.splitMessage(raw);
    final headers = List<String>.from(parts.headers);
    final asUri = '${match.applicationServer};lr';
    ih.prependRouteSet(headers, [asUri, '$serviceRouteUri']);
    h.addRecordRoute(headers, recordRouteUri);
    final wire = h.joinMessage(headers, parts.body);
    final mutated = SipMsg()..Parse(wire);
    // We model AS forwarding the same as off-net: the IMS Core decides
    // how to actually deliver, since AS may be in-network.
    routeToOffNet(mutated, inbound);
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  void _reject(SipMsg request, int code, String reason) {
    final raw = h.buildResponse(
      request,
      code: code,
      reason: reason,
      toTag: h.generateTag(),
    );
    replyLocal(SipMsg()..Parse(raw));
  }

  String? _impuOfTo(SipMsg request) =>
      _impuOf(request.To.User, request.To.Host);

  String? _impuOf(String? user, String? host) {
    if (user == null || host == null) return null;
    return 'sip:$user@$host';
  }

  /// Detects an emergency REGISTER (TS 24.229 §5.1.6.2 / §5.4.1.2.2).
  /// Triggers:
  ///  * The Contact carries the `sos` URI parameter or feature tag.
  ///  * The Request-URI / To is `urn:service:sos[.*]` (RFC 5031).
  bool _isEmergencyRegister(SipMsg request) {
    final raw = request.src ?? '';
    final headers = h.splitMessage(raw).headers;
    for (final line in headers) {
      final lower = line.toLowerCase();
      if (lower.startsWith('contact:') || lower.startsWith('contact ')) {
        // Match `;sos` as a URI parameter or as a header parameter.
        if (RegExp(r';\s*sos(?:[;,>=\s]|$)').hasMatch(lower)) return true;
      }
      if (lower.startsWith('to:') || lower.startsWith('to ')) {
        if (lower.contains('urn:service:sos')) return true;
      }
    }
    final reqUri = request.Req.Src ?? '';
    if (reqUri.toLowerCase().contains('urn:service:sos')) return true;
    return false;
  }

  /// Synthesises a stable IMPI for an unauthenticated emergency UE so the
  /// binding has *some* identifier to log / correlate. Built from the
  /// Contact host:port of the UE per TS 24.229 §5.4.1.2.2.
  String _syntheticEmergencyImpi(SipMsg request) {
    final host = request.Contact.Host ?? 'unknown';
    final port = request.Contact.Port;
    return 'sos-$host${port == null ? '' : ':$port'}@${hss.realm}';
  }

  /// Detects a non-REGISTER emergency request: the Request-URI is the
  /// emergency URN (RFC 5031) or the originator has only an emergency
  /// binding active.
  bool _isEmergencyRequest(SipMsg request, String? fromImpu) {
    final reqUri = request.Req.Src ?? '';
    if (reqUri.toLowerCase().contains('urn:service:sos')) return true;
    if (fromImpu != null) {
      final binding = _bindings[fromImpu];
      if (binding != null && binding.emergency) return true;
    }
    return false;
  }

  bool _topRouteHasOrig(SipMsg request) {
    final headers = _headersOf(request);
    for (final line in headers) {
      final lower = line.toLowerCase();
      if (lower.startsWith('route:') || lower.startsWith('route ')) {
        return lower.contains(';orig') || lower.contains(' orig');
      }
    }
    return false;
  }

  List<String> _headersOf(SipMsg request) {
    final raw = request.src ?? '';
    return h.splitMessage(raw).headers;
  }

  String? _findRawHeader(String raw, String name) {
    final lines = raw.split('\r\n');
    final lower = name.toLowerCase();
    for (final line in lines) {
      final l = line.toLowerCase();
      if (l.startsWith('$lower:') || l.startsWith('$lower ')) {
        final colon = line.indexOf(':');
        return line.substring(colon + 1).trim();
      }
    }
    return null;
  }

  String? _extractContactUri(SipMsg data) {
    final user = data.Contact.User ?? data.From.User;
    final host = data.Contact.Host;
    final port = data.Contact.Port;
    if (user == null || host == null) return null;
    final portPart = port == null ? '' : ':$port';
    final tran = data.Contact.Tran;
    final tranPart = tran == null ? '' : ';transport=$tran';
    return 'sip:$user@$host$portPart$tranPart';
  }

  /// Returns IMPUs currently registered at this S-CSCF.
  Iterable<String> get registeredImpus => _bindings.keys;
}

/// One active reg-event subscription dialog (RFC 3680).
class _RegSubscription {
  _RegSubscription({
    required this.aor,
    required this.callId,
    required this.fromTag,
    required this.toTag,
    required this.remoteContact,
    required this.remoteUri,
    required this.expiresAt,
    required this.transport,
    required this.cseq,
  });
  final String aor;
  final String callId;
  final String fromTag; // UE's tag (becomes To-tag on outbound NOTIFY)
  final String toTag; // S-CSCF's tag (becomes From-tag on outbound NOTIFY)
  final String remoteContact;
  final String remoteUri;
  final DateTime expiresAt;
  final SipTransport transport;
  int cseq;
}
