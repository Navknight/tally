import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'app/theme.dart';
import 'app/ui.dart';
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

/// Shown at the foot of Settings. Kept in step with `pubspec.yaml`'s
/// `version:` by hand - a package to read the real one is a dependency for a
/// single line of text.
const kAppVersion = '0.5.0';

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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 28),
              Container(
                width: 60,
                height: 60,
                decoration: ShapeDecoration(
                  color: scheme.primary,
                  shape: LipBorder(
                    radius: 20,
                    depth: 5,
                    lip: lipOf(scheme.primary),
                  ),
                ),
                child: Icon(
                  Icons.account_balance_wallet_rounded,
                  size: 28,
                  color: scheme.onPrimary,
                ),
              ),
              const SizedBox(height: 26),
              Text(
                'A clearer view\nof your money.',
                style: text.displaySmall?.copyWith(fontSize: 38),
              ),
              const SizedBox(height: 12),
              Text(
                'Everything stays on this device. Start with the account you '
                'spend from, and Tally keeps up from your bank texts.',
                style: text.bodyLarge?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 32),
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
                  hintText: 'Debit card digits too, space separated',
                  counterText: '',
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  SizedBox(
                    width: 82,
                    child: TextField(
                      controller: _currency,
                      textAlign: TextAlign.center,
                      decoration: const InputDecoration(labelText: 'Symbol'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _amount,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Balance right now',
                        hintText: '0.00',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'You can import a statement or scan your SMS inbox from '
                'Settings once you are in.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 26),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _saving ? null : _finish,
                  child: const Padding(
                    padding: EdgeInsets.all(13),
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
    HomeScreen(
      onOpenInsights: () => _showTab(2),
      onOpenActivity: () => _showTab(1),
    ),
    const TransactionsScreen(),
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
        body: IndexedStack(
          index: _tab,
          children: [
            for (var i = 0; i < _pages.length; i++)
              if (_visited.contains(i)) _pages[i] else const SizedBox.shrink(),
          ],
        ),
        floatingActionButton: _tab < 2
            ? FloatingActionButton(
                onPressed: () => showTransactionSheet(context),
                tooltip: 'Add a transaction',
                child: const Icon(Icons.add_rounded, size: 28),
              )
            : null,
        // The sync strip sits above the bar rather than above the title, so
        // a message arriving mid-scroll never shoves the page down.
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
              child: status == null
                  ? const SizedBox(width: double.infinity)
                  : _SyncStrip(status: status),
            ),
            NavigationBar(
              selectedIndex: _tab,
              onDestinationSelected: _showTab,
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.cottage_outlined),
                  selectedIcon: Icon(Icons.cottage_rounded),
                  label: 'Home',
                ),
                NavigationDestination(
                  icon: Icon(Icons.receipt_long_outlined),
                  selectedIcon: Icon(Icons.receipt_long_rounded),
                  label: 'Activity',
                ),
                NavigationDestination(
                  icon: Icon(Icons.donut_small_outlined),
                  selectedIcon: Icon(Icons.donut_small_rounded),
                  label: 'Insights',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings_rounded),
                  label: 'Settings',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// What the SMS reader is doing right now, shown only while it runs.
class _SyncStrip extends StatelessWidget {
  const _SyncStrip({required this.status});
  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerLow,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 9, 20, 9),
            child: Row(
              children: [
                SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(width: 11),
                Text(
                  'Reading messages · ${status.done} of ${status.total}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          LinearProgressIndicator(
            minHeight: 2,
            value: status.total == 0 ? null : status.done / status.total,
            backgroundColor: Colors.transparent,
          ),
        ],
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
  const HomeScreen({
    super.key,
    required this.onOpenInsights,
    required this.onOpenActivity,
  });
  final VoidCallback onOpenInsights;
  final VoidCallback onOpenActivity;

  @override
  Widget build(BuildContext context) => TallyPage(
    title: 'Tally',
    builder: (context, state) {
      final symbol = state.symbol;
      final recent = state.recent;
      return ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          110 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          RepaintBoundary(
            child: PeriodCard(
              spent: state.spent,
              budget: state.budgetMinor,
              period: state.period,
              symbol: symbol,
              onOpen: onOpenInsights,
            ),
          ),
          const SizedBox(height: 18),
          RepaintBoundary(
            child: SpendStrip(
              byDay: state.lastWeek,
              symbol: symbol,
              onTap: onOpenInsights,
            ),
          ),
          SectionHeading(
            title: 'Accounts',
            caption: state.accounts.isEmpty
                ? null
                : '${money(state.totalBalance, symbol)} available',
          ),
          AccountRail(
            accounts: state.accounts,
            balances: state.balances,
            symbol: symbol,
          ),
          ...state.detections.map(
            (d) => Padding(
              padding: const EdgeInsets.only(top: 10),
              child: DetectedAccountCard(detection: d),
            ),
          ),
          ...state.lowAccounts.map(
            (a) => Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _WarningCard(
                message:
                    '${a.name} is below its minimum of '
                    '${moneyShort(a.minBalanceMinor!, symbol)}',
              ),
            ),
          ),
          if (state.review.isNotEmpty) ...[
            SectionHeading(
              title: 'Needs review',
              caption: state.review.length == 1
                  ? "Tally wasn't sure how to label this one."
                  : "Tally wasn't sure how to label these ${state.review.length}.",
              // Only the first few belong on Home. A queue of fifty turns the
              // screen into a work list and makes it build fifty rows before
              // it can paint one.
              action: state.review.length > _reviewOnHome ? 'Review all' : null,
              onAction: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const ReviewScreen()),
              ),
            ),
            ...state.review
                .take(_reviewOnHome)
                .map(
                  (t) => TransactionTile(
                    transaction: t,
                    symbol: symbol,
                    onTap: () => showTransactionSheet(context, existing: t),
                  ),
                ),
          ],
          SectionHeading(
            title: 'Recent',
            action: recent.isEmpty ? null : 'See all',
            onAction: onOpenActivity,
          ),
          if (recent.isEmpty)
            DashedTile(
              onTap: () => showTransactionSheet(context),
              padding: const EdgeInsets.symmetric(vertical: 26),
              child: Text(
                'Nothing yet. Add one, or scan your SMS inbox.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ...recent.map(
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

/// How many rows waiting on a label Home shows before handing the rest to
/// [ReviewScreen].
const _reviewOnHome = 3;

/// The whole review queue, one row at a time. Reached from Home when there
/// are more than a handful; labelling one drops it off the list.
class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Needs review')),
    body: ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final rows = appState.review;
        if (rows.isEmpty)
          return const EmptyState(
            icon: Icons.check_circle_outline_rounded,
            title: 'All labelled',
            message: 'Nothing is waiting on you.',
          );
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            24 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          itemCount: rows.length,
          itemBuilder: (context, i) => TransactionTile(
            transaction: rows[i],
            symbol: appState.symbol,
            onTap: () => showTransactionSheet(context, existing: rows[i]),
          ),
        );
      },
    ),
  );
}

