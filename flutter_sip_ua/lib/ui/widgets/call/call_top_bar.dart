import 'package:flutter/material.dart';

import '../../../sip/sip_user_agent.dart';
import '../../bp_palette.dart';

/// Slim header above the party card.
///
///   * Minimise button (collapses the screen back to home, disabled
///     once the call is over so the auto-pop runs).
///   * Direction label (Outgoing / Incoming).
///   * Recording dot, only visible while a local recording is active.
class CallTopBar extends StatelessWidget {
  const CallTopBar({
    super.key,
    required this.outgoing,
    required this.state,
    required this.recording,
    this.onMinimise,
  });

  final bool outgoing;
  final CallState state;
  final bool recording;
  final VoidCallback? onMinimise;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bp = Theme.of(context).bp;
    final canPop = state != CallState.ended;
    return Row(
      children: [
        IconButton(
          tooltip: 'Minimise',
          onPressed: canPop ? onMinimise : null,
          icon: const Icon(Icons.expand_more),
        ),
        if (recording) _RecordingPill(color: bp.hangup),
        const Spacer(),
        Text(
          outgoing ? 'Outgoing' : 'Incoming',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
            color: scheme.onSurface.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }
}

class _RecordingPill extends StatefulWidget {
  const _RecordingPill({required this.color});
  final Color color;

  @override
  State<_RecordingPill> createState() => _RecordingPillState();
}

class _RecordingPillState extends State<_RecordingPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: 0.4 + 0.6 * _c.value,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: widget.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'REC',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
