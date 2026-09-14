import '../../models/transaction.dart';
import 'message_filter.dart';

/// Outcome of feeding one bank SMS through a [BankParser].
sealed class SmsOutcome {}

/// A real ledger entry.
class SmsTransaction extends SmsOutcome {
  SmsTransaction({
    required this.amountMinor,
    required this.kind,
    required this.merchant,
    this.last4,
    this.reference,
    this.balanceAfterMinor,
    required this.bank,
    this.isCard = false,
  });
  final int amountMinor;
  final TransactionKind kind;
  final String merchant;
  final String? last4; // account/card last 4 digits, digits only
  final String? reference; // UPI ref / UTR / txn id
  final int? balanceAfterMinor; // running balance stated in the same message
  final String bank;

  /// True when [last4] names a card ("Card XX3001", "Credit Card") rather
  /// than a bank account, so a detection can be typed correctly.
  final bool isCard;
}

/// Message stated a balance but no transaction (e.g. a balance enquiry alert).
class SmsBalance extends SmsOutcome {
  SmsBalance({
    required this.balanceMinor,
    this.last4,
    required this.bank,
    this.isCard = false,
  });
  final int balanceMinor;
  final String? last4;
  final String bank;
  final bool isCard;
}

/// Not a ledger event. [reason] says why.
class SmsIgnored extends SmsOutcome {
  SmsIgnored(this.reason);
  final MessageClass reason;
}

/// Template-method base for a bank's SMS parser.
///
/// [parse] decides the outcome shape; subclasses only need to override the
/// extraction pieces that differ between banks.
abstract class BankParser {
  String get bank;

  bool canHandle(String sender);

  int? extractAmount(String body);

  TransactionKind? extractKind(String body);

  String? extractLast4(String body);

  String? extractReference(String body);

  int? extractBalance(String body);

  String extractMerchant(String body, String sender);

  SmsOutcome parse(String body, String sender) {
    final messageClass = classifyMessage(body);
    if (messageClass != MessageClass.transactional)
      return SmsIgnored(messageClass);

    final amount = extractAmount(body);
    // A zero-rupee figure is never a real movement (a wallet spend quoting
    // its balance, a TDS notice); nothing downstream should book it.
    if (amount == 0) return SmsIgnored(MessageClass.personal);
    final kind = extractKind(body);
    final balance = extractBalance(body);
    final last4 = extractLast4(body);
    final isCard = _cardRegex.hasMatch(body);

    if (amount == null || kind == null) {
      if (balance != null)
        return SmsBalance(
          balanceMinor: balance,
          last4: last4,
          bank: bank,
          isCard: isCard,
        );
      return SmsIgnored(MessageClass.personal);
    }

    return SmsTransaction(
      amountMinor: amount,
      kind: kind,
      merchant: extractMerchant(body, sender),
      last4: last4,
      reference: extractReference(body),
      balanceAfterMinor: balance,
      bank: bank,
      isCard: isCard,
    );
  }
}

/// Wording that names a card rather than a bank account: "Card XX3001",
/// "Credit Card", "spent using ... Card".
final _cardRegex = RegExp(r'\bcard\b|spent using', caseSensitive: false);