/// The screen's one loud element: what this period has cost so far, the limit
/// it is running against, and a marker for where an even pace would have you
/// by today. Tapping opens Insights, which breaks the same period down; the
/// pencil edits the limit without leaving Home.
class PeriodCard extends StatelessWidget {
  const PeriodCard({
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
    final ahead = budget > 0 && !over && spent <= budget * pace;
    return Container(
      decoration: raisedDecoration(
        scheme,
        radius: Corners.hero,
        edge: over ? scheme.error : null,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onOpen,
          borderRadius: BorderRadius.circular(Corners.hero),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 16, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Spent since ${_dayMonth(period.start)}',
                        style: text.bodySmall,
                      ),
                    ),
                    _Pill(
                      label: daysLeft <= 0
                          ? 'Last day'
                          : daysLeft == 1
                          ? '1 day left'
                          : '$daysLeft days left',
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      iconSize: 18,
                      color: scheme.onSurfaceVariant,
                      icon: const Icon(Icons.tune_rounded),
                      tooltip: 'Budget settings',
                      onPressed: () => showBudgetSheet(context),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                // Seven-figure spends would run off the edge at this size.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: AnimatedMoney(
                    minor: spent,
                    symbol: symbol,
                    style: text.displayMedium?.copyWith(
                      color: over ? scheme.error : null,
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                if (budget <= 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton(
                      onPressed: () => showBudgetSheet(context),
                      child: const Text('Set a limit'),
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      Icon(
                        over
                            ? Icons.trending_up_rounded
                            : ahead
                            ? Icons.check_circle_rounded
                            : Icons.schedule_rounded,
                        size: 16,
                        color: over
                            ? scheme.error
                            : ahead
                            ? scheme.primary
                            : scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          over
                              ? '${money(spent - budget, symbol)} over ${moneyShort(budget, symbol)}'
                              : '${money(budget - spent, symbol)} left of ${moneyShort(budget, symbol)}',
                          style: text.bodyMedium?.copyWith(
                            color: over ? scheme.error : scheme.onSurface,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  PaceBar(
                    fraction: (spent / budget).clamp(0, 1).toDouble(),
                    pace: pace,
                    over: over,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    over
                        ? 'Past the limit with $daysLeft to go'
                        : ahead
                        ? 'Under an even pace, which is ${moneyShort((budget * pace).round(), symbol)} by today'
                        : 'An even pace puts you at ${moneyShort((budget * pace).round(), symbol)} by today',
                    style: text.bodySmall,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small outlined label, used where a figure needs a qualifier next to it.
class _Pill extends StatelessWidget {
  const _Pill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: scheme.onSurfaceVariant),
      ),
    );
  }
}

class _WarningCard extends StatelessWidget {
  const _WarningCard({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: raisedDecoration(scheme, edge: scheme.error),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 20, color: scheme.error),
          const SizedBox(width: 12),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

/// Accounts as a row of cards you can push along, each opening its own sheet.
/// A balance is a thing you hold, so it gets an object to sit on; the ledger
/// rows below stay a list. The last tile is an empty slot waiting to be
/// filled rather than a button that looks like every other button.
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
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        padding: EdgeInsets.zero,
        itemCount: accounts.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) => index == accounts.length
            ? SizedBox(
                width: accounts.isEmpty ? 220 : 130,
                child: DashedTile(
                  onTap: () => showAccountSheet(context),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.add_rounded,
                        size: 22,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Add account',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              )
            : _AccountCard(
                account: accounts[index],
                balance: balances[accounts[index].id] ?? 0,
                symbol: symbol,
              ),
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({
    required this.account,
    required this.balance,
    required this.symbol,
  });
  final Account account;
  final int balance;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final card = account.kind == AccountKind.card;
    final low =
        !card &&
        account.minBalanceMinor != null &&
        balance < account.minBalanceMinor!;
    return SizedBox(
      width: 168,
      child: Container(
        decoration: raisedDecoration(scheme),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: () => showAccountSheet(context, existing: account),
            borderRadius: BorderRadius.circular(Corners.card),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 11, 14, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Icon(
                        card
                            ? Icons.credit_card_rounded
                            : Icons.account_balance_rounded,
                        size: 14,
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
                      style: text.titleLarge?.copyWith(
                        fontFeatures: tabular,
                        color: low ? scheme.error : null,
                      ),
                    ),
                  ),
                  Text(
                    account.last4.isEmpty
                        ? (card ? 'Card' : 'Bank account')
                        : '···· ${account.last4}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontFeatures: tabular,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
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
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      decoration: raisedDecoration(scheme, edge: scheme.primary),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(Corners.tile),
            ),
            child: Icon(
              detection.kind == AccountKind.card
                  ? Icons.credit_card_rounded
                  : Icons.account_balance_rounded,
              size: 19,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(detection.suggestedName, style: text.titleMedium),
                Text(
                  'Seen in ${detection.messageCount} messages',
                  style: text.bodySmall,
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: _dismiss,
            tooltip: 'Dismiss',
            iconSize: 20,
            color: scheme.onSurfaceVariant,
            icon: const Icon(Icons.close_rounded),
          ),
          FilledButton(
            onPressed: () => _add(context),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 40)),
            child: const Text('Track'),
          ),
        ],
      ),
    );
  }
}

class TransactionsScreen extends StatelessWidget {
  const TransactionsScreen({super.key});

  /// Jumps the ledger back to a chosen day instead of paging to it.
  Future<void> _pickDay(BuildContext context) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: appState.anchor ?? now,
      firstDate: appState.oldest ?? DateTime(now.year - 5),
      lastDate: now,
      helpText: 'Jump to a day',
    );
    if (picked != null) await appState.jumpTo(picked);
  }

  @override
  Widget build(BuildContext context) => TallyPage(
    title: 'Activity',
    actions: [
      Builder(
        builder: (context) => IconButton(
          icon: const Icon(Icons.event_rounded),
          tooltip: 'Jump to a day',
          onPressed: () => _pickDay(context),
        ),
      ),
      const SizedBox(width: 4),
    ],
    builder: (context, state) {
      if (state.ledger.isEmpty && state.anchor == null)
        return EmptyState(
          icon: Icons.receipt_long_outlined,
          title: 'Nothing logged yet',
          message:
              'Transactions land here as your bank texts arrive. You can '
              'always add one by hand.',
          action: 'Add a transaction',
          onAction: () => showTransactionSheet(context),
        );
      return CustomScrollView(
        slivers: [
          if (state.anchor != null)
            SliverToBoxAdapter(child: _AnchorBanner(day: state.anchor!)),
          if (state.ledger.isEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
                child: Text(
                  'Nothing on or before that day.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          // One pinned heading per day, so the date the rows belong to stays
          // on screen while that day scrolls past.
          for (final day in state.ledgerDays)
            SliverMainAxisGroup(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _DayHeaderDelegate(
                    date: day.day,
                    spent: day.spent,
                    symbol: state.symbol,
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  sliver: SliverList.builder(
                    itemCount: day.rows.length,
                    itemBuilder: (context, i) => _DismissibleRow(
                      transaction: day.rows[i],
                      symbol: state.symbol,
                    ),
                  ),
                ),
              ],
            ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              20,
              16,
              20,
              110 + MediaQuery.viewPaddingOf(context).bottom,
            ),
            sliver: SliverToBoxAdapter(
              child: state.hasMore
                  ? Center(
                      child: OutlinedButton(
                        onPressed: () => unawaited(state.loadMore()),
                        child: const Text('Load more'),
                      ),
                    )
                  : Center(
                      child: Text(
                        '${state.ledger.length} transactions',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
            ),
          ),
        ],
      );
    },
  );
}

/// A ledger row you can swipe away. Split out so the list builder stays cheap
/// and each row repaints on its own.
class _DismissibleRow extends StatelessWidget {
  const _DismissibleRow({required this.transaction, required this.symbol});
  final TallyTransaction transaction;
  final String symbol;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey(transaction.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) async {
        await TallyDatabase.instance.delete(transaction.id!);
        refreshApp();
      },
      background: Container(
        alignment: Alignment.centerRight,
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.only(right: 20),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(Corners.card),
        ),
        child: Icon(
          Icons.delete_outline_rounded,
          color: scheme.onErrorContainer,
        ),
      ),
      child: TransactionTile(
        transaction: transaction,
        symbol: symbol,
        showDate: false,
        onTap: () => showTransactionSheet(context, existing: transaction),
      ),
    );
  }
}

/// Says the ledger is showing a chosen day rather than today, and gets back.
class _AnchorBanner extends StatelessWidget {
  const _AnchorBanner({required this.day});
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
      child: Container(
        decoration: raisedDecoration(scheme, edge: scheme.primary),
        padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        child: Row(
          children: [
            Icon(Icons.event_rounded, size: 17, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Showing ${_dayMonth(day)} ${day.year} and earlier',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            TextButton(
              onPressed: () => unawaited(appState.jumpTo(null)),
              child: const Text('Back to today'),
            ),
          ],
        ),
      ),
    );
  }
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

