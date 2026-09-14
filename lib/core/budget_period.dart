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
