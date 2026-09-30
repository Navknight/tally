// Every ledger row, on every screen, must open the edit sheet - that is the
// only way to label one. Insights shipped its rows without an onTap and the
// whole review loop was dead there, so this pins the behaviour down.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tally/core/budget_period.dart';
import 'package:tally/insights.dart';
import 'package:tally/main.dart';
import 'package:tally/models/account.dart';
import 'package:tally/models/transaction.dart';
import 'package:tally/state/app_state.dart';

final _labelled = TallyTransaction(
  id: 8,
  amountMinor: 45000,
  kind: TransactionKind.expense,
  occurredAt: DateTime(2026, 9, 30, 11),
  merchant: 'Corner Cafe',
  category: 'Food',
  accountId: 1,
);

final _needsLabel = TallyTransaction(
  id: 7,
  amountMinor: 120000,
  kind: TransactionKind.expense,
  occurredAt: DateTime(2026, 9, 30, 10),
  merchant: 'UPI/9845012345',
  category: 'Other',
  accountId: 1,
  needsReview: true,
);

void _seed() {
  final s = appState
    ..loaded = true
    ..symbol = '₹'
    ..budgetMinor = 2000000
    ..startDay = 1
    ..accounts = const [
      Account(id: 1, name: 'Main', last4: '4417', openingBalanceMinor: 0),
    ]
    ..balances = const {1: 100000}
    ..ledger = [_needsLabel]
    ..recent = [_needsLabel]
    ..review = [_needsLabel]
    ..budgetRows = [_needsLabel]
    ..budgetRowCount = 1
    ..ledgerCount = 1
    ..byCategory = const [('Other', 120000)]
    ..detections = const [];
  s.period = budgetPeriod(DateTime.now(), 1);
  s.ledgerDays = groupByDay(s.ledger);
}

Future<void> _tapRow(WidgetTester tester, Widget screen) async {
  // Tall enough that the lazy lists build their rows: the default 800x600
  // surface leaves Insights' ledger below the fold, where it never exists.
  tester.view.physicalSize = const Size(1000, 4200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: screen));
  await tester.pumpAndSettle();
  final tile = find.byType(TransactionTile);
  expect(tile, findsWidgets, reason: 'the row should be on screen at all');
  await tester.tap(tile.first);
  await tester.pumpAndSettle();
}

void _useLabelledRow() {
  final s = appState
    ..ledger = [_labelled]
    ..recent = [_labelled]
    ..review = const []
    ..budgetRows = [_labelled]
    ..byCategory = const [('Food', 45000)];
  s.ledgerDays = groupByDay(s.ledger);
}

void main() {
  setUp(_seed);

  // A row waiting on a label goes straight to the one-tap sheet; everything
  // else opens the full editor. Both have to work from every screen - the
  // Insights list shipped with no onTap at all and killed the loop there.
  for (final screen in {
    'Insights': () => InsightsScreen(onOpenActivity: () {}),
    'Home': () => HomeScreen(onOpenInsights: () {}, onOpenActivity: () {}),
    'Activity': () => const TransactionsScreen(),
  }.entries) {
    testWidgets('${screen.key} rows waiting on a label offer one', (
      tester,
    ) async {
      await _tapRow(tester, screen.value());
      expect(find.text('what was this?', skipOffstage: false), findsNothing);
      expect(find.textContaining('what was this?'), findsOneWidget);
      expect(find.text('Groceries'), findsWidgets);
    });

    testWidgets('${screen.key} labelled rows open the full editor', (
      tester,
    ) async {
      _useLabelledRow();
      await _tapRow(tester, screen.value());
      expect(find.text('Edit transaction'), findsOneWidget);
    });
  }
}