/// Splits the ledger into days, each headed by what that day cost. The
/// heading is the only place spend is summed outside the budget itself.
class _DayHeaderDelegate extends SliverPersistentHeaderDelegate {
  const _DayHeaderDelegate({
    required this.date,
    required this.spent,
    required this.symbol,
  });
  final DateTime date;
  final int spent;
  final String symbol;

  static const _height = 46.0;

  @override
  double get minExtent => _height;
  @override
  double get maxExtent => _height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) {
    final theme = Theme.of(context);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final label = date == today
        ? 'Today'
        : date == today.subtract(const Duration(days: 1))
        ? 'Yesterday'
        : '${_weekdays[date.weekday - 1]} ${_dayMonth(date)}';
    return Container(
      color: theme.colorScheme.surface,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (spent > 0)
            Text(
              money(spent, symbol),
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: tabular,
              ),
            ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_DayHeaderDelegate old) =>
      old.date != date || old.spent != spent || old.symbol != symbol;
}

/// One ledger row: the category mark, who it was, and what it cost. A row
/// still waiting on a label says so in the accent rather than naming a
/// category Tally only guessed at.
class TransactionTile extends StatelessWidget {
  const TransactionTile({
    super.key,
    required this.transaction,
    required this.symbol,
    this.onTap,
    this.showDate = true,
  });
  final TallyTransaction transaction;
  final String symbol;
  final VoidCallback? onTap;

