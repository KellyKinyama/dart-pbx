import 'package:flutter/material.dart';

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
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Square keys, sized so 3 fit per row with comfortable gaps.
        const gap = 12.0;
        final width = constraints.maxWidth;
        final keySize = ((width - gap * 2) / 3).clamp(56.0, 96.0);
        final pad = compact ? 6.0 : 10.0;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in _rows) ...[
              Padding(
                padding: EdgeInsets.symmetric(vertical: pad),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final k in row)
                      _KeyButton(
                        size: keySize,
                        digit: k.digit,
                        letters: k.letters,
                        onTap: () => onKey(k.digit),
                        onLongPress: k.digit == '0' ? onLongZero : null,
                        accent: k.digit == '*' || k.digit == '#'
                            ? scheme.tertiary
                            : null,
                      ),
                  ],
                ),
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
    this.accent,
  });

  final double size;
  final String digit;
  final String letters;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = accent ?? scheme.onSurface;
    return Material(
      color: scheme.surfaceContainerHigh,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
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
                    color: scheme.onSurfaceVariant,
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
