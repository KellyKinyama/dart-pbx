import 'dart:async';

import 'package:flutter/material.dart';

import '../sip/sip_user_agent.dart';
import 'widgets/dial_pad.dart';
import 'widgets/status_chip.dart';

class CallPage extends StatefulWidget {
  const CallPage({super.key, required this.ua, required this.callId});
  final SipUserAgent ua;
  final String callId;

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage>
    with SingleTickerProviderStateMixin {
  StreamSubscription<SipCall>? _sub;
  SipCall? _call;
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  DateTime? _activeSince;
  bool _muted = false;
  bool _speaker = false;
  bool _showKeypad = false;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _sub = widget.ua.callStream.listen((c) {
      if (c.id != widget.callId) return;
      _onUpdate(c);
    });
  }

  void _onUpdate(SipCall c) {
    setState(() => _call = c);
    if (c.state == CallState.active && _activeSince == null) {
      _activeSince = DateTime.now();
      _ticker?.cancel();
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (!mounted) return;
        setState(() {
          _elapsed = DateTime.now().difference(_activeSince!);
        });
      });
    }
    if (c.state == CallState.ended) {
      _ticker?.cancel();
      _pulse.stop();
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted) Navigator.of(context).maybePop();
      });
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _ticker?.cancel();
    _pulse.dispose();
    super.dispose();
  }

  String _stateLabel(CallState s) {
    switch (s) {
      case CallState.outgoingRinging:
        return 'Calling…';
      case CallState.incomingRinging:
        return 'Incoming call';
      case CallState.active:
        return _formatDuration(_elapsed);
      case CallState.ended:
        return 'Call ended';
      case CallState.idle:
        return '';
    }
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  void _toggleMute() {
    final next = !_muted;
    final applied = widget.ua.setMuted(widget.callId, next);
    if (applied != null) setState(() => _muted = applied);
  }

  void _sendDtmf(String d) {
    widget.ua.sendDtmf(widget.callId, d);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final c = _call;
    final state = c?.state ?? CallState.idle;
    final isRinging =
        state == CallState.incomingRinging ||
        state == CallState.outgoingRinging;

    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: switch (state) {
        CallState.active => [
          scheme.primary,
          Color.lerp(scheme.primary, scheme.surface, 0.6) ?? scheme.surface,
        ],
        CallState.ended => [scheme.errorContainer, scheme.surface],
        _ => [
          Color.lerp(scheme.primary, scheme.surface, 0.3) ?? scheme.surface,
          scheme.surface,
        ],
      },
    );

    return PopScope(
      canPop: state == CallState.ended,
      child: Scaffold(
        body: Container(
          decoration: BoxDecoration(gradient: gradient),
          child: SafeArea(
            child: c == null
                ? const Center(child: CircularProgressIndicator())
                : Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 24,
                      vertical: 16,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Row(
                          children: [
                            IconButton(
                              tooltip: 'Minimise',
                              onPressed: state == CallState.ended
                                  ? null
                                  : () => Navigator.of(context).maybePop(),
                              icon: const Icon(Icons.expand_more),
                            ),
                            const Spacer(),
                            Text(
                              c.outgoing ? 'Outgoing' : 'Incoming',
                              style: Theme.of(context).textTheme.labelLarge
                                  ?.copyWith(
                                    color: scheme.onSurface.withValues(
                                      alpha: 0.7,
                                    ),
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        _PulsingAvatar(
                          party: c.remoteParty,
                          animate: isRinging,
                          controller: _pulse,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          _displayName(c.remoteParty),
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                          textAlign: TextAlign.center,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _subtitle(c.remoteParty),
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: scheme.onSurface.withValues(alpha: 0.6),
                              ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          _stateLabel(state),
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                fontWeight: FontWeight.w500,
                              ),
                        ),
                        const Spacer(),
                        if (_showKeypad && state == CallState.active)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: DialPad(compact: true, onKey: _sendDtmf),
                          )
                        else if (state == CallState.active)
                          _ActionGrid(
                            muted: _muted,
                            speaker: _speaker,
                            onMute: _toggleMute,
                            onSpeaker: () =>
                                setState(() => _speaker = !_speaker),
                            onKeypad: () => setState(() => _showKeypad = true),
                          ),
                        if (_showKeypad)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: TextButton.icon(
                              onPressed: () =>
                                  setState(() => _showKeypad = false),
                              icon: const Icon(Icons.keyboard_arrow_down),
                              label: const Text('Hide keypad'),
                            ),
                          ),
                        _CallActionBar(
                          state: state,
                          onAnswer: () => widget.ua.answer(c.id),
                          onHangup: () => widget.ua.hangup(c.id),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  static String _displayName(String party) {
    var s = party;
    if (s.startsWith('sip:')) s = s.substring(4);
    final at = s.indexOf('@');
    if (at > 0) return s.substring(0, at);
    return s;
  }

  static String _subtitle(String party) {
    var s = party;
    if (s.startsWith('sip:')) s = s.substring(4);
    final at = s.indexOf('@');
    return at > 0 ? s.substring(at + 1) : '';
  }
}

class _PulsingAvatar extends StatelessWidget {
  const _PulsingAvatar({
    required this.party,
    required this.animate,
    required this.controller,
  });
  final String party;
  final bool animate;
  final AnimationController controller;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = animate ? Curves.easeInOut.transform(controller.value) : 0.0;
        return SizedBox(
          width: 200,
          height: 200,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (animate) ...[_ring(t, 0.0, scheme), _ring(t, 0.4, scheme)],
              PartyAvatar(party: party, size: 132),
            ],
          ),
        );
      },
    );
  }

  Widget _ring(double t, double offset, ColorScheme scheme) {
    final phase = (t + offset) % 1.0;
    final size = 132 + phase * 80;
    return Opacity(
      opacity: (1 - phase).clamp(0.0, 1.0) * 0.4,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: scheme.primary, width: 2),
        ),
      ),
    );
  }
}

