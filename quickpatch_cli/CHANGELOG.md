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
