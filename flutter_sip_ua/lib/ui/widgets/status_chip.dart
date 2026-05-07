import 'package:flutter/material.dart';

import '../../sip/sip_user_agent.dart';

/// Compact pill that summarises the current registration state.
class RegistrationStatusChip extends StatefulWidget {
  const RegistrationStatusChip({super.key, required this.state});

  final RegistrationState state;

  @override
  State<RegistrationStatusChip> createState() => _RegistrationStatusChipState();
}

class _RegistrationStatusChipState extends State<RegistrationStatusChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void initState() {
    super.initState();
    _syncSpin();
  }

  @override
  void didUpdateWidget(covariant RegistrationStatusChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) _syncSpin();
  }

  void _syncSpin() {
    if (widget.state == RegistrationState.registering) {
      _spin.repeat();
    } else {
      _spin.stop();
      _spin.value = 0;
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, fg, bg, icon) = switch (widget.state) {
      RegistrationState.registered => (
        'Registered',
        scheme.onPrimaryContainer,
        scheme.primaryContainer,
        Icons.check_circle,
      ),
      RegistrationState.registering => (
        'Connecting',
        scheme.onTertiaryContainer,
        scheme.tertiaryContainer,
        Icons.sync,
      ),
      RegistrationState.failed => (
        'Failed',
        scheme.onErrorContainer,
        scheme.errorContainer,
        Icons.error_outline,
      ),
      RegistrationState.unregistered => (
        'Offline',
        scheme.onSurfaceVariant,
        scheme.surfaceContainerHigh,
        Icons.cloud_off,
      ),
    };

    final iconWidget = Icon(icon, size: 14, color: fg);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.state == RegistrationState.registering)
            RotationTransition(turns: _spin, child: iconWidget)
          else
            iconWidget,
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: fg,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Round avatar that renders the first 1–2 characters of an extension or
/// SIP URI. Used in call lists, chats, and the active-call screen.
class PartyAvatar extends StatelessWidget {
  const PartyAvatar({super.key, required this.party, this.size = 40});

  final String party;
  final double size;

  String get _initials {
    var s = party.trim();
    if (s.startsWith('sip:')) s = s.substring(4);
    final at = s.indexOf('@');
    if (at > 0) s = s.substring(0, at);
    if (s.isEmpty) return '?';
    final clean = s.replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (clean.isEmpty) return s.characters.first.toUpperCase();
    return clean.length >= 2
        ? clean.substring(0, 2).toUpperCase()
        : clean.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        shape: BoxShape.circle,
      ),
      child: Text(
        _initials,
        style: TextStyle(
          color: scheme.onPrimaryContainer,
          fontWeight: FontWeight.w600,
          fontSize: size * 0.4,
        ),
      ),
    );
  }
}
