final _nonDigitRegex = RegExp(r'[^0-9.]');

/// Formats integer minor units for display. Indian digit grouping is used for
/// the rupee (1,23,456.00) and three-digit grouping for everything else.
String money(int minor, String symbol) {
  final abs = minor.abs();
  final units = (abs ~/ 100).toString();
  final paise = (abs % 100).toString().padLeft(2, '0');
  final grouped = symbol == '₹' ? _groupIndian(units) : _groupWestern(units);
  return '${minor < 0 ? '-' : ''}$symbol$grouped.$paise';
}

String _groupIndian(String units) {
  if (units.length <= 3) return units;
  final head = units.substring(0, units.length - 3);
  final tail = units.substring(units.length - 3);
  final pairs = <String>[];
  for (var end = head.length; end > 0; end -= 2)
    pairs.insert(0, head.substring(end - 2 < 0 ? 0 : end - 2, end));
  return '${pairs.join(',')},$tail';
}

String _groupWestern(String units) {
  final groups = <String>[];
  for (var end = units.length; end > 0; end -= 3)
    groups.insert(0, units.substring(end - 3 < 0 ? 0 : end - 3, end));
  return groups.join(',');
}

/// Parses a user- or statement-supplied amount into minor units.
///
/// Understands a leading or trailing minus, accountant parentheses, Indian
/// lakh/crore grouping and trailing Dr/Cr markers. Returns null when there is
/// no number to read, so callers can skip a row instead of storing a zero.
int? parseMoney(String value) {
  var text = value.trim();
  if (text.isEmpty) return null;
  final lower = text.toLowerCase();
  var negative =
      text.startsWith('-') ||
      text.endsWith('-') ||
      (text.startsWith('(') && text.endsWith(')')) ||
      lower.endsWith('dr');
  if (lower.endsWith('cr')) negative = false;
  final digits = text.replaceAll(_nonDigitRegex, '');
  if (digits.isEmpty) return null;
  // A statement may carry a stray second dot ("1.234.50"); keep the last one
  // as the decimal separator and treat earlier ones as grouping.
  final lastDot = digits.lastIndexOf('.');
  final normalized = lastDot < 0
      ? digits
      : '${digits.substring(0, lastDot).replaceAll('.', '')}'
            '.${digits.substring(lastDot + 1)}';
  final parsed = double.tryParse(normalized);
  if (parsed == null) return null;
  final minor = (parsed * 100).round();
  return negative ? -minor : minor;
}
