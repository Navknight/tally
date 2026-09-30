import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'app/theme.dart';
import 'app/selection.dart';
import 'app/ui.dart';
import 'core/budget_period.dart';
import 'core/money.dart';
import 'data/tally_database.dart';
import 'insights.dart';
import 'models/account.dart';
import 'models/banks.dart';
import 'models/categories.dart';
import 'models/category_def.dart';
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
    await loadBankLogos(rootBundle.loadString);
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
    InsightsScreen(onOpenActivity: () => _showTab(1)),
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

/// A tab.
///
/// Every screen is one scroll view with a large title that shrinks into a bar
/// as you go - the thing iOS gets for free and Android apps usually skip,
/// which is most of why they feel less settled. Screens hand back slivers so
/// the title, pull-to-refresh and the pinned day headings all live in the
/// same scroll, instead of each screen bolting its own app bar on top.
///
/// The spinner shows only before the first read finishes; after that a
/// refresh repaints in place rather than emptying the screen.
class TallyPage extends StatelessWidget {
  const TallyPage({
    super.key,
    required this.title,
    required this.slivers,
    this.actions,
    this.titleWidget,
  });

  final String title;
  final List<Widget> Function(BuildContext, AppState) slivers;
  final List<Widget>? actions;

  /// Replaces the title, for a screen that puts a search field there.
  final Widget? titleWidget;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: ListenableBuilder(
      listenable: appState,
      builder: (context, _) => !appState.loaded
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: appState.load,
              child: CustomScrollView(
                slivers: [
                  SliverAppBar.medium(
                    pinned: true,
                    title: titleWidget ?? Text(title),
                    actions: actions,
                    expandedHeight: titleWidget == null ? null : 0,
                    toolbarHeight: kToolbarHeight,
                  ),
                  ...slivers(context, appState),
                ],
              ),
            ),
    ),
  );
}

/// Wraps ordinary widgets as one sliver with the page's side gutters, so a
/// screen that is just a column of things does not have to think in slivers.
class PageColumn extends StatelessWidget {
  const PageColumn({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.fromLTRB(20, 0, 20, 0),
  });
  final List<Widget> children;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => SliverPadding(
    padding: padding,
    sliver: SliverList.list(children: children),
  );
}

/// The trailing gap every tab needs so its last row clears the floating
/// button and the navigation bar.
class PageBottomGap extends StatelessWidget {
  const PageBottomGap({super.key});

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: SizedBox(height: 110 + MediaQuery.viewPaddingOf(context).bottom),
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
    slivers: (context, state) {
      final symbol = state.symbol;
      final recent = state.recent;
      return [
        PageColumn(
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
            if (!state.smsScanned) ...[
              const SizedBox(height: 14),
              const _ScanInvite(),
            ],
            const SizedBox(height: 18),
            RepaintBoundary(
              child: SpendStrip(
                byDay: state.lastWeek,
                symbol: symbol,
                onTap: (day) async {
                  await appState.showDay(day);
                  onOpenActivity();
                },
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
              onOpenAccount: (account) async {
                await appState.setFilter(LedgerFilter(accountId: account.id));
                onOpenActivity();
              },
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
                action: state.review.length > _reviewOnHome
                    ? 'Review all'
                    : null,
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
        ),
        const PageBottomGap(),
      ];
    },
  );
}

/// How many rows waiting on a label Home shows before handing the rest to
/// [ReviewScreen].
const _reviewOnHome = 3;

/// The whole review queue, one row at a time. Reached from Home when there
/// are more than a handful; labelling one drops it off the list.
/// The whole review queue, with the same batch tools as Activity: a hundred
/// rows that all want the same label is exactly when picking them one at a
/// time stops being reasonable.
class ReviewScreen extends StatefulWidget {
  const ReviewScreen({super.key});

