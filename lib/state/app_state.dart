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
  int ledgerLimit = _ledgerPage;
  bool hasMore = false;

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
      db.transactions(limit: ledgerLimit + 1),
      db.reviewQueue(),
      db.spentInPeriodSql(period),
      db.spendByCategory(period),
      db.dailySpend(period),
      db.budgetRowsPage(period),
    ]);
    accounts = data[0] as List<Account>;
    balances = data[1] as Map<int, int>;
    detections = data[2] as List<DetectedAccount>;
    final rows = data[3] as List<TallyTransaction>;
    hasMore = rows.length > ledgerLimit;
    ledger = hasMore ? rows.sublist(0, ledgerLimit) : rows;
    review = data[4] as List<TallyTransaction>;
    spent = data[5] as int;
    byCategory = data[6] as List<(String, int)>;
    byDay = data[7] as Map<DateTime, int>;
    final page = data[8] as (List<TallyTransaction>, int);
    budgetRows = page.$1;
    budgetRowCount = page.$2;
  }

  Future<void> loadMore() {
    ledgerLimit += _ledgerPage;
    return load();
  }
}

final appState = AppState.instance;
