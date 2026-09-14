import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../core/hash.dart';
import '../data/tally_database.dart';
import '../models/account.dart';
import '../models/categories.dart';
import '../models/transaction.dart';
import '../platform/android_bridge.dart';
import 'categorizer.dart';
import 'sms/bank_parser.dart';
import 'sms/bank_parsers.dart';
import 'statement_import.dart';

/// What one ingestion pass did, so the UI can say something truthful instead of
/// just "done".
class IngestReport {
  const IngestReport({
    this.inserted = 0,
    this.duplicates = 0,
    this.ignored = 0,
    this.balanceUpdates = 0,
    this.needsReview = 0,
    this.failed = 0,
  });

  final int inserted;
  final int duplicates;
  final int ignored;
  final int balanceUpdates;
  final int needsReview;

  /// Messages that raised while being parsed or stored; never surfaced as a
  /// crash, only counted so the snackbar can say something was wrong.
  final int failed;

  int get considered => inserted + duplicates + ignored + balanceUpdates;

  IngestReport plus({
    int inserted = 0,
    int duplicates = 0,
    int ignored = 0,
    int balanceUpdates = 0,
    int needsReview = 0,
    int failed = 0,
  }) => IngestReport(
    inserted: this.inserted + inserted,
    duplicates: this.duplicates + duplicates,
    ignored: this.ignored + ignored,
    balanceUpdates: this.balanceUpdates + balanceUpdates,
    needsReview: this.needsReview + needsReview,
    failed: this.failed + failed,
  );
}

/// Progress of a running ingestion pass, for a thin progress bar on the shell.
/// Null when nothing is running.
class SyncStatus {
  const SyncStatus(this.done, this.total);
  final int done;
  final int total;
}

final ValueNotifier<SyncStatus?> smsSyncStatus = ValueNotifier(null);

/// Identity of an imported message.
///
/// The timestamp is deliberately excluded: the SMS provider hands back a
/// different timestamp for a live-received message than a later inbox scan
/// of the same row would, so folding time in would re-import every historic
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
  accountLast4: parsed.last4,
  bank: parsed.bank,
  smsBody: message.body,
  smsSender: message.sender,
);

/// One message run through [parseBankSms], with its fingerprint precomputed
/// when it turned out to be a transaction. Kept pure so the whole batch can be
/// produced on a background isolate.
class _Parsed {
  const _Parsed(this.message, this.outcome);
  final BankSms message;
  final SmsOutcome outcome;
}

List<_Parsed> _parseBatch(List<BankSms> messages) => [
  for (final m in messages)
    _Parsed(m, parseBankSms(sender: m.sender, body: m.body)),
];