  @override
  State<ReviewScreen> createState() => _ReviewScreenState();
}

class _ReviewScreenState extends State<ReviewScreen>
    with LedgerSelection<ReviewScreen> {
  @override
  List<TallyTransaction> get selectableRows => appState.review;

  @override
  void onSelectionApplied() => refreshApp();

  @override
  Future<String?> pickCategory(BuildContext context) =>
      showCategorySheet(context);

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !selecting,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) clearSelection();
    },
    child: ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final rows = appState.review;
        return Scaffold(
          appBar: AppBar(
            title: selecting
                ? _SelectionTitle(ids: selected)
                : const Text('Needs review'),
            actions: selecting
                ? [
                    Builder(
                      builder: (context) =>
                          Row(children: selectionActions(context)),
                    ),
                  ]
                : null,
          ),
          body: rows.isEmpty
              ? const EmptyState(
                  icon: Icons.check_circle_outline_rounded,
                  title: 'All labelled',
                  message: 'Nothing is waiting on you.',
                )
              : Column(
                  children: [
                    if (!selecting)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${rows.length} to label. Tap one to pick a '
                                'category, or hold to choose several.',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            TextButton(
                              onPressed: () => unawaited(selectAll()),
                              child: const Text('Select all'),
                            ),
                          ],
                        ),
                      ),
                    Expanded(
                      child: ListView.builder(
                        padding: EdgeInsets.fromLTRB(
                          20,
                          4,
                          20,
                          24 + MediaQuery.viewPaddingOf(context).bottom,
                        ),
                        itemCount: rows.length,
                        itemBuilder: (context, i) {
                          final row = rows[i];
                          return TransactionTile(
                            transaction: row,
                            symbol: appState.symbol,
                            selected: selected.contains(row.id),
                            onTap: row.id == null
                                ? null
                                : selecting
                                ? () => toggleSelected(row.id!)
                                : () => showQuickLabelSheet(context, row),
                            onLongPress: row.id == null
                                ? null
                                : () => toggleSelected(row.id!),
                          );
                        },
                      ),
                    ),
                  ],
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

/// Until the inbox has been read once, Tally is just a manual ledger and the
/// one thing that makes it different sits three taps away in Settings. This
/// says so on the screen the user is already looking at.
class _ScanInvite extends StatefulWidget {
  const _ScanInvite();

  @override
  State<_ScanInvite> createState() => _ScanInviteState();
}

class _ScanInviteState extends State<_ScanInvite> {
  bool _busy = false;

