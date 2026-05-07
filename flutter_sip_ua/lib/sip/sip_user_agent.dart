/// Pure-Dart SIP user agent.
///
/// Implements the subset of RFC 3261 needed to interoperate with the
/// dart-pbx server (see ../../../../lib/handlers/requests_handlers.dart):
///
///   * Transports: WebSocket (ws/wss) **and** UDP (RFC 3261 §18.1).
///     Selected automatically from the account's `serverUri` scheme.
///   * REGISTER with MD5 / qop=auth digest, expires negotiation, refresh.
///   * OPTIONS keep-alive (and answering inbound OPTIONS qualifies).
///   * MESSAGE (out-of-dialog).
///   * INVITE / 200 OK / ACK / BYE / CANCEL with a real G.711/RTP media
///     session (mic capture + μ-law/A-law encode + RTP send via the
///     pure-Dart packetizer under `audio/`).
///   * RFC 4028 Session Timers: Session-Expires / Min-SE negotiation,
///     re-INVITE refresh at half-interval (when refresher = uac),
///     hard-timeout BYE when refresher = uas and no refresh arrives,
///     422 Session Interval Too Small handling.
library;

import 'dart:async';
import 'dart:math';

import 'package:uuid/uuid.dart';

import 'audio/audio_sink.dart';
import 'audio/media_session.dart';
import 'digest.dart';
import 'sdp.dart';
import 'sip_message.dart';
import 'transport.dart';
import 'video/video_codec.dart';
import 'video/video_session.dart';

/// User-visible registration state.
enum RegistrationState { unregistered, registering, registered, failed }

/// User-visible call lifecycle.
enum CallState {
  idle,
  outgoingRinging, // INVITE sent, waiting for 180/200
  incomingRinging, // INVITE received, awaiting answer/decline
  active, // 200 OK / ACK exchanged
  ended, // BYE / CANCEL / failure
}

/// Snapshot of an in-flight or finished call exposed to the UI.
class SipCall {
  SipCall({
    required this.id,
    required this.remoteParty,
    required this.outgoing,
    this.state = CallState.idle,
    this.startedAt,
    this.endedAt,
  });

  final String id;
  final String remoteParty;
  final bool outgoing;
  CallState state;
  DateTime? startedAt;
  DateTime? endedAt;
}

class SipAccount {
  const SipAccount({
    required this.username,
    required this.password,
    required this.domain,
    required this.serverUri,
    this.displayName,
    this.sessionExpires = 1800,
    this.minSE = 90,
  });

  final String username;
  final String password;
  final String domain;

  /// Where to connect. Schemes:
  ///  * `ws://host:port`  — plain WebSocket
  ///  * `wss://host:port` — TLS WebSocket
  ///  * `sip:host:port`   — UDP (default port 5060)
  final Uri serverUri;

  final String? displayName;

  /// RFC 4028 desired session interval (seconds).
  final int sessionExpires;

  /// RFC 4028 minimum session interval we will accept.
  final int minSE;

  String get aor => 'sip:$username@$domain';

  /// Backwards-compatible alias for older code that used `wsUri`.
  Uri get wsUri => serverUri;
}

class SipTextMessage {
  SipTextMessage({
    required this.from,
    required this.body,
    required this.receivedAt,
  });
  final String from;
  final String body;
  final DateTime receivedAt;
}

class SipUserAgent {
  SipUserAgent({Random? rng, AudioSink Function()? audioSinkFactory})
    : _rng = rng ?? Random.secure(),
      _digest = DigestClient(),
      _audioSinkFactory = audioSinkFactory;

  final Random _rng;
  final DigestClient _digest;
  final AudioSink Function()? _audioSinkFactory;
  final _uuid = const Uuid();

  SipAccount? _account;
  SipTransport? _transport;
  StreamSubscription<SipMessage>? _msgSub;
  StreamSubscription<TransportState>? _stateSub;
  Timer? _registerTimer;
  Timer? _keepAliveTimer;

  // Registration bookkeeping.
  String? _regCallId;
  String _regFromTag = '';
  int _regCseq = 0;
  int _registrationExpires = 600;
  int _registerAttempts = 0;
  DigestChallenge? _pendingChallenge;

  final Map<String, _CallContext> _calls = {};

  final _registrationCtl = StreamController<RegistrationState>.broadcast();
  final _callCtl = StreamController<SipCall>.broadcast();
  final _messageCtl = StreamController<SipTextMessage>.broadcast();
  final _logCtl = StreamController<String>.broadcast();

  Stream<RegistrationState> get registrationStream => _registrationCtl.stream;
  Stream<SipCall> get callStream => _callCtl.stream;
  Stream<SipTextMessage> get messageStream => _messageCtl.stream;
  Stream<String> get logStream => _logCtl.stream;

  RegistrationState _regState = RegistrationState.unregistered;
  RegistrationState get registrationState => _regState;
  SipAccount? get account => _account;

  // ===========================================================================
  // Lifecycle
  // ===========================================================================

  Future<void> start(SipAccount account) async {
    await stop();
    _account = account;
    final transport = SipTransport.forUri(account.serverUri);
    _transport = transport;
    _stateSub = transport.state.listen(_onTransportState);
    _msgSub = transport.messages.listen(_onMessage);
    await transport.connect();
    _register(expires: _registrationExpires);
  }

