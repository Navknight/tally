import 'package:flutter_test/flutter_test.dart';
import 'package:tally/core/money.dart';

void main() {
  test('money values use integer minor units', () {
    expect(parseMoney('₹1,234.50'), 123450);
    expect(money(-123450, '₹'), '-₹1,234.50');
  });
}
