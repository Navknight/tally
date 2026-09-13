import 'package:flutter_test/flutter_test.dart';
import 'package:tally/platform/android_bridge.dart';
import 'package:tally/services/sms/bank_parser.dart';
import 'package:tally/services/sms/bank_parsers.dart';
import 'package:tally/services/sms_ingestion.dart';

void main() {
  test('parses a debit SMS using its original timestamp', () {
    final message = BankSms(
      sender: 'AD-HDFCBK',
      timestamp: DateTime(2026, 9, 12, 9, 30),
      body: 'Rs. 1,234.50 debited from your account at ACME MART',
    );
    final parsed = parseBankSms(sender: message.sender, body: message.body);
    expect(parsed, isA<SmsTransaction>());
    final row = buildTransaction(
      parsed: parsed as SmsTransaction,
      message: message,
      category: 'Uncategorized',
    );
    expect(row.amountMinor, 123450);
    expect(row.occurredAt, message.timestamp);
    expect(row.merchant, 'Acme Mart');
    expect(row.fingerprint, isNotEmpty);
  });

  test('ignores an OTP message', () {
    expect(
      parseBankSms(sender: 'VM-HDFCBK', body: 'Your OTP is 123456'),
      isA<SmsIgnored>(),
    );
  });

  test('fingerprint excludes the timestamp', () {
    String fp(DateTime at) => buildTransaction(
      parsed:
          parseBankSms(sender: 'AD-HDFCBK', body: 'Rs.500 debited at ACME')
              as SmsTransaction,
      message: BankSms(
        sender: 'AD-HDFCBK',
        timestamp: at,
        body: 'Rs.500 debited at ACME',
      ),
      category: 'Uncategorized',
    ).fingerprint!;
    expect(fp(DateTime(2026)), fp(DateTime(2027)));
  });
}