  Future<void> stop() async {
    _registerTimer?.cancel();
    _registerTimer = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    for (final ctx in _calls.values.toList()) {
      ctx.cancelTimers();
    }
    if (_transport != null &&
        _account != null &&
        _regState == RegistrationState.registered) {
      try {
        _register(expires: 0);
      } catch (_) {}
    }
    await _msgSub?.cancel();
    await _stateSub?.cancel();
    await _transport?.close();
    _msgSub = null;
    _stateSub = null;
    _transport = null;
    _setRegState(RegistrationState.unregistered);
  }

  // ===========================================================================
  // Public actions
  // ===========================================================================

  Future<SipCall?> makeCall(
    String target, {
    bool withVideo = false,
    VideoEncoder? videoEncoder,
    VideoDecoder? videoDecoder,
  }) async {
    final acc = _account;
    final tx = _transport;
    if (acc == null || tx == null || !tx.isConnected) return null;
    final targetUri = _normaliseTarget(target, acc.domain);
    final callId = _uuid.v4();
    final fromTag = _shortTag();
    final branch = _branch();
    final cseq = _nextCseq();

    // Bind a local RTP port and put it in our SDP offer.
    final media = MediaSession(sink: _audioSinkFactory?.call());
    final rtpPort = await media.bindLocalPort();

    VideoSession? video;
    int? videoPort;
    if (withVideo) {
      video = VideoSession(encoder: videoEncoder, decoder: videoDecoder);
      videoPort = await video.bindLocalPort();
    }

    final body = video == null
        ? buildG711Offer(
            username: acc.username,
            localHost: _mediaLocalHost(),
            localPort: rtpPort,
          )
        : buildAvOffer(
            username: acc.username,
            localHost: _mediaLocalHost(),
            audioPort: rtpPort,
            videoPort: videoPort,
          );

    final extra = <String, String>{
      'Content-Type': 'application/sdp',
      // RFC 4028: advertise session timer support and propose interval.
      'Supported': 'timer',
      'Session-Expires': '${acc.sessionExpires};refresher=uac',
      'Min-SE': '${acc.minSE}',
    };
    final invite = _buildRequest(
      method: 'INVITE',
      requestUri: targetUri,
      callId: callId,
      fromTag: fromTag,
      cseq: cseq,
      branch: branch,
      target: targetUri,
      account: acc,
      extra: extra,
      body: body,
    );

    final ctx = _CallContext(
      call: SipCall(
        id: callId,
        remoteParty: targetUri,
        outgoing: true,
        state: CallState.outgoingRinging,
        startedAt: DateTime.now(),
      ),
      localTag: fromTag,
      cseq: cseq,
      lastInvite: invite,
      branch: branch,
      proposedSE: acc.sessionExpires,
      minSE: acc.minSE,
    );
    ctx.media = media;
    ctx.video = video;
    _calls[callId] = ctx;
    _emitCall(ctx.call);
    _send(invite);
    return ctx.call;
  }

  /// Toggle whether mic input is dropped on the wire for [callId]. Returns
  /// the new muted state, or `null` if the call isn't active.
  bool? setMuted(String callId, bool muted) {
    final media = _calls[callId]?.media;
    if (media == null) return null;
    media.muted = muted;
    return media.muted;
  }

  /// Convenience: returns whether [callId] is currently muted, or `null`
  /// if the call has no active media.
  bool? isMuted(String callId) => _calls[callId]?.media?.muted;

  /// Place [callId] on hold (or resume it). Sends a re-INVITE with
  /// `a=sendonly` (hold) or `a=sendrecv` (resume). The local mic is also
  /// muted while held so we don't keep streaming audio after the peer
  /// stops listening. Returns the new held state, or `null` if the call
  /// isn't active.
  bool? setHold(String callId, bool hold) {
    final ctx = _calls[callId];
    if (ctx == null) return null;
    if (ctx.call.state != CallState.active) return null;
    if (ctx.held == hold) return ctx.held;
    ctx.held = hold;
    final media = ctx.media;
    if (media != null) media.muted = hold;
    _sendReinvite(ctx);
    _emitCall(ctx.call);
    return ctx.held;
  }

  /// Whether [callId] is currently on hold.
  bool? isHeld(String callId) => _calls[callId]?.held;

  void hangup(String callId) {
    final ctx = _calls[callId];
    if (ctx == null) return;
    final acc = _account;
    if (acc == null) return;

    if (ctx.call.state == CallState.outgoingRinging) {
      final cancel = _buildRequest(
        method: 'CANCEL',
        requestUri: ctx.call.remoteParty,
        callId: callId,
        fromTag: ctx.localTag,
        cseq: ctx.cseq,
        branch: ctx.branch,
        target: ctx.call.remoteParty,
        account: acc,
        toTag: ctx.remoteTag,
      );
      cancel.setHeader('CSeq', '${ctx.cseq} CANCEL');
      _send(cancel);
    } else if (ctx.call.state == CallState.incomingRinging) {
      _respondToInvite(ctx, code: 603, reason: 'Decline');
    } else if (ctx.call.state == CallState.active) {
      final cseq = _nextCseq();
      final bye = _buildRequest(
        method: 'BYE',
        requestUri: ctx.remoteContact ?? ctx.call.remoteParty,
        callId: callId,
        fromTag: ctx.localTag,
        cseq: cseq,
        branch: _branch(),
        target: ctx.remoteContact ?? ctx.call.remoteParty,
        account: acc,
        toTag: ctx.remoteTag,
      );
      _send(bye);
    }
    _markEnded(ctx);
  }