class _ActionGrid extends StatelessWidget {
  const _ActionGrid({
    required this.muted,
    required this.speaker,
    required this.onMute,
    required this.onSpeaker,
    required this.onKeypad,
  });
  final bool muted;
  final bool speaker;
  final VoidCallback onMute;
  final VoidCallback onSpeaker;
  final VoidCallback onKeypad;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _CallToggle(
            icon: muted ? Icons.mic_off : Icons.mic,
            label: muted ? 'Unmute' : 'Mute',
            active: muted,
            onTap: onMute,
          ),
          _CallToggle(
            icon: Icons.dialpad,
            label: 'Keypad',
            active: false,
            onTap: onKeypad,
          ),
          _CallToggle(
            icon: speaker ? Icons.volume_up : Icons.volume_down,
            label: 'Speaker',
            active: speaker,
            onTap: onSpeaker,
          ),
        ],
      ),
    );
  }
}

class _CallToggle extends StatelessWidget {
  const _CallToggle({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = active ? scheme.primary : scheme.surfaceContainerHigh;
    final fg = active ? scheme.onPrimary : scheme.onSurface;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: bg,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 64,
              height: 64,
              child: Icon(icon, color: fg, size: 28),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: scheme.onSurface.withValues(alpha: 0.8),
          ),
        ),
      ],
    );
  }
}

class _CallActionBar extends StatelessWidget {
  const _CallActionBar({
    required this.state,
    required this.onAnswer,
    required this.onHangup,
  });
  final CallState state;
  final VoidCallback onAnswer;
  final VoidCallback onHangup;

  @override
  Widget build(BuildContext context) {
    final isIncoming = state == CallState.incomingRinging;
    final isEnded = state == CallState.ended;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16, top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          if (isIncoming)
            _BigCircleButton(
              color: Colors.green.shade600,
              icon: Icons.call,
              label: 'Answer',
              onTap: onAnswer,
            ),
          _BigCircleButton(
            color: Colors.red.shade600,
            icon: Icons.call_end,
            label: isIncoming ? 'Decline' : (isEnded ? 'Close' : 'Hang up'),
            onTap: isEnded ? () => Navigator.of(context).maybePop() : onHangup,
          ),
        ],
      ),
    );
  }
}

class _BigCircleButton extends StatelessWidget {
  const _BigCircleButton({
    required this.color,
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: color,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          elevation: 4,
          child: InkWell(
            onTap: onTap,
            child: SizedBox(
              width: 76,
              height: 76,
              child: Icon(icon, color: Colors.white, size: 32),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: Theme.of(context).textTheme.labelMedium),
      ],
    );
  }
}
