## 1.6.120

- **Branded CLI experience**: `quickpatch init` now opens with a welcome banner — an emerald ANSI "QUICKPATCH" wordmark, tagline, and a short wizard intro — and `quickpatch --help` shows the same logo header. Color and art are automatically stripped when output isn't a terminal (pipes, CI, files) and are never emitted in `--json` mode, so scripting output stays clean.

## 1.6.119

- **Default endpoints now use the production custom domains**: the default hosted server is `https://api.quickpatch.dev` (was the Railway origin URL) and the login/console hint points to `https://quickpatch.dev`. These are only defaults — `QUICKPATCH_HOSTED_URL` and the `base_url` in `quickpatch.yaml` still override them, so self-hosting and existing projects are unaffected.

## 1.6.118

- **Multi-version foundation**: the CLI now resolves the engine revision for a Flutter version from the server's `/api/v1/engine-versions` registry, falling back to the built-in map if the server is unreachable. This means a newly-built Flutter version becomes usable without shipping a new CLI - the engine-build pipeline just publishes the version to the registry. Behavior is unchanged for the currently-shipped version (it resolves identically), and offline/no-server builds keep working via the fallback.

## 1.6.117

- **Signing-key rotation (end to end)**: a build can now trust more than one patch-signing public key (a primary key plus rotation keys), so a patch signed by a newly-rotated key is accepted alongside one signed by the prior key — letting the signing key be rotated without invalidating installs. The additional keys, supplied as a comma-separated list, are embedded into `quickpatch.yaml` for the Android/data-patch path and baked into the iOS interpreter bootstrapper's trusted-key set; in both cases a patch verifies if its signature matches **any** trusted key (a valid-but-wrong key is skipped, never accepted). Device-verified on a physical Android device and a physical iPhone: a patch signed with a rotated key is downloaded, verified against the multi-key set, and applied.

## 1.6.116

- **Patch signing fix (security)**: ensure the patch public key is embedded into the app before every Android and iOS build, so on-device patch **signature verification is actually enforced**. Previously the key could be omitted for QuickPatch projects, leaving the on-device updater unable to verify patches (effectively unsigned). Device-verified on a physical Android device: a patch signed with an **untrusted key is now rejected** at boot ("Patch signature is invalid"), while one signed with the trusted key applies normally. Applied automatically and idempotently, so existing installs are fixed on the next build.
- Forward additional trusted public keys (for signing-key rotation) to the build environment, so a rotated key can be trusted before the old one is retired.

## 1.6.115

- **Self-host without an env var**: the storage/mirror base URL now falls back to `quickpatch.yaml`'s `base_url` (after the `QUICKPATCH_HOSTED_URL` env override, before the hosted default), so a `base_url` in your config is enough to point both the build-time engine downloads and the on-device updater at your own server — no manual `QUICKPATCH_HOSTED_URL` export. With neither set, behaviour is unchanged.

## 1.6.114

- **Fix `--version` reporting**: `version.dart` was not bumped in the previous two releases, so `quickpatch --version` (and the `x-cli-version` request header) reported a stale version. Now synced to the package version.

## 1.6.113

- **Cleanup**: removed the legacy config-file fallback (projects use `quickpatch.yaml` exclusively) and tidied source comments. No functional change for existing projects.

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

- **`flutter versions list`**: Now fetches supported versions directly from your QuickPatch server instead of reading all engine fork branches. Only versions mirrored in R2 are shown — the ones you actually support. Falls back to local git branch listing if server is unreachable.

## 1.6.106

- **Fix**: When `QUICKPATCH_HOSTED_URL` is not set, the CLI now shows a clear error with the exact export command (platform-aware: `export` on macOS/Linux, `$env:` on Windows) instead of a cryptic `SocketException`.

## 1.6.105

- **Login**: Replaced browser OAuth flow with API key authentication. Run `quickpatch login` and paste your key from the dashboard.
- **Upgrade**: `quickpatch upgrade` now shows the correct `dart pub global activate quickpatch_cli` instruction instead of crashing with a git error.
- Published to [pub.dev](https://pub.dev/packages/quickpatch_cli) — install and upgrade via `dart pub global activate quickpatch_cli`.