  Future<void> answer(
    String callId, {
    VideoEncoder? videoEncoder,
    VideoDecoder? videoDecoder,
  }) async {
    final ctx = _calls[callId];
    if (ctx == null || ctx.call.state != CallState.incomingRinging) return;
    final acc = _account;
    if (acc == null) return;

    // Bind RTP socket and parse the peer's offer so we know where to send.
    final media = MediaSession(sink: _audioSinkFactory?.call());
    final rtpPort = await media.bindLocalPort();
    ctx.media = media;
    final offer = parseSdp(ctx.lastInvite.body);
    final remoteAudio = offer.audio;
    final remoteVideo = offer.video;

    VideoSession? video;
    int? videoPort;
    if (remoteVideo != null) {
      video = VideoSession(encoder: videoEncoder, decoder: videoDecoder);
      videoPort = await video.bindLocalPort();
      ctx.video = video;
    }

    final answerSdp = video == null
        ? buildG711Offer(
            username: acc.username,
            localHost: _mediaLocalHost(),
            localPort: rtpPort,
            preferred: remoteAudio?.codec ?? G711Variant.pcmu,
          )
        : buildAvOffer(
            username: acc.username,
            localHost: _mediaLocalHost(),
            audioPort: rtpPort,
            videoPort: videoPort,
            audioPreferred: remoteAudio?.codec ?? G711Variant.pcmu,
            videoPayloadType: remoteVideo!.payloadType,
            videoCodec: remoteVideo.codec,
          );

    // RFC 4028: if the peer asked for timers, accept and choose refresher.
    final extra = <String, String>{};
    if (ctx.proposedSE != null) {
      // If peer didn't pin a refresher, take the role ourselves (uas).
      ctx.refresher ??= 'uas';
      extra['Require'] = 'timer';
      extra['Session-Expires'] = '${ctx.proposedSE};refresher=${ctx.refresher}';
    }
    _respondToInvite(
      ctx,
      code: 200,
      reason: 'OK',
      sdp: answerSdp,
      extra: extra,
    );
    ctx.call.state = CallState.active;
    _emitCall(ctx.call);
    _armSessionTimers(ctx);
    if (remoteAudio != null) {
      try {
        await media.start(remoteAudio.toEndpoint());
      } catch (e) {
        _log('media: failed to start: $e');
      }
    }
    if (video != null && remoteVideo != null) {
      try {
        await video.start(VideoEndpoint.fromSdp(remoteVideo));
      } catch (e) {
        _log('video: failed to start: $e');
      }
    }
  }

  /// Send an RFC 4733 DTMF digit on an active call. No-op if the call
  /// isn't active or DTMF wasn't negotiated.
  Future<void> sendDtmf(
    String callId,
    String digit, {
    Duration duration = const Duration(milliseconds: 200),
  }) async {
    final ctx = _calls[callId];
    if (ctx == null || ctx.call.state != CallState.active) return;
    final media = ctx.media;
    if (media == null) return;
    try {
      await media.sendDtmf(digit, duration: duration);
    } catch (e) {
      _log('dtmf: $e');
    }
  }

  void sendMessage(String target, String text) {
    final acc = _account;
    if (acc == null) return;
    final targetUri = _normaliseTarget(target, acc.domain);
    final callId = _uuid.v4();
    final msg = _buildRequest(
      method: 'MESSAGE',
      requestUri: targetUri,
      callId: callId,
      fromTag: _shortTag(),
      cseq: _nextCseq(),
      branch: _branch(),
      target: targetUri,
      account: acc,
      extra: {'Content-Type': 'text/plain'},
      body: text,
    );
    _send(msg);
  }

  // ===========================================================================
  // Inbound dispatch
  // ===========================================================================

  void _onTransportState(TransportState s) {
    _log('transport: $s');
    switch (s) {
      case TransportState.connecting:
        _setRegState(RegistrationState.registering);
        break;
      case TransportState.connected:
        _scheduleKeepAlive();
        break;
      case TransportState.disconnected:
        _keepAliveTimer?.cancel();
        _keepAliveTimer = null;
        _setRegState(RegistrationState.unregistered);
        break;
    }
  }

  void _onMessage(SipMessage msg) {
    _log(
      '<-- ${msg.isResponse ? "${msg.statusCode} ${msg.reasonPhrase}" : "${msg.method} ${msg.requestUri}"}',
    );
    if (msg.isResponse) {
      _onResponse(msg);
    } else {
      _onRequest(msg);
    }
  }

