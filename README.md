# Tally

A small, private money tracker for Android. It reads your bank and UPI SMS to keep the ledger up to date, and learns your categories as you correct them.

- Everything stays on your phone. No account, no internet access, no analytics.
- Multiple bank accounts, matched by the last four digits in each SMS.
- Import CSV or PDF bank statements.
- Tell it a merchant's category once and it applies it to past and future transactions.

## Install

Download the APK from [Releases](https://github.com/Navknight/tally/releases). Most phones want `app-arm64-v8a-release.apk`.

Android will ask to scan the app, since it isn't from the Play Store. On Android 13 and later, SMS access starts out blocked for sideloaded apps: open Settings → Apps → Tally → ⋮ → Allow restricted settings, then grant SMS in the app.

Tally is in testing (0.x). Expect rough edges.

## Build

```sh
flutter pub get
flutter test
flutter build apk --release
```

Release builds read `android/key.properties`; without it they fall back to the debug key. Pushing a `v*` tag builds signed APKs on GitHub Actions.

## Privacy

See [PRIVACY.md](PRIVACY.md).
