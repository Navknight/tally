/// FNV-1a, 64-bit. Dart's native `int` is 64-bit two's complement and wraps on
/// overflow, which is exactly the arithmetic FNV needs; the app is Android-only
/// so the web's double-backed ints never apply.
///
/// Width matters here: fingerprints back a UNIQUE index that drops conflicting
/// rows silently, so a collision loses a real transaction. 64 bits keeps that
/// below one in a million even for a ledger of a million rows.
String stableHash(String value) {
  var hash = -3750763034362895579; // 0xcbf29ce484222325 as a signed 64-bit int
  for (final code in value.codeUnits) {
    // Fold surrogate-free UTF-16 units byte-wise so the digest is independent
    // of how the platform handed us the string.
    hash = (hash ^ (code & 0xff)) * 0x100000001b3;
    if (code > 0xff) hash = (hash ^ (code >> 8)) * 0x100000001b3;
  }
  return _hex32((hash >> 32) & 0xffffffff) + _hex32(hash & 0xffffffff);
}

String _hex32(int half) => half.toRadixString(16).padLeft(8, '0');
