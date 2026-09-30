import 'dart:convert';

import 'package:flutter/material.dart';

/// A mark for a bank: its short name on a steady colour.
///
/// Real logos are trademarked and would have to be bundled as assets, which a
/// small, local, GPL app has no business doing. A coloured chip carrying the
/// bank's own short name identifies an account on sight just as well, and the
/// colour is stable across restarts because it is derived from the name.
///
/// Drop a logo at `assets/banks/<key>.png` (the key below, e.g. `hdfc.png`)
/// and [bankLogo] picks it up instead of the chip. Nothing ships with one:
/// logos are copyrighted, and F-Droid and IzzyOnDroid want every asset in the
/// APK free-licensed, so the choice to bundle them is left to whoever builds.
///
/// The table is only for the banks whose messages Tally sees most; anything
/// else falls back to initials on a colour picked from the name, so a new
/// bank still gets a consistent mark without an entry here.
const _known = <String, (String, int)>{
  'hdfc': ('HDFC', 0xFF004C8F),
  'statebank': ('SBI', 0xFF22409A),
  'sbi': ('SBI', 0xFF22409A),
  'icici': ('ICICI', 0xFFF37E20),
  'axis': ('AXIS', 0xFF97144D),
  'kotak': ('KOTAK', 0xFFED1C24),
  'canara': ('CANARA', 0xFF00539F),
  'punjabnational': ('PNB', 0xFF4B2E83),
  'pnb': ('PNB', 0xFF4B2E83),
  'baroda': ('BOB', 0xFFF15A22),
  'idfc': ('IDFC', 0xFF9C1D26),
  'yes': ('YES', 0xFF00518F),
  'indusind': ('INDUS', 0xFF9E1B32),
  'union': ('UNION', 0xFF00539F),
  'federal': ('FED', 0xFF00539B),
  'rbl': ('RBL', 0xFFB4141E),
  'bandhan': ('BANDHAN', 0xFFE4002B),
  'idbi': ('IDBI', 0xFF006F3C),
  'indianoverseas': ('IOB', 0xFF00539F),
  'indian': ('INDIAN', 0xFF1B3C8C),
  'central': ('CBI', 0xFF00539F),
  'uco': ('UCO', 0xFF005CA9),
  'paytm': ('PAYTM', 0xFF00BAF2),
  'amazon': ('AMZN', 0xFFFF9900),
  'airtel': ('AIRTEL', 0xFFE40000),
  'jupiter': ('JUPI', 0xFFFF7B5A),
  'slice': ('SLICE', 0xFF6E3FF3),
  'au': ('AU', 0xFF6D2077),
  'karnataka': ('KBL', 0xFFC8102E),
  'southindian': ('SIB', 0xFF0066B3),
  'dcb': ('DCB', 0xFF00539F),
  'equitas': ('EQ', 0xFF00A4A7),
  'ujjivan': ('UJJ', 0xFFE4002B),
  'ippb': ('IPPB', 0xFFCC0000),
  'citi': ('CITI', 0xFF003B70),
  'hsbc': ('HSBC', 0xFFDB0011),
  'standardchartered': ('SC', 0xFF0473EA),
  'dbs': ('DBS', 0xFFEC1B2E),
};

final _lettersRegex = RegExp('[^a-z]');

/// Logo keys the build actually shipped, filled once from the asset manifest.
/// Empty until [loadBankLogos] runs, so the chip is what shows by default.
Set<String> _logos = const {};

/// The asset path for [name]'s logo, or null to draw the chip instead.
String? bankLogo(String name) {
  if (_logos.isEmpty) return null;
  final key = _matchKey(name);
  return key != null && _logos.contains(key) ? 'assets/banks/$key.png' : null;
}

/// Reads which `assets/banks/*.png` this build contains. Called once at
/// startup; without it every bank falls back to its chip.
Future<void> loadBankLogos(Future<String> Function(String) loadAsset) async {
  try {
    final manifest = await loadAsset('AssetManifest.json');
    _logos = {
      for (final path in (jsonDecode(manifest) as Map).keys.cast<String>())
        if (path.startsWith('assets/banks/') && path.endsWith('.png'))
          path.substring('assets/banks/'.length, path.length - 4),
    };
  } catch (_) {
    // No manifest entry for the folder means no logos were bundled.
    _logos = const {};
  }
}

/// The known entry whose key appears in [name], longest key first so
/// "Punjab National" beats "pnb" and "State Bank" beats "sbi".
String? _matchKey(String name) {
  final flat = name.toLowerCase().replaceAll(_lettersRegex, '');
  if (flat.isEmpty) return null;
  String? best;
  for (final key in _known.keys)
    if (flat.contains(key) && (best == null || key.length > best.length))
      best = key;
  return best;
}

(String, int)? _match(String name) {
  final key = _matchKey(name);
  return key == null ? null : _known[key];
}

/// What to print on the chip: the bank's short name when it is one Tally
/// knows, otherwise up to two initials from the words of [name].
String bankMark(String name) {
  final known = _match(name);
  if (known != null) return known.$1;
  final words = name.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return '?';
  if (words.length == 1) return words.first.substring(0, 1).toUpperCase();
  return (words[0].substring(0, 1) + words[1].substring(0, 1)).toUpperCase();
}

/// The chip colour. Known banks get their own; anything else gets one of a
/// fixed set, chosen from the name so it never changes between runs.
Color bankColor(String name) {
  final known = _match(name);
  if (known != null) return Color(known.$2);
  var hash = 0;
  for (final unit in name.toLowerCase().codeUnits)
    hash = (hash * 31 + unit) & 0x7fffffff;
  return _fallbacks[hash % _fallbacks.length];
}

const _fallbacks = [
  Color(0xFF3D6FB8),
  Color(0xFF4F8C5A),
  Color(0xFF9A5B3F),
  Color(0xFF7A5BA8),
  Color(0xFFB0563F),
  Color(0xFF3E8C8C),
  Color(0xFF8C6B2F),
  Color(0xFF9B3F63),
];
