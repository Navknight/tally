import 'package:flutter/foundation.dart';

import '../core/budget_period.dart';
import '../data/tally_database.dart';
import '../models/account.dart';
import '../models/categories.dart';
import '../models/category_def.dart';
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

  List<CategoryDef> categories = const [];

  /// How many transactions each category holds, for the manage screen.
  Map<String, int> categoryCounts = const {};
  List<Account> accounts = const [];

  /// Category names in the user's own order. Falls back to the built-in set
  /// before the table has been read, so a picker is never empty.
  List<String> get categoryNames =>
      categories.isEmpty ? kCategories : [for (final c in categories) c.name];
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

  /// What Activity is narrowed to. One filter drives the search box, the
  /// account and category chips, the amount bounds, and the drill-down from
  /// an Insights slice, so those can never disagree about what is on screen.
  LedgerFilter filter = const LedgerFilter();

  /// How many rows [filter] matches and what they add up to, in and out kept
  /// apart. Counted by the database, not by the page that was loaded.
  int ledgerCount = 0;
  int ledgerOut = 0;
  int ledgerIn = 0;

  /// The first transaction on record, for the date picker's lower bound.
  DateTime? oldest;

  /// False until the inbox has been read once. Tally's whole premise is that
  /// the ledger fills itself in, so until this is true Home leads with the
  /// offer to do it rather than leaving it buried in Settings.
  bool smsScanned = false;

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
  int periodIncome = 0;
  List<(String, int, int)> topMerchants = const [];

  /// Which period Insights charts, and whether it stays inside the budget.
  /// Defaults to the budget's own view; widening it answers "where did the
  /// money go" rather than "how am I doing against the limit".
  InsightsRange insightsRange = InsightsRange.thisPeriod;
  bool insightsBudgetedOnly = true;

  /// The range Insights is actually charting, derived from [insightsRange].
  BudgetPeriod get insightsPeriod => switch (insightsRange) {
    InsightsRange.thisPeriod => period,
    InsightsRange.lastPeriod => budgetPeriod(
      period.start.subtract(const Duration(days: 1)),
      startDay,
    ),
    InsightsRange.sixMonths => BudgetPeriod(
      DateTime(period.end.year, period.end.month - 6, period.end.day),
      period.end,
    ),
    InsightsRange.everything => BudgetPeriod(
      oldest ?? DateTime(2000),
      period.end,
    ),
  };

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
      db.setting('sms_last_seen'),
    ]);
    symbol = settings[0] as String;
    budgetMinor = int.tryParse(settings[1] as String? ?? '') ?? 0;
    startDay = settings[2] as int;
    smsScanned = (settings[3] as String?) != null;
    period = budgetPeriod(DateTime.now(), startDay);

    final data = await Future.wait([
      db.categories(),
      db.accounts(),
      db.accountBalancesSql(),
      db.detectedAccounts(),
      db.transactions(
        limit: ledgerLimit + 1,
        from: filter.from,
        to: filter.to,
        category: filter.category,
        accountId: filter.accountId,
        search: filter.text,
        minMinor: filter.minMinor,
        maxMinor: filter.maxMinor,
      ),
      db.reviewQueue(limit: 500),
      db.spentInPeriodSql(period),
      db.spendByCategory(insightsPeriod, budgetedOnly: insightsBudgetedOnly),
      db.dailySpend(insightsPeriod, budgetedOnly: insightsBudgetedOnly),
      db.budgetRowsPage(insightsPeriod, budgetedOnly: insightsBudgetedOnly),
      db.dailySpend(_lastWeek()),
      db.transactions(limit: 6),
      db.oldestTransaction(),
      db.ledgerSummary(
        from: filter.from,
        to: filter.to,
        category: filter.category,
        accountId: filter.accountId,
        search: filter.text,
        minMinor: filter.minMinor,
        maxMinor: filter.maxMinor,
      ),
      db.incomeInPeriod(insightsPeriod, budgetedOnly: insightsBudgetedOnly),
      db.categoryUsage(),
      db.topMerchants(insightsPeriod, budgetedOnly: insightsBudgetedOnly),
    ]);
    categories = data[0] as List<CategoryDef>;
    // Icons and colours come from the table, so a recoloured or renamed
    // category takes effect everywhere at once.
    setLiveCategories({for (final c in categories) c.name: (c.icon, c.color)});
    accounts = data[1] as List<Account>;
    balances = data[2] as Map<int, int>;
    detections = data[3] as List<DetectedAccount>;
    final rows = data[4] as List<TallyTransaction>;
    hasMore = rows.length > ledgerLimit;
    ledger = hasMore ? rows.sublist(0, ledgerLimit) : rows;
    ledgerDays = groupByDay(ledger);
    review = data[5] as List<TallyTransaction>;
    spent = data[6] as int;
    byCategory = data[7] as List<(String, int)>;
    byDay = data[8] as Map<DateTime, int>;
    final page = data[9] as (List<TallyTransaction>, int);
    budgetRows = page.$1;
    budgetRowCount = page.$2;
    lastWeek = data[10] as Map<DateTime, int>;
    recent = data[11] as List<TallyTransaction>;
    oldest = data[12] as DateTime?;
    final summary = data[13] as (int, int, int);
    ledgerCount = summary.$1;
    ledgerOut = summary.$2;
    ledgerIn = summary.$3;
    periodIncome = data[14] as int;
    categoryCounts = data[15] as Map<String, int>;
    topMerchants = data[16] as List<(String, int, int)>;
  }

  /// Every id the current filter matches, for selecting a whole filtered set
  /// rather than only the page that has been loaded.
  Future<List<int>> filteredIds() => TallyDatabase.instance.ledgerIds(
    from: filter.from,
    to: filter.to,
    category: filter.category,
    accountId: filter.accountId,
    search: filter.text,
    minMinor: filter.minMinor,
    maxMinor: filter.maxMinor,
  );

  Future<void> setInsightsScope({InsightsRange? range, bool? budgetedOnly}) {
    insightsRange = range ?? insightsRange;
    insightsBudgetedOnly = budgetedOnly ?? insightsBudgetedOnly;
    return load();
  }

  /// Narrows Activity. Paging starts over, since the window changed.
  Future<void> setFilter(LedgerFilter next) {
    filter = next;
    ledgerLimit = _ledgerPage;
    return load();
  }

  /// Drops every narrowing at once.
  Future<void> clearFilter() => setFilter(const LedgerFilter());

  /// Rewinds Activity to [day]: that day and everything before it. Null goes
  /// back to the live view.
  Future<void> jumpTo(DateTime? day) => setFilter(
    day == null
        ? filter.copyWith(clearDates: true)
        : filter.copyWith(
            to: DateTime(day.year, day.month, day.day + 1),
            clearFrom: true,
          ),
  );

  /// Shows exactly one day, which is what tapping a bar on Home's strip
  /// means - the old behaviour sent you to Insights for a different period
  /// entirely.
  Future<void> showDay(DateTime day) => setFilter(
    filter.copyWith(
      from: DateTime(day.year, day.month, day.day),
      to: DateTime(day.year, day.month, day.day + 1),
    ),
  );

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