/// Parses, categorises and stores a batch of messages, skipping anything
/// already held and anything that is not a transaction. Never throws: a
/// message that fails to parse or store is counted in [IngestReport.failed]
/// and logged, not surfaced as a crash.
Future<IngestReport> ingestSms(Iterable<BankSms> messages) async {
  final list = messages.toList(growable: false);
  if (list.isEmpty) return const IngestReport();
  smsSyncStatus.value = SyncStatus(0, list.length);
  try {
    final db = TallyDatabase.instance;
    final categorizer = Categorizer(db);
    final accounts = await db.accounts();

    // Parsing is pure regex work with no DB access, so it runs off the main
    // isolate; only the categoriser/DB phase below needs the main isolate.
    final parsed = list.length > 20
        ? await Isolate.run(() => _parseBatch(list))
        : _parseBatch(list);

    // Batch the categoriser lookup: one query for every distinct token in
    // the whole batch instead of one per token per message.
    final spendItems = <int>[]; // index into `parsed` needing a real guess
    for (var i = 0; i < parsed.length; i++) {
      final outcome = parsed[i].outcome;
      if (outcome is SmsTransaction && outcome.kind != TransactionKind.transfer)
        spendItems.add(i);
    }
    final guesses = await categorizer.guessMany([
      for (final i in spendItems)
        (
          merchant: (parsed[i].outcome as SmsTransaction).merchant,
          body: parsed[i].message.body,
        ),
    ]);
    final guessByIndex = {
      for (var j = 0; j < spendItems.length; j++) spendItems[j]: guesses[j],
    };

    var report = const IngestReport();
    final rows = <TallyTransaction>[];
    final balanceUpdates = <(int, int, DateTime)>[];
    final detections = <(String bank, String last4, AccountKind kind, int? bal, DateTime at)>[];

    for (var i = 0; i < parsed.length; i++) {
      final message = parsed[i].message;
      final outcome = parsed[i].outcome;
      switch (outcome) {
        case SmsIgnored():
          report = report.plus(ignored: 1);
        case SmsBalance(:final balanceMinor, :final last4, :final bank, :final isCard):
          final account = _match(accounts, last4);
          if (account?.id == null) {
            if (last4 != null && last4.isNotEmpty)
              detections.add((
                bank,
                last4,
                isCard ? AccountKind.card : AccountKind.bank,
                balanceMinor,
                message.timestamp,
              ));
            report = report.plus(ignored: 1);
            continue;
          }
          balanceUpdates.add((account!.id!, balanceMinor, message.timestamp));
          report = report.plus(balanceUpdates: 1);
        case SmsTransaction():
          final account = _match(accounts, outcome.last4);
          if (account?.id == null &&
              outcome.last4 != null &&
              outcome.last4!.isNotEmpty)
            detections.add((
              outcome.bank,
              outcome.last4!,
              outcome.isCard ? AccountKind.card : AccountKind.bank,
              outcome.balanceAfterMinor,
              message.timestamp,
            ));
          final guess = outcome.kind == TransactionKind.transfer
              ? const CategoryGuess('Transfers', 1)
              : _resolveIncomeGuess(outcome, guessByIndex[i]!);
          rows.add(
            buildTransaction(
              parsed: outcome,
              message: message,
              category: guess.category,
              categorySource: CategorySource.learned,
              needsReview: guess.needsReview,
              accountId: account?.id,
            ),
          );
          if (outcome.balanceAfterMinor != null && account?.id != null)
            balanceUpdates.add((
              account!.id!,
              outcome.balanceAfterMinor!,
              message.timestamp,
            ));
      }
      if ((i + 1) % 50 == 0 || i == parsed.length - 1)
        smsSyncStatus.value = SyncStatus(i + 1, parsed.length);
    }

    final inserted = await db.storeIngestBatch(
      rows: rows,
      balanceUpdates: balanceUpdates,
    );
    report = report.plus(
      inserted: inserted,
      duplicates: rows.length - inserted,
      needsReview: rows.where((r) => r.needsReview).length,
    );
    for (final d in detections)
      await db.upsertDetection(
        bank: d.$1,
        last4: d.$2,
        kind: d.$3,
        balanceMinor: d.$4,
        at: d.$5,
      );
    await db.linkSelfTransfers();
    return report;
  } catch (e, st) {
    debugPrint('ingestSms failed: $e\n$st');
    return IngestReport(failed: list.length);
  } finally {
    smsSyncStatus.value = null;
  }
}

/// Money coming in is income by definition, so it never needs review — only
/// spending has a category worth guessing.
CategoryGuess _resolveIncomeGuess(SmsTransaction parsed, CategoryGuess guess) {
  if (parsed.kind == TransactionKind.income && guess.needsReview)
    return const CategoryGuess('Income', 1);
  return guess;
}

Account? _match(List<Account> accounts, String? last4) {
  if (last4 != null && last4.isNotEmpty) {
    for (final account in accounts)
      if (account.last4.isNotEmpty && last4Matches(last4, account.last4))
        return account;
    // Digits that match nothing are usually a credit card or another bank.
    // Only a lone account with no digits entered can safely claim them.
    return accounts.length == 1 && accounts.single.last4.isEmpty
        ? accounts.single
        : null;
  }
  return accounts.length == 1 ? accounts.single : null;
}

/// Reads whatever the SMS provider has newer than the last watermark, then
/// advances it. Called on resume and at startup once permission is granted.
Future<IngestReport> ingestNewSms() async {
  final db = TallyDatabase.instance;
  final since = int.tryParse(await db.setting('sms_last_seen') ?? '0') ?? 0;
  final messages = await AndroidBridge.smsSince(since);
  final report = await ingestSms(messages);
  final watermark = nextWatermark(since, messages);
  if (watermark != since)
    await db.setSetting('sms_last_seen', '$watermark');
  return report;
}

