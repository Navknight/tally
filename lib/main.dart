import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app/theme.dart';
import 'core/budget_period.dart';
import 'core/money.dart';
import 'data/tally_database.dart';
import 'insights.dart';
import 'models/account.dart';
import 'models/categories.dart';
import 'models/detected_account.dart';
import 'models/transaction.dart';
import 'platform/android_bridge.dart';
import 'services/export.dart';
import 'services/sms_ingestion.dart';
import 'services/statement_import.dart';
import 'state/app_state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TallyApp());
}

class TallyApp extends StatelessWidget {
  const TallyApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Tally',
    debugShowCheckedModeBanner: false,
    theme: TallyTheme.build(Brightness.light),
    darkTheme: TallyTheme.build(Brightness.dark),
    home: const AppRoot(),
  );
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});
  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> with WidgetsBindingObserver {
  bool? _ready;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _load() async {
    final done = await TallyDatabase.instance.setting('onboarded') == 'true';
    await TallyDatabase.instance.ensureCategorySeed();
    if (done) await appState.load();
    if (mounted) setState(() => _ready = done);
    if (done) {
      AndroidBridge.onSmsChanged(() => unawaited(_syncSms()));
      unawaited(_syncSms());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _ready == true)
      unawaited(_syncSms());
  }

  Future<void> _syncSms() async {
    final report = await ingestNewSms();
    if (report.considered == 0) return;
    await recategorizeReviewQueue();
    refreshApp();
  }

  @override
  Widget build(BuildContext context) {
    if (_ready == null)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return _ready!
        ? const TallyShell()
        : Onboarding(
            onComplete: () async {
              await appState.load();
              if (mounted) setState(() => _ready = true);
            },
          );
  }
}