  Future<void> _scan() async {
    if (!await showSmsDisclosure(context)) return;
    setState(() => _busy = true);
    final granted = await AndroidBridge.requestSmsPermission();
    if (granted) {
      await ingestHistoricSms();
      await recategorizeReviewQueue();
      refreshApp();
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('SMS access was not granted.')),
      );
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      decoration: raisedDecoration(scheme, edge: scheme.primary),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome_rounded, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Text('Let Tally fill this in', style: text.titleMedium),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Your bank already texts you every time money moves. Read those '
            'messages once and the ledger builds itself.',
            style: text.bodySmall,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton(
                onPressed: _busy ? null : _scan,
                style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
                child: Text(_busy ? 'Reading…' : 'Scan my inbox'),
              ),
              const SizedBox(width: 8),
              Text('Stays on this device', style: text.bodySmall),
            ],
          ),
        ],
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
    required this.onOpenAccount,
  });
  final List<Account> accounts;
  final Map<int, int> balances;
  final String symbol;

  /// Tapping a card shows that account's transactions, which is what a
  /// balance makes you want to do; editing it is behind the card's own
  /// button, so the common intent is the plain tap.
  final void Function(Account account) onOpenAccount;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      // Tall enough for the name row (which now carries the edit button),
      // the balance and the digits without clipping.
      height: 106,
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
                onOpen: () => onOpenAccount(accounts[index]),
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
    required this.onOpen,
  });
  final Account account;
  final int balance;
  final String symbol;
  final VoidCallback onOpen;

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
            onTap: onOpen,
            onLongPress: () => showAccountSheet(context, existing: account),
            borderRadius: BorderRadius.circular(Corners.card),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 6, 6, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      BankMark(name: account.name, size: 22),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          account.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall,
                        ),
                      ),
                      if (card)
                        Icon(
                          Icons.credit_card_rounded,
                          size: 13,
                          color: scheme.onSurfaceVariant,
                        ),
                      IconButton(
                        icon: const Icon(Icons.more_horiz_rounded),
                        iconSize: 17,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 30,
                          minHeight: 30,
                        ),
                        color: scheme.onSurfaceVariant,
                        tooltip: 'Edit account',
                        onPressed: () =>
                            showAccountSheet(context, existing: account),
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
          BankMark(name: detection.bank, size: 38),
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

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen>
    with LedgerSelection<TransactionsScreen> {
  final _search = TextEditingController();
  Timer? _debounce;
  bool _searching = false;

  @override
  List<TallyTransaction> get selectableRows => appState.ledger;

  /// "All" here means everything the filter matches, not the sixty rows that
  /// happen to be loaded - picking a category and selecting all of it is the
  /// whole point.
  @override
  Future<List<int>> allSelectableIds() => appState.filteredIds();

  @override
  void onSelectionApplied() => refreshApp();

  @override
  Future<String?> pickCategory(BuildContext context) =>
      showCategorySheet(context);

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// Types run together into one query: a re-read per keystroke would hit the
  /// database five times for a three-letter merchant.
  void _onQueryChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 260), () {
      unawaited(appState.setFilter(appState.filter.copyWith(text: value)));
    });
  }

  void _closeSearch() {
    _search.clear();
    setState(() => _searching = false);
    unawaited(appState.setFilter(appState.filter.copyWith(text: '')));
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !selecting,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) clearSelection();
    },
    child: _body(context),
  );

  Widget _body(BuildContext context) => TallyPage(
    title: 'Activity',
    titleWidget: selecting
        ? _SelectionTitle(ids: selected)
        : _searching
        ? TextField(
            controller: _search,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onChanged: _onQueryChanged,
            style: Theme.of(context).textTheme.titleLarge,
            decoration: const InputDecoration(
              filled: false,
              border: InputBorder.none,
              focusedBorder: InputBorder.none,
              hintText: 'Search merchants',
              isDense: true,
            ),
          )
        : null,
    actions: selecting
        ? [
            Builder(
              builder: (context) => Row(children: selectionActions(context)),
            ),
          ]
        : [
            IconButton(
              icon: Icon(
                _searching ? Icons.close_rounded : Icons.search_rounded,
              ),
              tooltip: _searching ? 'Close search' : 'Search',
              onPressed: _searching
                  ? _closeSearch
                  : () => setState(() => _searching = true),
            ),
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.tune_rounded),
                tooltip: 'Filter',
                onPressed: () => showLedgerFilterSheet(context),
              ),
            ),
            const SizedBox(width: 4),
          ],
    slivers: (context, state) {
      if (state.ledger.isEmpty && state.filter.isEmpty)
        return [
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.receipt_long_outlined,
              title: 'Nothing logged yet',
              message:
                  'Transactions land here as your bank texts arrive. You '
                  'can always add one by hand.',
              action: 'Add a transaction',
              onAction: () => showTransactionSheet(context),
              embedded: true,
            ),
          ),
        ];
      return [
        if (!state.filter.isEmpty)
          SliverToBoxAdapter(child: _FilterBar(state: state)),
        if (state.ledger.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 60, 20, 20),
              child: Text(
                'Nothing matches.',
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
                    selected: selected.contains(day.rows[i].id),
                    selecting: selecting,
                    onToggle: toggleSelected,
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
                      '${state.ledgerCount} transactions',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
          ),
        ),
      ];
    },
  );
}

/// A ledger row you can swipe away. Split out so the list builder stays cheap
/// and each row repaints on its own.
/// A ledger row: swipe to delete when nothing is selected, and a target for
/// the batch actions once something is. Swiping is off in selection mode so a
/// stray gesture can't delete a row you never picked.
class _DismissibleRow extends StatelessWidget {
  const _DismissibleRow({
    required this.transaction,
    required this.symbol,
    required this.selected,
    required this.selecting,
    required this.onToggle,
  });
  final TallyTransaction transaction;
  final String symbol;
  final bool selected;
  final bool selecting;
  final void Function(int id) onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final id = transaction.id;
    final tile = TransactionTile(
      transaction: transaction,
      symbol: symbol,
      showDate: false,
      selected: selected,
      onTap: id == null
          ? null
          : selecting
          ? () => onToggle(id)
          : () => showTransactionSheet(context, existing: transaction),
      onLongPress: id == null ? null : () => onToggle(id),
    );
    if (selecting) return tile;
    return Dismissible(
      key: ValueKey(id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) async {
        final messenger = ScaffoldMessenger.of(context);
        await TallyDatabase.instance.delete(id!);
        refreshApp();
        // A swipe is easy to make by accident, and a deleted transaction is
        // not something the user can reconstruct from memory.
        messenger.clearSnackBars();
        messenger.showSnackBar(
          SnackBar(
            content: Text('Deleted ${transaction.merchant}'),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () async {
                await TallyDatabase.instance.restore(transaction);
                refreshApp();
              },
            ),
          ),
        );
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
      child: tile,
    );
  }
}

