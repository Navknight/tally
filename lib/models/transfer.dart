import 'transaction.dart';

/// One self-transfer pairing: [debit] (an expense on the source account) and
/// [credit] (an income on the destination account) are actually one movement
/// of money. The caller keeps the debit, converted into a transfer, and drops
/// the credit.
class TransferMatch {
  const TransferMatch({required this.debit, required this.credit});
  final TallyTransaction debit;
  final TallyTransaction credit;
}

const _window = Duration(minutes: 30);

/// True when [debit] and [credit] look like two legs of one self transfer:
/// an expense and an income, same amount, different tracked accounts, within
/// 30 minutes of each other, and matching references when both carry one.
bool isSelfTransferPair(TallyTransaction debit, TallyTransaction credit) {
  if (debit.kind != TransactionKind.expense) return false;
  if (credit.kind != TransactionKind.income) return false;
  if (debit.accountId == null || credit.accountId == null) return false;
  if (debit.accountId == credit.accountId) return false;
  if (debit.amountMinor != credit.amountMinor) return false;
  if (debit.occurredAt.difference(credit.occurredAt).abs() > _window)
    return false;
  final dRef = debit.reference;
  final cRef = credit.reference;
  if (dRef != null &&
      dRef.isNotEmpty &&
      cRef != null &&
      cRef.isNotEmpty &&
      dRef != cRef)
    return false;
  return true;
}

/// Scans [rows] for self-transfer pairs, matching each debit to at most one
/// credit (the closest in time), each credit used at most once.
///
// ponytail: O(n^2) scan; fine for one device's transaction history, revisit
// with a time-bucketed index if a ledger ever runs into the tens of thousands.
List<TransferMatch> findSelfTransfers(List<TallyTransaction> rows) {
  final matches = <TransferMatch>[];
  final usedCredits = <int>{};
  for (final debit in rows) {
    if (debit.kind != TransactionKind.expense) continue;
    TallyTransaction? best;
    Duration? bestDiff;
    for (final credit in rows) {
      if (credit.id == null || usedCredits.contains(credit.id)) continue;
      if (!isSelfTransferPair(debit, credit)) continue;
      final diff = debit.occurredAt.difference(credit.occurredAt).abs();
      if (bestDiff == null || diff < bestDiff) {
        best = credit;
        bestDiff = diff;
      }
    }
    if (best != null) {
      matches.add(TransferMatch(debit: debit, credit: best));
      usedCredits.add(best.id!);
    }
  }
  return matches;
}
