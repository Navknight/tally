import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../core/budget_period.dart';
import '../models/account.dart';
import '../models/categories.dart';
import '../models/transaction.dart';
import '../models/transfer.dart';
import '../services/categorizer.dart';

/// Single SQLite file, opened lazily. Also backs the categorizer's learning
/// tables, which is why it implements [CategoryStore].
class TallyDatabase implements CategoryStore {
  TallyDatabase._();
  static final instance = TallyDatabase._();
  Database? _database;

  Future<Database> get _db async => _database ??= await openDatabase(
    join(await getDatabasesPath(), 'tally.db'),
    version: 4,
    onCreate: (db, _) async {
      await db.execute('''CREATE TABLE settings (
            key TEXT PRIMARY KEY, value TEXT NOT NULL)''');
      await db.execute('''CREATE TABLE transactions (
            id INTEGER PRIMARY KEY AUTOINCREMENT, amount_minor INTEGER NOT NULL,
            kind TEXT NOT NULL, occurred_at INTEGER NOT NULL, merchant TEXT NOT NULL,
            category TEXT NOT NULL, note TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT 'manual', fingerprint TEXT,
            account_id INTEGER, reference TEXT, balance_after_minor INTEGER,
            category_source TEXT NOT NULL DEFAULT 'manual',
            needs_review INTEGER NOT NULL DEFAULT 0,
            exclude_from_budget INTEGER NOT NULL DEFAULT 0,
            transfer_account_id INTEGER)''');
      await db.execute(
        'CREATE INDEX tx_date ON transactions(occurred_at DESC)',
      );
      await db.execute(
        'CREATE UNIQUE INDEX tx_fingerprint ON transactions(fingerprint)',
      );
      await _createV3(db);
    },
    onUpgrade: (db, oldVersion, _) async {
      if (oldVersion < 2) {
        await db.execute(
          'ALTER TABLE transactions ADD COLUMN fingerprint TEXT',
        );
        await db.execute(
          'CREATE UNIQUE INDEX tx_fingerprint ON transactions(fingerprint)',
        );
      }
      if (oldVersion < 3) {
        for (final column in const [
          'account_id INTEGER',
          'reference TEXT',
          'balance_after_minor INTEGER',
          "category_source TEXT NOT NULL DEFAULT 'manual'",
          'needs_review INTEGER NOT NULL DEFAULT 0',
        ])
          await db.execute('ALTER TABLE transactions ADD COLUMN $column');
        await _createV3(db);
        await _adoptLegacyOpeningBalance(db);
      }
      if (oldVersion < 4) {
        for (final column in const [
          'exclude_from_budget INTEGER NOT NULL DEFAULT 0',
          'transfer_account_id INTEGER',
        ])
          await db.execute('ALTER TABLE transactions ADD COLUMN $column');
        // A fresh-from-<3 upgrade already created accounts with these
        // columns via _createV3 above; only a v3 install needs them added.
        if (oldVersion >= 3)
          for (final column in const [
            'in_budget INTEGER NOT NULL DEFAULT 1',
            'min_balance_minor INTEGER',
          ])
            await db.execute('ALTER TABLE accounts ADD COLUMN $column');
      }
    },
  );

  static Future<void> _createV3(Database db) async {
    await db.execute('''CREATE TABLE accounts (
      id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
      last4 TEXT NOT NULL DEFAULT '', opening_balance_minor INTEGER NOT NULL DEFAULT 0,
      reported_balance_minor INTEGER, reported_at INTEGER,
      in_budget INTEGER NOT NULL DEFAULT 1, min_balance_minor INTEGER)''');
    await db.execute('''CREATE TABLE merchant_rules (
      merchant_key TEXT PRIMARY KEY, category TEXT NOT NULL,
      hits INTEGER NOT NULL DEFAULT 1)''');
    await db.execute('''CREATE TABLE token_stats (
      token TEXT NOT NULL, category TEXT NOT NULL,
      count INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (token, category))''');
    await db.execute('''CREATE TABLE category_stats (
      category TEXT PRIMARY KEY, count INTEGER NOT NULL DEFAULT 0)''');
    await db.execute('CREATE INDEX tx_review ON transactions(needs_review)');
  }

