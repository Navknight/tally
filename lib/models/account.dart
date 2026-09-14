import '../core/budget_period.dart';
import 'transaction.dart';

/// A bank account, card or wallet the ledger tracks.
///
/// [last4] is how an incoming SMS is matched back to an account: bank messages
/// name the account as "A/c XX1234" rather than by any id we control.
class Account {
  const Account({
    required this.id,
    required this.name,
    required this.last4,
    required this.openingBalanceMinor,
    this.reportedBalanceMinor,
    this.reportedAt,
    this.inBudget = true,
    this.minBalanceMinor,
    this.kind = AccountKind.bank,
  });

  final int? id;
  final String name;
  final String last4;
  final int openingBalanceMinor;
  final AccountKind kind;

  /// Running balance as last stated by the bank itself, used to reconcile
  /// against the ledger's own arithmetic. Null until a message reports one.
  final int? reportedBalanceMinor;
  final DateTime? reportedAt;

  /// Whether this account's spending counts toward the budget.
  final bool inBudget;

  /// Optional floor; the home screen warns when the balance dips below it.
  final int? minBalanceMinor;

  Account copyWith({
    int? id,
    String? name,
    String? last4,
    int? openingBalanceMinor,
    int? reportedBalanceMinor,
    DateTime? reportedAt,
    bool? inBudget,
    int? minBalanceMinor,
    bool clearMinBalance = false,
    AccountKind? kind,
  }) => Account(
    id: id ?? this.id,
    name: name ?? this.name,
    last4: last4 ?? this.last4,
    openingBalanceMinor: openingBalanceMinor ?? this.openingBalanceMinor,
    reportedBalanceMinor: reportedBalanceMinor ?? this.reportedBalanceMinor,
    reportedAt: reportedAt ?? this.reportedAt,
    inBudget: inBudget ?? this.inBudget,
    minBalanceMinor: clearMinBalance
        ? null
        : (minBalanceMinor ?? this.minBalanceMinor),
    kind: kind ?? this.kind,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'last4': last4,
    'opening_balance_minor': openingBalanceMinor,
    'reported_balance_minor': reportedBalanceMinor,
    'reported_at': reportedAt?.millisecondsSinceEpoch,
    'in_budget': inBudget ? 1 : 0,
    'min_balance_minor': minBalanceMinor,
    'kind': kind.name,
  };

  factory Account.fromMap(Map<String, Object?> map) => Account(
    id: map['id'] as int?,
    name: map['name'] as String,
    last4: (map['last4'] as String?) ?? '',
    openingBalanceMinor: (map['opening_balance_minor'] as int?) ?? 0,
    reportedBalanceMinor: map['reported_balance_minor'] as int?,
    reportedAt: map['reported_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(map['reported_at'] as int),
    inBudget: ((map['in_budget'] as int?) ?? 1) == 1,
    minBalanceMinor: map['min_balance_minor'] as int?,
    kind: AccountKind.values.firstWhere(
      (v) => v.name == map['kind'],
      orElse: () => AccountKind.bank,
    ),
  );
}

/// True when two last-4-digit strings could name the same account or card:
/// an exact match, or one ending in the other (a message that quoted more
/// digits than another did, e.g. "XX3001" vs "3001"). Empty strings never
/// match anything, including each other.
bool last4Matches(String a, String b) {
  if (a.isEmpty || b.isEmpty) return false;
  return a.endsWith(b) || b.endsWith(a);
}

/// Whether an orphan transaction (`accountLast4`/`bank` as parsed, no
/// `accountId` yet) should be claimed by an account or detection identified
/// by [last4]/[bank]. Bank only excludes a match when both sides name one and
/// they differ, since plenty of parsed rows carry no bank at all.
bool matchesForClaim({
  required String rowLast4,
  required String? rowBank,
  required String last4,
  String? bank,
}) {
  if (!last4Matches(rowLast4, last4)) return false;
  if (bank != null && rowBank != null && rowBank != bank) return false;
  return true;
}

/// Whether an account is a bank account or a credit card. Cards count toward
/// the budget but never toward [totalBalance] or a minimum-balance warning:
/// their "Avl Limit" is not money the user has.
enum AccountKind { bank, card }

/// Opening balance plus every transaction booked against [account].
/// The latest known balance plus everything after it. The anchor is the newest
/// balance a bank SMS or statement reported, or the balance typed in when the
/// account was set up; older transactions are already inside that number.
///
/// A self transfer is booked on its source account (`accountId`) with
/// `transferAccountId` pointing at the destination: it counts as an outflow
/// there and an inflow on the destination account, so the pair nets to zero
/// across the portfolio but moves money between the two balances.
int accountBalance(Account account, Iterable<TallyTransaction> transactions) {
  final at = account.reportedAt;
  bool afterAnchor(DateTime when) => at == null || when.isAfter(at);
  return (at == null
          ? account.openingBalanceMinor
          : account.reportedBalanceMinor ?? account.openingBalanceMinor) +
      transactions.fold<int>(0, (sum, t) {
        if (t.accountId == account.id && afterAnchor(t.occurredAt))
          return sum +
              (t.kind == TransactionKind.transfer
                  ? -t.amountMinor
                  : t.signedMinor);
        if (t.transferAccountId == account.id && afterAnchor(t.occurredAt))
          return sum + t.amountMinor;
        return sum;
      });
}

/// Rows that matched no account (a credit card, someone else's bank) are
/// listed but never move the balance. Card accounts also never count: their
/// balance is what's owed, not money the user has.
int totalBalance(List<Account> accounts, List<TallyTransaction> transactions) =>
    accounts
        .where((a) => a.kind == AccountKind.bank)
        .fold<int>(0, (sum, a) => sum + accountBalance(a, transactions));

/// Total spend inside [period] that counts toward the budget: expenses only,
/// on accounts flagged [Account.inBudget], excluding rows flagged
/// [TallyTransaction.excludeFromBudget], transfers, and rows with no account.
int budgetSpent(
  Iterable<TallyTransaction> transactions,
  Iterable<Account> accounts,
  BudgetPeriod period,
) => budgetTransactions(
  transactions,
  accounts,
  period,
).fold<int>(0, (sum, t) => sum + t.amountMinor);

/// The rows [budgetSpent] adds up, for listing them.
Iterable<TallyTransaction> budgetTransactions(
  Iterable<TallyTransaction> transactions,
  Iterable<Account> accounts,
  BudgetPeriod period,
) {
  final inBudget = {for (final a in accounts) a.id: a.inBudget};
  return transactions.where(
    (t) =>
        t.kind == TransactionKind.expense &&
        !t.excludeFromBudget &&
        t.accountId != null &&
        (inBudget[t.accountId] ?? false) &&
        period.contains(t.occurredAt),
  );
}