class Onboarding extends StatefulWidget {
  const Onboarding({super.key, required this.onComplete});
  final VoidCallback onComplete;
  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  final _name = TextEditingController(text: 'Main account');
  final _last4 = TextEditingController();
  final _amount = TextEditingController();
  final _currency = TextEditingController(text: '₹');
  bool _saving = false;
  @override
  void dispose() {
    _name.dispose();
    _last4.dispose();
    _amount.dispose();
    _currency.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    setState(() => _saving = true);
    final opening = parseMoney(_amount.text) ?? 0;
    await TallyDatabase.instance.setSetting(
      'currency',
      _currency.text.trim().isEmpty ? '₹' : _currency.text.trim(),
    );
    await TallyDatabase.instance.setSetting('monthly_budget', '0');
    await TallyDatabase.instance.addAccountAndClaim(
      Account(
        id: null,
        name: _name.text.trim().isEmpty ? 'Main account' : _name.text.trim(),
        last4: _last4.text.trim(),
        openingBalanceMinor: opening,
        reportedBalanceMinor: opening,
        reportedAt: DateTime.now(),
      ),
    );
    await TallyDatabase.instance.setSetting('onboarded', 'true');
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 24),
            Icon(
              Icons.account_balance_wallet_rounded,
              size: 48,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 24),
            Text(
              'A clearer view\nof your money.',
              style: Theme.of(context).textTheme.displaySmall
                  ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -1),
            ),
            const SizedBox(height: 10),
            Text(
              'Everything stays on this device. Start with your main account.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 30),
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Account name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _last4,
              maxLength: 40,
              keyboardType: TextInputType.text,
              decoration: const InputDecoration(
                labelText: 'Last 4 digits (optional)',
                hintText: 'Add debit card digits too, space separated',
                counterText: '',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                SizedBox(
                  width: 76,
                  child: TextField(
                    controller: _currency,
                    decoration: const InputDecoration(labelText: 'Currency'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Opening balance',
                      hintText: '0.00',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'You can import a statement or connect SMS from Settings afterwards.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _saving ? null : _finish,
                child: const Padding(
                  padding: EdgeInsets.all(14),
                  child: Text('Start tallying'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class TallyShell extends StatefulWidget {
  const TallyShell({super.key});
  @override
  State<TallyShell> createState() => _TallyShellState();
}

class _TallyShellState extends State<TallyShell> {
  int _tab = 0;

  /// Tabs the user has opened. A screen is built the first time it is shown
  /// and then kept alive by the [IndexedStack] - startup lays out Home alone
  /// instead of five screens' worth of lists and charts, and coming back to a
  /// tab runs no queries at all, since they all read [appState] rather than
  /// the database.
  final Set<int> _visited = {0};

  late final List<Widget> _pages = [
    HomeScreen(onOpenInsights: () => _showTab(3)),
    const TransactionsScreen(),
    const BudgetScreen(),
    const InsightsScreen(),
    const SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    smsSyncStatus.addListener(_onSyncChanged);
  }

  @override
  void dispose() {
    smsSyncStatus.removeListener(_onSyncChanged);
    super.dispose();
  }

  void _onSyncChanged() {
    if (!mounted) return;
    // A finished sync means new rows may have landed; re-read once it's done.
    // While running, just repaint the progress bar.
    if (smsSyncStatus.value == null)
      refreshApp();
    else
      setState(() {});
  }

  void _showTab(int i) => setState(() {
    _tab = i;
    _visited.add(i);
  });

  @override
  Widget build(BuildContext context) {
    final status = smsSyncStatus.value;
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _showTab(0);
      },
      child: Scaffold(
        body: Column(
          children: [
            if (status != null) ...[
              const LinearProgressIndicator(minHeight: 2),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                child: Text(
                  'Reading SMS · ${status.done} of ${status.total}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  for (var i = 0; i < _pages.length; i++)
                    if (_visited.contains(i))
                      _pages[i]
                    else
                      const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
        floatingActionButton: _tab < 2
            ? FloatingActionButton(
                onPressed: () => showTransactionSheet(context),
                child: const Icon(Icons.add),
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: _showTab,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home',
            ),
            NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long),
              label: 'Activity',
            ),
            NavigationDestination(
              icon: Icon(Icons.savings_outlined),
              selectedIcon: Icon(Icons.savings),
              label: 'Budget',
            ),
            NavigationDestination(
              icon: Icon(Icons.insights_outlined),
              selectedIcon: Icon(Icons.insights),
              label: 'Insights',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom inset a sheet needs so its content clears the gesture/3-button nav
/// bar and any open keyboard, since the app draws edge-to-edge.
double sheetBottomInset(BuildContext context) =>
    MediaQuery.viewPaddingOf(context).bottom +
    MediaQuery.viewInsetsOf(context).bottom;

/// Re-reads everything after a write. Every screen listens to [appState], so
/// one call is all any save, delete or sync needs to do.
void refreshApp() => unawaited(appState.load());

/// A tab: title bar, live [appState], pull to refresh. The spinner shows only
/// before the first read finishes - after that a refresh repaints in place
/// rather than emptying the screen.
class TallyPage extends StatelessWidget {
  const TallyPage({
    super.key,
    required this.title,
    required this.builder,
    this.actions,
  });
  final String title;
  final Widget Function(BuildContext, AppState) builder;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(title), actions: actions),
    body: ListenableBuilder(
      listenable: appState,
      builder: (context, _) => !appState.loaded
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: appState.load,
              child: builder(context, appState),
            ),
    ),
  );
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onOpenInsights});
  final VoidCallback onOpenInsights;

  @override
  Widget build(BuildContext context) => TallyPage(
    title: 'Tally',
    builder: (context, state) {
      final scheme = Theme.of(context).colorScheme;
      final symbol = state.symbol;
      return ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          12,
          20,
          100 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          BudgetHero(
            spent: state.spent,
            budget: state.budgetMinor,
            period: state.period,
            symbol: symbol,
            onOpen: onOpenInsights,
          ),
          const SizedBox(height: 26),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Available', style: Theme.of(context).textTheme.bodySmall),
              Text(
                money(state.totalBalance, symbol),
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(fontFeatures: tabular),
              ),
            ],
          ),
          const SizedBox(height: 10),
          AccountRail(
            accounts: state.accounts,
            balances: state.balances,
            symbol: symbol,
          ),
          if (state.detections.isNotEmpty) ...[
            const SizedBox(height: 18),
            ...state.detections.map(
              (d) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DetectedAccountCard(detection: d),
              ),
            ),
          ],
          ...state.lowAccounts.map(
            (a) => Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Card(
                color: scheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Row(
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        color: scheme.onErrorContainer,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${a.name} is below its minimum balance of '
                          '${money(a.minBalanceMinor!, symbol)}',
                          style: TextStyle(color: scheme.onErrorContainer),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (state.review.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('Needs review', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              "Tally wasn't sure how to label these.",
              style: Theme.of(context).textTheme.bodySmall,
            ),
            ...state.review.map(
              (t) => TransactionTile(
                transaction: t,
                symbol: symbol,
                onTap: () => showTransactionSheet(context, existing: t),
              ),
            ),
          ],
          const SizedBox(height: 28),
          Text(
            'Recent activity',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          ...state.ledger
              .take(6)
              .map(
                (t) => TransactionTile(
                  transaction: t,
                  symbol: symbol,
                  onTap: () => showTransactionSheet(context, existing: t),
                ),
              ),
        ],
      );
    },
  );
}

/// The screen's one loud element: what this period has cost so far, the limit
/// it is running against, and a marker for where an even pace would have you
/// by today. Tapping opens Insights, which breaks the same period down.
class BudgetHero extends StatelessWidget {
  const BudgetHero({
    super.key,
    required this.spent,
    required this.budget,
    required this.period,
    required this.symbol,
    required this.onOpen,
  });
  final int spent;
  final int budget;
  final BudgetPeriod period;
  final String symbol;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final now = DateTime.now();
    final pace = budgetPace(period, now);
    final over = budget > 0 && spent > budget;
    final daysLeft = period.end.difference(now).inDays;
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(Corners.card),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Spent since ${_dayMonth(period.start)}',
                style: text.bodySmall,
              ),
              Text(
                daysLeft <= 0
                    ? 'Last day'
                    : daysLeft == 1
                    ? '1 day left'
                    : '$daysLeft days left',
                style: text.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 2),
          // Seven-figure spends would run off the edge at this size.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              money(spent, symbol),
              maxLines: 1,
              style: text.displayMedium?.copyWith(
                color: over ? scheme.error : null,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            budget <= 0
                ? 'Set a limit in Budget to track this'
                : over
                ? '${money(spent - budget, symbol)} over ${moneyShort(budget, symbol)}'
                : '${money(budget - spent, symbol)} left of ${moneyShort(budget, symbol)}',
            style: text.bodyMedium?.copyWith(
              color: over ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 14),
          PaceBar(
            fraction: budget > 0 ? (spent / budget).clamp(0, 1).toDouble() : 0,
            pace: budget > 0 ? pace : null,
            over: over,
          ),
          if (budget > 0) ...[
            const SizedBox(height: 8),
            Text(
              'An even pace puts you at ${moneyShort((budget * pace).round(), symbol)} by today',
              style: text.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

/// The budget bar. [pace] draws the marker for an even spend across the
/// period, which is the whole point of the bar: the fill alone says how much
/// is gone, not whether that is early or late.
class PaceBar extends StatelessWidget {
  const PaceBar({
    super.key,
    required this.fraction,
    required this.pace,
    this.over = false,
  });
  final double fraction;
  final double? pace;
  final bool over;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: 14,
        child: Stack(
          children: [
            Container(
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(7),
              ),
            ),
            FractionallySizedBox(
              widthFactor: fraction == 0 ? 0.001 : fraction,
              child: Container(
                decoration: BoxDecoration(
                  color: over ? scheme.error : scheme.primary,
                  borderRadius: BorderRadius.circular(7),
                ),
              ),
            ),
            if (pace != null)
              Positioned(
                left: (constraints.maxWidth - 4) * pace!.clamp(0.0, 1.0),
                top: -3,
                bottom: -3,
                child: Container(
                  width: 4,
                  decoration: BoxDecoration(
                    color: scheme.onSurface,
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(color: scheme.surface, width: 1),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Accounts as a row of cards you can push along, each opening its own sheet.
/// A balance is a thing you hold, so it gets an object to sit on; the ledger
/// rows below stay a list.
class AccountRail extends StatelessWidget {
  const AccountRail({
    super.key,
    required this.accounts,
    required this.balances,
    required this.symbol,
  });
  final List<Account> accounts;
  final Map<int, int> balances;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 84,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: accounts.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          if (index == accounts.length)
            return OutlinedButton(
              onPressed: () => showAccountSheet(context),
              child: const Text('Add account'),
            );
          final account = accounts[index];
          final balance = balances[account.id] ?? 0;
          final low =
              account.kind == AccountKind.bank &&
              account.minBalanceMinor != null &&
              balance < account.minBalanceMinor!;
          return SizedBox(
            width: 152,
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => showAccountSheet(context, existing: account),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          Icon(
                            account.kind == AccountKind.card
                                ? Icons.credit_card_rounded
                                : Icons.account_balance_rounded,
                            size: 15,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              account.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: text.bodySmall,
                            ),
                          ),
                        ],
                      ),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          money(balance, symbol),
                          maxLines: 1,
                          style: text.titleMedium?.copyWith(
                            fontFeatures: tabular,
                            color: low ? scheme.error : null,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _dayMonth(DateTime date) => '${date.day} ${_months[date.month - 1]}';

/// Quiet prompt for an untracked (bank, last4) pair seen enough in SMS to be
/// worth naming as an account or card.
class DetectedAccountCard extends StatelessWidget {
  const DetectedAccountCard({super.key, required this.detection});
  final DetectedAccount detection;

  Future<void> _add(BuildContext context) async {
    final db = TallyDatabase.instance;
    final now = detection.lastSeen;
    await db.addAccountAndClaim(
      Account(
        id: null,
        name: detection.suggestedName,
        last4: detection.last4,
        openingBalanceMinor: detection.lastBalanceMinor ?? 0,
        reportedBalanceMinor: detection.lastBalanceMinor,
        reportedAt: detection.lastBalanceMinor == null ? null : now,
        kind: detection.kind,
      ),
      bank: detection.bank,
    );
    await db.linkSelfTransfers();
    await db.dismissDetection(detection.bank, detection.last4);
    refreshApp();
  }

  Future<void> _dismiss() async {
    await TallyDatabase.instance.dismissDetection(
      detection.bank,
      detection.last4,
    );
    refreshApp();
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  detection.suggestedName,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  'Seen in ${detection.messageCount} messages',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          TextButton(onPressed: _dismiss, child: const Text('Dismiss')),
          FilledButton(
            onPressed: () => _add(context),
            child: const Text('Add'),
          ),
        ],
      ),
    ),
  );
}

class TransactionsScreen extends StatelessWidget {
  const TransactionsScreen({super.key});

  @override
  Widget build(BuildContext context) => TallyPage(
    title: 'Activity',
    builder: (context, state) {
      final transactions = state.ledger;
      if (transactions.isEmpty)
        return ListView(
          children: const [
            SizedBox(height: 120),
            Center(child: Text('No transactions yet.')),
          ],
        );
      // What each day cost, so the list reads like a ledger rather than a
      // stream. Money coming in is not spend and never joins the total.
      final dayTotals = <DateTime, int>{};
      for (final t in transactions)
        if (t.kind == TransactionKind.expense)
          dayTotals[_dayKey(t.occurredAt)] =
              (dayTotals[_dayKey(t.occurredAt)] ?? 0) + t.amountMinor;
      return ListView.builder(
        padding: EdgeInsets.fromLTRB(
          20,
          8,
          20,
          100 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        itemCount: transactions.length + (state.hasMore ? 1 : 0),
        itemBuilder: (_, index) {
          if (index == transactions.length)
            return Center(
              child: TextButton(
                onPressed: () => unawaited(state.loadMore()),
                child: const Text('Load more'),
              ),
            );
          final transaction = transactions[index];
          final previous = index == 0 ? null : transactions[index - 1];
          final tile = Dismissible(
            key: ValueKey(transaction.id),
            direction: DismissDirection.endToStart,
            onDismissed: (_) async {
              await TallyDatabase.instance.delete(transaction.id!);
              refreshApp();
            },
            background: Container(
              alignment: Alignment.centerRight,
              padding: const EdgeInsets.only(right: 24),
              color: Theme.of(context).colorScheme.errorContainer,
              child: const Icon(Icons.delete),
            ),
            child: TransactionTile(
              transaction: transaction,
              symbol: state.symbol,
              onTap: () => showTransactionSheet(context, existing: transaction),
            ),
          );
          if (previous != null &&
              _sameDay(previous.occurredAt, transaction.occurredAt))
            return tile;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _DayHeading(
                date: transaction.occurredAt,
                spent: dayTotals[_dayKey(transaction.occurredAt)] ?? 0,
                symbol: state.symbol,
                first: index == 0,
              ),
              tile,
            ],
          );
        },
      );
    },
  );
}

DateTime _dayKey(DateTime at) => DateTime(at.year, at.month, at.day);

bool _sameDay(DateTime a, DateTime b) => _dayKey(a) == _dayKey(b);

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Splits the ledger into days, each headed by what that day cost. The
/// heading is the only place spend is summed outside the budget itself.
class _DayHeading extends StatelessWidget {
  const _DayHeading({
    required this.date,
    required this.spent,
    required this.symbol,
    required this.first,
  });
  final DateTime date;
  final int spent;
  final String symbol;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final today = _dayKey(DateTime.now());
    final day = _dayKey(date);
    final label = day == today
        ? 'Today'
        : day == today.subtract(const Duration(days: 1))
        ? 'Yesterday'
        : '${_weekdays[date.weekday - 1]} ${_dayMonth(date)}';
    return Padding(
      padding: EdgeInsets.fromLTRB(0, first ? 4 : 22, 0, 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: text.titleMedium),
          if (spent > 0)
            Text(
              money(spent, symbol),
              style: text.bodySmall?.copyWith(fontFeatures: tabular),
            ),
        ],
      ),
    );
  }
}

class TransactionTile extends StatelessWidget {
  const TransactionTile({
    super.key,
    required this.transaction,
    required this.symbol,
    this.onTap,
  });
  final TallyTransaction transaction;
  final String symbol;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final positive = transaction.kind == TransactionKind.income;
    final isTransfer = transaction.kind == TransactionKind.transfer;
    final scheme = Theme.of(context).colorScheme;
    final color = categoryColor(transaction.category);
    final sign = isTransfer ? '' : (positive ? '+' : '-');
    return ListTile(
      onTap: onTap,
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: color.withValues(alpha: 0.16),
        foregroundColor: color,
        child: Icon(categoryIcon(transaction.category), size: 20),
      ),
      title: Text(transaction.merchant),
      subtitle: Text(
        '${transaction.needsReview ? 'Needs a label' : transaction.category}'
        ' · ${transaction.occurredAt.day}/${transaction.occurredAt.month}',
        style: transaction.needsReview
            ? TextStyle(color: scheme.primary, fontWeight: FontWeight.w700)
            : null,
      ),
      trailing: Text(
        '$sign${money(transaction.amountMinor, symbol)}',
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontFeatures: tabular,
          color: positive ? scheme.primary : null,
        ),
      ),
    );
  }
}

class BudgetScreen extends StatefulWidget {
  const BudgetScreen({super.key});
  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

/// The one screen with its own state: a text field the user is typing in.
/// Everything else it shows comes from [appState].
class _BudgetScreenState extends State<BudgetScreen> {
  final controller = TextEditingController();
  bool _seeded = false;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TallyPage(
    title: 'Budget',
    builder: (context, state) {
      // Fill the field from the saved limit once, then leave it alone - a
      // refresh mid-edit must not overwrite what is being typed.
      if (!_seeded) {
        _seeded = true;
        controller.text = (state.budgetMinor / 100).toStringAsFixed(2);
      }
      return ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          20 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          Text(
            'One number is enough.',
            style: Theme.of(context).textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'Set a gentle spending limit for the period. Tally will keep the rest simple.',
          ),
          const SizedBox(height: 28),
          TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              prefixText: '${state.symbol} ',
              labelText: 'Spending limit',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              await TallyDatabase.instance.setSetting(
                'monthly_budget',
                '${parseMoney(controller.text) ?? 0}',
              );
              refreshApp();
              if (context.mounted)
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Budget saved')));
            },
            child: const Text('Save budget'),
          ),
          const SizedBox(height: 28),
          Text(
            'Period start day',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Your budget period runs from this day of the month to the day before it next month.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: state.startDay,
            decoration: const InputDecoration(labelText: 'Starts on'),
            items: List.generate(
              28,
              (i) => DropdownMenuItem(value: i + 1, child: Text('${i + 1}')),
            ),
            onChanged: (v) async {
              if (v == null) return;
              await TallyDatabase.instance.setSetting('budget_start_day', '$v');
              refreshApp();
            },
          ),
          if (state.accounts.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('Accounts', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Turn an account off to leave its spending out of the budget.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            ...state.accounts.map(
              (a) => SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(a.name),
                subtitle: const Text('Count in budget'),
                value: a.inBudget,
                onChanged: (v) async {
                  await TallyDatabase.instance.updateAccount(
                    a.copyWith(inBudget: v),
                  );
                  refreshApp();
                },
              ),
            ),
          ],
        ],
      );
    },
  );
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _smsStatus = '';

  Future<void> _scanSms() async {
    final granted = await AndroidBridge.requestSmsPermission();
    if (!granted) {
      setState(() => _smsStatus = 'SMS access was not granted.');
      return;
    }
    final report = await ingestHistoricSms();
    await recategorizeReviewQueue();
    refreshApp();
    if (!mounted) return;
    setState(() => _smsStatus = _describeIngest(report));
  }

  Future<void> _confirmRereadSms(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Re-read SMS?'),
        content: const Text(
          'Re-parses every SMS transaction from its saved message text. '
          'Manual category and account changes stay.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Re-read'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final report = await rereadStoredSms();
    await recategorizeReviewQueue();
    refreshApp();
    if (!mounted) return;
    setState(() => _smsStatus = _describeIngest(report));
  }

  Future<void> _importStatement() async {
    final file = await AndroidBridge.pickStatementFile();
    if (file == null) {
      if (mounted) _showPasteCsvSheet(context);
      return;
    }
    final rows = file.name.toLowerCase().endsWith('.pdf')
        ? parsePdfStatement(file.bytes)
        : parseCsvStatement(utf8.decode(file.bytes, allowMalformed: true));
    await _importRows(rows, file.name);
  }

  Future<void> _importRows(List<StatementRow> rows, String source) async {
    if (rows.isEmpty) {
      _snack('No transactions found in $source.');
      return;
    }
    final account = await _chooseAccount();
    if (account == null) return;
    final inserted = await ingestStatementRows(
      rows: rows,
      accountId: account.id!,
      source: source.toLowerCase().endsWith('.pdf') ? 'pdf' : 'csv',
    );
    refreshApp();
    _snack('$inserted transactions imported to ${account.name}');
  }

  /// Skips the picker entirely when there is only one account to target.
  Future<Account?> _chooseAccount() async {
    final accounts = appState.accounts;
    if (accounts.isEmpty) {
      _snack('Add an account first.');
      return null;
    }
    if (accounts.length == 1) return accounts.single;
    if (!mounted) return null;
    return showModalBottomSheet<Account>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(bottom: sheetBottomInset(sheetContext)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: accounts
              .map(
                (a) => ListTile(
                  title: Text(a.name),
                  subtitle: a.last4.isEmpty ? null : Text('···· ${a.last4}'),
                  onTap: () => Navigator.pop(sheetContext, a),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _exportTransactions() async {
    final db = TallyDatabase.instance;
    final rows = await db.transactions(limit: -1);
    final accounts = await db.accounts();
    final csv = transactionsCsv(rows, accounts);
    final now = DateTime.now();
    final name =
        'tally-${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}.csv';
    final saved = await AndroidBridge.saveFile(
      name,
      'text/csv',
      Uint8List.fromList(utf8.encode(csv)),
    );
    if (saved) _snack('Exported ${rows.length} transactions');
  }

  @override
  Widget build(BuildContext context) => TallyPage(
    title: 'Settings',
    builder: (context, state) {
      final accounts = state.accounts;
      final balances = state.balances;
      final symbol = state.symbol;
      return ListView(
        padding: EdgeInsets.fromLTRB(
          12,
          12,
          12,
          12 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          const ListTile(
            title: Text('Privacy'),
            subtitle: Text('Your ledger stays on this device.'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Accounts',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                TextButton(
                  onPressed: () => showAccountSheet(context),
                  child: const Text('Add'),
                ),
              ],
            ),
          ),
          ...accounts.map(
            (a) => ListTile(
              leading: Icon(
                a.kind == AccountKind.card
                    ? Icons.credit_card_outlined
                    : Icons.account_balance_outlined,
              ),
              title: Text(a.name),
              subtitle: Text(
                '${money(balances[a.id] ?? 0, symbol)}'
                '${a.last4.isEmpty ? '' : ' · ···· ${a.last4}'}'
                '${a.inBudget ? '' : ' · not in budget'}',
              ),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _confirmDeleteAccount(context, a),
              ),
              onTap: () => showAccountSheet(context, existing: a),
            ),
          ),
          const Divider(height: 32),
          ValueListenableBuilder<SyncStatus?>(
            valueListenable: smsSyncStatus,
            builder: (context, status, _) => Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.sms_outlined),
                  title: const Text('Bank SMS'),
                  subtitle: Text(
                    _smsStatus.isEmpty
                        ? 'Scan your inbox for past transactions'
                        : _smsStatus,
                  ),
                  trailing: FilledButton(
                    onPressed: status == null ? _scanSms : null,
                    child: const Text('Scan SMS inbox'),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.restart_alt_outlined),
                  title: const Text('Re-read SMS'),
                  subtitle: const Text('Fix wrongly parsed SMS transactions'),
                  onTap: status == null
                      ? () => _confirmRereadSms(context)
                      : null,
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.file_upload_outlined),
            title: const Text('Import statement'),
            subtitle: const Text('Choose a CSV or PDF, or paste rows'),
            onTap: _importStatement,
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Export transactions'),
            subtitle: const Text('Save every transaction as a CSV file'),
            onTap: _exportTransactions,
          ),
        ],
      );
    },
  );

  Future<void> _confirmDeleteAccount(BuildContext context, Account a) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete account?'),
        content: Text(
          'Transactions from ${a.name} stay in your ledger without an account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await TallyDatabase.instance.deleteAccount(a.id!);
      refreshApp();
    }
  }

  void _showPasteCsvSheet(BuildContext context) {
    final text = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          sheetBottomInset(sheetContext) + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Paste CSV',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 4),
            const Text('date, merchant, signed amount'),
            const SizedBox(height: 12),
            TextField(
              controller: text,
              minLines: 5,
              maxLines: 8,
              decoration: const InputDecoration(
                hintText: '2026-09-01, Groceries, -1240.00\n2026-09-02, Salary, 50000',
              ),
            ),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: () async {
                final rows = parseCsvStatement(text.text);
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                await _importRows(rows, 'pasted.csv');
              },
              child: const Text('Import'),
            ),
          ],
        ),
      ),
    );
  }
}

