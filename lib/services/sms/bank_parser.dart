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
  });
  final int amountMinor;
  final TransactionKind kind;
  final String merchant;
  final String? last4; // account/card last 4 digits, digits only
  final String? reference; // UPI ref / UTR / txn id
  final int? balanceAfterMinor; // running balance stated in the same message
  final String bank;
}

/// Message stated a balance but no transaction (e.g. a balance enquiry alert).
class SmsBalance extends SmsOutcome {
  SmsBalance({required this.balanceMinor, this.last4, required this.bank});
  final int balanceMinor;
  final String? last4;
  final String bank;
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
    final kind = extractKind(body);
    final balance = extractBalance(body);
    final last4 = extractLast4(body);

    if (amount == null || kind == null) {
      if (balance != null) return SmsBalance(balanceMinor: balance, last4: last4, bank: bank);
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
    );
  }
}