  void _onResponse(SipMessage msg) {
    final cseqMethod = msg.cseqMethod;
    final code = msg.statusCode!;
    final callId = msg.callId;

    if (cseqMethod == 'REGISTER' && callId == _regCallId) {
      _onRegisterResponse(msg);
      return;
    }
    if (callId == null) return;
    final ctx = _calls[callId];
    if (ctx == null) return;

    if (cseqMethod == 'INVITE') {
      if (msg.toTag != null) ctx.remoteTag = msg.toTag;
      if (code >= 100 && code < 200) {
        if (code != 100) {
          ctx.call.state = CallState.outgoingRinging;
          _emitCall(ctx.call);
        }
      } else if (code >= 200 && code < 300) {
        ctx.remoteContact = _firstContactUri(msg) ?? ctx.remoteContact;
        _absorbSessionExpires(ctx, msg, weAreUac: true);
        _sendAck(ctx, msg);
        final wasRefresh = ctx.call.state == CallState.active;
        ctx.call.state = CallState.active;
        _emitCall(ctx.call);
        if (!wasRefresh) {
          _armSessionTimers(ctx);
          // Start mic + RTP from the peer's answer SDP.
          final answer = parseSdp(msg.body);
          final remoteAudio = answer.audio;
          final remoteVideo = answer.video;
          final media = ctx.media;
          if (media != null && remoteAudio != null) {
            media.start(remoteAudio.toEndpoint()).catchError((e) {
              _log('media: failed to start: $e');
            });
          }
          final video = ctx.video;
          if (video != null && remoteVideo != null) {
            video.start(VideoEndpoint.fromSdp(remoteVideo)).catchError((e) {
              _log('video: failed to start: $e');
            });
          }
        } else {
          // Re-arm after a successful refresh.
          _armSessionTimers(ctx);
        }
      } else if (code == 401 || code == 407) {
        _retryInviteWithAuth(ctx, msg);
      } else if (code == 422) {
        // Session Interval Too Small — bump Min-SE and resend INVITE.
        _retryInviteWith422(ctx, msg);
      } else {
        _markEnded(ctx);
      }
    } else if (cseqMethod == 'BYE' || cseqMethod == 'CANCEL') {
      _markEnded(ctx);
    }
  }

  void _onRequest(SipMessage msg) {
    final method = msg.method!.toUpperCase();
    switch (method) {
      case 'OPTIONS':
        _send(_buildResponseFor(msg, 200, 'OK'));
        return;
      case 'INVITE':
        _onInboundInvite(msg);
        return;
      case 'ACK':
        return;
      case 'BYE':
        _send(_buildResponseFor(msg, 200, 'OK'));
        final ctx = _calls[msg.callId];
        if (ctx != null) _markEnded(ctx);
        return;
      case 'CANCEL':
        _send(_buildResponseFor(msg, 200, 'OK'));
        final ctx = _calls[msg.callId];
        if (ctx != null && ctx.call.state == CallState.incomingRinging) {
          _respondToInvite(ctx, code: 487, reason: 'Request Terminated');
          _markEnded(ctx);
        }
        return;
      case 'UPDATE':
        // Honour an UPDATE-style session refresh (RFC 4028 §11) by echoing
        // the negotiated Session-Expires.
        final ctx = _calls[msg.callId];
        if (ctx == null) {
          _send(_buildResponseFor(msg, 481, 'Call/Transaction Does Not Exist'));
          return;
        }
        _absorbSessionExpiresFromRequest(ctx, msg);
        final extra = <String, String>{};
        if (ctx.negotiatedSE != null) {
          extra['Session-Expires'] =
              '${ctx.negotiatedSE};refresher=${ctx.refresher ?? 'uac'}';
          extra['Require'] = 'timer';
        }
        _send(
          _buildResponseFor(
            msg,
            200,
            'OK',
            addToTag: ctx.localTag,
            extra: extra,
          ),
        );
        _armSessionTimers(ctx);
        return;
      case 'MESSAGE':
        _send(_buildResponseFor(msg, 200, 'OK'));
        final from = extractUri(msg.header('From') ?? '');
        _messageCtl.add(
          SipTextMessage(
            from: from,
            body: msg.body,
            receivedAt: DateTime.now(),
          ),
        );
        return;
      case 'NOTIFY':
      case 'INFO':
        _send(_buildResponseFor(msg, 200, 'OK'));
        return;
      default:
        _send(_buildResponseFor(msg, 405, 'Method Not Allowed'));
    }
  }

  void _onInboundInvite(SipMessage msg) {
    final callId = msg.callId;
    if (callId == null) return;

    // Re-INVITE within an existing dialog: treat as a session refresh.
    final existing = _calls[callId];
    if (existing != null && existing.call.state == CallState.active) {
      _absorbSessionExpiresFromRequest(existing, msg);

      // Detect peer-initiated hold/resume from the offer's media direction.
      // RFC 3264 §8.4: peer's `a=sendonly` / `a=inactive` puts us on hold.
      final offered = parseSdpAudio(msg.body);
      if (offered != null) {
        final wasHeld = existing.held;
        final peerHolds =
            offered.direction == SdpDirection.sendonly ||
            offered.direction == SdpDirection.inactive;
        if (peerHolds != wasHeld) {
          existing.held = peerHolds;
          // Stop sending audio while the peer holds us; resume on unhold.
          existing.media?.muted = peerHolds;
          _emitCall(existing.call);
        }
      }

      final extra = <String, String>{};
      if (existing.negotiatedSE != null) {
        extra['Session-Expires'] =
            '${existing.negotiatedSE};refresher=${existing.refresher ?? 'uac'}';
        extra['Require'] = 'timer';
      }
      final acc = _account;
      _send(
        _buildResponseFor(
          msg,
          200,
          'OK',
          addToTag: existing.localTag,
          sdp: acc == null ? null : _buildOfferSdpForCall(existing, acc),
          extra: extra,
        ),
      );
      existing.lastInvite = msg;
      _armSessionTimers(existing);
      return;
    }
    if (existing != null) return;

    _send(_buildResponseFor(msg, 100, 'Trying'));
    final localTag = _shortTag();

    // Pre-screen Session-Expires so we can reject early with 422 if needed.
    final acc = _account;
    final wantedMin = acc?.minSE ?? 90;
    final hdr = msg.header('Session-Expires') ?? msg.header('x');
    int? proposedSE;
    String? refresher;
    if (hdr != null) {
      final parsed = _parseSessionExpires(hdr);
      proposedSE = parsed.expires;
      refresher = parsed.refresher;
      if (proposedSE != null && proposedSE < wantedMin) {
        _send(
          _buildResponseFor(
            msg,
            422,
            'Session Interval Too Small',
            extra: {'Min-SE': '$wantedMin'},
          ),
        );
        return;
      }
    }

    final ringing = _buildResponseFor(msg, 180, 'Ringing', addToTag: localTag);
    _send(ringing);

    final from = extractUri(msg.header('From') ?? '');
    final ctx = _CallContext(
      call: SipCall(
        id: callId,
        remoteParty: from,
        outgoing: false,
        state: CallState.incomingRinging,
        startedAt: DateTime.now(),
      ),
      localTag: localTag,
      cseq: msg.cseqNumber ?? 0,
      lastInvite: msg,
      branch: _branch(),
      proposedSE: proposedSE,
      minSE: wantedMin,
    );
    ctx.refresher = refresher;
    ctx.remoteTag = msg.fromTag;
    ctx.remoteContact = _firstContactUri(msg);
    _calls[callId] = ctx;
    _emitCall(ctx.call);
  }

