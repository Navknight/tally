import 'dart:typed_data';

import '../core/money.dart';
import '../core/pdf_text.dart';

/// One transaction row recovered from a bank statement (CSV or PDF).
class StatementRow {
  const StatementRow({
    required this.date,
    required this.merchant,
    required this.amountMinor,
    required this.isCredit,
    this.reference,
    this.balanceMinor,
  });

  final DateTime date;
  final String merchant;

  /// Always a positive magnitude, in minor units (paise).
  final int amountMinor;
  final bool isCredit;
  final String? reference;
  final int? balanceMinor;
}

const _totalMarkers = [
  'total',
  'closing balance',
  'opening balance',
  'brought forward',
  'b/f',
];

bool _isTotalRow(String merchant) {
  final m = merchant.toLowerCase();
  return _totalMarkers.any(m.contains);
}

const _months = [
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];

int? _monthNumber(String name) {
  if (name.length < 3) return null;
  final idx = _months.indexOf(name.toLowerCase().substring(0, 3));
  return idx < 0 ? null : idx + 1;
}

/// Parses a date in one of the statement formats this importer understands:
/// `yyyy-MM-dd`, `dd/MM/yyyy`, `dd-MM-yyyy`, `dd/MM/yy`, `dd-MMM-yyyy` and
/// `dd MMM yyyy`. Two-digit years map to `2000 + yy`. Returns null when the
/// text does not match any of these shapes.
DateTime? parseStatementDate(String value) {
  final t = value.trim();

  var m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(t);
  if (m != null)
    return DateTime(int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!));

  m = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$').firstMatch(t);
  if (m != null)
    return DateTime(int.parse(m[3]!), int.parse(m[2]!), int.parse(m[1]!));

  m = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{2})$').firstMatch(t);
  if (m != null)
    return DateTime(
      2000 + int.parse(m[3]!),
      int.parse(m[2]!),
      int.parse(m[1]!),
    );

  m = RegExp(r'^(\d{1,2})[-\s]([A-Za-z]{3,})[-\s](\d{4})$').firstMatch(t);
  if (m != null) {
    final month = _monthNumber(m[2]!);
    if (month != null)
      return DateTime(int.parse(m[3]!), month, int.parse(m[1]!));
  }

  return null;
}

const _delimiterCandidates = [',', ';', '\t', '|'];

String _detectDelimiter(String line) {
  var best = ',';
  var bestCount = -1;
  for (final d in _delimiterCandidates) {
    final count = line.split(d).length - 1;
    if (count > bestCount) {
      bestCount = count;
      best = d;
    }
  }
  return best;
}

List<String> _splitCsvLine(String line, String delimiter) {
  final fields = <String>[];
  final sb = StringBuffer();
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          sb.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        sb.write(c);
      }
    } else {
      if (c == '"')
        inQuotes = true;
      else if (c == delimiter) {
        fields.add(sb.toString());
        sb.clear();
      } else
        sb.write(c);
    }
  }
  fields.add(sb.toString());
  return fields;
}

const _headerKeywords = [
  'date',
  'particulars',
  'narration',
  'description',
  'merchant',
  'payee',
  'amount',
  'debit',
  'credit',
  'withdrawal',
  'deposit',
  'balance',
  'ref',
];

bool _looksLikeHeader(List<String> fields) {
  return fields.any((f) {
    final lower = f.trim().toLowerCase();
    return _headerKeywords.any(lower.contains);
  });
}

Map<String, int> _mapColumns(List<String> headers) {
  final map = <String, int>{};
  for (var i = 0; i < headers.length; i++) {
    final h = headers[i].trim().toLowerCase();
    if (h.contains('date') && !map.containsKey('date'))
      map['date'] = i;
    else if ((h.contains('particular') ||
            h.contains('narration') ||
            h.contains('description') ||
            h.contains('merchant') ||
            h.contains('payee')) &&
        !map.containsKey('merchant'))
      map['merchant'] = i;
    else if ((h.contains('withdrawal') || h.contains('debit')) &&
        !map.containsKey('debit'))
      map['debit'] = i;
    else if ((h.contains('deposit') || h.contains('credit')) &&
        !map.containsKey('credit'))
      map['credit'] = i;
    else if (h.contains('balance') && !map.containsKey('balance'))
      map['balance'] = i;
    else if (h.contains('ref') && !map.containsKey('reference'))
      map['reference'] = i;
    else if (h.contains('amount') && !map.containsKey('amount'))
      map['amount'] = i;
  }
  return map;
}

String _field(List<String> fields, Map<String, int> col, String key) {
  final idx = col[key];
  if (idx == null || idx >= fields.length) return '';
  return fields[idx];
}