/// What Activity is narrowed to: free text over the merchant and note, one
/// category, one account, or any combination. Every field empty is the whole
/// ledger.
class LedgerFilter {
  const LedgerFilter({
    this.text = '',
    this.category,
    this.accountId,
    this.minMinor,
    this.maxMinor,
    this.from,
    this.to,
  });

  final String text;
  final String? category;
  final int? accountId;

  /// Half-open date window. [from] alone is "since", [to] alone is "up to",
  /// and both together is one day or one stretch.
  final DateTime? from;
  final DateTime? to;

  /// Amount bounds in minor units, either end optional: "everything over
  /// 1,000" is as useful a question as a band.
  final int? minMinor;
  final int? maxMinor;

  bool get isEmpty =>
      text.isEmpty &&
      category == null &&
      accountId == null &&
      minMinor == null &&
      maxMinor == null &&
      from == null &&
      to == null;

  /// True when the window is exactly one day, which reads differently in the
  /// filter bar than an open-ended "and earlier".
  bool get isSingleDay =>
      from != null && to != null && to!.difference(from!).inHours <= 25;

  LedgerFilter copyWith({
    String? text,
    String? category,
    int? accountId,
    int? minMinor,
    int? maxMinor,
    DateTime? from,
    DateTime? to,
    bool clearCategory = false,
    bool clearAccount = false,
    bool clearAmount = false,
    bool clearDates = false,
    bool clearFrom = false,
  }) => LedgerFilter(
    text: text ?? this.text,
    category: clearCategory ? null : (category ?? this.category),
    accountId: clearAccount ? null : (accountId ?? this.accountId),
    minMinor: clearAmount ? null : (minMinor ?? this.minMinor),
    maxMinor: clearAmount ? null : (maxMinor ?? this.maxMinor),
    from: clearDates || clearFrom ? null : (from ?? this.from),
    to: clearDates ? null : (to ?? this.to),
  );
}

/// The stretch of time Insights charts.
enum InsightsRange {
  thisPeriod('This period'),
  lastPeriod('Last period'),
  sixMonths('6 months'),
  everything('All time');

  const InsightsRange(this.label);
  final String label;
}
