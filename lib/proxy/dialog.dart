// Dialog state (RFC 3261 §12).
//
// A dialog is identified by the triple (Call-ID, local-tag, remote-tag) where
// "local" is from the perspective of the entity holding the dialog. For a
// proxy that records routes, two dialogs typically exist per call (one with
// each endpoint). Here we use one logical Dialog per call leg and key it by
// (call-id, caller-from-tag, callee-to-tag) which is unique for the original
// INVITE direction.

import 'dart:async';

import 'package:dart_pbx/sip_client.dart';
import 'package:dart_pbx/sip_parser/sip.dart';

import 'sip_helpers.dart';

enum DialogState { early, confirmed, terminated }

class DialogId {
  const DialogId(this.callId, this.localTag, this.remoteTag);

  final String callId;
  final String localTag;
  final String remoteTag;

  @override
  bool operator ==(Object other) =>
      other is DialogId &&
      other.callId == callId &&
      other.localTag == localTag &&
      other.remoteTag == remoteTag;

  @override
  int get hashCode => Object.hash(callId, localTag, remoteTag);

  @override
  String toString() => '$callId|$localTag|$remoteTag';
}

class Dialog {
  Dialog({
    required this.id,
    required this.localUri,
    required this.remoteUri,
    required this.remoteTarget,
    this.state = DialogState.early,
    this.localSeq = 0,
    this.remoteSeq = 0,
    this.routeSet = const [],
    this.secure = false,
    this.caller,
    this.callee,
  });

  final DialogId id;

  /// AOR/Contact this entity advertises for this dialog.
  final String localUri;

  /// AOR/Contact of the peer.
  final String remoteUri;

  /// Current remote Contact (may be updated by re-INVITE / target refresh).
  String remoteTarget;

  /// Pre-loaded list of Route URIs derived from Record-Route on the dialog
  /// establishing transaction (RFC 3261 §12.1.2).
  List<String> routeSet;

  /// True when the request URI scheme is sips: (RFC 3261 §12.1.2).
  bool secure;

  DialogState state;

  /// Local CSeq for requests we originate within the dialog.
  int localSeq;

  /// Highest CSeq observed from the peer (for in-dialog ordering checks).
  int remoteSeq;

  /// Caller-side endpoint (the UAC that sent the original INVITE). Used to
  /// route in-dialog requests originating from the callee back downstream.
  SipClient? caller;

  /// Callee-side endpoint (the UAS that answered). Used to route in-dialog
  /// requests originating from the caller upstream.
  SipClient? callee;

  /// Returns the peer endpoint that should *receive* a request whose From
  /// matches [originUser]. When [originUser] equals the caller's user we
  /// forward to the callee, and vice versa.
  SipClient? peerOf(String originUser) {
    if (caller != null && caller!.number == originUser) return callee;
    if (callee != null && callee!.number == originUser) return caller;
    return null;
  }

  // -------------------------------------------------------------------------
  // RFC 4028 Session Timer state.
  //
  // The proxy currently *monitors* session timers rather than actively
  // refreshing: when a 2xx INVITE response carries `Session-Expires`, we
  // arm [sessionTimer] for that interval. Any in-dialog re-INVITE / UPDATE
  // observed by the proxy resets it. If neither side refreshes before the
  // timer fires the proxy tears the dialog down with BYE on both legs.
  // -------------------------------------------------------------------------

  /// Negotiated Session-Expires interval in seconds (0 = disabled).
  int sessionExpires = 0;

  /// Refresher role as advertised in the response: `uac`, `uas`, or null
  /// when neither side took ownership.
  String? sessionRefresher;

  /// Active timer that fires when the session is considered dead.
  Timer? sessionTimer;

  /// Optional callback invoked when the dialog leaves [DialogState.confirmed]
  /// (BYE 2xx, session-timer expiry, or proxy-initiated tear-down). Used by
  /// the call-center module to release the agent.
  void Function()? onTerminated;

  void cancelSessionTimer() {
    sessionTimer?.cancel();
    sessionTimer = null;
  }
}

class DialogLayer {
  final Map<DialogId, Dialog> _dialogs = {};

  /// Look up a dialog by the id derived from a request from the *peer*. Per
  /// §12.2.2 the peer's view of (local-tag, remote-tag) is the inverse of
  /// ours, so we try both orderings.
  Dialog? findFromRequest(SipMsg request) {
    final callId = request.CallId.Value;
    final fromTag = request.From.Tag;
    final toTag = request.To.Tag;
    if (callId == null || fromTag == null || toTag == null) return null;
    return _dialogs[DialogId(callId, toTag, fromTag)] ??
        _dialogs[DialogId(callId, fromTag, toTag)];
  }

  Dialog? findFromResponse(SipMsg response) {
    final callId = response.CallId.Value;
    final fromTag = response.From.Tag;
    final toTag = response.To.Tag;
    if (callId == null || fromTag == null || toTag == null) return null;
    return _dialogs[DialogId(callId, fromTag, toTag)] ??
        _dialogs[DialogId(callId, toTag, fromTag)];
  }

  void add(Dialog d) => _dialogs[d.id] = d;
  void remove(Dialog d) => _dialogs.remove(d.id);
  Iterable<Dialog> get dialogs => _dialogs.values;

  /// Cancels every dialog's session timer and clears the layer. Used during
  /// graceful shutdown.
  void close() {
    for (final d in _dialogs.values.toList()) {
      d.cancelSessionTimer();
      d.state = DialogState.terminated;
    }
    _dialogs.clear();
  }

  /// Convenience for the proxy: build a dialog from the original INVITE plus
  /// the to-tag that was placed on the 200 OK by the callee.
  Dialog createFromInvite(
    SipMsg invite,
    String calleeToTag, {
    SipClient? caller,
    SipClient? callee,
    List<String> routeSet = const [],
  }) {
    final callId = invite.CallId.Value!;
    final fromTag = invite.From.Tag ?? generateTag();
    final id = DialogId(callId, fromTag, calleeToTag);
    final d = Dialog(
      id: id,
      localUri: '${invite.From.User ?? ''}@${invite.From.Host ?? ''}',
      remoteUri: '${invite.To.User ?? ''}@${invite.To.Host ?? ''}',
      remoteTarget: invite.Contact.Src ?? '',
      remoteSeq: cseqNumber(invite) ?? 0,
      caller: caller,
      callee: callee,
      routeSet: List<String>.from(routeSet),
    );
    add(d);
    return d;
  }
}
