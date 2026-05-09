import 'package:flutter/material.dart';

import '../bp_palette.dart';

/// A telephone-style 3×4 keypad. Tapping a key invokes [onKey] with the
/// digit character (`0`-`9`, `*`, `#`). The optional [onLongZero] is
/// fired when the user long-presses `0` (commonly used to enter `+`).
class DialPad extends StatelessWidget {
  const DialPad({
    super.key,
    required this.onKey,
    this.onLongZero,
    this.compact = false,
  });

  final ValueChanged<String> onKey;
  final VoidCallback? onLongZero;
  final bool compact;

  static const _rows = <List<_Key>>[
    [_Key('1', ''), _Key('2', 'ABC'), _Key('3', 'DEF')],
    [_Key('4', 'GHI'), _Key('5', 'JKL'), _Key('6', 'MNO')],
    [_Key('7', 'PQRS'), _Key('8', 'TUV'), _Key('9', 'WXYZ')],
    [_Key('*', ''), _Key('0', '+'), _Key('#', '')],
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 14.0;
        final width = constraints.maxWidth;
        // Browser-Phone .dialButtons are 55px round; we let them flex on
        // narrow screens but keep the BP look on regular widths.
        final keySize = ((width - gap * 2) / 3).clamp(
          compact ? 48.0 : 55.0,
          compact ? 64.0 : 72.0,
        );
        // BP keeps rows visually tight (the 7px digit margin only applies
        // inside the button); we just need a small gap between rows.
        final rowGap = compact ? 4.0 : 8.0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < _rows.length; i++) ...[
              if (i > 0) SizedBox(height: rowGap),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (final k in _rows[i])
                    _KeyButton(
                      size: keySize,
                      digit: k.digit,
                      letters: k.letters,
                      onTap: () => onKey(k.digit),
                      onLongPress: k.digit == '0' ? onLongZero : null,
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Key {
  const _Key(this.digit, this.letters);
  final String digit;
  final String letters;
}

class _KeyButton extends StatelessWidget {
  const _KeyButton({
    required this.size,
    required this.digit,
    required this.letters,
    required this.onTap,
    this.onLongPress,
  });

  final double size;
  final String digit;
  final String letters;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    // Browser-Phone .dialButtons:
    //   light: bg #eeeeee  text #3478f3 (.dialButtons span -> #999)
    //   dark : bg #404040  text #cccccc (.dialButtons span -> #999)
    //   :active (pressed)  bg #666666   text #ffffff   (both modes)
    final isDark = theme.brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF404040) : const Color(0xFFEEEEEE);
    final fg = isDark ? const Color(0xFFCCCCCC) : scheme.primary;
    return Material(
      color: bg,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        // BP `.dialButtons:active { background-color: #666666; color: #FFFFFF }`
        // — the splash colour mimics the same dark grey flash.
        splashColor: const Color(0xFF666666).withValues(alpha: 0.45),
        highlightColor: const Color(0xFF666666).withValues(alpha: 0.20),
        child: SizedBox(
          width: size,
          height: size,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                digit,
                style: TextStyle(
                  fontSize: size * 0.42,
                  fontWeight: FontWeight.w500,
                  color: fg,
                  height: 1,
                ),
              ),
              if (letters.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  letters,
                  style: TextStyle(
                    fontSize: size * 0.13,
                    letterSpacing: 1.4,
                    color: const Color(0xFF999999),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Big circular green dial button matching Browser-Phone's `.dialButtonsDial`.
class DialCallButton extends StatelessWidget {
  const DialCallButton({super.key, required this.onPressed, this.size = 64});

  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    final bp = Theme.of(context).bp;
    final disabled = onPressed == null;
    return SizedBox(
      width: size,
      height: size,
      child: Material(
        color: disabled ? bp.dial.withValues(alpha: 0.4) : bp.dial,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: Center(
            child: Icon(Icons.call, color: Colors.white, size: size * 0.45),
          ),
        ),
      ),
    );
  }
}
