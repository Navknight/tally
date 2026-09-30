Bank logos, shown in place of the coloured initials chip. The file name is the
key from `lib/models/banks.dart` — `hdfc.png`, `sbi.png` and so on — and any
bank without a file here falls back to its chip, which is why only some of the
table is covered.

Each one is that bank's own favicon, trimmed and scaled to 192×192.

**If you redistribute Tally yourself, read this first.** These are registered
trademarks of the banks concerned. Showing a bank's mark to label the user's
own account with that bank is ordinary nominative use, and every finance app
does it — but the images are not free-licensed, and F-Droid (and, more
loosely, IzzyOnDroid) expect everything inside the APK to be. Deleting this
folder is safe: every bank falls back to its chip and nothing else changes.

To refresh or extend the set, see `tool/fetch_bank_logos.sh`.
