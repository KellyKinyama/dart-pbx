import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_sip_ua/ui/widgets/dial_pad.dart';

Future<void> _pump(WidgetTester tester, Widget w) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SizedBox(width: 320, child: w)),
    ),
  );
}

void main() {
  group('DialPad', () {
    testWidgets('renders all 12 keys with letter labels', (tester) async {
      await _pump(tester, DialPad(onKey: (_) {}));

      // 12 digit characters all visible.
      for (final d in const [
        '1',
        '2',
        '3',
        '4',
        '5',
        '6',
        '7',
        '8',
        '9',
        '*',
        '0',
        '#',
      ]) {
        expect(find.text(d), findsOneWidget, reason: 'missing key $d');
      }
      // Letter rows present (sample).
      expect(find.text('ABC'), findsOneWidget);
      expect(find.text('JKL'), findsOneWidget);
      expect(find.text('WXYZ'), findsOneWidget);
      // 0 shows '+' as its alternate label.
      expect(find.text('+'), findsOneWidget);
    });

    testWidgets('tapping a digit invokes onKey with that digit', (
      tester,
    ) async {
      final pressed = <String>[];
      await _pump(tester, DialPad(onKey: pressed.add));

      await tester.tap(find.text('5'));
      await tester.tap(find.text('#'));
      await tester.tap(find.text('0'));
      await tester.pumpAndSettle();

      expect(pressed, ['5', '#', '0']);
    });

    testWidgets('long-pressing 0 invokes onLongZero, not onKey', (
      tester,
    ) async {
      final pressed = <String>[];
      var longCount = 0;
      await _pump(
        tester,
        DialPad(onKey: pressed.add, onLongZero: () => longCount++),
      );

      await tester.longPress(find.text('0'));
      await tester.pumpAndSettle();

      expect(longCount, 1);
      // Long-press should not also fire onKey for '0'.
      expect(pressed.contains('0'), isFalse);
    });
  });
}