/// "12 selected · ₹4,820". The sum is only shown when every picked row is
/// actually loaded; after "select all" on a paged list it would otherwise be
/// the total of whatever happened to be on screen, which is a lie.
class _SelectionTitle extends StatelessWidget {
  const _SelectionTitle({required this.ids});
  final Set<int> ids;

  @override
  Widget build(BuildContext context) {
    final byId = {
      for (final row in appState.ledger)
        if (row.id != null) row.id!: row,
    };
    final loaded = ids.where(byId.containsKey).length;
    final total = ids.fold<int>(
      0,
      (sum, id) => sum + (byId[id]?.amountMinor ?? 0),
    );
    return Text(
      loaded == ids.length
          ? '${ids.length} selected · ${money(total, appState.symbol)}'
          : '${ids.length} selected',
    );
  }
}

/// What the ledger is narrowed to, and what that leaves: one chip per
/// narrowing, each removable on its own, and the totals for whatever is left.
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final filter = state.filter;
    final account = state.accounts
        .where((a) => a.id == filter.accountId)
        .firstOrNull;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (filter.from != null || filter.to != null)
                _FilterChip(
                  icon: Icons.event_rounded,
                  label: filter.isSingleDay
                      ? _dayMonth(filter.from!)
                      : filter.to != null
                      ? '${_dayMonth(filter.to!.subtract(const Duration(days: 1)))} and earlier'
                      : 'since ${_dayMonth(filter.from!)}',
                  onRemove: () => unawaited(
                    appState.setFilter(filter.copyWith(clearDates: true)),
                  ),
                ),
              if (filter.minMinor != null || filter.maxMinor != null)
                _FilterChip(
                  icon: Icons.tune_rounded,
                  label: filter.minMinor != null && filter.maxMinor != null
                      ? '${moneyShort(filter.minMinor!, state.symbol)}–${moneyShort(filter.maxMinor!, state.symbol)}'
                      : filter.minMinor != null
                      ? 'over ${moneyShort(filter.minMinor!, state.symbol)}'
                      : 'under ${moneyShort(filter.maxMinor!, state.symbol)}',
                  onRemove: () => unawaited(
                    appState.setFilter(filter.copyWith(clearAmount: true)),
                  ),
                ),
              if (filter.category != null)
                _FilterChip(
                  icon: categoryIcon(filter.category!),
                  color: categoryColor(filter.category!),
                  label: filter.category!,
                  onRemove: () => unawaited(
                    appState.setFilter(filter.copyWith(clearCategory: true)),
                  ),
                ),
              if (account != null)
                _FilterChip(
                  icon: Icons.account_balance_rounded,
                  label: account.name,
                  onRemove: () => unawaited(
                    appState.setFilter(filter.copyWith(clearAccount: true)),
                  ),
                ),
              if (filter.text.isNotEmpty)
                _FilterChip(
                  icon: Icons.search_rounded,
                  label: '"${filter.text}"',
                  onRemove: () =>
                      unawaited(appState.setFilter(filter.copyWith(text: ''))),
                ),
              TextButton(
                onPressed: () => unawaited(appState.clearFilter()),
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Clear all'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            [
              '${state.ledgerCount} '
                  '${state.ledgerCount == 1 ? 'transaction' : 'transactions'}',
              if (state.ledgerOut > 0)
                '${money(state.ledgerOut, state.symbol)} out',
              if (state.ledgerIn > 0)
                '${money(state.ledgerIn, state.symbol)} in',
            ].join(' · '),
            style: text.bodySmall?.copyWith(color: scheme.onSurface),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.icon,
    required this.label,
    required this.onRemove,
    this.color,
  });
  final IconData icon;
  final String label;
  final VoidCallback onRemove;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLowest,
      shape: StadiumBorder(
        side: BorderSide(color: scheme.outlineVariant, width: 1.5),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onRemove,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 8, 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color ?? scheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Text(label, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(width: 4),
              Icon(
                Icons.close_rounded,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Google Play's user-data policy wants the app to say what it will read and
/// why *before* the system permission prompt, in its own words. It is the
/// honest thing to show anyway, so it runs on every build, from wherever the
/// scan was started.
Future<bool> showSmsDisclosure(BuildContext context) async {
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

/// The fast path for the one thing the user does over and over: a row Tally
/// could not label, and every category one tap away. No form, no save button
/// - the tap is the answer. The full editor is one link away for the rare
/// time the amount or account is wrong too.
Future<void> showQuickLabelSheet(
  BuildContext context,
  TallyTransaction row,
) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  await showModalBottomSheet<void>(
    context: navigator.context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) {
      final text = Theme.of(sheetContext).textTheme;
      final scheme = Theme.of(sheetContext).colorScheme;
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          sheetBottomInset(sheetContext) + 20,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    row.merchant,
                    style: text.headlineSmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  money(row.amountMinor, appState.symbol),
                  style: text.titleLarge?.copyWith(fontFeatures: tabular),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '${_weekdays[row.occurredAt.weekday - 1]} '
              '${_dayMonth(row.occurredAt)} · what was this?',
              style: text.bodySmall,
            ),
            const SizedBox(height: 18),
            CategoryPicker(
              value: row.needsReview ? '' : row.category,
              categories: appState.categoryNames,
              onChanged: (picked) async {
                final messenger = ScaffoldMessenger.of(context);
                final swept = await confirmCategory(row, picked);
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                refreshApp();
                // Saying how far the correction reached is what makes the
                // learning feel like learning rather than a silent guess.
                messenger.clearSnackBars();
                messenger.showSnackBar(
                  SnackBar(
                    content: Text(
                      swept > 1
                          ? '$picked · also applied to ${swept - 1} other '
                                '${swept == 2 ? 'row' : 'rows'} from '
                                '${row.merchant}'
                          : 'Labelled $picked',
                    ),
                  ),
                );
              },
            ),
            if (row.smsBody?.isNotEmpty ?? false) ...[
              const SizedBox(height: 18),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainer,
                  borderRadius: BorderRadius.circular(Corners.control),
                ),
                child: Text(row.smsBody!, style: text.bodySmall),
              ),
            ],
            const SizedBox(height: 14),
            Center(
              child: TextButton.icon(
                icon: const Icon(Icons.edit_outlined, size: 17),
                label: const Text('Edit the whole row'),
                onPressed: () {
                  Navigator.pop(sheetContext);
                  showTransactionSheet(context, existing: row, force: true);
                },
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// Manage the category set: rename, recolour, re-mark, add and remove.
/// Deleting always reassigns, so no transaction is ever left pointing at a
/// label that no longer exists.
class CategoriesScreen extends StatelessWidget {
  const CategoriesScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Categories'),
      actions: [
        Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: 'New category',
            onPressed: () => showCategoryEditor(context),
          ),
        ),
        const SizedBox(width: 4),
      ],
    ),
    body: ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final categories = appState.categories;
        final counts = appState.categoryCounts;
        return ListView.builder(
          padding: EdgeInsets.fromLTRB(
            20,
            8,
            20,
            24 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          itemCount: categories.length,
          itemBuilder: (context, i) {
            final category = categories[i];
            final used = counts[category.name] ?? 0;
            return ListTile(
              contentPadding: EdgeInsets.zero,
              leading: CategoryAvatar(category: category.name),
              title: Text(
                category.name,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
              subtitle: Text(
                used == 0
                    ? (category.builtin ? 'Built in' : 'Yours, unused')
                    : '$used ${used == 1 ? 'transaction' : 'transactions'}'
                          '${category.builtin ? '' : ' · yours'}',
              ),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: () => showCategoryEditor(context, existing: category),
            );
          },
        );
      },
    ),
  );
}

