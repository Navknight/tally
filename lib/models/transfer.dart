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
/// Credits are sorted by time once, so each debit only scans the ±30 minute
/// window around it instead of every credit in the ledger.
List<TransferMatch> findSelfTransfers(List<TallyTransaction> rows) {
  final credits =
      rows.where((t) => t.kind == TransactionKind.income && t.id != null).toList()
        ..sort((a, b) => a.occurredAt.compareTo(b.occurredAt));
  final matches = <TransferMatch>[];
  final usedCredits = <int>{};
  for (final debit in rows) {
    if (debit.kind != TransactionKind.expense) continue;
    final low = debit.occurredAt.subtract(_window);
    final high = debit.occurredAt.add(_window);
    var start = _lowerBound(credits, low);
    TallyTransaction? best;
    Duration? bestDiff;
    for (var i = start; i < credits.length; i++) {
      final credit = credits[i];
      if (credit.occurredAt.isAfter(high)) break;
      if (usedCredits.contains(credit.id)) continue;
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

/// Index of the first entry in [sorted] (ascending by [TallyTransaction.occurredAt])
/// whose time is not before [at].
int _lowerBound(List<TallyTransaction> sorted, DateTime at) {
  var lo = 0, hi = sorted.length;
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (sorted[mid].occurredAt.isBefore(at))
      lo = mid + 1;
    else
      hi = mid;
  }
  return lo;
}