String _describeIngest(IngestReport report) =>
    '${report.inserted} added, ${report.duplicates} already saved, '
    '${report.ignored} skipped'
    '${report.failed > 0 ? ', ${report.failed} failed' : ''}';

/// Add or edit an account: name, the digits its SMS quote, kind, what the
/// bank shows right now, and whether it counts toward the budget.
void showAccountSheet(BuildContext context, {Account? existing}) {
  final name = TextEditingController(text: existing?.name ?? '');
  final last4 = TextEditingController(text: existing?.last4 ?? '');
  final opening = TextEditingController(
    text: existing == null
        ? ''
        : ((existing.reportedBalanceMinor ?? existing.openingBalanceMinor) /
                  100)
              .toStringAsFixed(2),
  );
  final initialBalance = opening.text;
  final minBalance = TextEditingController(
    text: existing?.minBalanceMinor == null
        ? ''
        : (existing!.minBalanceMinor! / 100).toStringAsFixed(2),
  );
  var inBudget = existing?.inBudget ?? true;
  var kind = existing?.kind ?? AccountKind.bank;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          sheetBottomInset(context) + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                existing == null ? 'Add account' : 'Edit account',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Account name'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: last4,
                maxLength: 40,
                keyboardType: TextInputType.text,
                decoration: const InputDecoration(
                  labelText: 'Last 4 digits (optional)',
                  hintText: 'Add debit card digits too, space separated',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 10),
              SegmentedButton<AccountKind>(
                segments: const [
                  ButtonSegment(
                    value: AccountKind.bank,
                    label: Text('Bank account'),
                  ),
                  ButtonSegment(
                    value: AccountKind.card,
                    label: Text('Credit card'),
                  ),
                ],
                selected: {kind},
                onSelectionChanged: (v) => setSheetState(() => kind = v.first),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: opening,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Balance',
                  helperText: 'What your bank shows right now',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: minBalance,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Minimum balance (optional)',
                  helperText:
                      'Tally warns you when the balance dips below this',
                ),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Count in budget'),
                value: inBudget,
                onChanged: (v) => setSheetState(() => inBudget = v),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    if (name.text.trim().isEmpty) return;
                    final typed = parseMoney(opening.text) ?? 0;
                    // A changed balance means "this is what I have now".
                    final reanchor =
                        existing == null || opening.text != initialBalance;
                    final account = Account(
                      id: existing?.id,
                      name: name.text.trim(),
                      last4: last4.text.trim(),
                      openingBalanceMinor:
                          existing?.openingBalanceMinor ?? typed,
                      reportedBalanceMinor: reanchor
                          ? typed
                          : existing.reportedBalanceMinor,
                      reportedAt: reanchor
                          ? DateTime.now()
                          : existing.reportedAt,
                      inBudget: inBudget,
                      minBalanceMinor: parseMoney(minBalance.text),
                      kind: kind,
                    );
                    if (existing == null) {
                      await TallyDatabase.instance.addAccountAndClaim(account);
                      await TallyDatabase.instance.linkSelfTransfers();
                    } else {
                      await TallyDatabase.instance.updateAccount(account);
                      if (account.last4.isNotEmpty &&
                          account.last4 != existing.last4) {
                        await TallyDatabase.instance.claimOrphans(
                          account.id!,
                          last4: account.last4,
                        );
                        await TallyDatabase.instance.linkSelfTransfers();
                      }
                    }
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                    refreshApp();
                  },
                  child: const Text('Save account'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Bottom sheet for both adding a transaction and editing one (tap any
/// tile). [existing] null means "add"; otherwise the sheet edits that row,
/// offers delete, and re-runs [confirmCategory] when the category changes so
/// the learner still sees the correction.
void showTransactionSheet(
  BuildContext context, {
  TallyTransaction? existing,
}) async {
  // An SMS ingest can rebuild the page this tile sits on while the accounts
  // load, which left the tap doing nothing at all. The root navigator and the
  // messenger outlive any page, so the sheet still opens.
  final navigator = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.of(context);
  final accounts = appState.accounts;
  if (accounts.isEmpty) {
    messenger.showSnackBar(
      const SnackBar(content: Text('Add an account first')),
    );
    return;
  }

  final merchant = TextEditingController(text: existing?.merchant ?? '');
  final amount = TextEditingController(
    text: existing == null
        ? ''
        : (existing.amountMinor / 100).toStringAsFixed(2),
  );
  var kind = existing?.kind ?? TransactionKind.expense;
  var category = existing?.category ?? kCategories.first;
  var accountId = existing?.accountId ?? accounts.first.id;
  var transferAccountId = existing?.transferAccountId;
  var exclude = existing?.excludeFromBudget ?? false;

  showModalBottomSheet(
    context: navigator.context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          sheetBottomInset(context) + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                existing == null ? 'Add transaction' : 'Edit transaction',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              SegmentedButton<TransactionKind>(
                segments: const [
                  ButtonSegment(
                    value: TransactionKind.expense,
                    label: Text('Expense'),
                  ),
                  ButtonSegment(
                    value: TransactionKind.income,
                    label: Text('Income'),
                  ),
                  ButtonSegment(
                    value: TransactionKind.transfer,
                    label: Text('Transfer'),
                  ),
                ],
                selected: {kind},
                onSelectionChanged: (v) => setSheetState(() => kind = v.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: merchant,
                autofocus: existing == null,
                decoration: InputDecoration(
                  labelText: kind == TransactionKind.transfer
                      ? 'Note (optional)'
                      : 'Merchant or description',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: amount,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'Amount'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                initialValue: accountId,
                decoration: const InputDecoration(labelText: 'Account'),
                items: accounts
                    .map(
                      (a) => DropdownMenuItem(value: a.id, child: Text(a.name)),
                    )
                    .toList(),
                onChanged: (v) => setSheetState(() => accountId = v),
              ),
              if (kind == TransactionKind.transfer) ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<int>(
                  initialValue: accounts.any((a) => a.id == transferAccountId)
                      ? transferAccountId
                      : null,
                  decoration: const InputDecoration(labelText: 'To account'),
                  items: accounts
                      .where((a) => a.id != accountId)
                      .map(
                        (a) =>
                            DropdownMenuItem(value: a.id, child: Text(a.name)),
                      )
                      .toList(),
                  onChanged: (v) => setSheetState(() => transferAccountId = v),
                ),
              ] else ...[
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: kCategories.contains(category)
                      ? category
                      : kCategories.first,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: kCategories
                      .map((v) => DropdownMenuItem(value: v, child: Text(v)))
                      .toList(),
                  onChanged: (v) =>
                      setSheetState(() => category = v ?? category),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text("Don't count in budget"),
                  value: exclude,
                  onChanged: (v) => setSheetState(() => exclude = v),
                ),
              ],
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    final minor = parseMoney(amount.text);
                    if (minor == null || accountId == null) return;
                    if (kind == TransactionKind.transfer &&
                        transferAccountId == null)
                      return;
                    final isTransfer = kind == TransactionKind.transfer;
                    final resolvedCategory = isTransfer
                        ? 'Transfers'
                        : category;
                    final resolvedMerchant = merchant.text.trim().isEmpty
                        ? (isTransfer ? 'Transfer' : merchant.text.trim())
                        : merchant.text.trim();
                    if (existing == null) {
                      await TallyDatabase.instance.add(
                        TallyTransaction(
                          id: null,
                          amountMinor: minor,
                          kind: kind,
                          occurredAt: DateTime.now(),
                          merchant: resolvedMerchant,
                          category: resolvedCategory,
                          accountId: accountId,
                          transferAccountId: isTransfer
                              ? transferAccountId
                              : null,
                          excludeFromBudget: isTransfer ? true : exclude,
                        ),
                      );
                    } else {
                      final updated = existing.copyWith(
                        merchant: resolvedMerchant,
                        amountMinor: minor,
                        kind: kind,
                        accountId: accountId,
                        category: resolvedCategory,
                        excludeFromBudget: isTransfer ? true : exclude,
                        transferAccountId: isTransfer
                            ? transferAccountId
                            : null,
                        clearTransferAccount: !isTransfer,
                      );
                      if (!isTransfer &&
                          (category != existing.category ||
                              existing.needsReview))
                        await confirmCategory(updated, category);
                      else
                        await TallyDatabase.instance.updateTransaction(updated);
                    }
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                    refreshApp();
                  },
                  child: const Text('Save transaction'),
                ),
              ),
              if (existing?.smsBody?.isNotEmpty ?? false) ...[
                const SizedBox(height: 8),
                Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Original message'),
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    expandedAlignment: Alignment.centerLeft,
                    children: [
                      Text(
                        existing!.smsBody!,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
              if (existing != null) ...[
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete'),
                    onPressed: () async {
                      await TallyDatabase.instance.delete(existing.id!);
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                      refreshApp();
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
