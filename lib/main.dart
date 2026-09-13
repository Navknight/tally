import 'dart:async';

import 'package:flutter/material.dart';

import 'app/theme.dart';
import 'core/money.dart';
import 'data/tally_database.dart';
import 'models/transaction.dart';
import 'platform/android_bridge.dart';
import 'services/sms_ingestion.dart';

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
    if (mounted) setState(() => _ready = done);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _ready == true)
      unawaited(_importPendingSms());
  }

  Future<void> _importPendingSms() async {
    final messages = await AndroidBridge.pendingSms();
    await ingestSms(messages);
    if (messages.isNotEmpty && mounted) setState(() {});
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
  final _amount = TextEditingController();
  final _currency = TextEditingController(text: '₹');
  bool _saving = false;
  @override
  void dispose() {
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
    await TallyDatabase.instance.setSetting('opening_balance', '$opening');
    await TallyDatabase.instance.setSetting('monthly_budget', '0');
    await TallyDatabase.instance.setSetting('onboarded', 'true');
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Spacer(),
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
              'Everything stays on this device. Start with the balance in your main account.',
              style: Theme.of(context).textTheme.bodyLarge,
            ),
            const SizedBox(height: 30),
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
              'You can import a CSV statement or connect SMS from Settings afterwards.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Spacer(),
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
      HomeScreen(key: ValueKey(_refresh), onChanged: _changed),
      TransactionsScreen(key: ValueKey(_refresh), onChanged: _changed),
      BudgetScreen(key: ValueKey(_refresh), onChanged: _changed),
      const SettingsScreen(),
    ];
    return Scaffold(
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
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.onChanged});
  final VoidCallback onChanged;
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Object?>>(
    future: Future.wait([
      TallyDatabase.instance.transactions(),
      TallyDatabase.instance.setting('opening_balance'),
      TallyDatabase.instance.setting('currency'),
      TallyDatabase.instance.setting('monthly_budget'),
    ]),
    builder: (context, snapshot) {
      if (!snapshot.hasData)
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      final values = snapshot.data!;
      final tx = values[0] as List<TallyTransaction>;
      final opening = int.tryParse(values[1] as String? ?? '0') ?? 0;
      final symbol = values[2] as String? ?? '₹';
      final budget = int.tryParse(values[3] as String? ?? '0') ?? 0;
      final now = DateTime.now();
      final month = tx
          .where(
            (t) =>
                t.occurredAt.year == now.year &&
                t.occurredAt.month == now.month,
          )
          .toList();
      final spent = month
          .where((t) => t.kind == TransactionKind.expense)
          .fold<int>(0, (sum, t) => sum + t.amountMinor);
      final balance =
          opening +
          tx.fold<int>(
            0,
            (sum, t) =>
                sum +
                (t.kind == TransactionKind.income
                    ? t.amountMinor
                    : -t.amountMinor),
          );
      return Scaffold(
        appBar: AppBar(title: const Text('Tally')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 100),
          children: [
            Text('Available', style: Theme.of(context).textTheme.bodySmall),
            Text(
              money(balance, symbol),
              style: Theme.of(context).textTheme.displayMedium,
            ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('This month'),
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
                    ),
                    const SizedBox(height: 8),
                    Text(
                      style: Theme.of(context).textTheme.bodySmall,
                      budget > 0
                          ? '${money((budget - spent).clamp(0, budget), symbol)} left of ${money(budget, symbol)}'
                          : 'Set a monthly limit in Budget',
                    ),
                  ],
                ),
              ),
            ),
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
                .map((t) => TransactionTile(transaction: t, symbol: symbol)),
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
      TallyDatabase.instance.setting('currency'),
    ]),
    builder: (context, snapshot) {
      if (!snapshot.hasData)
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      final transactions = snapshot.data![0] as List<TallyTransaction>;
      final symbol = snapshot.data![1] as String? ?? '₹';
      return Scaffold(
        appBar: AppBar(title: const Text('Activity')),
        body: transactions.isEmpty
            ? const Center(child: Text('No transactions yet.'))
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 100),
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
  });
  final TallyTransaction transaction;
  final String symbol;
  @override
  Widget build(BuildContext context) {
    final positive = transaction.kind == TransactionKind.income;
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: CircleAvatar(
        backgroundColor: scheme.surfaceContainerHigh,
        foregroundColor: positive ? scheme.primary : scheme.onSurfaceVariant,
        child: Icon(positive ? Icons.south_west : Icons.north_east, size: 20),
      ),
      title: Text(transaction.merchant),
      subtitle: Text(
        '${transaction.category} · ${transaction.occurredAt.day}/${transaction.occurredAt.month}',
      ),
      trailing: Text(
        '${positive ? '+' : '-'}${money(transaction.amountMinor, symbol)}',
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
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    controller.text =
        ((int.tryParse(
                      await TallyDatabase.instance.setting('monthly_budget') ??
                          '0',
                    ) ??
                    0) /
                100)
            .toStringAsFixed(2);
    symbol = await TallyDatabase.instance.setting('currency') ?? '₹';
    if (mounted) setState(() => loading = false);
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Monthly budget')),
    body: loading
        ? const Center(child: CircularProgressIndicator())
        : Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'One number is enough.',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Set a gentle spending limit for this month. Tally will keep the rest simple.',
                ),
                const SizedBox(height: 28),
                TextField(
                  controller: controller,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    prefixText: '$symbol ',
                    labelText: 'Monthly spending limit',
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
              ],
            ),
          ),
  );
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String _status = '';
  Future<void> _sms() async {
    final granted = await AndroidBridge.requestSmsPermission();
    final imported = granted
        ? await ingestSms(await AndroidBridge.historicSms())
        : 0;
    if (mounted)
      setState(
        () => _status = granted
            ? 'SMS enabled. Imported $imported historic transactions locally.'
            : 'SMS access was not granted.',
      );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      padding: const EdgeInsets.all(12),
      children: [
        const ListTile(
          title: Text('Privacy'),
          subtitle: Text('Your ledger stays on this device.'),
        ),
        ListTile(
          leading: const Icon(Icons.sms_outlined),
          title: const Text('Bank SMS'),
          subtitle: Text(
            _status.isEmpty ? 'Optional local transaction detection' : _status,
          ),
          trailing: FilledButton(onPressed: _sms, child: const Text('Enable')),
        ),
        ListTile(
          leading: const Icon(Icons.file_upload_outlined),
          title: const Text('Import statement'),
          subtitle: const Text(
            'Choose or paste a CSV: date, merchant, signed amount',
          ),
          onTap: () => _pickCsv(context),
        ),
      ],
    ),
  );
  Future<void> _pickCsv(BuildContext context) async {
    final text = await AndroidBridge.pickCsv();
    if (text == null) {
      if (context.mounted) _showCsv(context);
      return;
    }
    await _importRows(text, context);
  }

  Future<void> _importRows(String text, BuildContext context) async {
    var count = 0;
    for (final row in text.split('\n')) {
      final cells = row.split(',');
      if (cells.length < 3) continue;
      final amount = parseMoney(cells[2]) ?? 0;
      final date = DateTime.tryParse(cells[0].trim()) ?? DateTime.now();
      await TallyDatabase.instance.add(
        TallyTransaction(
          id: null,
          amountMinor: amount.abs(),
          kind: amount >= 0 ? TransactionKind.income : TransactionKind.expense,
          occurredAt: date,
          merchant: cells[1].trim(),
          category: 'Imported',
          source: 'csv',
        ),
      );
      count++;
    }
    if (context.mounted)
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('$count transactions imported')));
  }

  void _showCsv(BuildContext context) {
    final text = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.of(sheetContext).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Import CSV',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.3,
              ),
            ),
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
                var count = 0;
                for (final row in text.text.split('\n')) {
                  final cells = row.split(',');
                  if (cells.length < 3) continue;
                  final amount = parseMoney(cells[2]) ?? 0;
                  final date =
                      DateTime.tryParse(cells[0].trim()) ?? DateTime.now();
                  await TallyDatabase.instance.add(
                    TallyTransaction(
                      id: null,
                      amountMinor: amount.abs(),
                      kind: amount >= 0
                          ? TransactionKind.income
                          : TransactionKind.expense,
                      occurredAt: date,
                      merchant: cells[1].trim(),
                      category: 'Imported',
                      source: 'csv',
                    ),
                  );
                  count++;
                }
                if (sheetContext.mounted) Navigator.pop(sheetContext);
                if (mounted)
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('$count transactions imported')),
                  );
              },
              child: const Text('Import locally'),
            ),
          ],
        ),
      ),
    );
  }
}

void showTransactionSheet(BuildContext context, VoidCallback onSaved) {
  final merchant = TextEditingController();
  final amount = TextEditingController();
  var kind = TransactionKind.expense;
  var category = 'General';
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, setSheetState) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          20,
          20,
          MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Add transaction',
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
              ],
              selected: {kind},
              onSelectionChanged: (v) => setSheetState(() => kind = v.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: merchant,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Merchant or description',
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
            DropdownButtonFormField<String>(
              value: category,
              decoration: const InputDecoration(labelText: 'Category'),
              items: const [
                'General',
                'Food',
                'Transport',
                'Shopping',
                'Bills',
                'Health',
                'Income',
              ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
              onChanged: (v) => category = v ?? category,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () async {
                  final minor = parseMoney(amount.text);
                  if (minor == null || merchant.text.trim().isEmpty) return;
                  await TallyDatabase.instance.add(
                    TallyTransaction(
                      id: null,
                      amountMinor: minor,
                      kind: kind,
                      occurredAt: DateTime.now(),
                      merchant: merchant.text.trim(),
                      category: category,
                    ),
                  );
                  if (sheetContext.mounted) Navigator.pop(sheetContext);
                  onSaved();
                },
                child: const Text('Save transaction'),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
