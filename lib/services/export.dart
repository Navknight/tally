import '../models/account.dart';
import '../models/transaction.dart';

/// Builds a CSV of [rows] against [accounts], one line per transaction. Pure
/// so the format can be tested without a database or a file picker.
String transactionsCsv(List<TallyTransaction> rows, List<Account> accounts) {
  final names = {for (final a in accounts) a.id: a.name};
  final inBudget = {for (final a in accounts) a.id: a.inBudget};
  final buffer = StringBuffer();
  buffer.writeln(
    _csvLine([
      'Date',
      'Account',
      'Merchant',
      'Category',
      'Kind',
      'Amount',
      'Counted in budget',
      'Transfer destination',
      'Note',
      'Reference',
    ]),
  );
  for (final t in rows) {
    final counted =
        t.kind != TransactionKind.transfer &&
        !t.excludeFromBudget &&
        (inBudget[t.accountId] ?? false);
    buffer.writeln(
      _csvLine([
        t.occurredAt.toIso8601String(),
        names[t.accountId] ?? '',
        t.merchant,
        t.category,
        t.kind.name,
        _majorUnits(t.kind == TransactionKind.income ? t.amountMinor : -t.amountMinor),
        counted ? 'yes' : 'no',
        names[t.transferAccountId] ?? '',
        t.note,
        t.reference ?? '',
      ]),
    );
  }
  return buffer.toString();
}

String _majorUnits(int minor) {
  final abs = minor.abs();
  final sign = minor < 0 ? '-' : '';
  return '$sign${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}';
}

String _csvLine(List<String> fields) => fields.map(_csvField).join(',');

String _csvField(String value) {
  final needsQuoting = value.contains(RegExp('[,"\n\r]'));
  if (!needsQuoting) return value;
  return '"${value.replaceAll('"', '""')}"';
}