/// The new watermark after reading [messages] that arrived since
/// [currentWatermark]: the latest message timestamp seen, or the same
/// watermark when nothing came back. Pure, so the "did we move forward"
/// logic is testable without the platform channel.
int nextWatermark(int currentWatermark, Iterable<BankSms> messages) =>
    messages.fold(
      currentWatermark,
      (max, m) => m.timestamp.millisecondsSinceEpoch > max
          ? m.timestamp.millisecondsSinceEpoch
          : max,
    );

/// One-shot consent-gated scan of the entire local SMS inbox, used for the
/// first "Scan SMS inbox" and to fully rebuild the watermark.
Future<IngestReport> ingestHistoricSms() async {
  final messages = await AndroidBridge.smsSince(0);
  final report = await ingestSms(messages);
  final watermark = nextWatermark(0, messages);
  await TallyDatabase.instance.setSetting('sms_last_seen', '$watermark');
  return report;
}

/// Re-parses every stored SMS transaction against its saved message text,
/// so a parser fix corrects history without re-reading the inbox. Manual
/// category/account edits are kept; only fields [parseBankSms] fills in are
/// refreshed. Rows saved before this field existed have no stored body and
/// fall back to a full inbox re-read.
Future<IngestReport> rereadStoredSms() async {
  final db = TallyDatabase.instance;
  final rows = await db.smsTransactions();
  final withBody = <TallyTransaction>[];
  final withoutBody = <TallyTransaction>[];
  for (final row in rows)
    ((row.smsBody ?? '').isEmpty ? withoutBody : withBody).add(row);

  var reparsed = 0;
  var failed = 0;
  for (final row in withBody) {
    try {
      final outcome = parseBankSms(
        sender: row.smsSender ?? '',
        body: row.smsBody!,
      );
      if (outcome is! SmsTransaction) continue;
      // A manually confirmed category was set while looking at this
      // merchant text, so leave it (and the label) exactly as the user saw
      // it; the account link is likewise never touched by a re-read.
      final keepMerchant = row.categorySource == CategorySource.manual;
      await db.updateTransaction(
        row.copyWith(
          amountMinor: outcome.amountMinor,
          kind: outcome.kind,
          merchant: keepMerchant ? row.merchant : outcome.merchant,
        ),
      );
      reparsed++;
    } catch (e, st) {
      debugPrint('rereadStoredSms failed for #${row.id}: $e\n$st');
      failed++;
    }
  }

  var report = IngestReport(inserted: reparsed, failed: failed);
  if (withoutBody.isNotEmpty) {
    await db.deleteByIds(withoutBody.map((r) => r.id!).toList());
    report = report.plus(inserted: (await ingestHistoricSms()).inserted);
  }
  await db.linkSelfTransfers();
  return report;
}

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

/// Categorises and stores parsed statement rows against one account. No
/// fingerprint/dedup here — a statement import is a deliberate one-off, unlike
/// the recurring SMS feed. Returns the number of rows inserted.
Future<int> ingestStatementRows({
  required List<StatementRow> rows,
  required int accountId,
  required String source,
}) async {
  final db = TallyDatabase.instance;
  final categorizer = Categorizer(db);
  var inserted = 0;
  for (final row in rows) {
    final guess = row.isCredit
        ? const CategoryGuess('Income', 1)
        : await categorizer.guess(merchant: row.merchant);
    if (await db.add(
      statementRowToTransaction(
        row,
        accountId: accountId,
        source: source,
        category: guess.category,
        needsReview: guess.needsReview,
      ),
    ))
      inserted++;
  }
  final withBalance = rows.where((row) => row.balanceMinor != null);
  if (withBalance.isNotEmpty) {
    final last = withBalance.last;
    await db.recordReportedBalance(accountId, last.balanceMinor!, last.date);
  }
  await db.linkSelfTransfers();
  return inserted;
}

/// Records a user's decision: trains the learner, then sweeps every other
/// unlabelled row from the same merchant so the question is asked once.
Future<int> confirmCategory(TallyTransaction row, String category) async {
  final db = TallyDatabase.instance;
  await Categorizer(db)
      .learn(merchant: row.merchant, body: row.note, category: category);
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
