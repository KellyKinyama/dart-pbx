import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/sip_providers.dart';
import '../sip/sip_user_agent.dart';
import 'widgets/call/call_action_panels.dart';
import 'widgets/call/call_backdrop.dart';
import 'widgets/call/call_party_card.dart';
import 'widgets/call/call_stats_panel.dart';
import 'widgets/call/call_top_bar.dart';
import 'widgets/call/transfer_sheet.dart';
import 'widgets/dial_pad.dart';

/// Full-screen call surface that orchestrates the modular call widgets.
///
/// Responsibilities kept here:
///   * Subscribe to UA call updates and own derived state (timer,
///     mute/hold/speaker/record/keypad/stats toggles, DTMF history).
///   * Pick which action panel to render given [SipCall.state].
///   * Wire individual button handlers to the SIP user agent.
class CallPage extends ConsumerStatefulWidget {
  const CallPage({super.key, required this.callId});
  final String callId;

  @override
  ConsumerState<CallPage> createState() => _CallPageState();
}

class _CallPageState extends ConsumerState<CallPage>
    with SingleTickerProviderStateMixin {
  StreamSubscription<SipCall>? _sub;
  SipCall? _call;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  DateTime? _activeSince;

  // UI-only toggles (Transfer / Record / Add-call have user-facing
  // fallbacks since the UA doesn't yet implement REFER/conference).
  bool _muted = false;
  bool _speaker = false;
  bool _showKeypad = false;
  bool _recording = false;
  bool _showStats = false;
  String _dtmfHistory = '';

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat(reverse: true);

  SipUserAgent get _ua => ref.read(sipUserAgentProvider);

  @override
  void initState() {
    super.initState();
    final initial = _ua.callById(widget.callId);
    if (initial != null) {
      _call = initial;
      _muted = _ua.isMuted(widget.callId) ?? false;
      if (initial.state == CallState.active) {
        _activeSince = initial.startedAt ?? DateTime.now();
        _startTicker();
      }
    }
    _sub = _ua.callStream.listen((c) {
      if (c.id != widget.callId) return;
      _onUpdate(c);
    });
  }

  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _activeSince == null) return;
      setState(() => _elapsed = DateTime.now().difference(_activeSince!));
    });
  }

  void _onUpdate(SipCall c) {
    setState(() => _call = c);
    if (c.state == CallState.active && _activeSince == null) {
      _activeSince = DateTime.now();
      _startTicker();
    }
    if (c.state == CallState.ended) {
      _ticker?.cancel();
      _pulse.stop();
      // Don't auto-pop — show the ended summary so the user can
      // dismiss it or place a call back.
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  // ── Handlers ─────────────────────────────────────────────────────────

  void _toggleMute() {
    final next = !_muted;
    final applied = _ua.setMuted(widget.callId, next);
    if (applied != null) setState(() => _muted = applied);
  }

  void _toggleHold() {
    final c = _call;
    if (c == null) return;
    final applied = _ua.setHold(widget.callId, !c.held);
    if (applied == null) _toast('Cannot hold this call right now');
  }

  void _toggleSpeaker() => setState(() => _speaker = !_speaker);

  void _toggleKeypad() => setState(() => _showKeypad = !_showKeypad);

  void _toggleRecording() {
    setState(() => _recording = !_recording);
    _toast(_recording ? 'Recording started' : 'Recording stopped');
  }

  void _toggleStats() => setState(() => _showStats = !_showStats);

  void _sendDtmf(String d) {
    _ua.sendDtmf(widget.callId, d);
    setState(() {
      final next = _dtmfHistory + d;
      _dtmfHistory = next.length > 16 ? next.substring(next.length - 16) : next;
    });
  }

  Future<void> _onTransfer() async {
    final req = await TransferSheet.show(context);
    if (req == null || !mounted) return;
    _toast(
      req.attended
          ? 'Attended transfer to ${req.target} not yet implemented'
          : 'Blind transfer to ${req.target} not yet implemented',
    );
  }

  void _onAddCall() {
    _toast('Add-call (conference) not yet implemented');
  }

  void _onCallBack() {
    final c = _call;
    if (c == null) return;
    _ua.makeCall(c.remoteParty);
    Navigator.of(context).maybePop();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final c = _call;
    final state = c?.state ?? CallState.idle;

    return PopScope(
      // Allow pop in any non-active state so users can bail out of an
      // accidentally placed outgoing call.
      canPop: state != CallState.active,
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: CallBackdrop(state: state, party: c?.remoteParty),
            ),
            SafeArea(
              child: c == null
                  ? const Center(child: CircularProgressIndicator())
                  : _buildContent(c, state),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContent(SipCall c, CallState state) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CallTopBar(
            outgoing: c.outgoing,
            state: state,
            recording: _recording,
            onMinimise: () => Navigator.of(context).maybePop(),
          ),
          const SizedBox(height: 16),
          CallPartyCard(
            party: c.remoteParty,
            state: state,
            held: c.held,
            elapsed: _elapsed,
            pulse: _pulse,
          ),
          if (_dtmfHistory.isNotEmpty && state == CallState.active)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _dtmfHistory,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  letterSpacing: 4,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          if (_showStats && state == CallState.active)
            const CallStatsPanel(
              codec: 'PCMU',
              bitrateKbps: null,
              packetLossPct: null,
              jitterMs: null,
              rttMs: null,
            ),
          const Spacer(),
          if (_showKeypad && state == CallState.active) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: DialPad(compact: true, onKey: _sendDtmf),
            ),
            TextButton.icon(
              onPressed: _toggleKeypad,
              icon: const Icon(Icons.keyboard_arrow_down),
              label: const Text('Hide keypad'),
            ),
          ],
          _buildActions(c, state),
        ],
      ),
    );
  }

  Widget _buildActions(SipCall c, CallState state) {
    switch (state) {
      case CallState.incomingRinging:
        return IncomingCallActions(
          onAnswer: () => _ua.answer(c.id),
          onDecline: () => _ua.hangup(c.id),
        );
      case CallState.outgoingRinging:
        return OutgoingCallActions(onCancel: () => _ua.hangup(c.id));
      case CallState.active:
        // Hide the bulky action grid behind the keypad — BP does the
        // same: when the keypad opens, the action row collapses.
        if (_showKeypad) return const SizedBox.shrink();
        return ActiveCallActions(
          muted: _muted,
          held: c.held,
          speaker: _speaker,
          recording: _recording,
          statsVisible: _showStats,
          onMute: _toggleMute,
          onHold: _toggleHold,
          onSpeaker: _toggleSpeaker,
          onKeypad: _toggleKeypad,
          onTransfer: _onTransfer,
          onRecord: _toggleRecording,
          onAddCall: _onAddCall,
          onToggleStats: _toggleStats,
          onHangup: () => _ua.hangup(c.id),
        );
      case CallState.ended:
        return EndedCallActions(
          onClose: () => Navigator.of(context).maybePop(),
          onCallBack: _onCallBack,
        );
      case CallState.idle:
        return const SizedBox.shrink();
    }
  }
}
