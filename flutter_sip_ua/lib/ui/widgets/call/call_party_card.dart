import 'package:flutter/material.dart';

import '../../../sip/sip_user_agent.dart';
import '../../bp_palette.dart';
import '../status_chip.dart';

/// Pulsing avatar + display name + remote-host subtitle, plus a status
/// line beneath that morphs by [CallState]: "Calling…", "Incoming call",
/// "On hold", call timer, or "Call ended".
class CallPartyCard extends StatelessWidget {
  const CallPartyCard({
    super.key,
    required this.party,
    required this.state,
    required this.held,
    required this.elapsed,
    required this.pulse,
  });

  final String party;
  final CallState state;
  final bool held;
  final Duration elapsed;
  final AnimationController pulse;

  bool get _isRinging =>
      state == CallState.incomingRinging || state == CallState.outgoingRinging;

  String get _displayName {
    var s = party;
    if (s.startsWith('sip:')) s = s.substring(4);
    final at = s.indexOf('@');
    if (at > 0) return s.substring(0, at);
    return s;
  }

  String get _subtitle {
    var s = party;
    if (s.startsWith('sip:')) s = s.substring(4);
    final at = s.indexOf('@');
    return at > 0 ? s.substring(at + 1) : '';
  }

  String _stateLabel() {
    if (state == CallState.active) {
      if (held) return 'On hold';
      return _formatDuration(elapsed);
    }
    return switch (state) {
      CallState.outgoingRinging => 'Calling…',
      CallState.incomingRinging => 'Incoming call',
      CallState.ended => 'Call ended',
      _ => '',
    };
  }

  static String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    final h = d.inHours;
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bp = Theme.of(context).bp;
    final stateColor = switch (state) {
      CallState.incomingRinging => bp.presenceRinging,
      CallState.active => held ? bp.holdingCall : bp.activeCall,
      CallState.ended => bp.hangup,
      _ => scheme.onSurface.withValues(alpha: 0.7),
    };

    return Column(
      children: [
        _PulsingAvatar(party: party, animate: _isRinging, controller: pulse),
        const SizedBox(height: 20),
        Text(
          _displayName,
          style: Theme.of(
            context,
          ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 6),
        Text(
          _subtitle,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurface.withValues(alpha: 0.6),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          _stateLabel(),
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: stateColor,
            fontFeatures: const [FontFeature.tabularFigures()],
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
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
