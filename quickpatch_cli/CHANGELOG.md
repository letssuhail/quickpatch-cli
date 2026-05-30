## 1.6.112

- **Fix onboarding crash**: `quickpatch --version` and `quickpatch doctor` no longer fail with a cache-corrupted error on a fresh install before the pinned Flutter/engine is downloaded. The engine revision now falls back to the install-root pin, and both commands degrade to a readable "not installed (downloaded on first release/patch)" instead of throwing.

## 1.6.111

- **iOS arbitrary code push (`--interpreter`)**: release/patch iOS apps with arbitrary Dart changes (new widgets, screens, control-flow) over the air via an on-device Dart interpreter.
- **Staged OTA**: interpreter patches are signature-verified, staged to disk on download, and applied at the next launch's first frame — no flash of the old UI, no live reassemble.
- **`quickpatch upgrade`**: now performs a real git fast-forward + rebuild instead of printing an upgrade hint.
- **Fix**: declare `asn1lib` as a direct dependency (used for patch-signature key parsing).

## 1.6.109

- **`flutter versions list`**: Show newest versions first. Remove `.reversed` since server already returns newest-first order.

## 1.6.108

- **Fix `flutter versions list`**: Always fetch from production server using a fixed URL — previous version used the project-level `hostedUri` which caused silent fallback to local git branches.

## 1.6.107

- **`flutter versions list`**: Now fetches supported versions directly from your QuickPatch server instead of reading all Shorebird fork branches. Only versions mirrored in R2 are shown — the ones you actually support. Falls back to local git branch listing if server is unreachable.

## 1.6.106

- **Fix**: When `QUICKPATCH_HOSTED_URL` is not set, the CLI now shows a clear error with the exact export command (platform-aware: `export` on macOS/Linux, `$env:` on Windows) instead of a cryptic `SocketException`.

## 1.6.105

- **Login**: Replaced browser OAuth flow with API key authentication. Run `quickpatch login` and paste your key from the dashboard.
- **Upgrade**: `quickpatch upgrade` now shows the correct `dart pub global activate quickpatch_cli` instruction instead of crashing with a git error.
- Published to [pub.dev](https://pub.dev/packages/quickpatch_cli) — install and upgrade via `dart pub global activate quickpatch_cli`.
