import 'package:flutter_test/flutter_test.dart';
import 'package:tally/core/budget_period.dart';
import 'package:tally/models/account.dart';
import 'package:tally/models/transaction.dart';

TallyTransaction _tx(int amount, TransactionKind kind, {int? accountId}) =>
    TallyTransaction(
      id: null,
      amountMinor: amount,
      kind: kind,
      occurredAt: DateTime(2026, 1, 1),
      merchant: 'Test',
      category: 'Other',
      accountId: accountId,
    );

void main() {
  test('accountBalance adds signed transactions to the opening balance', () {
    const account = Account(
      id: 1,
      name: 'Main',
      last4: '1234',
      openingBalanceMinor: 10000,
    );
    final transactions = [
      _tx(2000, TransactionKind.income, accountId: 1),
      _tx(500, TransactionKind.expense, accountId: 1),
      _tx(9999, TransactionKind.expense, accountId: 2), // different account
    ];
    expect(accountBalance(account, transactions), 11500);
  });

  test('balance starts from the newest reported balance', () {
    final account = Account(
      id: 1,
      name: 'Main',
      last4: '',
      openingBalanceMinor: 10000,
      reportedBalanceMinor: 50000,
      reportedAt: DateTime(2026, 1, 1),
    );
    TallyTransaction at(DateTime when, int amount) => TallyTransaction(
      id: null,
      amountMinor: amount,
      kind: TransactionKind.expense,
      occurredAt: when,
      merchant: 'Test',
      category: 'Other',
      accountId: 1,
    );
    final transactions = [
      at(DateTime(2025, 6, 1), 90000), // before the anchor, already counted
      at(DateTime(2026, 1, 1), 1000), // the SMS that reported the balance
      at(DateTime(2026, 2, 1), 2000),
    ];
    expect(accountBalance(account, transactions), 48000);
  });

  test('totalBalance ignores transactions that matched no account', () {
    const a = Account(id: 1, name: 'A', last4: '', openingBalanceMinor: 1000);
    const b = Account(id: 2, name: 'B', last4: '', openingBalanceMinor: 500);
    final transactions = [
      _tx(200, TransactionKind.expense, accountId: 1),
      _tx(300, TransactionKind.income, accountId: 2),
      _tx(100, TransactionKind.expense), // e.g. a credit card
    ];
    expect(totalBalance([a, b], transactions), 1600);
  });

  test('a transfer moves money out of the source and into the destination', () {
    const source = Account(id: 1, name: 'Source', last4: '', openingBalanceMinor: 10000);
    const dest = Account(id: 2, name: 'Dest', last4: '', openingBalanceMinor: 2000);
    final transfer = TallyTransaction(
      id: null,
      amountMinor: 3000,
      kind: TransactionKind.transfer,
      occurredAt: DateTime(2026, 1, 1),
      merchant: 'Transfer',
      category: 'Transfers',
      accountId: 1,
      transferAccountId: 2,
      excludeFromBudget: true,
    );
    expect(accountBalance(source, [transfer]), 7000);
    expect(accountBalance(dest, [transfer]), 5000);
    expect(totalBalance([source, dest], [transfer]), 12000);
  });

  test(
    'budgetSpent excludes flagged rows, transfers and out-of-budget accounts',
    () {
      const inBudgetAccount = Account(
        id: 1,
        name: 'A',
        last4: '',
        openingBalanceMinor: 0,
      );
      const outOfBudgetAccount = Account(
        id: 2,
        name: 'B',
        last4: '',
        openingBalanceMinor: 0,
        inBudget: false,
      );
      final period = budgetPeriod(DateTime(2026, 9, 13), 1);
      TallyTransaction expense(int amount, {int? accountId, bool excluded = false}) =>
          TallyTransaction(
            id: null,
            amountMinor: amount,
            kind: TransactionKind.expense,
            occurredAt: DateTime(2026, 9, 5),
            merchant: 'Test',
            category: 'Other',
            accountId: accountId,
            excludeFromBudget: excluded,
          );
      final transfer = TallyTransaction(
        id: null,
        amountMinor: 999,
        kind: TransactionKind.transfer,
        occurredAt: DateTime(2026, 9, 5),
        merchant: 'Transfer',
        category: 'Transfers',
        accountId: 1,
        transferAccountId: 2,
        excludeFromBudget: true,
      );
      final rows = [
        expense(1000, accountId: 1), // counted
        expense(500, accountId: 1, excluded: true), // excluded flag
        expense(700, accountId: 2), // out-of-budget account
        expense(400), // no account
        transfer, // transfer, and also excluded
      ];
      expect(
        budgetSpent(rows, [inBudgetAccount, outOfBudgetAccount], period),
        1000,
      );
    },
  );
}
