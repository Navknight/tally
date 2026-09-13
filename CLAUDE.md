# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Product intent

Tally is an ultra-performant, no-bloat budget and money tracker for Android (Flutter; there is no `ios/`, `web/`, or desktop runner). The intended flow:

1. **Seed** — the user enters a starting balance per bank account, or imports a bank statement (PDF/CSV).
2. **Stay current** — the ledger then maintains itself by parsing UPI and bank transaction SMS. Manual entry is the fallback, not the main path.
3. **Get smarter** — the app learns which transactions map to which category over time, so the user stops labelling the same merchant repeatedly.

Two constraints follow from "no bloat" and should be weighed before adding anything:

- **Local-only.** No network dependencies; everything lives in one on-device SQLite file. A network call or analytics SDK breaks the premise.
- **Small.** Categorisation learning must stay a lightweight on-device mechanism (lookup tables and integer counts), not a bundled model. Comparable apps ship a ~1.5 GB LLM for this; Tally deliberately does not.

Steps 1–3 exist in a first cut: multiple accounts, CSV/PDF statement import, a per-bank SMS parser registry, and category learning with a review queue. Still weak: UPI-specific shapes beyond the generic parser, and fixtures for every bank parser.

## Working agreement

- **Spend tokens sparingly.** Fan self-contained modules out to `sonnet`/`haiku` subagents with a precise interface contract in the prompt, and keep only architecture and integration in the main context. Reach for an existing tool or library before hand-rolling logic. Don't re-read files already in context or echo file contents back.
- **Reuse the reference parsers.** Mining PennyWiseAI/Cashiro for real SMS shapes is expected — widen Tally's own regexes from them and improve on them where they're weak. Fetch raw files with `curl` rather than browsing. Keep writing Tally's own Dart: their AGPL-3.0 only binds on distribution, so a verbatim copy would force Tally to be AGPL if it ever ships.
- **Every parsing rule ships with a fixture.** A pattern without a test in `test/` is a pattern nobody can safely change later.
- **No AI traces.** No Co-Authored-By or "Generated with" lines in commits or PRs, and no AI-sounding prose in code, comments or docs.
- **Releases** are `v*` tags built by `.github/workflows/release.yml` with signing secrets; the keystore password lives in the system keyring (`secret-tool lookup app tally key release-password`).

## Commands

```sh
flutter pub get
flutter run                          # needs a connected Android device/emulator
flutter analyze
flutter test
flutter test test/money_test.dart    # single file
flutter test --plain-name 'parses a debit SMS'   # single test by name
flutter build apk --debug
```

Release builds sign with `android/key.properties` when present, else the debug key.

## Architecture

**Layers** (`lib/`): `main.dart` holds every screen and sheet; `app/theme.dart` is the Rituals-family theme; `data/` owns SQLite; `services/` holds SMS parsing (`sms/`), ingestion, statement import and the categoriser; `platform/` is the only place that touches the method channel; `core/` and `models/` are pure Dart.

**Money is always `int` minor units.** Never introduce a `double` amount field. `core/money.dart` has the only formatter (`money`) and parser (`parseMoney`); the DB column is `amount_minor`.

**Database** (`data/tally_database.dart`): singleton `TallyDatabase.instance`, `tally.db`, schema version 3. Tables: `transactions`, `accounts`, key/value `settings`, and the learner's `merchant_rules`, `token_stats`, `category_stats`. v3 moved the old global `opening_balance` setting into the first account. Bumping the schema means an `onUpgrade` branch *and* keeping `onCreate` in sync.

**Deduplication** is a `UNIQUE INDEX` on `transactions.fingerprint` plus `ConflictAlgorithm.ignore`; `add()` returns whether a row was inserted. SMS rows use `smsFingerprint` (sender|amount|hash(body), no timestamp); statement rows hash account|date|amount|direction|merchant|balance; manual rows leave it null. Changing either formula re-imports history as duplicates.

**SMS flow** is pull-based, never background-writing: `SmsReceiver.kt` queues `sender\u0001timestamp\u0001body` records in the `tally_sms` SharedPreferences `pending` key; Dart drains it via `ingestPendingSms` on `AppLifecycleState.resumed`. `ingestHistoricSms` is a consent-gated one-shot inbox scan (capped at 5000). Both go through `parseBankSms` (`services/sms/`): `message_filter` rejects OTP/promo/requests first, then the first parser whose `canHandle(sender)` matches extracts; results are `SmsTransaction`, `SmsBalance` or `SmsIgnored`.

**Method channel** `com.navknight.tally/platform` (`MainActivity.kt` ⇄ `platform/android_bridge.dart`): `requestSmsPermission`, `takePendingSms`, `readHistoricSms`, `pickStatement` (CSV/PDF bytes + name, null when cancelled; Settings then offers a paste-CSV sheet). Every bridge call short-circuits on non-Android.

**UI refresh** is deliberately crude: `_TallyShellState._refresh` is an int bumped by `_changed()`, used as each page's `ValueKey` so the page rebuilds and its `FutureBuilder` re-queries. There is no state-management package and no router; pass `onChanged` down and call it after any write.

## Conventions

Three lints are disabled in `analysis_options.yaml` and the code relies on them: brace-less single-statement `if`s (`curly_braces_in_flow_control_structures`), `use_build_context_synchronously`, and `deprecated_member_use`. Match the surrounding expression-bodied style (`=>` members, `Future.wait` for parallel reads).


## Reference apps

Three apps solve the same problem and are worth consulting for parser and feature design:

- **[PennyWiseAI](https://github.com/sarim2000/pennywiseai-tracker)** (Kotlin/Compose, AGPL-3.0) — closest reference. Its `parser-core` module is the structure to learn from: an abstract `BankParser` with `canHandle(sender)`, a registry that picks the first matching parser, per-country base classes (`BaseIndianBankParser`), overridable `extractAmount` / `extractMerchant` / `extractBalance` / `extractAccountLast4` / `extractReference`, and a shared `isTransactionMessage()` gate that rejects OTP, promotional, and payment-request messages *before* extraction. Its transaction id is `md5(sender|normalizedAmount|md5(body)[:16])` — deliberately excluding the timestamp, because a broadcast-received message and the same message re-read from the SMS provider carry different timestamps. Tally has that exact split (`takePendingSms` uses the intent timestamp, `readHistoricSms` uses `Telephony.Sms.DATE`), so its fingerprint must keep excluding time too.
- **[Cashiro](https://github.com/ritesh-kanwar/Cashiro)** (Kotlin/Compose, AGPL-3.0) — similar feature surface, plus PDF statement parsing for GPay/PhonePe and subscription (recurring payment) detection.
- **Microsoft SMS Organizer** (closed source) — the model for step 3: on-device classification of every SMS into personal/transactional/promotional first, extraction second, and reminders derived from parsed due dates. Classify-then-extract is the pattern; Tally's current parser extracts from anything containing a currency amount.

**Licensing:** both repos are AGPL-3.0. Read them for approach and for which SMS shapes exist in the wild, but do not copy parser source or regex tables into Tally — that would make Tally AGPL.
