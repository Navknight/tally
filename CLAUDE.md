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

## Status and backlog

Released: v0.3.0 (tags on GitHub drive releases). Next, in order:
1. **Bills and due dates** — parse card/loan/EMI "due on" SMS, show on Home, remind before the date.
2. **Subscriptions** — same merchant, similar amount on a monthly/weekly cycle; list with next expected date.

Decided, don't reopen without the user:
- Parser accuracy grows from the user's own messages (fixtures in `test/sms_fixtures_test.dart`), not from porting other banks' shapes wholesale.
- No background processing: SMS are read on open and while the app is open. Background alerts only if the user asks for them.
- Cards are accounts with `kind = card`: they count toward budget, never toward balance.
- Debugging real data: phone over adb (`~/Dev/Android/Sdk/platform-tools/adb`), filter SMS on-device and mask 5+ digit runs before printing.

## Working agreement

- **Spend tokens sparingly.** Fan self-contained modules out to `sonnet`/`haiku` subagents with a precise interface contract in the prompt, and keep only architecture and integration in the main context. Reach for an existing tool or library before hand-rolling logic. Don't re-read files already in context or echo file contents back.
- **Reuse the reference parsers.** Mining PennyWiseAI/Cashiro for real SMS shapes is expected — widen Tally's own regexes from them and improve on them where they're weak. Fetch raw files with `curl` rather than browsing. Keep writing Tally's own Dart: their AGPL-3.0 only binds on distribution, so a verbatim copy would force Tally to be AGPL if it ever ships.
- **Every parsing rule ships with a fixture.** A pattern without a test in `test/` is a pattern nobody can safely change later.
- **No AI traces.** No Co-Authored-By or "Generated with" lines in commits or PRs, and no AI-sounding prose in code, comments or docs.
- **One session per feature.** Start a fresh session for each backlog item instead of extending a long chat; this file is the handover. Before ending a feature, update "Status and backlog" (what shipped, what's next, any new decision) so the next session starts accurate.
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

**Database** (`data/tally_database.dart`): singleton `TallyDatabase.instance`, `tally.db`, schema version 5. Tables: `transactions`, `accounts`, `detected_accounts`, key/value `settings`, and the learner's `merchant_rules`, `token_stats`, `category_stats`. v3 moved the old global `opening_balance` setting into the first account. v4 added `accounts.in_budget`/`min_balance_minor`, `transactions.exclude_from_budget`/`transfer_account_id`, and the `budget_start_day` setting (default `'1'`). v5 added `accounts.kind` (`'bank'|'card'`), `transactions.account_last4`/`bank`/`sms_body`/`sms_sender` (the last two only populated for `source = 'sms'`, so a re-read can reparse in place and the transaction sheet can show the original message), the `detected_accounts` table, and indexes on `reference`, `account_id`, `(account_id, account_last4)` and `source`. Bumping the schema means an `onUpgrade` branch *and* keeping `onCreate` in sync (`_createV3`/`_createV5` are shared by both paths).

**Self transfers** are one row: `kind = transfer`, `account_id` is the source, `transfer_account_id` the destination, `exclude_from_budget` forced true. `accountBalance` (`models/account.dart`) treats that row as an outflow on the source and an inflow on the destination, so the pair nets to zero across the portfolio but moves money between the two account balances. `models/transfer.dart` has the pure pairing rule (`isSelfTransferPair`/`findSelfTransfers`: same amount, opposite kinds, different tracked accounts, within 30 minutes, matching reference when both have one) and `TallyDatabase.linkSelfTransfers()` applies it to existing rows — keeps the debit as a transfer, drops the credit. Called after every SMS ingest and statement import. Because of this, `add()`'s reference+amount dedup check is scoped to `account_id`, or the credit leg would never reach the ledger to be paired.

**Budget periods** run from `budget_start_day` (1–28) to the day before that day next month (`core/budget_period.dart#budgetPeriod`, half-open `[start, end)`). Spend against the budget (`models/account.dart#budgetSpent`, wired up by `TallyDatabase.spentInPeriod`) is expenses only, on accounts with `in_budget`, excluding `exclude_from_budget` rows, transfers, and rows with no account — a pure function so it's tested without sqflite. The Insights tab (`lib/insights.dart`, fl_chart) charts the same period: spend by category as a donut, and daily spend as bars with the daily budget pace as a dashed line.

**Deduplication** is a `UNIQUE INDEX` on `transactions.fingerprint` plus `ConflictAlgorithm.ignore`; `add()` returns whether a row was inserted. SMS rows use `smsFingerprint` (sender|amount|hash(body), no timestamp); statement rows hash account|date|amount|direction|merchant|balance; manual rows leave it null. Changing either formula re-imports history as duplicates.

**SMS flow** has no broadcast receiver — Samsung and others sleep manifest receivers, and a multipart SMS only lands whole in the provider anyway. `MainActivity.readSmsSince(since)` queries `content://sms/inbox` for rows newer than a watermark, ascending, capped at 5000. The `sms_last_seen` setting holds that watermark (max message timestamp ingested); `ingestNewSms()` (`services/sms_ingestion.dart`) reads since it and advances it, called on `AppLifecycleState.resumed` and at startup. While `MainActivity` is alive, a `ContentObserver` on `content://sms` (registered `onResume`, unregistered `onPause`) debounces ~1s and calls Dart back over the platform channel (`smsChanged`), which triggers another `ingestNewSms()`. `ingestHistoricSms()` is the consent-gated one-shot full scan (`readSmsSince(0)`) used by "Scan SMS inbox" and to rebuild the watermark. Both funnel through `ingestSms`, which parses the whole batch in `Isolate.run` (pure, no DB), categorises in one batched pass (`Categorizer.guessMany`, one `token_stats` query for every distinct token in the batch), then writes everything — rows, reported-balance updates — in a single `db.transaction` (`TallyDatabase.storeIngestBatch`). Progress publishes to the top-level `ValueNotifier<SyncStatus?> smsSyncStatus` (throttled every 50 messages), which the shell shows as a thin progress bar plus "Reading SMS - done of total" and Settings uses to disable the scan/re-read buttons. `parseBankSms` (`services/sms/`) is unchanged in shape: `message_filter` rejects OTP/promo/requests first, then the first parser whose `canHandle(sender)` matches extracts; results are `SmsTransaction`, `SmsBalance` or `SmsIgnored`, each now carrying `isCard` (wording like "Card XX3001" or "spent using") so a detection can be typed correctly. `rereadStoredSms()` re-parses every `source = 'sms'` row from its saved `sms_body`/`sms_sender` in place (keeping a manually-confirmed category/merchant), falling back to a full inbox re-scan only for legacy rows saved before those columns existed.

**Account/card detection**: during ingestion, a parsed `(bank, last4)` that matches no tracked account (`models/account.dart#last4Matches` - exact or suffix match either way) upserts a row in `detected_accounts` (bumping `message_count`/`last_seen`). Home shows each non-dismissed detection as a quiet "Found SBI ••2774 in 214 messages" row with Add/Dismiss. Add calls `TallyDatabase.addAccountAndClaim`, which inserts the account and reassigns every orphan transaction matching `last4`/`bank` (`models/account.dart#matchesForClaim`) to it in one transaction, then `linkSelfTransfers()`. Adding an account by hand in Settings claims orphans the same way. `AccountKind` (`bank`/`card`) drives `totalBalance` and the min-balance warning, both of which skip cards entirely - a card counts toward the budget but its "Avl Limit" is never money the user has.

**Performance rules**, learned on a flagship device that still lagged: never query inside `build()` - a screen's `FutureBuilder` future is created once in `State` (`initState`, or when a refresh key changes), not recreated on every rebuild. The shell (`_TallyShellState`) keeps all five pages in an `IndexedStack` and only rebuilds the page list when its refresh counter changes, so switching tabs does no queries - reusing the same widget instances is what makes Flutter skip rebuilding them. Balances and budget spend have both a pure Dart form (`models/account.dart`, what the test suite exercises) and a SQL form (`TallyDatabase.accountBalancesSql`/`totalBalanceSql`/`spentInPeriodSql`) doing the same arithmetic as one `SUM`; sqflite has no in-memory FFI test build here, so the SQL is documented rather than test-covered, and Home uses it instead of loading every transaction. Any list that could grow unbounded is paged or capped with a count (Activity: 200 at a time with "Load more"; Insights' counted list: capped at 200 with a "showing X of Y" line). Every `RegExp` used inside a function that runs per-message or per-transaction (parsing, categorising, PDF text extraction, CSV export) is hoisted to a top-level/static `final` instead of being rebuilt on every call.

