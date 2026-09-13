import '../core/hash.dart';
import '../data/tally_database.dart';
import '../models/account.dart';
import '../models/categories.dart';
import '../models/transaction.dart';
import '../platform/android_bridge.dart';
import 'categorizer.dart';
import 'sms/bank_parser.dart';
import 'sms/bank_parsers.dart';

/// What one ingestion pass did, so the UI can say something truthful instead of
/// just "done".
class IngestReport {
  const IngestReport({
    this.inserted = 0,
    this.duplicates = 0,
    this.ignored = 0,
    this.balanceUpdates = 0,
    this.needsReview = 0,
  });

  final int inserted;
  final int duplicates;
  final int ignored;
  final int balanceUpdates;
  final int needsReview;

  int get considered => inserted + duplicates + ignored + balanceUpdates;

  IngestReport plus({
    int inserted = 0,
    int duplicates = 0,
    int ignored = 0,
    int balanceUpdates = 0,
    int needsReview = 0,
  }) => IngestReport(
    inserted: this.inserted + inserted,
    duplicates: this.duplicates + duplicates,
    ignored: this.ignored + ignored,
    balanceUpdates: this.balanceUpdates + balanceUpdates,
    needsReview: this.needsReview + needsReview,
  );
}

/// Identity of an imported message.
///
/// The timestamp is deliberately excluded: the same SMS reaches us with the
/// SMSC timestamp through the broadcast receiver and with the device timestamp
/// through the provider scan, so folding time in would re-import every historic
/// row as a duplicate.
String smsFingerprint({
  required String sender,
  required int amountMinor,
  required String body,
}) => stableHash('$sender|$amountMinor|${stableHash(body)}');

/// Turns a parsed message into a ledger row. Pure, so it can be tested without
/// a database.
TallyTransaction buildTransaction({
  required SmsTransaction parsed,
  required BankSms message,
  required String category,
  CategorySource categorySource = CategorySource.learned,
  bool needsReview = false,
  int? accountId,
}) => TallyTransaction(
  id: null,
  amountMinor: parsed.amountMinor,
  kind: parsed.kind,
  occurredAt: message.timestamp,
  merchant: parsed.merchant,
  category: category,
  note: parsed.reference == null ? '' : 'Ref ${parsed.reference}',
  source: 'sms',
  fingerprint: smsFingerprint(
    sender: message.sender,
    amountMinor: parsed.amountMinor,
    body: message.body,
  ),
  accountId: accountId,
  reference: parsed.reference,
  balanceAfterMinor: parsed.balanceAfterMinor,
  categorySource: categorySource,
  needsReview: needsReview,
);

/// Parses, categorises and stores a batch of messages, skipping anything
/// already held and anything that is not a transaction.
Future<IngestReport> ingestSms(Iterable<BankSms> messages) async {
  final db = TallyDatabase.instance;
  final categorizer = Categorizer(db);
  final accounts = await db.accounts();
  var report = const IngestReport();

  for (final message in messages) {
    final outcome = parseBankSms(sender: message.sender, body: message.body);
    switch (outcome) {
      case SmsIgnored():
        report = report.plus(ignored: 1);
      case SmsBalance(:final balanceMinor, :final last4):
        final account = _match(accounts, last4);
        if (account?.id == null) {
          report = report.plus(ignored: 1);
          continue;
        }
        await db.recordReportedBalance(
          account!.id!,
          balanceMinor,
          message.timestamp,
        );
        report = report.plus(balanceUpdates: 1);
      case SmsTransaction():
        final account = _match(accounts, outcome.last4);
        final guess = await _categorise(categorizer, outcome, message);
        final row = buildTransaction(
          parsed: outcome,
          message: message,
          category: guess.category,
          categorySource: CategorySource.learned,
          needsReview: guess.needsReview,
          accountId: account?.id,
        );
        if (!await db.add(row)) {
          report = report.plus(duplicates: 1);
          continue;
        }
        report = report.plus(
          inserted: 1,
          needsReview: guess.needsReview ? 1 : 0,
        );
        if (outcome.balanceAfterMinor != null && account?.id != null)
          await db.recordReportedBalance(
            account!.id!,
            outcome.balanceAfterMinor!,
            message.timestamp,
          );
    }
  }
  return report;
}

/// Money coming in is income by definition, so it never needs review — only
/// spending has a category worth guessing.
Future<CategoryGuess> _categorise(
  Categorizer categorizer,
  SmsTransaction parsed,
  BankSms message,
) async {
  if (parsed.kind == TransactionKind.transfer)
    return const CategoryGuess('Transfers', 1);
  final guess = await categorizer.guess(
    merchant: parsed.merchant,
    body: message.body,
  );
  if (parsed.kind == TransactionKind.income && guess.needsReview)
    return const CategoryGuess('Income', 1);
  return guess;
}

Account? _match(List<Account> accounts, String? last4) {
  if (last4 == null || last4.isEmpty) return null;
  for (final account in accounts)
    if (account.last4 == last4) return account;
  // A single tracked account is unambiguous even when the digits don't line up
  // (many users never enter them), so attribute rather than orphan the row.
  return accounts.length == 1 ? accounts.single : null;
}

/// Drains whatever the broadcast receiver has queued since the app was last
/// foregrounded.
Future<IngestReport> ingestPendingSms() async =>
    ingestSms(await AndroidBridge.pendingSms());

/// One-shot consent-gated scan of the local SMS inbox.
Future<IngestReport> ingestHistoricSms() async =>
    ingestSms(await AndroidBridge.historicSms());

/// Re-runs the categoriser over rows still marked for review, which is what
/// makes earlier transactions benefit from later corrections.
Future<int> recategorizeReviewQueue() async {
  final db = TallyDatabase.instance;
  final categorizer = Categorizer(db);
  var settled = 0;
  for (final row in await db.reviewQueue(limit: 200)) {
    final guess = await categorizer.guess(
      merchant: row.merchant,
      body: row.note,
    );
    if (guess.needsReview || guess.category == kUncategorized) continue;
    await db.updateTransaction(
      row.copyWith(
        category: guess.category,
        categorySource: CategorySource.learned,
        needsReview: false,
      ),
    );
    settled++;
  }
  return settled;
}

/// Records a user's decision: trains the learner, then sweeps every other
/// unlabelled row from the same merchant so the question is asked once.
Future<int> confirmCategory(TallyTransaction row, String category) async {
  final db = TallyDatabase.instance;
  await Categorizer(db).learn(
    merchant: row.merchant,
    body: row.note,
    category: category,
  );
  await db.updateTransaction(
    row.copyWith(
      category: category,
      categorySource: CategorySource.manual,
      needsReview: false,
    ),
  );
  return db.applyCategoryToMerchant(
    Categorizer.merchantKey(row.merchant),
    category,
  );
}
