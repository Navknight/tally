import 'dart:io';

import 'package:flutter/services.dart';

class AndroidBridge {
  static const _channel = MethodChannel('com.navknight.tally/platform');

  static Future<bool> requestSmsPermission() async {
    if (!Platform.isAndroid) return false;
    return (await _channel.invokeMethod<bool>('requestSmsPermission')) ?? false;
  }

  static Future<List<BankSms>> pendingSms() async =>
      _messages('takePendingSms');

  /// Bounded historic scan. Android reads only local SMS provider rows.
  static Future<List<BankSms>> historicSms() async =>
      _messages('readHistoricSms');

  static Future<List<BankSms>> _messages(String method) async {
    if (!Platform.isAndroid) return const [];
    final rows = await _channel.invokeListMethod<dynamic>(method) ?? const [];
    return rows
        .whereType<Map>()
        .map(
          (row) => BankSms(
            sender: row['sender'] as String? ?? '',
            body: row['body'] as String? ?? '',
            timestamp: DateTime.fromMillisecondsSinceEpoch(
              row['timestamp'] as int? ?? 0,
            ),
          ),
        )
        .where((message) => message.body.isNotEmpty)
        .toList(growable: false);
  }

  static Future<String?> pickCsv() async {
    if (!Platform.isAndroid) return null;
    return _channel.invokeMethod<String>('pickCsv');
  }
}

class BankSms {
  const BankSms({
    required this.sender,
    required this.body,
    required this.timestamp,
  });
  final String sender;
  final String body;
  final DateTime timestamp;
}
