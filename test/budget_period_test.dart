import 'package:flutter_test/flutter_test.dart';
import 'package:tally/core/budget_period.dart';

void main() {
  test('period with start day 1 is the calendar month', () {
    final period = budgetPeriod(DateTime(2026, 9, 13), 1);
    expect(period.start, DateTime(2026, 9, 1));
    expect(period.end, DateTime(2026, 10, 1));
  });

  test('start day 25 spans two calendar months', () {
    final period = budgetPeriod(DateTime(2026, 9, 13), 25);
    expect(period.start, DateTime(2026, 8, 25));
    expect(period.end, DateTime(2026, 9, 25));
  });

  test('start day 25 after the day rolls into the current month', () {
    final period = budgetPeriod(DateTime(2026, 9, 30), 25);
    expect(period.start, DateTime(2026, 9, 25));
    expect(period.end, DateTime(2026, 10, 25));
  });

  test('a January period anchored late in the month wraps the year', () {
    final period = budgetPeriod(DateTime(2026, 1, 5), 25);
    expect(period.start, DateTime(2025, 12, 25));
    expect(period.end, DateTime(2026, 1, 25));
  });

  test('short months still land on day 28', () {
    final period = budgetPeriod(DateTime(2026, 3, 1), 28);
    expect(period.start, DateTime(2026, 2, 28));
    expect(period.end, DateTime(2026, 3, 28));
  });

  test('contains is a half-open range', () {
    final period = budgetPeriod(DateTime(2026, 9, 13), 25);
    expect(period.contains(period.start), isTrue);
    expect(period.contains(period.end), isFalse);
    expect(period.contains(period.end.subtract(const Duration(milliseconds: 1))), isTrue);
  });
}