/// Add or edit one category. A built-in one can be renamed and restyled but
/// not deleted: the learner's seed lexicon points at those names.
void showCategoryEditor(BuildContext context, {CategoryDef? existing}) {
  final name = TextEditingController(text: existing?.name ?? '');
  var iconIndex = existing?.iconIndex ?? 10;
  var colorValue = existing?.colorValue ?? kCategoryColorChoices.first;
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (sheetContext, setSheetState) {
        final text = Theme.of(sheetContext).textTheme;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            sheetBottomInset(sheetContext) + 20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                existing == null ? 'New category' : 'Edit category',
                style: text.headlineSmall,
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      color: Color(colorValue).withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(Corners.tile),
                    ),
                    child: Icon(
                      kCategoryIconChoices[iconIndex],
                      color: Color(colorValue),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: TextField(
                      controller: name,
                      autofocus: existing == null,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(labelText: 'Name'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text('Colour', style: text.titleMedium),
              const SizedBox(height: 10),
              ColorChooser(
                value: colorValue,
                onChanged: (v) => setSheetState(() => colorValue = v),
              ),
              const SizedBox(height: 20),
              Text('Mark', style: text.titleMedium),
              const SizedBox(height: 10),
              IconChooser(
                value: iconIndex,
                color: Color(colorValue),
                onChanged: (v) => setSheetState(() => iconIndex = v),
              ),
              const SizedBox(height: 22),
              FilledButton(
                onPressed: () async {
                  final trimmed = name.text.trim();
                  if (trimmed.isEmpty) return;
                  await TallyDatabase.instance.saveCategory(
                    CategoryDef(
                      name: trimmed,
                      iconIndex: iconIndex,
                      colorValue: colorValue,
                      sort: existing?.sort ?? appState.categories.length,
                      builtin: existing?.builtin ?? false,
                    ),
                    renamedFrom: existing?.name,
                  );
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  refreshApp();
                },
                child: Text(existing == null ? 'Create' : 'Save'),
              ),
              if (existing != null && !existing.builtin) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Delete'),
                  onPressed: () async {
                    Navigator.pop(sheetContext);
                    await _deleteCategory(context, existing);
                  },
                ),
              ],
            ],
          ),
        );
      },
    ),
  ).whenComplete(name.dispose);
}