StatementRow? _parseHeaderRow(List<String> fields, Map<String, int> col) {
  final merchant = _field(fields, col, 'merchant').trim();
  if (_isTotalRow(merchant)) return null;

  final date = parseStatementDate(_field(fields, col, 'date'));
  if (date == null) return null;

  int? amountMinor;
  var isCredit = false;
  if (col.containsKey('debit') || col.containsKey('credit')) {
    final debit = parseMoney(_field(fields, col, 'debit'));
    final credit = parseMoney(_field(fields, col, 'credit'));
    if (credit != null && credit != 0) {
      amountMinor = credit.abs();
      isCredit = true;
    } else if (debit != null && debit != 0) {
      amountMinor = debit.abs();
      isCredit = false;
    }
  } else if (col.containsKey('amount')) {
    final amt = parseMoney(_field(fields, col, 'amount'));
    if (amt != null) {
      amountMinor = amt.abs();
      isCredit = amt >= 0;
    }
  }
  if (amountMinor == null) return null;

  final balance = col.containsKey('balance')
      ? parseMoney(_field(fields, col, 'balance'))
      : null;
  final ref = col.containsKey('reference')
      ? _field(fields, col, 'reference').trim()
      : null;

  return StatementRow(
    date: date,
    merchant: merchant,
    amountMinor: amountMinor,
    isCredit: isCredit,
    reference: (ref != null && ref.isNotEmpty) ? ref : null,
    balanceMinor: balance,
  );
}

StatementRow? _parsePositionalRow(List<String> fields) {
  if (fields.length < 3) return null;
  final merchant = fields[1].trim();
  if (_isTotalRow(merchant)) return null;

  final date = parseStatementDate(fields[0]);
  if (date == null) return null;

  final amt = parseMoney(fields[2]);
  if (amt == null) return null;

  final balance = fields.length > 3 ? parseMoney(fields[3]) : null;

  return StatementRow(
    date: date,
    merchant: merchant,
    amountMinor: amt.abs(),
    isCredit: amt >= 0,
    balanceMinor: balance,
  );
}

/// Parses a CSV/TSV statement. Detects and skips a header row, auto-detects
/// the delimiter, and handles both a single signed-amount column and
/// separate debit/credit columns.
List<StatementRow> parseCsvStatement(String text) {
  final lines = text
      .split(RegExp(r'\r\n|\r|\n'))
      .where((l) => l.trim().isNotEmpty)
      .toList();
  if (lines.isEmpty) return [];

  final delimiter = _detectDelimiter(lines.first);
  final firstFields = _splitCsvLine(lines.first, delimiter);

  var startIndex = 0;
  Map<String, int>? columns;
  if (_looksLikeHeader(firstFields)) {
    columns = _mapColumns(firstFields);
    startIndex = 1;
  }

  final rows = <StatementRow>[];
  for (var i = startIndex; i < lines.length; i++) {
    final fields = _splitCsvLine(lines[i], delimiter);
    final row = columns != null
        ? _parseHeaderRow(fields, columns)
        : _parsePositionalRow(fields);
    if (row != null) rows.add(row);
  }
  return rows;
}

final RegExp _leadingDate = RegExp(
  r'^(\d{4}-\d{2}-\d{2}|\d{1,2}[/-]\d{1,2}[/-]\d{4}|\d{1,2}[/-]\d{1,2}[/-]\d{2}|\d{1,2}[-\s][A-Za-z]{3,}[-\s]\d{4})\s+(.*)$',
);

final RegExp _moneyToken = RegExp(
  r'^[+-]?\(?[\d,]+(\.\d+)?\)?(dr|cr)?$',
  caseSensitive: false,
);

StatementRow? _parsePdfLine(String line) {
  final m = _leadingDate.firstMatch(line);
  if (m == null) return null;

  final date = parseStatementDate(m[1]!);
  if (date == null) return null;

  final rest = m[2]!.trim();
  final tokens = rest.split(RegExp(r'\s+'));
  if (tokens.isEmpty) return null;

  var end = tokens.length;
  int? amount;
  int? balance;
  if (_moneyToken.hasMatch(tokens[end - 1])) {
    final last = parseMoney(tokens[end - 1]);
    if (end > 1 && _moneyToken.hasMatch(tokens[end - 2])) {
      amount = parseMoney(tokens[end - 2]);
      balance = last;
      end -= 2;
    } else {
      amount = last;
      end -= 1;
    }
  }
  if (amount == null) return null;

  final merchant = tokens.sublist(0, end).join(' ').trim();
  if (_isTotalRow(merchant)) return null;

  return StatementRow(
    date: date,
    merchant: merchant,
    amountMinor: amount.abs(),
    isCredit: amount >= 0,
    balanceMinor: balance,
  );
}

/// Extracts text from a PDF statement and parses its transaction lines.
/// Returns an empty list when no text could be recovered.
List<StatementRow> parsePdfStatement(Uint8List bytes) {
  final text = extractPdfText(bytes);
  if (text == null) return [];

  final rows = <StatementRow>[];
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final row = _parsePdfLine(line);
    if (row != null) rows.add(row);
  }
  return rows;
}
