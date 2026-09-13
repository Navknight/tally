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
  });

  final int? id;
  final String name;
  final String last4;
  final int openingBalanceMinor;

  /// Running balance as last stated by the bank itself, used to reconcile
  /// against the ledger's own arithmetic. Null until a message reports one.
  final int? reportedBalanceMinor;
  final DateTime? reportedAt;

  Account copyWith({int? id, String? name, String? last4}) => Account(
    id: id ?? this.id,
    name: name ?? this.name,
    last4: last4 ?? this.last4,
    openingBalanceMinor: openingBalanceMinor,
    reportedBalanceMinor: reportedBalanceMinor,
    reportedAt: reportedAt,
  );

  Map<String, Object?> toMap() => {
    'id': id,
    'name': name,
    'last4': last4,
    'opening_balance_minor': openingBalanceMinor,
    'reported_balance_minor': reportedBalanceMinor,
    'reported_at': reportedAt?.millisecondsSinceEpoch,
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
  );
}
