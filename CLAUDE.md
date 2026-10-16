# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

QuotaPeek is a native macOS 14+ menu-bar app (SwiftPM, SwiftUI + AppKit, no third-party dependencies) that shows API quota usage from a `GET /v1/usage` endpoint. User-facing strings and the README are in Chinese.

## Commands

XCTest requires a full Xcode, not just Command Line Tools. On this machine, prefix with `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer` if `xcode-select` points at CLT.

```sh
swift build                                   # debug build of all targets
swift test                                    # all tests (QuotaCoreTests)
swift test --filter QuotaCoreTests.testClaudeWindowsAndDataEnvelope   # single test
bash scripts/build-app.sh                     # release .app + .zip + .dmg into dist/ (native arch)
bash scripts/build-app.sh --universal         # arm64 + x86_64
IDENTITY="Developer ID Application: ..." bash scripts/build-app.sh   # real signing (default is ad-hoc; never notarizes)
swift run quota-peek --parse response.json    # parse a saved response with the shared parser
swift run quota-peek --base-url https://... --key-stdin   # live fetch; key via stdin, never argv
```

The app accepts `--settings` (open settings on launch) and `--show` (open popover on launch). `build-dmg.sh` creates a venv in `.build/dmg-tools` with `ds-store` to write the DMG Finder layout. `dist/` is gitignored build output.

## Architecture

Three targets share one library:

- **`QuotaCore`** (library, the only tested target): protocol and data model.
  - `QuotaClient.endpoint(for:)` normalizes a user-entered base URL (root, `/v1`, or `/v1/usage`, keeping reverse-proxy prefixes); HTTPS only, except HTTP for exact loopback hosts; rejects credentials/query/fragment.
  - `QuotaClient.fetch` uses an ephemeral, cookie-less `URLSession`, refuses redirects (so the Bearer key never follows one), streams the body with a 1 MiB cap, and maps every failure to a `QuotaError`.
  - `QuotaParser` accepts only the named windows `five_hour`, `seven_day`, `seven_day_sonnet`, `seven_day_opus` (optionally wrapped in `data`, optional `unit: "percent_used"`). `null` or missing utilization means *unknown* and is skipped, not zero. Booleans, strings, and values outside 0–100 are errors. Unknown formats are rejected rather than guessed. `resets_at` may be ISO 8601 or Unix seconds (number or digit string); VM2API sends either depending on its data source.
  - `Preferences` / `ConnectionProfile` hold the on-disk config schema. Version 2 holds multiple profiles. Unversioned or v1 files (single `baseURL`/`name`) migrate to a profile with id `"default"`, which keeps the existing Keychain account. Future versions and duplicate/empty ids throw, so the file is never overwritten with defaults. `validated()` clamps settings to the allowed sets.
- **`QuotaPeek`** (app):
  - `QuotaPeekApp.swift`: custom `main` plus `AppDelegate` (accessory app, `NSStatusItem`, popover, right-click profile menu, settings window).
  - `AppModel.swift`: the `@MainActor` state machine. Per-profile `ProfileState`, a refresh queue capped at 3 concurrent fetches, and per-profile request tokens to drop stale results. `upsertProfile` validates against the live endpoint *before* saving; while a save is in progress it reserves a fetch slot via `connectionWaiter`. Notifications are deduplicated per window. Refresh also runs on a timer and on wake.
  - `Configuration.swift`: `ConfigurationStore` (atomic write via temp file + `rename`, 0700 dir / 0600 file in `~/Library/Application Support/QuotaPeek/`) and `KeyStore` (Keychain service `com.local.QuotaPeek.api-key`, account = profile id, non-synchronizable, `ThisDeviceOnly`; startup reads are non-interactive).
  - `QuotaViews.swift` / `SettingsView.swift`: SwiftUI popover and settings.
- **`QuotaPeekCLI`** (`quota-peek` executable): thin wrapper over `QuotaCore` for manual verification.

## Invariants to preserve

- **Never show unknown as zero.** On refresh failure, keep the last successful snapshot and mark it stale. Don't zero a window after its reset time passes until new data arrives.
- **Save transactionally.** The order is: fetch-validate, write the new key to Keychain, then write prefs. If the prefs write fails, restore the old key. If that restore also fails, set `storageRecoveryRequired` and block further saves. Nothing may throw after the `rename` in `ConfigurationStore.save`.
- **Unreadable config disables saving.** If the config can't be decoded, `globalError` is set and all persistence is disabled (`canPersist()`), so the user's file is never clobbered.
- **Only fixed `QuotaError` messages reach the UI.** `connectionError` never surfaces raw system or server text, which could contain secrets. The one exception is the server's `error.code`, carried in `QuotaError.http(_, reason:)`; `QuotaClient.errorCode(from:)` keeps it only if it is a short identifier. Never log response bodies or keys.
- **Keychain failures must not block launch.** A locked Keychain or a changed code signature should not block menu-bar startup. Use `allowInteraction: true` only in user-initiated save paths.
- **Language mode is Swift 5.** The package uses tools 6.0 but `swiftLanguageModes: [.v5]`.
