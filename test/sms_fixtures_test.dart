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
      final outcome = parseBankSms(
        sender: 'JK-CBSSBI-S',
        body:
            'Dear Customer, Your A/C XXXXX123456 has a debit by '
            'NACH of Rs 100.00 on 14/09/26. Avl Bal Rs 3,00,340.48. '
            'Download YONO - SBI',
      ) as SmsTransaction;
      expect(outcome.amountMinor, 10000);
      expect(outcome.kind, TransactionKind.expense);
      expect(outcome.balanceAfterMinor, 30034048);
      expect(outcome.bank, 'SBI');
    });

    test(
      'foreign currency card spend is ignored, not booked at the INR limit',
      () {
        final outcome = parseBankSms(
          sender: 'JD-ICICIT-S',
          body:
              'USD 23.60 spent using ICICI Bank Card XX3001 on 06-Sep-26 on '
              'ANTHROPIC* CLAU. Avl Limit: INR 3,06,279.77. If not you, call '
              '1800 2662/SMS BLOCK 3001 to 9215676766.',
        );
        expect(outcome, isA<SmsIgnored>());
      },
    );

    test(
      'INR card spend: limit never becomes the balance, merchant from "on"',
      () {
        final outcome = parseBankSms(
          sender: 'AD-ICICIT-S',
          body:
              'INR 422.90 spent using ICICI Bank Card XX3001 on '
              '06-Sep-26 on AMAZON PAY INDI. Avl Limit: INR '
              '3,08,510.68. If not you, call 1800 2662/SMS BLOCK 3001 '
              'to 9215676766.',
        ) as SmsTransaction;
        expect(outcome.amountMinor, 42290);
        expect(outcome.last4, '3001');
        expect(outcome.merchant, 'Amazon Pay Indi');
        expect(outcome.balanceAfterMinor, isNull);
        expect(outcome.isCard, isTrue);
      },
    );

    test('a plain bank account debit is not flagged as a card', () {
      final outcome = parseBankSms(
        sender: 'JK-CBSSBI-S',
        body:
            'Dear Customer, Your A/C XXXXX123456 has a debit by '
            'NACH of Rs 100.00 on 14/09/26. Avl Bal Rs 3,00,340.48. '
            'Download YONO - SBI',
      ) as SmsTransaction;
      expect(outcome.isCard, isFalse);
    });

    test('transfer-out merchant stops at ". Avl" and drops the honorific', () {
      final outcome = parseBankSms(
        sender: 'JK-CBSSBI-S',
        body:
            'Your A/C XXXXX123456 Debited INR 35,000.00 on '
            '29/07/26 -Transferred to Mr. DEEPAKGUPTA. Avl Balance '
            'INR 2,36,382.04-SBI',
      ) as SmsTransaction;
      expect(outcome.amountMinor, 3500000);
      expect(outcome.merchant, 'Deepakgupta');
      expect(outcome.balanceAfterMinor, 23638204);
    });

    test('"Your A/C" is never mistaken for a merchant', () {
      final outcome = parseBankSms(
        sender: 'JK-CBSSBI-S',
        body:
            'Your A/C XXXXX123456 Credited INR 43,000.00 on '
            '31/07/26 -Deposit by transfer from Mr. DEEPAKGUPTA. '
            'Avl Bal INR 3,88,232.04-SBI',
      ) as SmsTransaction;
      expect(outcome.amountMinor, 4300000);
      expect(outcome.kind, TransactionKind.income);
      expect(outcome.merchant, 'Deepakgupta');
    });

    test('YONO transfer: last4 is the sender account, not the destination', () {
      final outcome = parseBankSms(
        sender: 'JK-SBYONO-S',
        body:
            'Your Ac Xx2774 debited Rs.14,000.00 for transfer to '
            'Abhina Ac Xx9644 dt 12.09.26 Ref 625514756461. If not '
            'done by you, call 1800111109. YONO SBI',
      ) as SmsTransaction;
      expect(outcome.amountMinor, 1400000);
      expect(outcome.last4, '2774');
      expect(outcome.merchant, 'Abhina');
      expect(outcome.reference, '625514756461');
    });

    test('HDFC IMPS credit picks the sender name, not a generic fallback', () {
      final outcome = parseBankSms(
        sender: 'JD-HDFCBK-S',
        body:
            'Received! INR 14,000.00 in HDFC Bank A/c xx9644 On '
            '12-09-26 For IMPS -ABHINAV GUPTA- 625514756461 Avl '
            'bal INR 22,665.14',
      ) as SmsTransaction;
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
      final outcome = parseBankSms(
        sender: 'VM-HDFCBK-T',
        body:
            'Sent Rs.19771.00 From HDFC Bank A/C *9644 To CBDT TIN '
            '2 0 On 28/07/26 Ref 520912345678 Not You? Call '
            '18002586161/SMS BLOCK UPI to 7308080808',
      ) as SmsTransaction;
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
      final outcome = parseBankSms(
        sender: 'AX-CANBNK-S',
        body:
            'An amount of INR 590.00 has been DEBITED to your '
            'account XXX238 on 12/08/2026 towards PLATINUM DEBIT '
            'CARD annual service charges. Total Avail. bal INR '
            '22.57. - Canara Bank',
      ) as SmsTransaction;
      expect(outcome.amountMinor, 59000);
      expect(outcome.last4, '238');
      expect(outcome.merchant, 'Platinum Debit Card Annual Service Charges');
      expect(outcome.balanceAfterMinor, 2257);
      expect(outcome.bank, 'Canara');
    });

    test('Canara credit falls back to a bank-named merchant', () {
      final outcome = parseBankSms(
        sender: 'VM-CANBNK-S',
        body:
            'An amount of INR 2,500.00 has been CREDITED to your '
            'account XXX238 on 16/04/2026.Total Avail.bal INR '
            '3,056.57.- Canara Bank',
      ) as SmsTransaction;
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

    test('SBI NACH debit gets a shared merchant so one label covers all', () {
      final outcome = parseBankSms(
        sender: 'JX-CBSSBI-S',
        body:
            'Dear Customer, Your A/C XXXXX123456 has a debit by '
            'NACH of Rs 200.00 on 01/09/26. Avl Bal Rs 3,23,740.48. '
            'Download YONO - SBI',
      ) as SmsTransaction;
      expect(outcome.merchant, 'NACH debit');
    });

    test('YONO transfer SMS is SBI, not an unknown bank', () {
      final outcome = parseBankSms(
        sender: 'JK-SBYONO-S',
        body:
            'Your Ac Xx2774 debited Rs.14,000.00 for transfer to '
            'Abhina Ac Xx9644 dt 12.09.26 Ref 123456789012. If not '
            'done by you, call 1800111109. YONO SBI',
      ) as SmsTransaction;
      expect(outcome.bank, 'SBI');
      expect(outcome.last4, '2774');
      expect(outcome.amountMinor, 1400000);
    });

    test('declined card attempt is not a transaction', () {
      final outcome = parseBankSms(
        sender: 'JD-HDFCBK-S',
        body:
            'TXN DECLINED: Rs.2.00 on 29-10-25 at 07:20 on HDFC Bank Debit '
            'Card xx1006. Reason: Online Usage disabled.',
      );
      expect(outcome, isA<SmsIgnored>());
    });

    test('debit card spend is not a card account', () {
      final outcome = parseBankSms(
        sender: 'JD-HDFCBK-S',
        body:
            'Rs.6500 spent on HDFC Bank Card x9500 at GOOGLEPLAY on '
            '2026-07-18:20:41:03 Avl bal: 12345.67.Not You? Call '
            '18002586161 / SMS BLOCK DC 9500 to 7308080808',
      ) as SmsTransaction;
      expect(outcome.isCard, isFalse);
      expect(outcome.last4, '9500');
      final reversal = parseBankSms(
        sender: 'JD-HDFCBK-S',
        body:
            'Transaction Reversed!On HDFC Bank DEBIT/ATM Card xx1006 Amt: '
            'Rs.2 By PAYZAPP On 2025-10-03:22:26:25',
      );
      expect(reversal is SmsTransaction && !reversal.isCard, isTrue);
    });

    test('credit card applications quote limits and fees, not spends', () {
      for (final body in [
        'Dear Applicant, thank you for applying for SBI Credit Card. Your '
            'Application No. 12345678 is being processed with tentative '
            'credit limit ranging between Rs. 50000 and Rs. 100000.',
        'We have received your SBI Card Application. Pls give us 11 working '
            'days to process your App.No. 12345678. The ANNUAL fee on '
            'Flipkart SBI Card Visa is INR 500.',
      ])
        expect(
          parseBankSms(sender: 'VM-SBICRD-S', body: body),
          isA<SmsIgnored>(),
        );
    });

    test('credit card spend is still a card', () {
      final outcome = parseBankSms(
        sender: 'AX-ICICIT-S',
        body:
            'INR 482.93 spent using ICICI Bank Card XX3001 on '
            '03-Sep-26 on AMAZON PAY INDI. Avl Limit: INR 3,08,933.58. '
            'If not you, call 1800 2662/SMS BLOCK 3001 to 9215676766.',
      ) as SmsTransaction;
      expect(outcome.isCard, isTrue);
    });

    test('EPF passbook update is not a bank account', () {
      final outcome = parseBankSms(
        sender: 'AX-EPFOHO-S',
        body:
            'Dear XXXXXXXX7341, your passbook balance against '
            'BGBNG00000000004968 is Rs. 52,678/-. Contribution of Rs. '
            '18,750/- for due month May-26 has been received.',
      );
      expect(outcome, isA<SmsIgnored>());
    });

    test('loan disbursal credit is not a savings account', () {
      final outcome = parseBankSms(
        sender: 'AD-CANBNK-S',
        body:
            'Dear Customer, Your Loan account no. XXX940 has been credited '
            'with amount Rs. INR 50,000.00.  - Canara Bank',
      );
      expect(outcome, isA<SmsIgnored>());
    });

    test('non-bank senders naming no account are ignored', () {
      for (final (sender, body) in [
        (
          'JM-ZOMATO-S',
          'Refund of Rs. 622.39 for your Zomato order from McDonald\'s has been initiated and will be credited by Aug 22, 2026. -ZOMATO',
        ),
        (
          'AD-AIRSBL',
          'Hi, refund of Rs 1500.0 has been initiated for your Airtel Wi-Fi order. The amount will get credited to your source account.',
        ),
        (
          'JX-POLBAZ-S',
          'Hi Abhinav, Payment of Rs. 12000 is successful for the purchase of your Health policy.',
        ),
        (
          'JM-ITDCPC-S',
          'Dear User, Challan payment of Rs. 10000 against PAN/TAN DHXXXXXX6C for Assessment Year 2026 has been successfully paid.',
        ),
      ])
        expect(
          parseBankSms(sender: sender, body: body),
          isA<SmsIgnored>(),
          reason: sender,
        );
    });
  });
}
