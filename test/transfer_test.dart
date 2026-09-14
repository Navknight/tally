import 'package:flutter_test/flutter_test.dart';
import 'package:tally/models/transaction.dart';
import 'package:tally/models/transfer.dart';

TallyTransaction _leg({
  required int id,
  required TransactionKind kind,
  required int accountId,
  required int amount,
  DateTime? at,
  String? reference,
}) => TallyTransaction(
  id: id,
  amountMinor: amount,
  kind: kind,
  occurredAt: at ?? DateTime(2026, 9, 13, 10),
  merchant: 'Test',
  category: 'Other',
  accountId: accountId,
  reference: reference,
);

void main() {
  test('matches a same-amount debit and credit on different accounts', () {
    final debit = _leg(id: 1, kind: TransactionKind.expense, accountId: 1, amount: 5000);
    final credit = _leg(id: 2, kind: TransactionKind.income, accountId: 2, amount: 5000);
    expect(isSelfTransferPair(debit, credit), isTrue);

    final matches = findSelfTransfers([debit, credit]);
    expect(matches, hasLength(1));
    expect(matches.single.debit.id, 1);
    expect(matches.single.credit.id, 2);
  });

  test('rejects a mismatched amount', () {
    final debit = _leg(id: 1, kind: TransactionKind.expense, accountId: 1, amount: 5000);
    final credit = _leg(id: 2, kind: TransactionKind.income, accountId: 2, amount: 4999);
    expect(isSelfTransferPair(debit, credit), isFalse);
    expect(findSelfTransfers([debit, credit]), isEmpty);
  });

  test('rejects legs more than 30 minutes apart', () {
    final debit = _leg(
      id: 1,
      kind: TransactionKind.expense,
      accountId: 1,
      amount: 5000,
      at: DateTime(2026, 9, 13, 10),
    );
    final credit = _leg(
      id: 2,
      kind: TransactionKind.income,
      accountId: 2,
      amount: 5000,
      at: DateTime(2026, 9, 13, 10, 31),
    );
    expect(isSelfTransferPair(debit, credit), isFalse);
  });

  test('rejects legs with different references', () {
    final debit = _leg(
      id: 1,
      kind: TransactionKind.expense,
      accountId: 1,
      amount: 5000,
      reference: 'REF1',
    );
    final credit = _leg(
      id: 2,
      kind: TransactionKind.income,
      accountId: 2,
      amount: 5000,
      reference: 'REF2',
    );
    expect(isSelfTransferPair(debit, credit), isFalse);
  });

  test('matching references still pair up', () {
    final debit = _leg(
      id: 1,
      kind: TransactionKind.expense,
      accountId: 1,
      amount: 5000,
      reference: 'REF1',
    );
    final credit = _leg(
      id: 2,
      kind: TransactionKind.income,
      accountId: 2,
      amount: 5000,
      reference: 'REF1',
    );
    expect(isSelfTransferPair(debit, credit), isTrue);
  });

  test('pairs legs exactly 30 minutes apart (window edge is inclusive)', () {
    final debit = _leg(
      id: 1,
      kind: TransactionKind.expense,
      accountId: 1,
      amount: 5000,
      at: DateTime(2026, 9, 13, 10),
    );
    final credit = _leg(
      id: 2,
      kind: TransactionKind.income,
      accountId: 2,
      amount: 5000,
      at: DateTime(2026, 9, 13, 10, 30),
    );
    expect(isSelfTransferPair(debit, credit), isTrue);
    final matches = findSelfTransfers([debit, credit]);
    expect(matches, hasLength(1));
  });

  test('sliding-window scan matches the same pairing as a naive full scan '
      'across many unrelated rows', () {
    final rows = <TallyTransaction>[];
    // Unrelated noise well outside any 30-minute window.
    for (var i = 0; i < 20; i++)
      rows.add(
        _leg(
          id: 100 + i,
          kind: i.isEven ? TransactionKind.expense : TransactionKind.income,
          accountId: i.isEven ? 1 : 2,
          amount: 1000 + i,
          at: DateTime(2026, 1, 1).add(Duration(days: i)),
        ),
      );
    final debit = _leg(
      id: 1,
      kind: TransactionKind.expense,
      accountId: 1,
      amount: 5000,
      at: DateTime(2026, 9, 13, 10),
    );
    final credit = _leg(
      id: 2,
      kind: TransactionKind.income,
      accountId: 2,
      amount: 5000,
      at: DateTime(2026, 9, 13, 10, 15),
    );
    rows.addAll([debit, credit]);
    final matches = findSelfTransfers(rows);
    expect(matches, hasLength(1));
    expect(matches.single.debit.id, 1);
    expect(matches.single.credit.id, 2);
  });

  test('rejects legs on the same account', () {
    final debit = _leg(id: 1, kind: TransactionKind.expense, accountId: 1, amount: 5000);
    final credit = _leg(id: 2, kind: TransactionKind.income, accountId: 1, amount: 5000);
    expect(isSelfTransferPair(debit, credit), isFalse);
    expect(findSelfTransfers([debit, credit]), isEmpty);
  });
}
