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
import 'models/transaction.dart';
import 'platform/android_bridge.dart';
import 'services/export.dart';
import 'services/sms_ingestion.dart';
import 'services/statement_import.dart';

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
    if (mounted) setState(() => _ready = done);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _ready == true)
      unawaited(_importPendingSms());
  }

  Future<void> _importPendingSms() async {
    final report = await ingestPendingSms();
    if (report.considered == 0) return;
    await recategorizeReviewQueue();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (_ready == null)
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return _ready!
        ? const TallyShell()
        : Onboarding(onComplete: () => setState(() => _ready = true));
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
    await TallyDatabase.instance.addAccount(
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
              maxLength: 4,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Last 4 digits (optional)',
                hintText: 'Helps match bank SMS to this account',
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
  int _refresh = 0;
  void _changed() => setState(() => _refresh++);
  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeScreen(
        key: ValueKey(_refresh),
        onChanged: _changed,
        onOpenInsights: () => setState(() => _tab = 3),
      ),
      TransactionsScreen(key: ValueKey(_refresh), onChanged: _changed),
      BudgetScreen(key: ValueKey(_refresh), onChanged: _changed),
      InsightsScreen(key: ValueKey(_refresh), onChanged: _changed),
      SettingsScreen(key: ValueKey(_refresh), onChanged: _changed),
    ];
    return PopScope(
      canPop: _tab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _tab = 0);
      },
      child: Scaffold(
        body: pages[_tab],
        floatingActionButton: _tab < 2
            ? FloatingActionButton(
                onPressed: () => showTransactionSheet(context, _changed),
                child: const Icon(Icons.add),
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (i) => setState(() => _tab = i),
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

class HomeScreen extends StatelessWidget {
  const HomeScreen({
    super.key,
    required this.onChanged,
    required this.onOpenInsights,
  });
  final VoidCallback onChanged;
  final VoidCallback onOpenInsights;
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Object?>>(
    future: () async {
      final db = TallyDatabase.instance;
      final startDay = await db.budgetStartDay();
      final period = budgetPeriod(DateTime.now(), startDay);
      // ponytail: loads every row to sum balances; move to SQL SUM if it drags.
      return Future.wait([
        db.transactions(limit: -1),
        db.accounts(),
        db.currency(),
        db.setting('monthly_budget'),
        db.reviewQueue(),
        db.spentInPeriod(period),
      ]);
    }(),
    builder: (context, snapshot) {
      if (!snapshot.hasData)
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      final values = snapshot.data!;
      final tx = values[0] as List<TallyTransaction>;
      final accounts = values[1] as List<Account>;
      final symbol = values[2] as String;
      final budget = int.tryParse(values[3] as String? ?? '0') ?? 0;
      final review = values[4] as List<TallyTransaction>;
      final spent = values[5] as int;
      final balance = totalBalance(accounts, tx);
      final scheme = Theme.of(context).colorScheme;
      final lowAccounts = accounts.where((a) {
        final min = a.minBalanceMinor;
        return min != null && accountBalance(a, tx) < min;
      }).toList();
      return Scaffold(
        appBar: AppBar(title: const Text('Tally')),
        body: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            12,
            20,
            100 + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            Text('Available', style: Theme.of(context).textTheme.bodySmall),
            Text(
              money(balance, symbol),
              style: Theme.of(context).textTheme.displayMedium,
            ),
            if (accounts.length > 1) ...[
              const SizedBox(height: 12),
              ...accounts.map((a) {
                final accBalance = accountBalance(a, tx);
                final low =
                    a.minBalanceMinor != null &&
                    accBalance < a.minBalanceMinor!;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        a.name,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Text(
                        money(accBalance, symbol),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          fontFeatures: tabular,
                          color: low ? scheme.error : null,
                          fontWeight: low ? FontWeight.w600 : null,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
            if (lowAccounts.isNotEmpty) ...[
              const SizedBox(height: 16),
              ...lowAccounts.map(
                (a) => Card(
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
            ],
            const SizedBox(height: 24),
            Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onOpenInsights,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text('This budget period'),
                          Text(
                            money(spent, symbol),
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontFeatures: tabular,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: budget > 0
                            ? (spent / budget).clamp(0, 1).toDouble()
                            : 0,
                        color: spent > budget && budget > 0
                            ? scheme.error
                            : null,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: spent > budget && budget > 0
                              ? scheme.error
                              : null,
                        ),
                        budget <= 0
                            ? 'Set a monthly limit in Budget'
                            : spent > budget
                            ? '${money(spent - budget, symbol)} over ${money(budget, symbol)}'
                            : '${money(budget - spent, symbol)} left of ${money(budget, symbol)}',
                      ),
                    ],
                  ),
                ),
              ),
            ),
            if (review.isNotEmpty) ...[
              const SizedBox(height: 28),
              Text(
                'Needs review',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                'Tally wasn\'t sure how to label these.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              ...review.map(
                (t) => TransactionTile(
                  transaction: t,
                  symbol: symbol,
                  onTap: () =>
                      showTransactionSheet(context, onChanged, existing: t),
                ),
              ),
            ],
            const SizedBox(height: 28),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Recent activity',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                TextButton(onPressed: onChanged, child: const Text('Refresh')),
              ],
            ),
            ...tx
                .take(6)
                .map(
                  (t) => TransactionTile(
                    transaction: t,
                    symbol: symbol,
                    onTap: () =>
                        showTransactionSheet(context, onChanged, existing: t),
                  ),
                ),
          ],
        ),
      );
    },
  );
}