/// Deleting asks where its transactions should go first. Silently dumping
/// them in "Other" would quietly rewrite months of labelling.
Future<void> _deleteCategory(BuildContext context, CategoryDef category) async {
  final used = appState.categoryCounts[category.name] ?? 0;
  final target = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    builder: (sheetContext) => SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        sheetBottomInset(sheetContext) + 20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Delete ${category.name}',
            style: Theme.of(sheetContext).textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
          Text(
            used == 0
                ? 'Nothing uses it, so nothing moves.'
                : 'Move its $used '
                      '${used == 1 ? 'transaction' : 'transactions'} to:',
            style: Theme.of(sheetContext).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          CategoryPicker(
            value: '',
            categories: [
              for (final c in appState.categoryNames)
                if (c != category.name) c,
            ],
            onChanged: (picked) => Navigator.pop(sheetContext, picked),
          ),
        ],
      ),
    ),
  );
  if (target == null) return;
  await TallyDatabase.instance.deleteCategory(category.name, target);
  refreshApp();
}

/// Asks for one category and returns it, or null if the sheet was dismissed.
/// Used by the batch action; the transaction sheet picks inline instead,
/// since there it sits among the other fields.
Future<String?> showCategorySheet(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          sheetBottomInset(sheetContext) + 20,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Set category',
              style: Theme.of(sheetContext).textTheme.headlineSmall,
            ),
            const SizedBox(height: 18),
            CategoryPicker(
              value: '',
              onChanged: (v) => Navigator.pop(sheetContext, v),
            ),
          ],
        ),
      ),
    );

/// The two ends of the amount filter. Keeps its own controllers so typing
/// is not interrupted by the reloads each change triggers.
class _AmountRange extends StatefulWidget {
  const _AmountRange({required this.symbol, required this.filter});
  final String symbol;
  final LedgerFilter filter;

  @override
  State<_AmountRange> createState() => _AmountRangeState();
}

