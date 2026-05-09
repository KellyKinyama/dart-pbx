import 'package:flutter/material.dart';

import '../../bp_palette.dart';
import 'call_buttons.dart';

/// Browser-Phone incoming call action row: big green Answer + big red
/// Decline. The optional [autoAnswerCountdown] mirrors BP's
/// "Answering in N…" feature. Pass `null` to hide the chip.
class IncomingCallActions extends StatelessWidget {
  const IncomingCallActions({
    super.key,
    required this.onAnswer,
    required this.onDecline,
    this.autoAnswerCountdown,
  });

  final VoidCallback onAnswer;
  final VoidCallback onDecline;
  final int? autoAnswerCountdown;

  @override
  Widget build(BuildContext context) {
    final bp = Theme.of(context).bp;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16, top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (autoAnswerCountdown != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: bp.answer.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  'Answering in ${autoAnswerCountdown!}s…',
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: bp.answer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              BigCallButton(
                color: bp.answer,
                icon: Icons.call,
                label: 'Answer',
                onTap: onAnswer,
              ),
              BigCallButton(
                color: bp.hangup,
                icon: Icons.call_end,
                label: 'Decline',
                onTap: onDecline,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Outgoing-while-ringing actions: just a big red Cancel button.
class OutgoingCallActions extends StatelessWidget {
  const OutgoingCallActions({super.key, required this.onCancel});

  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final bp = Theme.of(context).bp;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16, top: 8),
      child: Center(
        child: BigCallButton(
          color: bp.hangup,
          icon: Icons.call_end,
          label: 'Cancel',
          onTap: onCancel,
        ),
      ),
    );
  }
}

/// Active-call action set: a primary 3-button row (Mute / Keypad /
/// Speaker), an extras strip (Hold / Transfer / Record / Add call /
/// Stats), and a centred big red Hang up.
class ActiveCallActions extends StatelessWidget {
  const ActiveCallActions({
    super.key,
    required this.muted,
    required this.held,
    required this.speaker,
    required this.recording,
    required this.statsVisible,
    required this.onMute,
    required this.onHold,
    required this.onSpeaker,
    required this.onKeypad,
    required this.onTransfer,
    required this.onRecord,
    required this.onAddCall,
    required this.onToggleStats,
    required this.onHangup,
  });

  final bool muted;
  final bool held;
  final bool speaker;
  final bool recording;
  final bool statsVisible;
  final VoidCallback onMute;
  final VoidCallback onHold;
  final VoidCallback onSpeaker;
  final VoidCallback onKeypad;
  final VoidCallback onTransfer;
  final VoidCallback onRecord;
  final VoidCallback onAddCall;
  final VoidCallback onToggleStats;
  final VoidCallback onHangup;

  @override
  Widget build(BuildContext context) {
    final bp = Theme.of(context).bp;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16, top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              CallActionButton(
                icon: muted ? Icons.mic_off : Icons.mic,
                label: muted ? 'Unmute' : 'Mute',
                active: muted,
                onTap: onMute,
              ),
              CallActionButton(
                icon: Icons.dialpad,
                label: 'Keypad',
                onTap: onKeypad,
              ),
              CallActionButton(
                icon: speaker ? Icons.volume_up : Icons.volume_down,
                label: 'Speaker',
                active: speaker,
                onTap: onSpeaker,
              ),
            ],
          ),
          const SizedBox(height: 14),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                CallExtraButton(
                  icon: held ? Icons.play_arrow : Icons.pause,
                  label: held ? 'Resume' : 'Hold',
                  active: held,
                  activeColor: bp.holdingCall,
                  onTap: onHold,
                ),
                CallExtraButton(
                  icon: Icons.phone_forwarded,
                  label: 'Transfer',
                  onTap: onTransfer,
                ),
                CallExtraButton(
                  icon: recording
                      ? Icons.fiber_manual_record
                      : Icons.radio_button_unchecked,
                  label: recording ? 'Stop rec' : 'Record',
                  active: recording,
                  activeColor: bp.hangup,
                  onTap: onRecord,
                ),
                CallExtraButton(
                  icon: Icons.person_add_alt_1,
                  label: 'Add call',
                  onTap: onAddCall,
                ),
                CallExtraButton(
                  icon: Icons.insights,
                  label: 'Stats',
                  active: statsVisible,
                  onTap: onToggleStats,
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          BigCallButton(
            color: bp.hangup,
            icon: Icons.call_end,
            label: 'Hang up',
            onTap: onHangup,
          ),
        ],
      ),
    );
  }
}

/// After a call ends BP shows a small summary with a "Close" and an
/// optional "Call back" button. Mirrors `.AfterCallButtons` from
/// phone.css.
class EndedCallActions extends StatelessWidget {
  const EndedCallActions({
    super.key,
    required this.onClose,
    required this.onCallBack,
  });

  final VoidCallback onClose;
  final VoidCallback onCallBack;

  @override
  Widget build(BuildContext context) {
    final bp = Theme.of(context).bp;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16, top: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          BigCallButton(
            color: bp.answer,
            icon: Icons.call,
            label: 'Call back',
            onTap: onCallBack,
          ),
          BigCallButton(
            color: bp.hangup,
            icon: Icons.close,
            label: 'Close',
            onTap: onClose,
          ),
        ],
      ),
    );
  }
}
