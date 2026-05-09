import 'package:flutter/material.dart';

import '../bp_palette.dart';

/// Browser-Phone style row of three call-action buttons used at the
/// bottom of the dialer:
///
///   * Video call — disabled in this UA (no video media yet).
///   * Audio call — primary green dial button.
///   * Send message — quick MESSAGE without placing a call.
///
/// Mirrors BP `.dialCall` (padding: 25px; margin-top: 10px) and
/// `.dialButtons` (55×55 round). All three buttons share the same
/// outer size for a uniform row; the dial button just gets a stronger
/// fill so it reads as the primary action.
class DialerActionRow extends StatelessWidget {
  const DialerActionRow({
    super.key,
    required this.enabled,
    required this.onAudioCall,
    required this.onMessage,
    this.onVideoCall,
    this.size = 60,
    this.spacing = 28,
  });

  final bool enabled;
  final VoidCallback? onAudioCall;
  final VoidCallback? onMessage;

  /// Pass `null` to render the video button as permanently disabled.
  final VoidCallback? onVideoCall;

  /// Outer diameter of each action button. BP uses 55, we go a touch
  /// larger by default so the touch targets feel right on mobile.
  final double size;

  /// Horizontal gap between buttons.
  final double spacing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bp = Theme.of(context).bp;
    return Padding(
      // BP `.dialCall { padding: 25px; margin-top: 10px; }`.
      padding: const EdgeInsets.symmetric(vertical: 18),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _DialerCircle(
            icon: Icons.videocam_outlined,
            color: scheme.surfaceContainerHigh,
            iconColor: scheme.onSurfaceVariant,
            size: size,
            tooltip: 'Video call (not supported)',
            onTap: enabled ? onVideoCall : null,
          ),
          SizedBox(width: spacing),
          _DialerCircle(
            icon: Icons.call,
            color: bp.dial,
            iconColor: Colors.white,
            size: size,
            tooltip: 'Audio call',
            primary: true,
            onTap: enabled ? onAudioCall : null,
          ),
          SizedBox(width: spacing),
          _DialerCircle(
            icon: Icons.chat_bubble_outline,
            color: scheme.surfaceContainerHigh,
            iconColor: scheme.primary,
            size: size,
            tooltip: 'Send message',
            onTap: enabled ? onMessage : null,
          ),
        ],
      ),
    );
  }
}

class _DialerCircle extends StatelessWidget {
  const _DialerCircle({
    required this.icon,
    required this.color,
    required this.iconColor,
    required this.size,
    required this.tooltip,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final Color color;
  final Color iconColor;
  final double size;
  final String tooltip;
  final VoidCallback? onTap;

  /// The primary action gets a small lift via elevation; secondary
  /// actions stay flat to match BP's understated message/video buttons.
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: disabled ? 0.4 : 1,
        child: SizedBox(
          width: size,
          height: size,
          child: Material(
            color: color,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            elevation: disabled
                ? 0
                : primary
                ? 3
                : 0,
            child: InkWell(
              onTap: onTap,
              child: Center(
                child: Icon(icon, color: iconColor, size: size * 0.44),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