**Method channel** `com.navknight.tally/platform` (`MainActivity.kt` ⇄ `platform/android_bridge.dart`): `requestSmsPermission` (READ_SMS only, no RECEIVE_SMS), `readSmsSince` (`{since}` → rows), `pickStatement` (CSV/PDF bytes + name, null when cancelled; Settings then offers a paste-CSV sheet), `saveFile` (name, mimeType, bytes → bool saved) via `ACTION_CREATE_DOCUMENT`, used by Settings' "Export transactions" over the pure CSV builder `services/export.dart#transactionsCsv`. Native to Dart carries only `smsChanged` (no args). Every bridge call short-circuits on non-Android.

**UI refresh** is deliberately crude: `_TallyShellState._refresh` is an int bumped by `_rebuildPages()`, used as each page's `ValueKey` so the page rebuilds and its `FutureBuilder` re-queries. There is no state-management package and no router; pass `onChanged` down and call it after any write. Back on a non-Home tab returns to Home (`PopScope` in the shell) instead of leaving the app. Every bottom sheet uses `useSafeArea: true` and pads its content by `sheetBottomInset()` (view padding + keyboard inset) so it clears the gesture/3-button nav bar.

## Conventions

Two lints are disabled in `analysis_options.yaml` and the code relies on them: brace-less single-statement `if`s (`curly_braces_in_flow_control_structures`) and `use_build_context_synchronously`. CI fails on any analyzer issue, infos included. Match the surrounding expression-bodied style (`=>` members, `Future.wait` for parallel reads).


