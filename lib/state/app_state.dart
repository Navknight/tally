import 'package:flutter/foundation.dart';

import '../core/budget_period.dart';
import '../data/tally_database.dart';
import '../models/account.dart';
import '../models/detected_account.dart';
import '../models/transaction.dart';

/// Everything the five tabs display, read once and held in memory.
///
/// Screens used to each own a `FutureBuilder` that re-queried on every
/// refresh, so opening a tab meant a spinner and another round of SQL. Here
/// one [load] fills every field in a single batch and [notifyListeners] hands
/// it to whoever is listening: switching tabs runs no queries at all, and a
/// write repaints with the old numbers still on screen until the new ones
/// land.
class AppState extends ChangeNotifier {
  AppState();
  static final instance = AppState();

  /// False until the first [load] finishes - the only time a spinner is right.
  bool loaded = false;

  String symbol = '₹';
  int budgetMinor = 0;
  int startDay = 1;
  BudgetPeriod period = budgetPeriod(DateTime.now(), 1);

  List<Account> accounts = const [];
  Map<int, int> balances = const {};
  List<DetectedAccount> detections = const [];

  /// The ledger, newest first, capped at [ledgerLimit]. Activity grows the cap
  /// with [loadMore]; Home shows the first handful.
  List<TallyTransaction> ledger = const [];

  /// [ledger] split into days with each day's spend, grouped once here rather
  /// than on every Activity rebuild.
  List<LedgerDay> ledgerDays = const [];
  int ledgerLimit = _ledgerPage;
  bool hasMore = false;

  /// Home's short list, always the newest rows whatever window Activity is
  /// showing.
  List<TallyTransaction> recent = const [];

  /// Set when Activity has been jumped back to a chosen day: the ledger then
  /// starts at that day instead of today. Null is the live view.
  DateTime? anchor;

  /// The first transaction on record, for the date picker's lower bound.
  DateTime? oldest;

  /// Spend per day over the last week, for the strip on Home. Separate from
  /// [byDay], which only covers the budget period and so can be empty on the
  /// first days of one.
  Map<DateTime, int> lastWeek = const {};

  List<TallyTransaction> review = const [];
  int spent = 0;

  List<(String, int)> byCategory = const [];
  Map<DateTime, int> byDay = const {};
  List<TallyTransaction> budgetRows = const [];
  int budgetRowCount = 0;

  static const _ledgerPage = 60;

  bool _loading = false;
  bool _queued = false;

  /// Money in accounts the user actually holds. Cards are debt, never balance.
  int get totalBalance => accounts
      .where((a) => a.kind == AccountKind.bank)
      .fold<int>(0, (sum, a) => sum + (balances[a.id] ?? 0));

  bool get hasBudget => budgetMinor > 0;

  /// What an even spend across the period would have cost by now.
  int get paceTarget =>
      (budgetMinor * budgetPace(period, DateTime.now())).round();

  List<Account> get lowAccounts => accounts
      .where(
        (a) =>
            a.kind == AccountKind.bank &&
            a.minBalanceMinor != null &&
            (balances[a.id] ?? 0) < a.minBalanceMinor!,
      )
      .toList();

  /// Re-reads everything. Calls that overlap collapse into one extra pass, so
  /// an SMS sync finishing mid-load doesn't stack queries.
  Future<void> load() async {
    if (_loading) {
      _queued = true;
      return;
    }
    _loading = true;
    try {
      do {
        _queued = false;
        await read();
        loaded = true;
        notifyListeners();
      } while (_queued);
    } finally {
      _loading = false;
    }
  }

  /// The actual queries. Visible so a test can count how often overlapping
  /// [load] calls reach the database.
  @protected
  @visibleForTesting
  Future<void> read() async {
    final db = TallyDatabase.instance;
    final settings = await Future.wait([
      db.currency(),
      db.setting('monthly_budget'),
      db.budgetStartDay(),
    ]);
    symbol = settings[0] as String;
    budgetMinor = int.tryParse(settings[1] as String? ?? '') ?? 0;
    startDay = settings[2] as int;
    period = budgetPeriod(DateTime.now(), startDay);

    final data = await Future.wait([
      db.accounts(),
      db.accountBalancesSql(),
      db.detectedAccounts(),
      db.transactions(
        limit: ledgerLimit + 1,
        before: anchor?.add(const Duration(days: 1)),
      ),
      db.reviewQueue(),
      db.spentInPeriodSql(period),
      db.spendByCategory(period),
      db.dailySpend(period),
      db.budgetRowsPage(period),
      db.dailySpend(_lastWeek()),
      db.transactions(limit: 6),
      db.oldestTransaction(),
    ]);
    accounts = data[0] as List<Account>;
    balances = data[1] as Map<int, int>;
    detections = data[2] as List<DetectedAccount>;
    final rows = data[3] as List<TallyTransaction>;
    hasMore = rows.length > ledgerLimit;
    ledger = hasMore ? rows.sublist(0, ledgerLimit) : rows;
    ledgerDays = groupByDay(ledger);
    review = data[4] as List<TallyTransaction>;
    spent = data[5] as int;
    byCategory = data[6] as List<(String, int)>;
    byDay = data[7] as Map<DateTime, int>;
    final page = data[8] as (List<TallyTransaction>, int);
    budgetRows = page.$1;
    budgetRowCount = page.$2;
    lastWeek = data[9] as Map<DateTime, int>;
    recent = data[10] as List<TallyTransaction>;
    oldest = data[11] as DateTime?;
  }

  /// Points Activity at [day], or back at today when it is null. Paging
  /// starts over, since the window moved.
  Future<void> jumpTo(DateTime? day) {
    anchor = day == null ? null : DateTime(day.year, day.month, day.day);
    ledgerLimit = _ledgerPage;
    return load();
  }

  /// The seven days ending today, as a period the daily-spend query accepts.
  static BudgetPeriod _lastWeek() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    return BudgetPeriod(
      today.subtract(const Duration(days: 6)),
      today.add(const Duration(days: 1)),
    );
  }

  Future<void> loadMore() {
    ledgerLimit += _ledgerPage;
    return load();
  }
}

final appState = AppState.instance;

/// One day of the ledger: the rows booked that day, newest first, and what
/// the day cost. Money coming in is not spend and never joins [spent].
class LedgerDay {
  const LedgerDay(this.day, this.spent, this.rows);
  final DateTime day;
  final int spent;
  final List<TallyTransaction> rows;
}

/// Splits [rows] (already newest first) into consecutive days.
List<LedgerDay> groupByDay(List<TallyTransaction> rows) {
  final days = <LedgerDay>[];
  var start = 0;
  DateTime keyOf(TallyTransaction t) =>
      DateTime(t.occurredAt.year, t.occurredAt.month, t.occurredAt.day);
  while (start < rows.length) {
    final day = keyOf(rows[start]);
    var end = start;
    var spent = 0;
    while (end < rows.length && keyOf(rows[end]) == day) {
      if (rows[end].kind == TransactionKind.expense)
        spent += rows[end].amountMinor;
      end++;
    }
    days.add(LedgerDay(day, spent, rows.sublist(start, end)));
    start = end;
  }
  return days;
}
