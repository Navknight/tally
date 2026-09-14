import 'package:flutter_test/flutter_test.dart';
import 'package:tally/models/transaction.dart';
import 'package:tally/services/sms/bank_parser.dart';
import 'package:tally/services/sms/bank_parsers.dart';

void main() {
  group('real-world fixtures', () {
    test('SIP debit reminder is a future-tense notice, not a transaction', () {
      final outcome = parseBankSms(
        sender: 'AD-IPRUMF-S',
        body:
            'Dear Investor, SIP of Rs.100 dated 18-09-2026 under Folio '
            '12345678 in Focused Fund - DP Growth is due for debit from '
            'your STATE BANK OF INDIA account-IPRUMF',
      );
      expect(outcome, isA<SmsIgnored>());
    });

    test('SIP purchase confirmation never moves bank money', () {
      final outcome = parseBankSms(
        sender: 'AD-IPRUMF-S',
        body:
            'Dear Investor, Your SIP Purchase of Rs.199.99 in Folio '
            '12345678 in Large & Mid Cap Fund - DP Growth for 0.173 units '
            'has been processed for NAV of Rs.1155.81 on 11-Sep-2026 - '
            'IPRUMF',
      );
      expect(outcome, isA<SmsIgnored>());
    });

    test('SBI NACH debit', () {
      final outcome =
          parseBankSms(
                sender: 'JK-CBSSBI-S',
                body:
                    'Dear Customer, Your A/C XXXXX123456 has a debit by '
                    'NACH of Rs 100.00 on 14/09/26. Avl Bal Rs 3,00,340.48. '
                    'Download YONO - SBI',
              )
              as SmsTransaction;
      expect(outcome.amountMinor, 10000);
      expect(outcome.kind, TransactionKind.expense);
      expect(outcome.balanceAfterMinor, 30034048);
      expect(outcome.bank, 'SBI');
    });

    test('foreign currency card spend is ignored, not booked at the INR limit', () {
      final outcome = parseBankSms(
        sender: 'JD-ICICIT-S',
        body:
            'USD 23.60 spent using ICICI Bank Card XX3001 on 06-Sep-26 on '
            'ANTHROPIC* CLAU. Avl Limit: INR 3,06,279.77. If not you, call '
            '1800 2662/SMS BLOCK 3001 to 9215676766.',
      );
      expect(outcome, isA<SmsIgnored>());
    });

    test('INR card spend: limit never becomes the balance, merchant from "on"', () {
      final outcome =
          parseBankSms(
                sender: 'AD-ICICIT-S',
                body:
                    'INR 422.90 spent using ICICI Bank Card XX3001 on '
                    '06-Sep-26 on AMAZON PAY INDI. Avl Limit: INR '
                    '3,08,510.68. If not you, call 1800 2662/SMS BLOCK 3001 '
                    'to 9215676766.',
              )
              as SmsTransaction;
      expect(outcome.amountMinor, 42290);
      expect(outcome.last4, '3001');
      expect(outcome.merchant, 'Amazon Pay Indi');
      expect(outcome.balanceAfterMinor, isNull);
      expect(outcome.isCard, isTrue);
    });

    test('a plain bank account debit is not flagged as a card', () {
      final outcome =
          parseBankSms(
                sender: 'JK-CBSSBI-S',
                body:
                    'Dear Customer, Your A/C XXXXX123456 has a debit by '
                    'NACH of Rs 100.00 on 14/09/26. Avl Bal Rs 3,00,340.48. '
                    'Download YONO - SBI',
              )
              as SmsTransaction;
      expect(outcome.isCard, isFalse);
    });

    test('transfer-out merchant stops at ". Avl" and drops the honorific', () {
      final outcome =
          parseBankSms(
                sender: 'JK-CBSSBI-S',
                body:
                    'Your A/C XXXXX123456 Debited INR 35,000.00 on '
                    '29/07/26 -Transferred to Mr. DEEPAKGUPTA. Avl Balance '
                    'INR 2,36,382.04-SBI',
              )
              as SmsTransaction;
      expect(outcome.amountMinor, 3500000);
      expect(outcome.merchant, 'Deepakgupta');
      expect(outcome.balanceAfterMinor, 23638204);
    });

    test('"Your A/C" is never mistaken for a merchant', () {
      final outcome =
          parseBankSms(
                sender: 'JK-CBSSBI-S',
                body:
                    'Your A/C XXXXX123456 Credited INR 43,000.00 on '
                    '31/07/26 -Deposit by transfer from Mr. DEEPAKGUPTA. '
                    'Avl Bal INR 3,88,232.04-SBI',
              )
              as SmsTransaction;
      expect(outcome.amountMinor, 4300000);
      expect(outcome.kind, TransactionKind.income);
      expect(outcome.merchant, 'Deepakgupta');
    });

    test('YONO transfer: last4 is the sender account, not the destination', () {
      final outcome =
          parseBankSms(
                sender: 'JK-SBYONO-S',
                body:
                    'Your Ac Xx2774 debited Rs.14,000.00 for transfer to '
                    'Abhina Ac Xx9644 dt 12.09.26 Ref 625514756461. If not '
                    'done by you, call 1800111109. YONO SBI',
              )
              as SmsTransaction;
      expect(outcome.amountMinor, 1400000);
      expect(outcome.last4, '2774');
      expect(outcome.merchant, 'Abhina');
      expect(outcome.reference, '625514756461');
    });

    test('HDFC IMPS credit picks the sender name, not a generic fallback', () {
      final outcome =
          parseBankSms(
                sender: 'JD-HDFCBK-S',
                body:
                    'Received! INR 14,000.00 in HDFC Bank A/c xx9644 On '
                    '12-09-26 For IMPS -ABHINAV GUPTA- 625514756461 Avl '
                    'bal INR 22,665.14',
              )
              as SmsTransaction;
      expect(outcome.amountMinor, 1400000);
      expect(outcome.last4, '9644');
      expect(outcome.merchant, 'Abhinav Gupta');
      expect(outcome.balanceAfterMinor, 2266514);
    });

    test('mandate setup is ignored', () {
      final outcome = parseBankSms(
        sender: 'VM-HDFCBK-S',
        body:
            'Mandate Set Rs.15000.00 For Google From HDFC Bank A/c x9644 '
            'UMN: 0a9730c5517e47e280e@pi Not you? Call 18002586161',
      );
      expect(outcome, isA<SmsIgnored>());
    });

    test('"Sent" transfer merchant stops before the reference', () {
      final outcome =
          parseBankSms(
                sender: 'VM-HDFCBK-T',
                body:
                    'Sent Rs.19771.00 From HDFC Bank A/C *9644 To CBDT TIN '
                    '2 0 On 28/07/26 Ref 520912345678 Not You? Call '
                    '18002586161/SMS BLOCK UPI to 7308080808',
              )
              as SmsTransaction;
      expect(outcome.amountMinor, 1977100);
      expect(outcome.last4, '9644');
      expect(outcome.merchant, 'Cbdt Tin');
      expect(outcome.reference, '520912345678');
    });

    test('wallet balance spend is ignored, not a bank account movement', () {
      final outcome = parseBankSms(
        sender: 'JK-JUSPAY-S',
        body:
            'Payment of Rs 587.18 using Apay Balance successful at '
            'merchant. Updated Balance is Rs 0.00 - If not u? call '
            '08061234567 - SMS via Juspay',
      );
      expect(outcome, isA<SmsIgnored>());
    });

    test('TDS notice is ignored', () {
      final outcome = parseBankSms(
        sender: 'JD-ITDCPC-G',
        body:
            'Total TDS by Employer of PAN DHSXXXXX6C for Qtr ending Sep '
            '30 is Rs 0 and cumulative TDS for FY 25-26 is Rs 0. View '
            '26AS/ATS for details. ITD Team',
      );
      expect(outcome, isA<SmsIgnored>());
    });

    test('Canara debit merchant comes from "towards"', () {
      final outcome =
          parseBankSms(
                sender: 'AX-CANBNK-S',
                body:
                    'An amount of INR 590.00 has been DEBITED to your '
                    'account XXX238 on 12/08/2026 towards PLATINUM DEBIT '
                    'CARD annual service charges. Total Avail. bal INR '
                    '22.57. - Canara Bank',
              )
              as SmsTransaction;
      expect(outcome.amountMinor, 59000);
      expect(outcome.last4, '238');
      expect(outcome.merchant, 'Platinum Debit Card Annual Service Charges');
      expect(outcome.balanceAfterMinor, 2257);
      expect(outcome.bank, 'Canara');
    });

    test('Canara credit falls back to a bank-named merchant', () {
      final outcome =
          parseBankSms(
                sender: 'VM-CANBNK-S',
                body:
                    'An amount of INR 2,500.00 has been CREDITED to your '
                    'account XXX238 on 16/04/2026.Total Avail.bal INR '
                    '3,056.57.- Canara Bank',
              )
              as SmsTransaction;
      expect(outcome.amountMinor, 250000);
      expect(outcome.last4, '238');
      expect(outcome.merchant, 'Canara transaction');
      expect(outcome.balanceAfterMinor, 305657);
    });

    test('an amount of zero is never booked', () {
      final outcome = parseBankSms(
        sender: 'AD-HDFCBK-S',
        body: 'Rs.0.00 debited from your account at ACME',
      );
      expect(outcome, isA<SmsIgnored>());
    });
  });
}
