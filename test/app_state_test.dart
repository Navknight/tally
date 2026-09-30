import 'package:flutter_test/flutter_test.dart';
import 'package:tally/models/transaction.dart';
import 'package:tally/state/app_state.dart';

TallyTransaction _row(DateTime at, int minor, TransactionKind kind) =>
    TallyTransaction(
      id: at.millisecondsSinceEpoch,
      amountMinor: minor,
      kind: kind,
      occurredAt: at,
      merchant: 'x',
      category: 'Other',
    );

/// Counts reads instead of running them, so the overlap rule is testable
/// without a database.
class _CountingState extends AppState {
  int reads = 0;
  @override
  Future<void> read() async {
    reads++;
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('overlapping loads collapse into one extra read', () async {
    final state = _CountingState();
    final first = state.load();
    // Three more arrive while the first is still running.
    await Future.wait([first, state.load(), state.load(), state.load()]);
    expect(state.reads, 2);
    expect(state.loaded, isTrue);
  });

  test('a later load reads again', () async {
    final state = _CountingState();
    await state.load();
    await state.load();
    expect(state.reads, 2);
  });

  group('groupByDay', () {
    test('splits consecutive days and totals only expenses', () {
      final days = groupByDay([
        _row(DateTime(2026, 9, 30, 18), 500, TransactionKind.expense),
        _row(DateTime(2026, 9, 30, 9), 300, TransactionKind.expense),
        _row(DateTime(2026, 9, 30, 8), 90000, TransactionKind.income),
        _row(DateTime(2026, 9, 29, 22), 250, TransactionKind.expense),
        _row(DateTime(2026, 9, 29, 7), 100, TransactionKind.transfer),
      ]);
      expect(days.map((d) => d.day), [
        DateTime(2026, 9, 30),
        DateTime(2026, 9, 29),
      ]);
      expect(days.first.rows, hasLength(3));
      expect(days.first.spent, 800);
      expect(days.last.spent, 250);
    });

    test('an empty ledger has no days', () {
      expect(groupByDay(const []), isEmpty);
    });

    test('one day that spans midnight stays two days', () {
      final days = groupByDay([
        _row(DateTime(2026, 9, 30, 0, 5), 100, TransactionKind.expense),
        _row(DateTime(2026, 9, 29, 23, 55), 200, TransactionKind.expense),
      ]);
      expect(days, hasLength(2));
    });
  });
}