class _AmountRangeState extends State<_AmountRange> {
  late final _min = TextEditingController(
    text: widget.filter.minMinor == null
        ? ''
        : (widget.filter.minMinor! / 100).toStringAsFixed(0),
  );
  late final _max = TextEditingController(
    text: widget.filter.maxMinor == null
        ? ''
        : (widget.filter.maxMinor! / 100).toStringAsFixed(0),
  );
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _min.dispose();
    _max.dispose();
    super.dispose();
  }

  void _push() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      final min = parseMoney(_min.text);
      final max = parseMoney(_max.text);
      unawaited(
        appState.setFilter(
          appState.filter
              .copyWith(clearAmount: true)
              .copyWith(minMinor: min, maxMinor: max),
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: TextField(
          controller: _min,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => _push(),
          decoration: InputDecoration(
            labelText: 'At least',
            prefixText: '${widget.symbol} ',
            isDense: true,
          ),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: TextField(
          controller: _max,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => _push(),
          decoration: InputDecoration(
            labelText: 'At most',
            prefixText: '${widget.symbol} ',
            isDense: true,
          ),
        ),
      ),
    ],
  );
}

/// Jumps the ledger back to a chosen day instead of paging to it.
Future<void> pickLedgerDay(BuildContext context) async {
  final now = DateTime.now();
  final picked = await showDatePicker(
    context: context,
    initialDate: appState.filter.to?.subtract(const Duration(days: 1)) ?? now,
    firstDate: appState.oldest ?? DateTime(now.year - 5),
    lastDate: now,
    helpText: 'Jump to a day',
  );
  if (picked != null) await appState.jumpTo(picked);
}

/// Picks the day, account and category Activity is narrowed to.
void showLedgerFilterSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetContext) => ListenableBuilder(
      listenable: appState,
      builder: (context, _) {
        final state = appState;
        final text = Theme.of(context).textTheme;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            4,
            20,
            sheetBottomInset(context) + 20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Filter', style: text.headlineSmall),
              const SizedBox(height: 18),
              OutlinedButton.icon(
                icon: const Icon(Icons.event_rounded, size: 18),
                label: Text(
                  state.filter.to == null
                      ? 'Jump to a day'
                      : 'To ${_dayMonth(state.filter.to!.subtract(const Duration(days: 1)))}',
                ),
                onPressed: () => pickLedgerDay(context),
              ),
              const SizedBox(height: 18),
              Text('Account', style: text.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final a in state.accounts)
                    ChoiceChip(
                      selected: state.filter.accountId == a.id,
                      label: Text(a.name),
                      onSelected: (on) => unawaited(
                        appState.setFilter(
                          on
                              ? state.filter.copyWith(accountId: a.id)
                              : state.filter.copyWith(clearAccount: true),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 18),
              Text('Amount', style: text.titleMedium),
              const SizedBox(height: 2),
              Text(
                'Leave either side blank for an open end.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 10),
              _AmountRange(symbol: state.symbol, filter: state.filter),
              const SizedBox(height: 18),
              Text('Category', style: text.titleMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in state.categoryNames)
                    ChoiceChip(
                      selected: state.filter.category == c,
                      avatar: Icon(
                        categoryIcon(c),
                        size: 15,
                        color: categoryColor(c),
                      ),
                      label: Text(c),
                      onSelected: (on) => unawaited(
                        appState.setFilter(
                          on
                              ? state.filter.copyWith(category: c)
                              : state.filter.copyWith(clearCategory: true),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => unawaited(appState.clearFilter()),
                      child: const Text('Clear all'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(sheetContext),
                      child: Text('Show ${state.ledgerCount}'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    ),
  );
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
    this.onLongPress,
    this.showDate = true,
    this.selected = false,
  });
  final TallyTransaction transaction;
  final String symbol;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Picked for a batch action: the row takes the accent wash and its
  /// category mark turns into a tick.
  final bool selected;

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
      color: selected
          ? scheme.primary.withValues(alpha: 0.10)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(Corners.card),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(Corners.card),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
          child: Row(
            children: [
              if (selected)
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(Corners.tile),
                  ),
                  child: Icon(
                    Icons.check_rounded,
                    size: 22,
                    color: scheme.onPrimary,
                  ),
                )
              else
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

  Future<bool> _disclose(BuildContext context) => showSmsDisclosure(context);

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
    slivers: (context, state) {
      final symbol = state.symbol;
      return [
        PageColumn(
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
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 20,
                        ),
                        tooltip: 'Delete account',
                        onPressed: () => _confirmDeleteAccount(context, a),
                      ),
                    ),
                ],
              ),
            SectionHeading(
              title: 'Categories',
              action: 'Manage',
              onAction: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const CategoriesScreen(),
                ),
              ),
            ),
            _SettingsGroup(
              children: [
                _SettingsRow(
                  icon: Icons.label_outline_rounded,
                  title: '${state.categories.length} categories',
                  subtitle: 'Rename, recolour, or add your own',
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CategoriesScreen(),
                    ),
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
        ),
        const PageBottomGap(),
      ];
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
                // The selected-segment tick steals enough width to clip
                // "Expense"; the fill already says which one is on.
                showSelectedIcon: false,
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
              if (existing != null && appState.accounts.length > 1) ...[
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.merge_rounded, size: 18),
                    label: const Text('Merge into another account'),
                    onPressed: () async {
                      Navigator.pop(sheetContext);
                      await showMergeAccountSheet(context, existing);
                    },
                  ),
                ),
              ],
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

