import 'account.dart';

/// A (bank, last4) pair seen in parsed SMS that matches no tracked account,
/// offered on Home as "Found SBI ••2774 in 214 messages" until added or
/// dismissed.
class DetectedAccount {
  const DetectedAccount({
    required this.bank,
    required this.last4,
    required this.kind,
    required this.messageCount,
    this.lastBalanceMinor,
    required this.lastSeen,
    this.dismissed = false,
  });

  final String bank;
  final String last4;
  final AccountKind kind;
  final int messageCount;
  final int? lastBalanceMinor;
  final DateTime lastSeen;
  final bool dismissed;

  String get suggestedName =>
      kind == AccountKind.card ? '$bank card ••$last4' : '$bank ••$last4';

  Map<String, Object?> toMap() => {
    'bank': bank,
    'last4': last4,
    'kind': kind.name,
    'message_count': messageCount,
    'last_balance_minor': lastBalanceMinor,
    'last_seen': lastSeen.millisecondsSinceEpoch,
    'dismissed': dismissed ? 1 : 0,
  };

  factory DetectedAccount.fromMap(Map<String, Object?> map) => DetectedAccount(
    bank: map['bank'] as String,
    last4: map['last4'] as String,
    kind: AccountKind.values.firstWhere(
      (v) => v.name == map['kind'],
      orElse: () => AccountKind.bank,
    ),
    messageCount: (map['message_count'] as int?) ?? 0,
    lastBalanceMinor: map['last_balance_minor'] as int?,
    lastSeen: DateTime.fromMillisecondsSinceEpoch(map['last_seen'] as int),
    dismissed: ((map['dismissed'] as int?) ?? 0) == 1,
  );
}