  /// v2 kept one global opening balance in `settings`. Carry it into a real
  /// account row so upgraders keep their starting figure.
  static Future<void> _adoptLegacyOpeningBalance(Database db) async {
    final rows = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: ['opening_balance'],
    );
    if (rows.isEmpty) return;
    final opening = int.tryParse(rows.single['value'] as String? ?? '0') ?? 0;
    final id = await db.insert('accounts', {
      'name': 'Main account',
      'last4': '',
      'opening_balance_minor': opening,
    });
    await db.update('transactions', {'account_id': id});
  }

  // ---------------------------------------------------------------- settings

  Future<String?> setting(String key) async => (await _db)
      .query('settings', columns: ['value'], where: 'key = ?', whereArgs: [key])
      .then((rows) => rows.isEmpty ? null : rows.single['value'] as String);

  Future<void> setSetting(String key, String value) async => (await _db).insert(
    'settings',
    {'key': key, 'value': value},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  Future<String> currency() async => await setting('currency') ?? '₹';

  Future<int> budgetStartDay() async =>
      int.tryParse(await setting('budget_start_day') ?? '1') ?? 1;

  // ---------------------------------------------------------------- accounts

  Future<List<Account>> accounts() async => (await _db)
      .query('accounts', orderBy: 'id')
      .then((rows) => rows.map(Account.fromMap).toList());

  Future<int> addAccount(Account account) async =>
      (await _db).insert('accounts', account.toMap()..remove('id'));

  Future<void> updateAccount(Account account) async => (await _db).update(
    'accounts',
    account.toMap()..remove('id'),
    where: 'id = ?',
    whereArgs: [account.id],
  );

  Future<void> deleteAccount(int id) async {
    final db = await _db;
    await db.update(
      'transactions',
      {'account_id': null},
      where: 'account_id = ?',
      whereArgs: [id],
    );
    await db.delete('accounts', where: 'id = ?', whereArgs: [id]);
  }

  /// Matches a bank-supplied last-4 to a tracked account. Returns null when no
  /// account claims those digits, so ingestion can still store the row.
  Future<Account?> accountForLast4(String? last4) async {
    if (last4 == null || last4.isEmpty) return null;
    final rows = await (await _db).query(
      'accounts',
      where: 'last4 = ?',
      whereArgs: [last4],
      limit: 1,
    );
    return rows.isEmpty ? null : Account.fromMap(rows.single);
  }

  /// Stores the running balance a bank stated, for reconciliation against the
  /// ledger's own arithmetic.
  Future<void> recordReportedBalance(
    int accountId,
    int balanceMinor,
    DateTime at,
  ) async => (await _db).update(
    'accounts',
    {
      'reported_balance_minor': balanceMinor,
      'reported_at': at.millisecondsSinceEpoch,
    },
    // Historic scans arrive out of order; only a newer balance may replace one.
    where: 'id = ? AND (reported_at IS NULL OR reported_at < ?)',
    whereArgs: [accountId, at.millisecondsSinceEpoch],
  );

  // ------------------------------------------------------------ transactions

  Future<List<TallyTransaction>> transactions({
    int limit = 500,
    int? accountId,
  }) async => (await _db)
      .query(
        'transactions',
        where: accountId == null ? null : 'account_id = ?',
        whereArgs: accountId == null ? null : [accountId],
        orderBy: 'occurred_at DESC',
        limit: limit,
      )
      .then((rows) => rows.map(TallyTransaction.fromMap).toList());

  /// Rows whose category was a low-confidence guess, newest first.
  Future<List<TallyTransaction>> reviewQueue({int limit = 50}) async =>
      (await _db)
          .query(
            'transactions',
            where: 'needs_review = 1',
            orderBy: 'occurred_at DESC',
            limit: limit,
          )
          .then((rows) => rows.map(TallyTransaction.fromMap).toList());

  /// Inserts unless an identical fingerprint is already stored. Returns whether
  /// a row was actually written.
  Future<bool> add(TallyTransaction transaction) async =>
      !await _hasReference(transaction) &&
      await (await _db).insert(
            'transactions',
            transaction.toMap()..remove('id'),
            conflictAlgorithm: ConflictAlgorithm.ignore,
          ) >
          0;

  /// The bank and a UPI app often both text about one payment, and statements
  /// repeat it again; a shared reference number with the same amount on the
  /// same account is the same money. Scoped to the account so the two legs of
  /// a self transfer (same reference, same amount, different accounts) both
  /// land in the ledger for [linkSelfTransfers] to pair up.
  Future<bool> _hasReference(TallyTransaction t) async =>
      (t.reference ?? '').isNotEmpty &&
      (await (await _db).query(
        'transactions',
        columns: ['id'],
        where: t.accountId == null
            ? 'reference = ? AND amount_minor = ? AND account_id IS NULL'
            : 'reference = ? AND amount_minor = ? AND account_id = ?',
        whereArgs: t.accountId == null
            ? [t.reference, t.amountMinor]
            : [t.reference, t.amountMinor, t.accountId],
        limit: 1,
      )).isNotEmpty;

  Future<int> addAll(Iterable<TallyTransaction> rows) async {
    var inserted = 0;
    final db = await _db;
    final batch = db.batch();
    for (final row in rows)
      batch.insert(
        'transactions',
        row.toMap()..remove('id'),
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
    for (final result in await batch.commit())
      if (result is int && result > 0) inserted++;
    return inserted;
  }

  /// Finds already-imported rows that are really two legs of one self
  /// transfer, keeps the debit (turned into a transfer), and drops the
  /// credit. Safe to call after every ingest: already-linked transfers don't
  /// match [findSelfTransfers] again since their kind is no longer expense.
  Future<int> linkSelfTransfers() async {
    final db = await _db;
    final rows = await transactions(limit: -1);
    final matches = findSelfTransfers(rows);
    for (final match in matches) {
      await db.update(
        'transactions',
        {
          'kind': TransactionKind.transfer.name,
          'transfer_account_id': match.credit.accountId,
          'exclude_from_budget': 1,
          'category': 'Transfers',
        },
        where: 'id = ?',
        whereArgs: [match.debit.id],
      );
      await db.delete(
        'transactions',
        where: 'id = ?',
        whereArgs: [match.credit.id],
      );
    }
    return matches.length;
  }

  /// Total spend in [period] on accounts that count toward the budget,
  /// excluding flagged rows, transfers, and rows with no account. The
  /// filtering itself is [budgetSpent], a pure function tested without sqflite.
  Future<List<TallyTransaction>> budgetRows(BudgetPeriod period) async =>
      budgetTransactions(
        await transactions(limit: -1),
        await accounts(),
        period,
      ).toList();

  Future<int> spentInPeriod(BudgetPeriod period) async =>
      budgetSpent(await transactions(limit: -1), await accounts(), period);

  Future<void> delete(int id) async =>
      (await _db).delete('transactions', where: 'id = ?', whereArgs: [id]);

  /// Removes every SMS-sourced transaction so the inbox can be re-read after
  /// a parser fix, without touching manual or statement entries or learned
  /// merchant rules.
  Future<void> deleteSmsRows() async =>
      (await _db).delete('transactions', where: "source = 'sms'");

  Future<void> updateTransaction(TallyTransaction transaction) async =>
      (await _db).update(
        'transactions',
        transaction.toMap()..remove('id'),
        where: 'id = ?',
        whereArgs: [transaction.id],
      );

  /// Applies a confirmed category to every other row from the same merchant
  /// that the user has not already labelled by hand. This is what stops the
  /// user re-labelling a recurring merchant. Returns the number of rows moved.
  Future<int> applyCategoryToMerchant(
    String merchantKey,
    String category,
  ) async {
    final db = await _db;
    final rows = await db.query(
      'transactions',
      columns: ['id', 'merchant'],
      where: 'category_source != ?',
      whereArgs: [CategorySource.manual.name],
    );
    final ids = rows
        .where(
          (row) =>
              Categorizer.merchantKey(row['merchant'] as String) == merchantKey,
        )
        .map((row) => row['id'] as int)
        .toList();
    if (ids.isEmpty) return 0;
    return db.update(
      'transactions',
      {
        'category': category,
        'category_source': CategorySource.learned.name,
        'needs_review': 0,
      },
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
  }

  // -------------------------------------------------- CategoryStore (learning)

  @override
  Future<String?> merchantCategory(String merchantKey) async => (await _db)
      .query(
        'merchant_rules',
        columns: ['category'],
        where: 'merchant_key = ?',
        whereArgs: [merchantKey],
        limit: 1,
      )
      .then((rows) => rows.isEmpty ? null : rows.single['category'] as String);

  @override
  Future<void> saveMerchantCategory(
    String merchantKey,
    String category,
  ) async => (await _db).rawInsert(
    '''INSERT INTO merchant_rules (merchant_key, category, hits) VALUES (?, ?, 1)
           ON CONFLICT(merchant_key) DO UPDATE SET category = excluded.category,
           hits = hits + 1''',
    [merchantKey, category],
  );

  @override
  Future<Map<String, int>> tokenCounts(String token) async => (await _db)
      .query(
        'token_stats',
        columns: ['category', 'count'],
        where: 'token = ?',
        whereArgs: [token],
      )
      .then(
        (rows) => {
          for (final row in rows)
            row['category'] as String: row['count'] as int,
        },
      );

  @override
  Future<Map<String, int>> categoryCounts() async => (await _db)
      .query('category_stats')
      .then(
        (rows) => {
          for (final row in rows)
            row['category'] as String: row['count'] as int,
        },
      );

  @override
  Future<void> train(List<String> tokens, String category) async {
    final db = await _db;
    final batch = db.batch();
    for (final token in tokens)
      batch.rawInsert(
        '''INSERT INTO token_stats (token, category, count) VALUES (?, ?, 1)
           ON CONFLICT(token, category) DO UPDATE SET count = count + 1''',
        [token, category],
      );
    batch.rawInsert(
      '''INSERT INTO category_stats (category, count) VALUES (?, 1)
         ON CONFLICT(category) DO UPDATE SET count = count + 1''',
      [category],
    );
    await batch.commit(noResult: true);
  }

  /// Everything the user has ever labelled, for the "what Tally has learned"
  /// view in Settings.
  Future<List<(String, String, int)>> learnedRules({int limit = 200}) async =>
      (await _db)
          .query('merchant_rules', orderBy: 'hits DESC', limit: limit)
          .then(
            (rows) => rows
                .map(
                  (row) => (
                    row['merchant_key'] as String,
                    row['category'] as String,
                    row['hits'] as int,
                  ),
                )
                .toList(),
          );

  Future<void> forgetRule(String merchantKey) async => (await _db).delete(
    'merchant_rules',
    where: 'merchant_key = ?',
    whereArgs: [merchantKey],
  );

  /// Categories with budget-counted spend inside [period], largest first.
  /// Computed in SQL so the UI never walks the whole table.
  Future<List<(String, int)>> spendByCategory(BudgetPeriod period) async {
    final rows = await (await _db).rawQuery(
      '''SELECT t.category AS category, SUM(t.amount_minor) AS total FROM transactions t
         JOIN accounts a ON a.id = t.account_id
         WHERE t.kind = ? AND t.exclude_from_budget = 0 AND a.in_budget = 1
           AND t.occurred_at >= ? AND t.occurred_at < ?
         GROUP BY t.category ORDER BY total DESC''',
      [
        TransactionKind.expense.name,
        period.start.millisecondsSinceEpoch,
        period.end.millisecondsSinceEpoch,
      ],
    );
    return rows
        .map((row) => (row['category'] as String, (row['total'] as int?) ?? 0))
        .toList();
  }

  /// Budget-counted spend for each calendar day inside [period], keyed by the
  /// day's midnight timestamp so days with no spend can still show a bar.
  Future<Map<DateTime, int>> dailySpend(BudgetPeriod period) async {
    final rows = await (await _db).rawQuery(
      '''SELECT t.occurred_at AS at, t.amount_minor AS amount FROM transactions t
         JOIN accounts a ON a.id = t.account_id
         WHERE t.kind = ? AND t.exclude_from_budget = 0 AND a.in_budget = 1
           AND t.occurred_at >= ? AND t.occurred_at < ?''',
      [
        TransactionKind.expense.name,
        period.start.millisecondsSinceEpoch,
        period.end.millisecondsSinceEpoch,
      ],
    );
    final byDay = <DateTime, int>{};
    for (final row in rows) {
      final at = DateTime.fromMillisecondsSinceEpoch(row['at'] as int);
      final day = DateTime(at.year, at.month, at.day);
      byDay[day] = (byDay[day] ?? 0) + (row['amount'] as int? ?? 0);
    }
    return byDay;
  }

  /// Seeds the fixed category list so the budget screen has rows to show even
  /// before anything is labelled.
  Future<void> ensureCategorySeed() async {
    final counts = await categoryCounts();
    if (counts.isNotEmpty) return;
    final db = await _db;
    final batch = db.batch();
    for (final category in kCategories)
      batch.insert('category_stats', {'category': category, 'count': 0});
    await batch.commit(noResult: true);
  }
}
