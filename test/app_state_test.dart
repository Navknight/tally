import 'package:flutter_test/flutter_test.dart';
import 'package:tally/state/app_state.dart';

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
}
