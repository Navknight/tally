import 'package:flutter_test/flutter_test.dart';
import 'package:tally/models/account.dart';
import 'package:tally/models/transaction.dart';
import 'package:tally/services/export.dart';

void main() {
  const account = Account(id: 1, name: 'Main', last4: '', openingBalanceMinor: 0);
  const other = Account(
    id: 2,
    name: 'Savings',
    last4: '',
    openingBalanceMinor: 0,
    inBudget: false,
  );

  test('renders a plain row', () {
    final csv = transactionsCsv([
      TallyTransaction(
        id: 1,
        amountMinor: 12345,
        kind: TransactionKind.expense,
        occurredAt: DateTime(2026, 9, 13),
        merchant: 'Cafe',
        category: 'Food',
        accountId: 1,
      ),
    ], [account]);
    final lines = csv.trim().split('\n');
    expect(lines, hasLength(2));
    expect(
      lines[1],
      '2026-09-13T00:00:00.000,Main,Cafe,Food,expense,-123.45,yes,,,',
    );
  });

  test('marks a row on an out-of-budget account as not counted', () {
    final csv = transactionsCsv([
      TallyTransaction(
        id: 1,
        amountMinor: 100,
        kind: TransactionKind.expense,
        occurredAt: DateTime(2026, 9, 13),
        merchant: 'Cafe',
        category: 'Food',
        accountId: 2,
      ),
    ], [account, other]);
    expect(csv.trim().split('\n')[1].contains(',no,'), isTrue);
  });

  test('quotes fields containing commas and quotes', () {
    final csv = transactionsCsv([
      TallyTransaction(
        id: 1,
        amountMinor: 100,
        kind: TransactionKind.income,
        occurredAt: DateTime(2026, 9, 13),
        merchant: 'Acme, "The" Store',
        category: 'Income',
        accountId: 1,
        note: 'line one\nline two',
      ),
    ], [account]);
    expect(csv, contains('"Acme, ""The"" Store"'));
    expect(csv, contains('"line one\nline two"'));
  });

  test('shows the destination account for a transfer', () {
    final csv = transactionsCsv([
      TallyTransaction(
        id: 1,
        amountMinor: 5000,
        kind: TransactionKind.transfer,
        occurredAt: DateTime(2026, 9, 13),
        merchant: 'Transfer',
        category: 'Transfers',
        accountId: 1,
        transferAccountId: 2,
        excludeFromBudget: true,
      ),
    ], [account, other]);
    final line = csv.trim().split('\n')[1];
    expect(line, contains(',transfer,-50.00,no,Savings,'));
  });
}
