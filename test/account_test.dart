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

  test('totalBalance sums tracked accounts plus unmatched transactions', () {
    const a = Account(id: 1, name: 'A', last4: '', openingBalanceMinor: 1000);
    const b = Account(id: 2, name: 'B', last4: '', openingBalanceMinor: 500);
    final transactions = [
      _tx(200, TransactionKind.expense, accountId: 1),
      _tx(300, TransactionKind.income, accountId: 2),
      _tx(100, TransactionKind.expense), // no account match
    ];
    // (1000-200) + (500+300) - 100 = 1500
    expect(totalBalance([a, b], transactions), 1500);
  });
}
