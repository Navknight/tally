import 'package:flutter_test/flutter_test.dart';
import 'package:tally/models/transaction.dart';
import 'package:tally/services/statement_import.dart';

void main() {
  test('parses a plain CSV statement', () {
    final rows = parseCsvStatement(
      '2026-01-05,Groceries,-1240.00\n2026-01-06,Salary,50000',
    );
    expect(rows, hasLength(2));
    expect(rows[0].merchant, 'Groceries');
    expect(rows[0].amountMinor, 124000);
    expect(rows[0].isCredit, isFalse);
    expect(rows[1].isCredit, isTrue);
  });

  test('statementRowToTransaction maps a debit row to an expense', () {
    final rows = parseCsvStatement('2026-01-05,Groceries,-1240.00');
    final tx = statementRowToTransaction(
      rows.single,
      accountId: 7,
      source: 'csv',
      category: 'Groceries',
    );
    expect(tx.kind, TransactionKind.expense);
    expect(tx.amountMinor, 124000);
    expect(tx.accountId, 7);
    expect(tx.categorySource, CategorySource.imported);
    expect(tx.needsReview, isFalse);
  });

  test('statementRowToTransaction maps a credit row to income', () {
    final rows = parseCsvStatement('2026-01-06,Salary,50000');
    final tx = statementRowToTransaction(
      rows.single,
      accountId: 7,
      source: 'csv',
      category: 'Income',
    );
    expect(tx.kind, TransactionKind.income);
  });

  test('statement rows get a stable fingerprint for dedup', () {
    String fp(String merchant) => statementRowToTransaction(
      StatementRow(
        date: DateTime(2026, 9, 1),
        merchant: merchant,
        amountMinor: 50000,
        isCredit: false,
        balanceMinor: 100000,
      ),
      accountId: 1,
      source: 'csv',
      category: 'Uncategorized',
    ).fingerprint!;
    expect(fp('Acme'), fp('Acme'));
    expect(fp('Acme'), isNot(fp('Other')));
  });
}
