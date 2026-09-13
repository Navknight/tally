import '../../core/money.dart';
import '../../models/transaction.dart';
import 'bank_parser.dart';

/// Parses one Indian bank/UPI SMS, picking a bank-specific parser by sender
/// id (DLT-style, e.g. `AD-HDFCBK-S`) and falling back to a generic parser
/// tuned on common Indian bank SMS shapes when no bank is recognised.
SmsOutcome parseBankSms({required String sender, required String body}) {
  final parser = _registry.firstWhere(
    (p) => p.canHandle(sender),
    orElse: () => GenericIndianBankParser(),
  );
  return parser.parse(body, sender);
}

// Subclass BankParser only when a bank's wording needs its own extraction.
final _registry = <BankParser>[
  GenericIndianBankParser('HDFC', 'HDFC'),
  GenericIndianBankParser('ICICI', 'ICICI'),
  GenericIndianBankParser('SBI', 'SBI'),
  GenericIndianBankParser('Axis', 'AXIS'),
  GenericIndianBankParser('Kotak', 'KOTAK'),
];

final _amountRegex = RegExp(
  r'(?:Rs\.?|INR|₹)\s*([\d,]+(?:\.\d{1,2})?)',
  caseSensitive: false,
);

final _last4Regex = RegExp(
  r'(?:a/c|ac|acct|account|card|xx|x)\s*(?:no\.?)?\s*[xX*]{0,4}(\d{3,6})',
  caseSensitive: false,
);

final _balanceRegex = RegExp(
  r'(?:avl(?:\.|able)?\s*(?:bal|balance)|bal(?:ance)?)\s*(?:is)?[:\s]*(?:Rs\.?|INR|₹)?\s*([\d,]+(?:\.\d{1,2})?)',
  caseSensitive: false,
);

final _referenceRegex = RegExp(
  r'(?:ref(?:erence)?\s*(?:no\.?|id)?|upi(?:\s*ref)?|utr|txn\s*id)[:\s#]*([A-Za-z0-9]{6,22})',
  caseSensitive: false,
);

final _vpaRegex = RegExp(r'([A-Za-z0-9._-]{2,})@[a-z]{3,}', caseSensitive: false);

final _upiSlashRegex = RegExp(
  r"UPI(?:/[A-Za-z0-9. &'-]+)+",
  caseSensitive: false,
);

final _atToRegex = RegExp(
  r"(?:at|to|towards|in favour of)\s+([A-Za-z0-9 .&'-]{2,40})",
  caseSensitive: false,
);

const _debitWords = [
  'debited',
  'spent',
  'sent',
  'withdrawn',
  'paid',
  'purchase',
  'deducted',
  'dr',
];

const _creditWords = ['credited', 'received', 'deposited', 'refund', 'cashback', 'cr'];

int? _earliestIndex(String lower, List<String> words) {
  int? best;
  for (final word in words) {
    final match = RegExp(r'\b' + word + r'\b').firstMatch(lower);
    if (match != null && (best == null || match.start < best)) best = match.start;
  }
  return best;
}

/// Baseline parser tuned on common Indian bank/UPI SMS wording. Bank-specific
/// subclasses override only the pieces that differ.
class GenericIndianBankParser extends BankParser {
  GenericIndianBankParser([this._bank = 'Bank', this._senderKey]);
  final String _bank;
  final String? _senderKey;

  @override
  String get bank => _bank;

  @override
  bool canHandle(String sender) =>
      _senderKey == null || sender.toUpperCase().contains(_senderKey);

  @override
  int? extractAmount(String body) {
    final match = _amountRegex.firstMatch(body);
    if (match == null) return null;
    return parseMoney(match.group(1)!);
  }

  @override
  TransactionKind? extractKind(String body) {
    final lower = body.toLowerCase();
    final selfTransfer = lower.contains('to your own') || lower.contains('self');
    final transferWording = lower.contains('transferred to') ||
        lower.contains('trf to') ||
        lower.contains('sent to');
    if (transferWording) return selfTransfer ? TransactionKind.transfer : TransactionKind.expense;

    final debitIdx = _earliestIndex(lower, _debitWords);
    final creditIdx = _earliestIndex(lower, _creditWords);
    if (debitIdx == null && creditIdx == null) return null;
    if (debitIdx != null && (creditIdx == null || debitIdx <= creditIdx))
      return TransactionKind.expense;
    return TransactionKind.income;
  }

  @override
  String? extractLast4(String body) {
    final match = _last4Regex.firstMatch(body);
    if (match == null) return null;
    final digits = match.group(1)!;
    return digits.length <= 4 ? digits : digits.substring(digits.length - 4);
  }

  @override
  String? extractReference(String body) {
    final match = _referenceRegex.firstMatch(body);
    return match?.group(1);
  }

  @override
  int? extractBalance(String body) {
    final match = _balanceRegex.firstMatch(body);
    if (match == null) return null;
    return parseMoney(match.group(1)!);
  }

  @override
  String extractMerchant(String body, String sender) {
    // 1. UPI VPA, skipping a handle that is really a phone number.
    for (final match in _vpaRegex.allMatches(body)) {
      final handle = match.group(1)!;
      if (RegExp(r'^\d+$').hasMatch(handle)) continue;
      return _cleanMerchant(handle, bank);
    }

    // 2. Slash-delimited UPI info block, e.g. UPI/P2M/123456789/MERCHANT NAME.
    final slashMatch = _upiSlashRegex.firstMatch(body);
    if (slashMatch != null) {
      final segments = slashMatch.group(0)!.split('/');
      for (final segment in segments.reversed) {
        final trimmed = segment.trim();
        if (trimmed.isEmpty) continue;
        if (RegExp(r'^\d+$').hasMatch(trimmed)) continue;
        if (trimmed.toUpperCase() == 'UPI') continue;
        return _cleanMerchant(trimmed, bank);
      }
    }

    // 3. "at/to/towards/in favour of <name>", skipping a capture that is
    // really a truncated phone-number VPA (the '@' just fell outside the
    // charclass above).
    for (final match in _atToRegex.allMatches(body)) {
      final candidate = match.group(1)!.trim();
      if (RegExp(r'^\d+$').hasMatch(candidate)) continue;
      return _cleanMerchant(candidate, bank);
    }

    // 4. Fallback.
    return '$bank transaction';
  }
}

String _cleanMerchant(String raw, String bank) {
  var text = raw.trim();
  text = text.replaceFirst(RegExp(r'^vpa\s+', caseSensitive: false), '');
  text = text.replaceFirst(RegExp(r'\s+on\s+\d.*$', caseSensitive: false), '');
  text = text.replaceFirst(RegExp(r'\s+ref\S*.*$', caseSensitive: false), '');
  text = text.replaceFirst(RegExp(r'\s+via\s.*$', caseSensitive: false), '');
  text = text.replaceFirst(RegExp(r'[.;\-\s]+$'), '');
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.isEmpty) return '$bank transaction';
  final hasLetters = text.contains(RegExp(r'[A-Za-z]'));
  if (hasLetters && text == text.toUpperCase())
    text = text
        .split(' ')
        .map((word) => word.isEmpty
            ? word
            : word[0].toUpperCase() + word.substring(1).toLowerCase())
        .join(' ');
  return text.isEmpty ? '$bank transaction' : text;
}
