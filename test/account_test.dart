import 'package:flutter_test/flutter_test.dart';
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
}