  // ===========================================================================
  // Session timers (RFC 4028)
  // ===========================================================================

  void _absorbSessionExpires(
    _CallContext ctx,
    SipMessage msg, {
    required bool weAreUac,
  }) {
    final hdr = msg.header('Session-Expires') ?? msg.header('x');
    if (hdr == null) {
      ctx.negotiatedSE = null;
      ctx.refresher = null;
      return;
    }
    final parsed = _parseSessionExpires(hdr);
    if (parsed.expires == null) return;
    ctx.negotiatedSE = parsed.expires;
    ctx.refresher = parsed.refresher ?? (weAreUac ? 'uac' : 'uas');
  }

  void _absorbSessionExpiresFromRequest(_CallContext ctx, SipMessage req) {
    final hdr = req.header('Session-Expires') ?? req.header('x');
    if (hdr == null) return;
    final parsed = _parseSessionExpires(hdr);
    if (parsed.expires != null) ctx.negotiatedSE = parsed.expires;
    if (parsed.refresher != null) ctx.refresher = parsed.refresher;
  }

  _SessionExpires _parseSessionExpires(String value) {
    final parts = value.split(';');
    final expires = int.tryParse(parts.first.trim());
    String? refresher;
    for (var i = 1; i < parts.length; i++) {
      final p = parts[i].trim();
      if (p.toLowerCase().startsWith('refresher=')) {
        refresher = p.substring('refresher='.length).trim().toLowerCase();
      }
    }
    return _SessionExpires(expires: expires, refresher: refresher);
  }

  void _armSessionTimers(_CallContext ctx) {
    ctx.cancelTimers();
    final se = ctx.negotiatedSE;
    if (se == null) return;
    if (ctx.refresher == 'uac') {
      // Refresh at half-interval.
      final delay = Duration(seconds: (se / 2).floor().clamp(1, 1 << 30));
      ctx.refreshTimer = Timer(delay, () => _sendRefreshInvite(ctx));
      _log('session-timer: will refresh ${ctx.call.id} in ${delay.inSeconds}s');
    } else {
      // Peer refreshes; arm a hard timeout after full interval (+ small grace).
      final delay = Duration(seconds: se + 32);
      ctx.expiryTimer = Timer(delay, () {
        _log(
          'session-timer: peer missed refresh, sending BYE on ${ctx.call.id}',
        );
        hangup(ctx.call.id);
      });
    }
  }

  void _sendRefreshInvite(_CallContext ctx) {
    final acc = _account;
    if (acc == null) return;
    if (ctx.call.state != CallState.active) return;
    final newCseq = _nextCseq();
    final newBranch = _branch();
    final target = ctx.remoteContact ?? ctx.call.remoteParty;
    final extra = <String, String>{
      'Content-Type': 'application/sdp',
      'Supported': 'timer',
      'Session-Expires':
          '${ctx.negotiatedSE ?? acc.sessionExpires};refresher=uac',
      'Min-SE': '${ctx.minSE ?? acc.minSE}',
    };
    final invite = _buildRequest(
      method: 'INVITE',
      requestUri: target,
      callId: ctx.call.id,
      fromTag: ctx.localTag,
      cseq: newCseq,
      branch: newBranch,
      target: target,
      account: acc,
      toTag: ctx.remoteTag,
      extra: extra,
      body: _buildOfferSdpForCall(ctx, acc),
    );
    ctx.cseq = newCseq;
    ctx.branch = newBranch;
    ctx.lastInvite = invite;
    _send(invite);
  }