  /// Activity groups rows under a day heading, so repeating the date on every
  /// row there says nothing.
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final positive = transaction.kind == TransactionKind.income;
    final isTransfer = transaction.kind == TransactionKind.transfer;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final review = transaction.needsReview;
    final sign = isTransfer ? '' : (positive ? '+' : '-');
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Corners.card),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
          child: Row(
            children: [
              CategoryAvatar(category: transaction.category),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      transaction.merchant,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyLarge,
                    ),
                    const SizedBox(height: 1),
                    Row(
                      children: [
                        if (review)
                          Icon(
                            Icons.label_important_outline_rounded,
                            size: 13,
                            color: scheme.primary,
                          ),
                        if (review) const SizedBox(width: 3),
                        Flexible(
                          child: Text(
                            review ? 'Needs a label' : transaction.category,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.bodySmall?.copyWith(
                              color: review ? scheme.primary : null,
                              fontWeight: review
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                        if (showDate)
                          Text(
                            ' · ${transaction.occurredAt.day}/${transaction.occurredAt.month}',
                            style: text.bodySmall,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '$sign${money(transaction.amountMinor, symbol)}',
                style: text.titleMedium?.copyWith(
                  fontFeatures: tabular,
                  color: positive
                      ? scheme.primary
                      : isTransfer
                      ? scheme.onSurfaceVariant
                      : null,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The budget, edited where it is read rather than on a tab of its own: the
/// limit, the day the period turns over, and which accounts count toward it.
void showBudgetSheet(BuildContext context) {
  final controller = TextEditingController(
    text: appState.budgetMinor == 0
        ? ''
        : (appState.budgetMinor / 100).toStringAsFixed(0),
  );
  final messenger = ScaffoldMessenger.of(context);
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) {
        final state = appState;
        final text = Theme.of(sheetContext).textTheme;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            sheetBottomInset(sheetContext) + 20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Budget', style: text.headlineSmall),
              const SizedBox(height: 4),
              Text(
                'One number is enough. Tally keeps the rest simple.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 22),
              TextField(
                controller: controller,
                autofocus: state.budgetMinor == 0,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: text.displaySmall,
                decoration: InputDecoration(
                  prefixText: '${state.symbol} ',
                  prefixStyle: text.displaySmall?.copyWith(
                    color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
                  ),
                  labelText: 'Spending limit for the period',
                  contentPadding: const EdgeInsets.fromLTRB(16, 26, 16, 16),
                ),
              ),
              const SizedBox(height: 18),
              Text('Period starts on', style: text.titleMedium),
              const SizedBox(height: 2),
              Text(
                'Runs from this day of the month to the day before it next month.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                initialValue: state.startDay,
                items: List.generate(
                  28,
                  (i) => DropdownMenuItem(
                    value: i + 1,
                    child: Text('Day ${i + 1}'),
                  ),
                ),
                onChanged: (v) async {
                  if (v == null) return;
                  await TallyDatabase.instance.setSetting(
                    'budget_start_day',
                    '$v',
                  );
                  refreshApp();
                },
              ),
              if (state.accounts.isNotEmpty) ...[
                const SizedBox(height: 22),
                Text('Counted accounts', style: text.titleMedium),
                const SizedBox(height: 2),
                Text(
                  'Turn one off to leave its spending out of the budget.',
                  style: text.bodySmall,
                ),
                ...state.accounts.map(
                  (a) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: Text(a.name),
                    value: a.inBudget,
                    onChanged: (v) async {
                      await TallyDatabase.instance.updateAccount(
                        a.copyWith(inBudget: v),
                      );
                      await appState.load();
                      setSheetState(() {});
                    },
                  ),
                ),
              ],
              const SizedBox(height: 22),
              FilledButton(
                onPressed: () async {
                  await TallyDatabase.instance.setSetting(
                    'monthly_budget',
                    '${parseMoney(controller.text) ?? 0}',
                  );
                  refreshApp();
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Budget saved')),
                  );
                },
                child: const Text('Save budget'),
              ),
            ],
          ),
        );
      },
    ),
  ).whenComplete(controller.dispose);
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _smsStatus = '';

  /// Google Play's user-data policy wants the app to say what it will read
  /// and why *before* the system permission prompt, in its own words. It is
  /// the honest thing to show anyway, so it runs on every build.
  Future<bool> _disclose(BuildContext context) async {
    final text = Theme.of(context).textTheme;
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(Icons.sms_outlined),
            title: const Text('Tally needs to read your SMS'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'To keep your ledger up to date, Tally reads the '
                  'transaction messages your bank and UPI apps send you, and '
                  'records the amount, the merchant and the account.',
                  style: text.bodyMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  'Messages that are not about a transaction are skipped and '
                  'never stored. Nothing is uploaded: Tally has no internet '
                  'permission, no account and no analytics.',
                  style: text.bodyMedium,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Not now'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Continue'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Future<void> _scanSms() async {
    if (!await _disclose(context)) return;
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
      final symbol = state.symbol;
      return ListView(
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          40 + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: [
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: Icons.lock_outline_rounded,
                title: 'Everything stays here',
                subtitle:
                    'Tally has no network access. Your ledger lives in one '
                    'file on this device.',
              ),
            ],
          ),
          SectionHeading(
            title: 'Accounts',
            action: 'Add',
            onAction: () => showAccountSheet(context),
          ),
          if (state.accounts.isEmpty)
            DashedTile(
              onTap: () => showAccountSheet(context),
              padding: const EdgeInsets.symmetric(vertical: 22),
              child: Text(
                'No accounts yet',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            )
          else
            _SettingsGroup(
              children: [
                for (final a in state.accounts)
                  _SettingsRow(
                    icon: a.kind == AccountKind.card
                        ? Icons.credit_card_rounded
                        : Icons.account_balance_rounded,
                    title: a.name,
                    subtitle:
                        '${money(state.balances[a.id] ?? 0, symbol)}'
                        '${a.last4.isEmpty ? '' : ' · ···· ${a.last4}'}'
                        '${a.inBudget ? '' : ' · not in budget'}',
                    onTap: () => showAccountSheet(context, existing: a),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, size: 20),
                      tooltip: 'Delete account',
                      onPressed: () => _confirmDeleteAccount(context, a),
                    ),
                  ),
              ],
            ),
          const SectionHeading(title: 'Budget'),
          _SettingsGroup(
            children: [
              _SettingsRow(
                icon: Icons.savings_outlined,
                title: state.hasBudget
                    ? '${moneyShort(state.budgetMinor, symbol)} a period'
                    : 'No limit set',
                subtitle:
                    'Starts on day ${state.startDay} · '
                    '${state.accounts.where((a) => a.inBudget).length} of '
                    '${state.accounts.length} accounts counted',
                onTap: () => showBudgetSheet(context),
              ),
            ],
          ),
          const SectionHeading(title: 'Data'),
          ValueListenableBuilder<SyncStatus?>(
            valueListenable: smsSyncStatus,
            builder: (context, status, _) => _SettingsGroup(
              children: [
                _SettingsRow(
                  icon: Icons.sms_outlined,
                  title: 'Scan SMS inbox',
                  subtitle: _smsStatus.isEmpty
                      ? 'Read past bank messages into the ledger'
                      : _smsStatus,
                  muted: status != null,
                  onTap: status == null ? _scanSms : null,
                ),
                _SettingsRow(
                  icon: Icons.restart_alt_rounded,
                  title: 'Re-read SMS',
                  subtitle: 'Reparse stored messages after a parser fix',
                  muted: status != null,
                  onTap: status == null
                      ? () => _confirmRereadSms(context)
                      : null,
                ),
                _SettingsRow(
                  icon: Icons.file_upload_outlined,
                  title: 'Import statement',
                  subtitle: 'Choose a CSV or PDF, or paste rows',
                  onTap: _importStatement,
                ),
                _SettingsRow(
                  icon: Icons.file_download_outlined,
                  title: 'Export transactions',
                  subtitle: 'Save the whole ledger as a CSV file',
                  onTap: _exportTransactions,
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Center(
            child: Text(
              'Tally $kAppVersion',
              style: Theme.of(context).textTheme.bodySmall,
            ),
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
        padding: EdgeInsets.fromLTRB(20, 4, 20, sheetBottomInset(context) + 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                existing == null ? 'Add account' : 'Edit account',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 18),
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
        padding: EdgeInsets.fromLTRB(20, 4, 20, sheetBottomInset(context) + 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                existing == null ? 'Add transaction' : 'Edit transaction',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 18),
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
                Text(
                  'Category',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                CategoryPicker(
                  value: kCategories.contains(category)
                      ? category
                      : kCategories.first,
                  onChanged: (v) => setSheetState(() => category = v),
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

/// Settings rows sharing one raised card, divided by hairlines - a list of
/// related switches reads as one object rather than four loose tiles.
class _SettingsGroup extends StatelessWidget {
  const _SettingsGroup({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Container(
    decoration: raisedDecoration(Theme.of(context).colorScheme),
    clipBehavior: Clip.antiAlias,
    child: Column(
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i != 0) const Divider(height: 1, indent: 56),
          children[i],
        ],
      ],
    ),
  );
}

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
    this.muted = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// Greys the row out while its action is unavailable. A row that simply
  /// states something has no action to disable, so it stays at full strength.
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final enabled = !muted;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 13, trailing == null ? 16 : 6, 13),
        child: Row(
          children: [
            Icon(
              icon,
              size: 20,
              color: enabled ? scheme.onSurfaceVariant : scheme.outline,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: text.titleMedium?.copyWith(
                      color: enabled ? null : scheme.outline,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(subtitle, style: text.bodySmall),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}