class TransactionsScreen extends StatelessWidget {
  const TransactionsScreen({super.key, required this.onChanged});
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Object?>>(
    future: Future.wait([
      TallyDatabase.instance.transactions(),
      TallyDatabase.instance.currency(),
    ]),
    builder: (context, snapshot) {
      if (!snapshot.hasData)
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      final transactions = snapshot.data![0] as List<TallyTransaction>;
      final symbol = snapshot.data![1] as String;
      return Scaffold(
        appBar: AppBar(title: const Text('Activity')),
        body: transactions.isEmpty
            ? const Center(child: Text('No transactions yet.'))
            : ListView.builder(
                padding: EdgeInsets.fromLTRB(
                  20,
                  8,
                  20,
                  100 + MediaQuery.viewPaddingOf(context).bottom,
                ),
                itemCount: transactions.length,
                itemBuilder: (_, index) {
                  final transaction = transactions[index];
                  return Dismissible(
                    key: ValueKey(transaction.id),
                    direction: DismissDirection.endToStart,
                    onDismissed: (_) async {
                      await TallyDatabase.instance.delete(transaction.id!);
                      onChanged();
                    },
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: 24),
                      color: Theme.of(context).colorScheme.errorContainer,
                      child: const Icon(Icons.delete),
                    ),
                    child: TransactionTile(
                      transaction: transaction,
                      symbol: symbol,
                      onTap: () => showTransactionSheet(
                        context,
                        onChanged,
                        existing: transaction,
                      ),
                    ),
                  );
                },
              ),
      );
    },
  );
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
        '${transaction.category} · ${transaction.occurredAt.day}/${transaction.occurredAt.month}'
        '${transaction.needsReview ? ' · tap to label' : ''}',
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
  const BudgetScreen({super.key, required this.onChanged});
  final VoidCallback onChanged;
  @override
  State<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends State<BudgetScreen> {
  final controller = TextEditingController();
  String symbol = '₹';
  bool loading = true;
  int startDay = 1;
  List<Account> accounts = const [];
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = TallyDatabase.instance;
    controller.text =
        ((int.tryParse(await db.setting('monthly_budget') ?? '0') ?? 0) / 100)
            .toStringAsFixed(2);
    symbol = await db.currency();
    startDay = await db.budgetStartDay();
    accounts = await db.accounts();
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Budget')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
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
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  prefixText: '$symbol ',
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
                  widget.onChanged();
                  if (mounted)
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Budget saved')),
                    );
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
                initialValue: startDay,
                decoration: const InputDecoration(labelText: 'Starts on'),
                items: List.generate(
                  28,
                  (i) =>
                      DropdownMenuItem(value: i + 1, child: Text('${i + 1}')),
                ),
                onChanged: (v) async {
                  if (v == null) return;
                  setState(() => startDay = v);
                  await TallyDatabase.instance.setSetting(
                    'budget_start_day',
                    '$v',
                  );
                  widget.onChanged();
                },
              ),
              if (accounts.isNotEmpty) ...[
                const SizedBox(height: 28),
                Text(
                  'Accounts',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 4),
                Text(
                  "Turn an account off to leave its spending out of the budget.",
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                ...accounts.map(
                  (a) => SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(a.name),
                    subtitle: const Text('Count in budget'),
                    value: a.inBudget,
                    onChanged: (v) async {
                      final updated = a.copyWith(inBudget: v);
                      await TallyDatabase.instance.updateAccount(updated);
                      setState(
                        () => accounts = accounts
                            .map((x) => x.id == a.id ? updated : x)
                            .toList(),
                      );
                      widget.onChanged();
                    },
                  ),
                ),
              ],
            ],
          ),
  );
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.onChanged});
  final VoidCallback onChanged;
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
    widget.onChanged();
    if (!mounted) return;
    setState(() => _smsStatus = _describeIngest(report));
  }

  Future<void> _confirmRereadSms(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Re-read SMS?'),
        content: const Text(
          'Deletes transactions imported from SMS and reads your inbox '
          'again. Manual and statement entries stay.',
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
    await TallyDatabase.instance.deleteSmsRows();
    final report = await ingestHistoricSms();
    await recategorizeReviewQueue();
    widget.onChanged();
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
    widget.onChanged();
    _snack('$inserted transactions imported to ${account.name}');
  }

  /// Skips the picker entirely when there is only one account to target.
  Future<Account?> _chooseAccount() async {
    final accounts = await TallyDatabase.instance.accounts();
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
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: FutureBuilder<List<Account>>(
      future: TallyDatabase.instance.accounts(),
      builder: (context, snapshot) {
        final accounts = snapshot.data ?? const [];
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
                    onPressed: () => _showAccountSheet(context),
                    child: const Text('Add'),
                  ),
                ],
              ),
            ),
            ...accounts.map(
              (a) => ListTile(
                leading: const Icon(Icons.account_balance_outlined),
                title: Text(a.name),
                subtitle: Text(
                  a.last4.isEmpty ? 'No linked digits' : '···· ${a.last4}',
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _confirmDeleteAccount(context, a),
                ),
                onTap: () => _showAccountSheet(context, existing: a),
              ),
            ),
            const Divider(height: 32),
            ListTile(
              leading: const Icon(Icons.sms_outlined),
              title: const Text('Bank SMS'),
              subtitle: Text(
                _smsStatus.isEmpty
                    ? 'Scan your inbox for past transactions'
                    : _smsStatus,
              ),
              trailing: FilledButton(
                onPressed: _scanSms,
                child: const Text('Scan SMS inbox'),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.restart_alt_outlined),
              title: const Text('Re-read SMS'),
              subtitle: const Text('Fix wrongly parsed SMS transactions'),
              onTap: () => _confirmRereadSms(context),
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
    ),
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
      widget.onChanged();
      setState(() {});
    }
  }

  void _showAccountSheet(BuildContext context, {Account? existing}) {
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
                  maxLength: 4,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'Last 4 digits (optional)',
                    counterText: '',
                  ),
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
                      );
                      if (existing == null)
                        await TallyDatabase.instance.addAccount(account);
                      else
                        await TallyDatabase.instance.updateAccount(account);
                      if (sheetContext.mounted) Navigator.pop(sheetContext);
                      widget.onChanged();
                      setState(() {});
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
    '${report.inserted} added, ${report.duplicates} already saved, ${report.ignored} skipped';

/// Bottom sheet for both adding a transaction and editing one (tap any
/// tile). [existing] null means "add"; otherwise the sheet edits that row,
/// offers delete, and re-runs [confirmCategory] when the category changes so
/// the learner still sees the correction.
void showTransactionSheet(
  BuildContext context,
  VoidCallback onSaved, {
  TallyTransaction? existing,
}) async {
  final accounts = await TallyDatabase.instance.accounts();
  if (accounts.isEmpty) {
    if (context.mounted)
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Add an account first')));
    return;
  }
  if (!context.mounted) return;

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
                      if (!isTransfer && category != existing.category)
                        await confirmCategory(updated, category);
                      else
                        await TallyDatabase.instance.updateTransaction(updated);
                    }
                    if (sheetContext.mounted) Navigator.pop(sheetContext);
                    onSaved();
                  },
                  child: const Text('Save transaction'),
                ),
              ),
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
                      onSaved();
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