  /// Send a re-INVITE that re-negotiates the media direction (used for
  /// hold/resume). Reuses the existing dialog and the bound RTP port.
  void _sendReinvite(_CallContext ctx) {
    final acc = _account;
    if (acc == null) return;
    final newCseq = _nextCseq();
    final newBranch = _branch();
    final target = ctx.remoteContact ?? ctx.call.remoteParty;
    final extra = <String, String>{
      'Content-Type': 'application/sdp',
      if (ctx.negotiatedSE != null) ...{
        'Supported': 'timer',
        'Session-Expires':
            '${ctx.negotiatedSE};refresher=${ctx.refresher ?? 'uac'}',
        'Min-SE': '${ctx.minSE ?? acc.minSE}',
      },
    };
    final invite = _buildRequest(
      method: 'INVITE',
      requestUri: target,
      callId: ctx.call.id,
      fromTag: ctx.localTag,
      cseq: newCseq,
      branch: newBranch,
      target: target,
      account: acc,
      toTag: ctx.remoteTag,
      extra: extra,
      body: _buildOfferSdpForCall(ctx, acc),
    );
    ctx.cseq = newCseq;
    ctx.branch = newBranch;
    ctx.lastInvite = invite;
    _send(invite);
  }

  void _retryInviteWith422(_CallContext ctx, SipMessage resp) {
    final acc = _account;
    if (acc == null) return;
    final minHdr = resp.header('Min-SE');
    final newMin = int.tryParse(minHdr ?? '') ?? (ctx.minSE ?? 90) * 2;
    ctx.minSE = newMin;
    final newSE = newMin > (ctx.proposedSE ?? acc.sessionExpires)
        ? newMin
        : (ctx.proposedSE ?? acc.sessionExpires);
    ctx.proposedSE = newSE;

    // ACK the 422 first.
    _sendAck(ctx, resp);

    final newCseq = _nextCseq();
    final newBranch = _branch();
    final extra = <String, String>{
      'Content-Type': 'application/sdp',
      'Supported': 'timer',
      'Session-Expires': '$newSE;refresher=uac',
      'Min-SE': '$newMin',
    };
    final invite = _buildRequest(
      method: 'INVITE',
      requestUri: ctx.call.remoteParty,
      callId: ctx.call.id,
      fromTag: ctx.localTag,
      cseq: newCseq,
      branch: newBranch,
      target: ctx.call.remoteParty,
      account: acc,
      extra: extra,
      body: _buildOfferSdp(acc),
    );
    ctx.cseq = newCseq;
    ctx.branch = newBranch;
    ctx.lastInvite = invite;
    _send(invite);
  }

  // ===========================================================================
  // REGISTER
  // ===========================================================================

  void _register({required int expires}) {
    final acc = _account;
    final tx = _transport;
    if (acc == null || tx == null) return;
    _regCallId ??= _uuid.v4();
    if (_regFromTag.isEmpty) _regFromTag = _shortTag();
    _regCseq++;
    _registerAttempts = 0;
    _setRegState(
      expires == 0
          ? RegistrationState.unregistered
          : RegistrationState.registering,
    );
    _send(_buildRegister(acc, expires: expires));
  }

  SipMessage _buildRegister(SipAccount acc, {required int expires}) {
    final registrarUri = 'sip:${acc.domain}';
    final req = _buildRequest(
      method: 'REGISTER',
      requestUri: registrarUri,
      callId: _regCallId!,
      fromTag: _regFromTag,
      cseq: _regCseq,
      branch: _branch(),
      target: acc.aor,
      account: acc,
      extra: {
        'Expires': '$expires',
        'Allow':
            'INVITE, ACK, CANCEL, BYE, MESSAGE, OPTIONS, NOTIFY, INFO, UPDATE',
        'Supported': 'timer, replaces',
      },
    );
    final challenge = _pendingChallenge;
    if (challenge != null) {
      final auth = _digest.authorize(
        challenge: challenge,
        username: acc.username,
        password: acc.password,
        method: 'REGISTER',
        uri: registrarUri,
      );
      req.setHeader('Authorization', 'Digest $auth');
    }
    return req;
  }

  void _onRegisterResponse(SipMessage msg) {
    final code = msg.statusCode!;
    if (code == 401 || code == 407) {
      if (_registerAttempts >= 2) {
        _setRegState(RegistrationState.failed);
        return;
      }
      _registerAttempts++;
      final hdr =
          msg.header(code == 401 ? 'WWW-Authenticate' : 'Proxy-Authenticate') ??
          '';
      _pendingChallenge = DigestChallenge.fromParams(parseAuthHeader(hdr));
      final acc = _account;
      if (acc == null) return;
      _regCseq++;
      _send(_buildRegister(acc, expires: _registrationExpires));
      return;
    }
    if (code >= 200 && code < 300) {
      final contact = msg.header('Contact');
      int? granted;
      if (contact != null) {
        final m = RegExp(
          r'expires=(\d+)',
          caseSensitive: false,
        ).firstMatch(contact);
        if (m != null) granted = int.tryParse(m.group(1)!);
      }
      granted ??= int.tryParse(msg.header('Expires') ?? '');
      if (granted != null && granted > 0) {
        _registrationExpires = granted;
        final refreshIn = (granted * 0.8).floor();
        _registerTimer?.cancel();
        _registerTimer = Timer(
          Duration(seconds: refreshIn),
          () => _register(expires: _registrationExpires),
        );
        _setRegState(RegistrationState.registered);
      } else {
        _setRegState(RegistrationState.unregistered);
      }
      return;
    }
    if (code >= 400) {
      _setRegState(RegistrationState.failed);
    }
  }

  // ===========================================================================
  // Builders
  // ===========================================================================