## Reference apps

Three apps solve the same problem and are worth consulting for parser and feature design:

- **[PennyWiseAI](https://github.com/sarim2000/pennywiseai-tracker)** (Kotlin/Compose, AGPL-3.0) — closest reference. Its `parser-core` module is the structure to learn from: an abstract `BankParser` with `canHandle(sender)`, a registry that picks the first matching parser, per-country base classes (`BaseIndianBankParser`), overridable `extractAmount` / `extractMerchant` / `extractBalance` / `extractAccountLast4` / `extractReference`, and a shared `isTransactionMessage()` gate that rejects OTP, promotional, and payment-request messages *before* extraction. Its transaction id is `md5(sender|normalizedAmount|md5(body)[:16])` — deliberately excluding the timestamp, because a broadcast-received message and the same message re-read from the SMS provider carry different timestamps. Tally has that exact split (`takePendingSms` uses the intent timestamp, `readHistoricSms` uses `Telephony.Sms.DATE`), so its fingerprint must keep excluding time too.
- **[Cashiro](https://github.com/ritesh-kanwar/Cashiro)** (Kotlin/Compose, AGPL-3.0) — similar feature surface, plus PDF statement parsing for GPay/PhonePe and subscription (recurring payment) detection.
- **Microsoft SMS Organizer** (closed source) — the model for step 3: on-device classification of every SMS into personal/transactional/promotional first, extraction second, and reminders derived from parsed due dates. Classify-then-extract is the pattern; Tally's current parser extracts from anything containing a currency amount.

**Licensing:** both repos are AGPL-3.0. Read them for approach and for which SMS shapes exist in the wild, but do not copy parser source or regex tables into Tally — that would make Tally AGPL.