/// Folds one account into another, for when detection made two rows for the
/// same real account - a bank quoting four digits in some messages and six in
/// others is the usual cause.
Future<void> showMergeAccountSheet(BuildContext context, Account from) async {
  final others = [
    for (final a in appState.accounts)
      if (a.id != from.id) a,
  ];
  if (others.isEmpty) return;
  final messenger = ScaffoldMessenger.of(context);
  final target = await showModalBottomSheet<Account>(
    context: Navigator.of(context, rootNavigator: true).context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (sheetContext) => SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        4,
        20,
        sheetBottomInset(sheetContext) + 20,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Merge ${from.name}',
            style: Theme.of(sheetContext).textTheme.headlineSmall,
          ),
          const SizedBox(height: 6),
          Text(
            'Its transactions move to the account you pick, which also takes '
            'on its digits. ${from.name} is then removed. Nothing is deleted '
            'from your ledger.',
            style: Theme.of(sheetContext).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          ...others.map(
            (a) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: BankMark(name: a.name),
              title: Text(a.name),
              subtitle: Text(
                a.last4.isEmpty
                    ? money(appState.balances[a.id] ?? 0, appState.symbol)
                    : '···· ${a.last4} · '
                          '${money(appState.balances[a.id] ?? 0, appState.symbol)}',
              ),
              onTap: () => Navigator.pop(sheetContext, a),
            ),
          ),
        ],
      ),
    ),
  );
  if (target == null) return;
  await TallyDatabase.instance.mergeAccounts(from.id!, target.id!);
  refreshApp();
  messenger.showSnackBar(
    SnackBar(content: Text('Merged ${from.name} into ${target.name}')),
  );
}

/// Bottom sheet for both adding a transaction and editing one (tap any
/// tile). [existing] null means "add"; otherwise the sheet edits that row,
/// offers delete, and re-runs [confirmCategory] when the category changes so
/// the learner still sees the correction.
void showTransactionSheet(
  BuildContext context, {
  TallyTransaction? existing,
  bool force = false,
}) async {
  // A row waiting on a label wants the one-tap sheet, not a form; [force] is
  // how that sheet hands over when the user asks to edit everything.
  if (!force && existing != null && existing.needsReview) {
    await showQuickLabelSheet(context, existing);
    return;
  }
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
                // The selected-segment tick steals enough width to clip
                // "Expense"; the fill already says which one is on.
                showSelectedIcon: false,
                onSelectionChanged: (v) => setSheetState(() => kind = v.first),
              ),
              const SizedBox(height: 12),
              // Amount leads and takes focus: it is the only field that is
              // always needed, and it decides which keyboard opens.
              TextField(
                controller: amount,
                autofocus: existing == null,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                style: Theme.of(context).textTheme.displaySmall,
                decoration: InputDecoration(
                  labelText: 'Amount',
                  prefixText: '${appState.symbol} ',
                  prefixStyle: Theme.of(context).textTheme.displaySmall
                      ?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                  contentPadding: const EdgeInsets.fromLTRB(16, 26, 16, 16),
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: merchant,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: kind == TransactionKind.transfer
                      ? 'Note (optional)'
                      : 'Merchant or description',
                ),
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
                  value: appState.categoryNames.contains(category)
                      ? category
                      : appState.categoryNames.first,
                  categories: appState.categoryNames,
                  onAdd: () => showCategoryEditor(context),
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