  SipMessage _buildRequest({
    required String method,
    required String requestUri,
    required String callId,
    required String fromTag,
    required int cseq,
    required String branch,
    required String target,
    required SipAccount account,
    String? toTag,
    Map<String, String>? extra,
    String body = '',
  }) {
    final tx = _transport!;
    final scheme = tx.protocol; // WS / WSS / UDP
    final localHost = _localContactHost();
    final fromDisplay = account.displayName == null
        ? ''
        : '"${account.displayName}" ';
    final toUri = method == 'REGISTER' ? account.aor : target;
    final toLine = toTag == null ? '<$toUri>' : '<$toUri>;tag=$toTag';
    final headers = <MapEntry<String, String>>[
      MapEntry('Via', 'SIP/2.0/$scheme $localHost;branch=$branch;rport'),
      MapEntry('Max-Forwards', '70'),
      MapEntry('From', '$fromDisplay<${account.aor}>;tag=$fromTag'),
      MapEntry('To', toLine),
      MapEntry('Call-ID', callId),
      MapEntry('CSeq', '$cseq $method'),
      MapEntry(
        'Contact',
        '<sip:${account.username}@$localHost;transport=$scheme>',
      ),
      const MapEntry('User-Agent', 'flutter_sip_ua/1.0 (pure-dart)'),
    ];
    if (extra != null) {
      extra.forEach((k, v) => headers.add(MapEntry(k, v)));
    }
    return SipMessage.request(method, requestUri, headers: headers, body: body);
  }

  SipMessage _buildResponseFor(
    SipMessage req,
    int code,
    String reason, {
    String? addToTag,
    String? sdp,
    Map<String, String>? extra,
  }) {
    final headers = <MapEntry<String, String>>[];
    for (final h in req.headers) {
      final k = h.key.toLowerCase();
      if (k == 'via' ||
          k == 'from' ||
          k == 'call-id' ||
          k == 'cseq' ||
          k == 'record-route') {
        headers.add(h);
      } else if (k == 'to') {
        var v = h.value;
        if (addToTag != null && _paramOfHeader(v, 'tag') == null) {
          v = '$v;tag=$addToTag';
        }
        headers.add(MapEntry(h.key, v));
      }
    }
    final acc = _account;
    if (acc != null && _transport != null) {
      final scheme = _transport!.protocol;
      final localHost = _localContactHost();
      headers.add(
        MapEntry(
          'Contact',
          '<sip:${acc.username}@$localHost;transport=$scheme>',
        ),
      );
    }
    headers.add(const MapEntry('User-Agent', 'flutter_sip_ua/1.0'));
    if (extra != null) {
      extra.forEach((k, v) => headers.add(MapEntry(k, v)));
    }
    final body = sdp ?? '';
    if (sdp != null) {
      headers.add(const MapEntry('Content-Type', 'application/sdp'));
    }
    return SipMessage.response(
      code: code,
      reason: reason,
      headers: headers,
      body: body,
    );
  }

  void _respondToInvite(
    _CallContext ctx, {
    required int code,
    required String reason,
    String? sdp,
    Map<String, String>? extra,
  }) {
    final resp = _buildResponseFor(
      ctx.lastInvite,
      code,
      reason,
      addToTag: ctx.localTag,
      sdp: sdp,
      extra: extra,
    );
    _send(resp);
  }

  void _sendAck(_CallContext ctx, SipMessage ok) {
    final acc = _account;
    if (acc == null) return;
    final target = ctx.remoteContact ?? ctx.call.remoteParty;
    final ack = _buildRequest(
      method: 'ACK',
      requestUri: target,
      callId: ctx.call.id,
      fromTag: ctx.localTag,
      cseq: ctx.cseq,
      branch: _branch(),
      target: target,
      account: acc,
      toTag: ok.toTag ?? ctx.remoteTag,
    );
    _send(ack);
  }

  void _retryInviteWithAuth(_CallContext ctx, SipMessage challenge) {
    if (ctx.authAttempts >= 2) {
      _markEnded(ctx);
      return;
    }
    ctx.authAttempts++;
    final acc = _account;
    if (acc == null) return;
    final code = challenge.statusCode!;
    final hdr = challenge.header(
      code == 401 ? 'WWW-Authenticate' : 'Proxy-Authenticate',
    );
    if (hdr == null) {
      _markEnded(ctx);
      return;
    }
    _sendAck(ctx, challenge);

    final newCseq = _nextCseq();
    final newBranch = _branch();
    final ch = DigestChallenge.fromParams(parseAuthHeader(hdr));
    final auth = _digest.authorize(
      challenge: ch,
      username: acc.username,
      password: acc.password,
      method: 'INVITE',
      uri: ctx.call.remoteParty,
    );
    final extra = <String, String>{
      'Content-Type': 'application/sdp',
      'Supported': 'timer',
      'Session-Expires':
          '${ctx.proposedSE ?? acc.sessionExpires};refresher=uac',
      'Min-SE': '${ctx.minSE ?? acc.minSE}',
      code == 401 ? 'Authorization' : 'Proxy-Authorization': 'Digest $auth',
    };
    final invite = _buildRequest(
      method: 'INVITE',
      requestUri: ctx.call.remoteParty,
      callId: ctx.call.id,
      fromTag: ctx.localTag,
      cseq: newCseq,
      branch: newBranch,
      target: ctx.call.remoteParty,
      account: acc,
      extra: extra,
      body: _buildOfferSdp(acc),
    );
    ctx.cseq = newCseq;
    ctx.branch = newBranch;
    ctx.lastInvite = invite;
    _send(invite);
  }

