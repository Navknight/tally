# Releasing Tally

## Cutting a release

1. Bump `version:` in `pubspec.yaml` (`x.y.z+N`) and `kAppVersion` in
   `lib/main.dart` — they are kept in step by hand.
2. Write `fastlane/metadata/android/en-US/changelogs/<N>.txt`, where `N` is
   the build number after the `+`. The release workflow uses it as the
   GitHub release body, and IzzyOnDroid shows it in-store.
3. Refresh the screenshots if the UI moved:
   `flutter test tool/store_assets.dart --update-goldens`. They render from
   seeded demo data on purpose — shots of a real ledger would publish the
   owner's balances and the names of people they paid.
4. `flutter analyze && flutter test`, then tag: `git tag -a vx.y.z -m vx.y.z
   && git push origin vx.y.z`.

`.github/workflows/release.yml` then builds the signed per-ABI APKs and a
universal one, attaches them to the GitHub release, and leaves the Play app
bundle as a run artefact (`play-bundle`). Signing comes from the repo
secrets; the keystore password is also in the system keyring
(`secret-tool lookup app tally key release-password`).

## IzzyOnDroid

IzzyOnDroid builds nothing — it watches the GitHub releases and picks up the
APKs, which is why the release has to carry them and why the filenames must
stay stable.

To get listed the first time, open an issue on
`IzzyOnDroid/repo` asking for inclusion with the repository URL. Their
checklist, and where Tally stands:

- Free software licence — GPL-3.0, `LICENSE`. ✓
- No proprietary dependencies or trackers — only `sqflite`, `path` and
  `fl_chart`. ✓
- Signed release APKs on the GitHub releases page. ✓
- Fastlane metadata at `fastlane/metadata/android/en-US/` for the title,
  descriptions, changelog, icon, feature graphic and screenshots. ✓
- **Bundled bank logos are the one thing to declare.** They are trademarks
  and are not free-licensed. Deleting `assets/banks/*.png` is safe — every
  bank falls back to its drawn chip — so if Izzy (or a stricter F-Droid
  build) objects, drop the folder and rebuild. See
  `assets/banks/README.md`.

## Google Play

Play **does** allow Tally's use of `READ_SMS`. The acceptable-use table in
the SMS and Call Log policy lists "SMS-based money management — for example,
apps that track and manage budget" among the permitted exceptions, so there
is one build for every channel and no stripped-down Play variant.

It is not automatic, though. Uploading the bundle triggers the Permissions
Declaration Form, and the release sits in "pending publication" through an
extended review that can take weeks.

What the submission needs:

1. The **app bundle** (`play-bundle` from the release run), not an APK.
2. Permissions Declaration Form:
   - Core functionality: **SMS-based money management**.
   - A **video demonstration** (YouTube link preferred) showing the flow:
     Settings → Scan SMS inbox → the disclosure dialog → the system prompt →
     transactions appearing in the ledger. Google reviews this by eye, so
     show the permission actually being used for the stated purpose.
   - Access instructions: "All functionality is available without special
     access" — there is no account.
3. A privacy policy URL. Point it at `PRIVACY.md` on GitHub.
4. The Data safety form. Tally collects nothing and transmits nothing: no
   data shared, no data collected, and the app requests no internet
   permission at all. SMS is read and processed on the device.
5. Store listing: reuse `fastlane/metadata/android/en-US/` — the title, short
   and full descriptions, the 512×512 icon, the 1024×500 feature graphic and
   the phone screenshots are already the right sizes.

The in-app disclosure before the permission prompt
(`showSmsDisclosure` in `lib/main.dart`) is required by Play's user-data
policy — it has to appear *before* the system dialog and say what is read
and why. Do not remove it.

If the declaration is ever rejected, the fallback is to ship on
IzzyOnDroid and GitHub only. Do not ship a Play build with the SMS features
removed: without them Tally is a manual ledger, which is not the product.
