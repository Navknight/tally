import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Extracts visible text from a simple, unencrypted PDF.
///
/// Locates each `stream`/`endstream` pair, inflates it when the preceding
/// dictionary declares `/FlateDecode`, then pulls text from the recovered
/// content stream's text-showing operators (`Tj`, `TJ`, `'`, `"`). Returns
/// null when the file is encrypted or carries no extractable text (a scanned
/// statement), so callers can fall back to CSV instead of silently importing
/// nothing.
String? extractPdfText(Uint8List bytes) {
  final raw = latin1.decode(bytes, allowInvalid: true);
  if (raw.contains('/Encrypt')) return null;

  final out = StringBuffer();
  var searchStart = 0;
  while (true) {
    final streamIdx = raw.indexOf('stream', searchStart);
    if (streamIdx < 0) break;

    final dictStart = raw.lastIndexOf('<<', streamIdx);
    final dict = dictStart >= 0 ? raw.substring(dictStart, streamIdx) : '';

    var contentStart = streamIdx + 'stream'.length;
    if (raw.startsWith('\r\n', contentStart))
      contentStart += 2;
    else if (contentStart < raw.length &&
        (raw[contentStart] == '\n' || raw[contentStart] == '\r'))
      contentStart += 1;

    final endIdx = raw.indexOf('endstream', contentStart);
    if (endIdx < 0) {
      searchStart = streamIdx + 'stream'.length;
      continue;
    }
    searchStart = endIdx + 'endstream'.length;

    if (contentStart > endIdx) continue;
    List<int> data = bytes.sublist(contentStart, endIdx);

    if (dict.contains('/FlateDecode')) {
      List<int>? inflated;
      try {
        inflated = ZLibCodec(raw: false).decode(data);
      } catch (_) {
        try {
          inflated = ZLibCodec(raw: true).decode(data);
        } catch (_) {
          inflated = null;
        }
      }
      if (inflated == null) continue;
      data = inflated;
    }

    final content = latin1.decode(data, allowInvalid: true);
    out.write(_textFromContentStream(content));
  }

  final text = out.toString();
  if (!_alphanumericRegex.hasMatch(text)) return null;
  return text;
}

final _alphanumericRegex = RegExp(r'[A-Za-z0-9]');
final _octalDigitRegex = RegExp(r'[0-7]');

/// True when [op] appears at [i] in [s] as a standalone operator token
/// (not part of a longer identifier).
bool _isOperatorAt(String s, int i, String op) {
  if (!s.startsWith(op, i)) return false;
  bool isWordChar(String c) => _alphanumericRegex.hasMatch(c);
  final before = i == 0 ? ' ' : s[i - 1];
  final afterIdx = i + op.length;
  final after = afterIdx >= s.length ? ' ' : s[afterIdx];
  return !isWordChar(before) && !isWordChar(after);
}

String _textFromContentStream(String s) {
  final out = StringBuffer();
  var i = 0;
  final n = s.length;
  while (i < n) {
    final c = s[i];
    if (c == '(') {
      i++;
      var depth = 1;
      final sb = StringBuffer();
      while (i < n && depth > 0) {
        final ch = s[i];
        if (ch == '\\' && i + 1 < n) {
          final next = s[i + 1];
          if (next == '(') {
            sb.write('(');
            i += 2;
          } else if (next == ')') {
            sb.write(')');
            i += 2;
          } else if (next == '\\') {
            sb.write('\\');
            i += 2;
          } else if (next == 'n') {
            sb.write('\n');
            i += 2;
          } else if (next == 'r') {
            sb.write('\r');
            i += 2;
          } else if (next == 't') {
            sb.write('\t');
            i += 2;
          } else if (_octalDigitRegex.hasMatch(next)) {
            var j = i + 1;
            var oct = '';
            while (j < n && oct.length < 3 && _octalDigitRegex.hasMatch(s[j])) {
              oct += s[j];
              j++;
            }
            sb.writeCharCode(int.parse(oct, radix: 8) & 0xFF);
            i = j;
          } else {
            sb.write(next);
            i += 2;
          }
        } else if (ch == '(') {
          depth++;
          sb.write(ch);
          i++;
        } else if (ch == ')') {
          depth--;
          i++;
          if (depth > 0) sb.write(ch);
        } else {
          sb.write(ch);
          i++;
        }
      }
      out.write(sb);
    } else if ((c == 'T' || c == 'E') &&
        (_isOperatorAt(s, i, 'Td') ||
            _isOperatorAt(s, i, 'TD') ||
            _isOperatorAt(s, i, 'T*') ||
            _isOperatorAt(s, i, 'ET'))) {
      out.write('\n');
      i += 2;
    } else {
      i++;
    }
  }
  return out.toString();
}