  // ===========================================================================
  // Misc
  // ===========================================================================

  String _localContactHost() {
    final tx = _transport!;
    final host = tx.localHost;
    final port = tx.localPort;
    return port == 0 ? host : '$host:$port';
  }

  String _normaliseTarget(String target, String defaultDomain) {
    final t = target.trim();
    if (t.startsWith('sip:') || t.startsWith('sips:')) return t;
    if (t.contains('@')) return 'sip:$t';
    return 'sip:$t@$defaultDomain';
  }

  String _branch() => 'z9hG4bK${_uuid.v4().replaceAll('-', '')}';

  String _shortTag() {
    final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  int _nextCseq() => DateTime.now().millisecondsSinceEpoch & 0x3fffffff;

  String _buildOfferSdp(SipAccount acc) {
    // Backwards-compatible offer used when no MediaSession is bound
    // (re-INVITE refresh paths). Real port/codec come from MediaSession
    // when one exists.
    return buildG711Offer(
      username: acc.username,
      localHost: _mediaLocalHost(),
      localPort: 0,
    );
  }

  /// Hold-aware variant: uses the call's bound RTP port if available and
  /// flips `a=sendonly` while the call is on hold so the peer knows to
  /// stop sending audio.
  String _buildOfferSdpForCall(_CallContext ctx, SipAccount acc) {
    final media = ctx.media;
    final port = media?.localPort ?? 0;
    final rtcp = media?.localRtcpPort;
    return buildG711Offer(
      username: acc.username,
      localHost: _mediaLocalHost(),
      localPort: port,
      rtcpPort: rtcp,
      direction: ctx.held ? SdpDirection.sendonly : SdpDirection.sendrecv,
    );
  }

  /// Best-effort "public" host to put in `c=` / `o=`. Falls back to the
  /// SIP transport's local host if it isn't 0.0.0.0.
  String _mediaLocalHost() {
    final tx = _transport;
    if (tx == null) return '0.0.0.0';
    final h = tx.localHost;
    if (h.isEmpty || h == '0.0.0.0' || h == '::') return '0.0.0.0';
    return h;
  }

  String? _firstContactUri(SipMessage msg) {
    final c = msg.header('Contact') ?? msg.header('m');
    if (c == null) return null;
    return extractUri(c);
  }

  void _scheduleKeepAlive() {
    _keepAliveTimer?.cancel();
    final tx = _transport;
    if (tx == null) return;
    // Only WS variants need RFC 5626 CRLF keep-alives.
    if (tx.protocol != 'WS' && tx.protocol != 'WSS') return;
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (tx.isConnected) {
        try {
          tx.sendRaw('\r\n\r\n');
        } catch (_) {}
      }
    });
  }

  void _send(SipMessage msg) {
    _log(
      '--> ${msg.isResponse ? "${msg.statusCode} ${msg.reasonPhrase}" : "${msg.method} ${msg.requestUri}"}',
    );
    _transport?.send(msg);
  }

  void _markEnded(_CallContext ctx) {
    ctx.cancelTimers();
    final media = ctx.media;
    ctx.media = null;
    if (media != null) {
      media.stop();
    }
    final video = ctx.video;
    ctx.video = null;
    if (video != null) {
      video.stop();
    }
    ctx.call.state = CallState.ended;
    ctx.call.endedAt = DateTime.now();
    _emitCall(ctx.call);
    _calls.remove(ctx.call.id);
  }

  void _emitCall(SipCall call) => _callCtl.add(call);

  void _setRegState(RegistrationState s) {
    if (_regState == s) return;
    _regState = s;
    _registrationCtl.add(s);
  }

  void _log(String line) => _logCtl.add(line);
}

class _CallContext {
  _CallContext({
    required this.call,
    required this.localTag,
    required this.cseq,
    required this.lastInvite,
    required this.branch,
    this.proposedSE,
    this.minSE,
  });

  final SipCall call;
  final String localTag;
  String? remoteTag;
  String? remoteContact;
  int cseq;
  String branch;
  SipMessage lastInvite;
  int authAttempts = 0;

  /// Active media plane (mic capture + RTP socket). Null until the call is
  /// being set up, and again once it ends.
  MediaSession? media;

  /// Optional video plane; only present when the call is negotiated with
  /// `m=video`.
  VideoSession? video;

  /// True once a hold re-INVITE has been sent and 200-OK confirmed (or
  /// optimistically, while the re-INVITE is in flight).
  bool held = false;

  // RFC 4028 state.
  int? proposedSE;
  int? negotiatedSE;
  int? minSE;
  String? refresher; // 'uac' | 'uas'
  Timer? refreshTimer;
  Timer? expiryTimer;

  void cancelTimers() {
    refreshTimer?.cancel();
    refreshTimer = null;
    expiryTimer?.cancel();
    expiryTimer = null;
  }
}

class _SessionExpires {
  const _SessionExpires({this.expires, this.refresher});
  final int? expires;
  final String? refresher;
}

String? _paramOfHeader(String value, String name) {
  final lower = name.toLowerCase();
  for (final part in value.split(';')) {
    final eq = part.indexOf('=');
    if (eq <= 0) continue;
    if (part.substring(0, eq).trim().toLowerCase() == lower) {
      return part.substring(eq + 1).trim();
    }
  }
  return null;
}
