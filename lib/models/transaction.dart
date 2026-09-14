import '../models/categories.dart';

enum TransactionKind { expense, income, transfer }

/// How a row's category was decided. Only [CategorySource.manual] is treated as
/// ground truth by the learner — everything else is a guess it may revise.
enum CategorySource { manual, learned, imported }

class TallyTransaction {
  const TallyTransaction({
    required this.id,
    required this.amountMinor,
    required this.kind,
    required this.occurredAt,
    required this.merchant,
    required this.category,
    this.note = '',
    this.source = 'manual',
    this.fingerprint,
    this.accountId,
    this.reference,
    this.balanceAfterMinor,
    this.categorySource = CategorySource.manual,
    this.needsReview = false,
    this.excludeFromBudget = false,
    this.transferAccountId,
  });

  final int? id;
  final int amountMinor;
  final TransactionKind kind;
  final DateTime occurredAt;
  final String merchant;
  final String category;
  final String note;

  /// Where the row came from: `manual`, `sms`, `csv` or `pdf`.
  final String source;

  /// Stable identity for imported transactions; null for user-entered rows.
  final String? fingerprint;

  final int? accountId;

  /// Bank-supplied reference (UPI id, cheque number) when the message has one.
  final String? reference;

  /// Running balance the bank stated in the same message, used for
  /// reconciliation. Null when unknown.
  final int? balanceAfterMinor;

  final CategorySource categorySource;

  /// True when the category is a low-confidence guess and worth confirming.
  final bool needsReview;

  /// True when this row should not count toward the budget, regardless of
  /// kind or account (manually flagged, or a self transfer).
  final bool excludeFromBudget;

  /// Destination account for a [TransactionKind.transfer] row; [accountId] is
  /// the source. Null for every other kind.
  final int? transferAccountId;

  /// Signed effect on a balance. Transfers between tracked accounts net out at
  /// the portfolio level, so they contribute nothing.
  int get signedMinor => switch (kind) {
    TransactionKind.income => amountMinor,
    TransactionKind.expense => -amountMinor,
    TransactionKind.transfer => 0,
  };

  bool get isSpend => kind == TransactionKind.expense;

  TallyTransaction copyWith({
    int? id,
    int? amountMinor,
    TransactionKind? kind,
    DateTime? occurredAt,
    String? category,
    String? merchant,
    String? note,
    int? accountId,
    CategorySource? categorySource,
    bool? needsReview,
    bool? excludeFromBudget,
    int? transferAccountId,
    bool clearTransferAccount = false,
  }) => TallyTransaction(
    id: id ?? this.id,
    amountMinor: amountMinor ?? this.amountMinor,
    kind: kind ?? this.kind,
    occurredAt: occurredAt ?? this.occurredAt,
    merchant: merchant ?? this.merchant,
    category: category ?? this.category,
    note: note ?? this.note,
    source: source,
    fingerprint: fingerprint,
    accountId: accountId ?? this.accountId,
    reference: reference,
    balanceAfterMinor: balanceAfterMinor,
    categorySource: categorySource ?? this.categorySource,
    needsReview: needsReview ?? this.needsReview,
    excludeFromBudget: excludeFromBudget ?? this.excludeFromBudget,
    transferAccountId: clearTransferAccount
        ? null
        : (transferAccountId ?? this.transferAccountId),
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'amount_minor': amountMinor,
    'kind': kind.name,
    'occurred_at': occurredAt.millisecondsSinceEpoch,
    'merchant': merchant,
    'category': category,
    'note': note,
    'source': source,
    'fingerprint': fingerprint,
    'account_id': accountId,
    'reference': reference,
    'balance_after_minor': balanceAfterMinor,
    'category_source': categorySource.name,
    'needs_review': needsReview ? 1 : 0,
    'exclude_from_budget': excludeFromBudget ? 1 : 0,
    'transfer_account_id': transferAccountId,
  };

  factory TallyTransaction.fromMap(Map<String, Object?> map) =>
      TallyTransaction(
        id: map['id'] as int?,
        amountMinor: map['amount_minor'] as int,
        kind: TransactionKind.values.firstWhere(
          (value) => value.name == map['kind'],
          orElse: () => TransactionKind.expense,
        ),
        occurredAt: DateTime.fromMillisecondsSinceEpoch(
          map['occurred_at'] as int,
        ),
        merchant: map['merchant'] as String,
        category: (map['category'] as String?) ?? kUncategorized,
        note: (map['note'] as String?) ?? '',
        source: (map['source'] as String?) ?? 'manual',
        fingerprint: map['fingerprint'] as String?,
        accountId: map['account_id'] as int?,
        reference: map['reference'] as String?,
        balanceAfterMinor: map['balance_after_minor'] as int?,
        categorySource: CategorySource.values.firstWhere(
          (value) => value.name == map['category_source'],
          orElse: () => CategorySource.manual,
        ),
        needsReview: (map['needs_review'] as int?) == 1,
        excludeFromBudget: (map['exclude_from_budget'] as int?) == 1,
        transferAccountId: map['transfer_account_id'] as int?,
      );
}
