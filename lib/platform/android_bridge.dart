import 'dart:io';

import 'package:flutter/services.dart';

class AndroidBridge {
  static const _channel = MethodChannel('com.navknight.tally/platform');

  /// Calls [callback] whenever the native ContentObserver sees the SMS
  /// provider change while the activity is alive (debounced natively).
  static void onSmsChanged(void Function() callback) {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'smsChanged') callback();
    });
  }

  static Future<bool> requestSmsPermission() async {
    if (!Platform.isAndroid) return false;
    return (await _channel.invokeMethod<bool>('requestSmsPermission')) ?? false;
  }

  /// Inbox rows strictly newer than [sinceMillis], oldest first, capped at
  /// 5000 by the platform side.
  static Future<List<BankSms>> smsSince(int sinceMillis) async =>
      _messages('readSmsSince', {'since': sinceMillis});

  static Future<List<BankSms>> _messages(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    if (!Platform.isAndroid) return const [];
    final rows =
        await _channel.invokeListMethod<dynamic>(method, args) ?? const [];
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

  /// Opens the system file picker for a CSV or PDF statement. Null when the
  /// picker is unavailable, cancelled, or the host isn't Android.
  static Future<PickedFile?> pickStatementFile() async {
    if (!Platform.isAndroid) return null;
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'pickStatement',
    );
    final bytes = result?['bytes'];
    if (bytes == null) return null;
    return PickedFile(
      name: result!['name'] as String? ?? 'statement',
      bytes: bytes is Uint8List
          ? bytes
          : Uint8List.fromList(List<int>.from(bytes as List)),
    );
  }

  /// Opens the system "save as" dialog for [bytes]. Returns whether the user
  /// went through with it; false when cancelled or the host isn't Android.
  static Future<bool> saveFile(
    String name,
    String mimeType,
    Uint8List bytes,
  ) async {
    if (!Platform.isAndroid) return false;
    return (await _channel.invokeMethod<bool>('saveFile', {
          'name': name,
          'mimeType': mimeType,
          'bytes': bytes,
        })) ??
        false;
  }
}

class PickedFile {
  const PickedFile({required this.name, required this.bytes});
  final String name;
  final Uint8List bytes;
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
