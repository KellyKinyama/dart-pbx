import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../sip/sip_user_agent.dart';
import '../../bp_palette.dart';
import '../status_chip.dart';

/// Browser-Phone style call wallpaper, layered exactly like BP:
///   1. The page background fill (BP `body { background-color: #f6f6f6 }`
///      / dark `#222222`).
///   2. `.CallPictureUnderlay` — a heavily blurred copy of the buddy
///      avatar at low opacity, providing the dominant tint.
///   3. `.CallColorUnderlay` — `radial-gradient(circle, transparent,
///      #f6f6f6)` (or `#222222` in dark): a centred vignette that
///      gently fades the picture out toward the page edges so the
///      foreground UI stays readable.
///   4. A whisper-thin top tint that varies by [CallState] so the
///      state still reads at a glance (active = activeCall green,
///      ringing = presenceRinging orange, ended = hangup red).
class CallBackdrop extends StatelessWidget {
  const CallBackdrop({super.key, required this.state, this.party});

  final CallState state;
  final String? party;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bp = Theme.of(context).bp;

    // BP `.CallColorUnderlay` is a centred radial fading from
    // transparent at the middle to the page background at the edges.
    final pageBg = Theme.of(context).scaffoldBackgroundColor;
    final colorUnderlay = RadialGradient(
      center: Alignment.center,
      radius: 0.95,
      colors: [Colors.transparent, pageBg],
    );

    final stateAccent = switch (state) {
      CallState.active => bp.activeCall,
      CallState.ended => bp.hangup,
      CallState.incomingRinging => bp.presenceRinging,
      CallState.outgoingRinging => scheme.primary,
      CallState.idle => scheme.primary,
    };

    return Stack(
      fit: StackFit.expand,
      children: [
        // Layer 1: page bg.
        Positioned.fill(child: ColoredBox(color: pageBg)),
        // Layer 2: blurred avatar picture underlay.
        if (party != null)
          Positioned.fill(
            child: ImageFiltered(
              imageFilter: ui.ImageFilter.blur(sigmaX: 60, sigmaY: 60),
              child: Opacity(
                opacity: 0.30,
                child: Align(
                  alignment: Alignment.center,
                  child: PartyAvatar(party: party!, size: 420),
                ),
              ),
            ),
          ),
        // Layer 3: BP `.CallColorUnderlay` — radial transparent → pageBg.
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: colorUnderlay),
          ),
        ),
        // Layer 4: subtle state-tint at the very top so the screen
        // still reads as "ringing" / "active" / "ended" at a glance.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: 220,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  stateAccent.withValues(alpha: 0.18),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
