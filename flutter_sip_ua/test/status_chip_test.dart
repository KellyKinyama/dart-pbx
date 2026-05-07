import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_sip_ua/sip/sip_user_agent.dart';
import 'package:flutter_sip_ua/ui/widgets/status_chip.dart';

Future<void> _pump(WidgetTester tester, Widget w) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Center(child: w)),
    ),
  );
}

void main() {
  group('RegistrationStatusChip', () {
    testWidgets('shows a label for every state', (tester) async {
      const cases = {
        RegistrationState.registered: 'Registered',
        RegistrationState.registering: 'Connecting',
        RegistrationState.failed: 'Failed',
        RegistrationState.unregistered: 'Offline',
      };
      for (final entry in cases.entries) {
        await _pump(tester, RegistrationStatusChip(state: entry.key));
        await tester.pump(); // build only; avoid waiting on the spin animation
        expect(
          find.text(entry.value),
          findsOneWidget,
          reason: 'missing label for ${entry.key}',
        );
      }
    });

    testWidgets('connecting state uses a RotationTransition', (tester) async {
      await _pump(
        tester,
        const RegistrationStatusChip(state: RegistrationState.registering),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(RegistrationStatusChip),
          matching: find.byType(RotationTransition),
        ),
        findsOneWidget,
      );
    });

    testWidgets('non-connecting states have no RotationTransition', (
      tester,
    ) async {
      await _pump(
        tester,
        const RegistrationStatusChip(state: RegistrationState.registered),
      );
      await tester.pump();
      expect(
        find.descendant(
          of: find.byType(RegistrationStatusChip),
          matching: find.byType(RotationTransition),
        ),
        findsNothing,
      );
    });
  });

  group('PartyAvatar', () {
    Future<void> render(WidgetTester tester, String party) =>
        _pump(tester, PartyAvatar(party: party));

    testWidgets('strips sip: prefix and uses up to two letters', (
      tester,
    ) async {
      await render(tester, 'sip:alice@pbx.local');
      expect(find.text('AL'), findsOneWidget);
    });

    testWidgets('uses digits for numeric extensions', (tester) async {
      await render(tester, '6001');
      expect(find.text('60'), findsOneWidget);
    });

    testWidgets('falls back to ? for empty input', (tester) async {
      await render(tester, '');
      expect(find.text('?'), findsOneWidget);
    });

    testWidgets('handles single-character usernames', (tester) async {
      await render(tester, 'sip:a@x');
      expect(find.text('A'), findsOneWidget);
    });
  });
}
