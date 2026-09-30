/// A half-open date range: `[start, end)`.
class BudgetPeriod {
  const BudgetPeriod(this.start, this.end);
  final DateTime start;
  final DateTime end;
  bool contains(DateTime at) => !at.isBefore(start) && at.isBefore(end);
}

/// The budget period containing [now], anchored on [startDay] (1-28: the
/// settings screen only offers that range, so every month has that day).
/// e.g. startDay 25 in September gives 25 Aug - 24 Sep.
BudgetPeriod budgetPeriod(DateTime now, int startDay) {
  final day = startDay.clamp(1, 28);
  final start = now.day >= day
      ? DateTime(now.year, now.month, day)
      : DateTime(now.year, now.month - 1, day);
  return BudgetPeriod(start, DateTime(start.year, start.month + 1, day));
}

/// How far through the period [now] is, 0 to 1. Spending evenly, this is the
/// share of the limit that should be gone by now, which is what the marker on
/// the budget bar points at.
double budgetPace(BudgetPeriod period, DateTime now) {
  final total = period.end.difference(period.start).inMinutes;
  if (total <= 0) return 1;
  final elapsed = now.difference(period.start).inMinutes;
  return (elapsed / total).clamp(0, 1).toDouble();
}
