## 1.6.135

- **iOS staged rollouts now gate per device.** The interpreter bootstrapper's patch-check request now carries the persistent per-install `client_id` (the same id used for download/install telemetry). The server buckets staged rollouts per device — `sha256(client_id:release:patch) → 0..99` compared against the rollout percent — so without a client id every iOS device hashed to the same bucket and a percentage rollout was effectively all-or-nothing. Android already sent it (native updater); no server change needed (the check endpoint already accepted `client_id`). Parity-safe: no bootstrapper import changes (the frozen-import regression test still passes). Rebuild the iOS release with ≥1.6.135 for per-device staged rollouts.

## 1.6.134

- **iOS interpreter releases report download/install telemetry — parity-safe this time.** Re-lands the 1.6.132 feature with the root cause of its breakage designed out: the telemetry helpers use ONLY libraries the bootstrapper already imports (`dart:io`, `dart:convert`, `package:crypto` — the client id is sha256 over process/time entropy instead of `dart:math` `Random`), so the base image's library graph is byte-identical to 1.6.131/1.6.133 and patch-module loading is unaffected by construction. A regression test now freezes the bootstrapper's exact import list so any future import change fails CI with a pointer to the patcher `extraImports` mirror. Events: `__patch_download__` when a patch is staged (background OTA and user-driven `update()` paths), `__patch_install__` when a patched module reaches its first frame; persistent per-install `client_id`; once-per-patch dedupe with the marker written only after a server 200 (failed sends retry next launch); fire-and-forget so reporting can never block or crash the app. Server-side, a partial unique index on `(appId, clientId, type, patchNumber, releaseVersion)` for the two countable types makes the dashboard numbers per-device facts even against client retries. Rebuild the iOS release with ≥1.6.134 for counts to appear; already-installed builds don't backfill.

## 1.6.133

- **Revert the 1.6.132 iOS download/install telemetry change — it broke patch application.** Adding an `import 'dart:math'` (+ telemetry helpers) to the release's server-mode bootstrapper changed the base image's library set without a matching update to the patcher's `extraImports` mirror. A patch built against the un-mirrored import-dill then bundles its own copy of a library the base already holds and fails to load on device ("library ... is already loaded") — the staged patch never applies. Reverted the bootstrapper to the byte-identical 1.6.131 generator so releases + patches are consistent again. iOS download/install telemetry is deferred until it can be added without perturbing the base/patch library parity (and verified with a real on-device build). The server-side fix (not counting iOS binary-diff `__patch_update_failure__` as a failure) is unaffected and stays.

## 1.6.132 (yanked — breaks iOS patch application; use 1.6.133)

- iOS interpreter releases report download/install telemetry from the bootstrapper. **Superseded/yanked**: the `dart:math` import it added to the base broke patch-module loading (see 1.6.133). Do not use for iOS releases.

## 1.6.131

- `quickpatch init` now always writes `base_url` into quickpatch.yaml (previously only when QUICKPATCH_HOSTED_URL was set). Without it, Android builds resolved the Flutter engine from Google's CDN and got the vanilla engine with no on-device updater — silently breaking OTA for newly initialized apps. `QUICKPATCH_HOSTED_URL` still overrides for self-hosted servers.

## 1.6.130

- **Zero-config patch signing.** On the first `quickpatch release` for an app, the CLI now auto-generates an RSA-2048 key pair into a per-app key store (`<config dir>/keys/<app_id>/`, next to the CLI credentials) and embeds the public key automatically; `quickpatch patch` signs with the stored key automatically. No openssl knowledge or key flags needed. Explicit `--public-key-path`/`--private-key-path`/`--public-key-cmd`/`--sign-cmd` always override, so CI and externally-managed keys keep working unchanged. A patch for a release built without a key stays unsigned (patching is never the key-creation moment).

## 1.6.129

- **quickpatch_code_push works on the iOS interpreter path (prompt-driven updates).** `update()` on an interpreter release failed ("Downloaded patch file does not have valid zstd magic bytes") because it invoked the native binary-diff updater, which cannot process bytecode-module patches. The generated bootstrapper now installs `QuickPatchInterpreterOverrides` hooks (package 1.1.0) so `checkForUpdate`/`update`/`readCurrentPatch`/`readNextPatch` drive the interpreter's staged full-module flow. Device-proven end-to-end: check → consent dialog → download+stage → restart → patched.
- **Interpreter bootstrapper honors `auto_update: false`** — the background download+stage is skipped; updates become user-driven via quickpatch_code_push (same semantics as the native updater).
- **iOS interpreter patch no longer collides at load.** The patcher's import-dill now covers the packages the release baked into the base (quickpatch_code_push, asn1lib/crypto/pointycastle — gated on the app's package_config), so the patch module references them instead of bundling copies ("library ... is already loaded" → boot-load skipped → blank screen).
- **A bad staged patch can no longer blank the app forever**: if the staged module fails to LOAD at boot, the stage is cleared and the bundled base is booted (previously nothing was loaded, and since the empty frame reset the crash counter the bad stage was never dropped).
- **Engine ensure re-asserts the interpreter platform overlay**: `flutter precache`/artifact re-materialization can revert `common/flutter_patched_sdk*` to stock while the engine dir stays overlaid, breaking --interpreter builds (`Method not found: 'loadDynamicModulePatch'`). Now detected and re-overlaid from the engine's cached platform dill.
- **iOS interpreter release hard-fails if the built archive is missing the app bytecode module** (previously such a release published and booted to a blank screen).

## 1.6.128

- **Android code push on stable Flutter 3.44.0.** Stable Flutter ships a vanilla Android engine with no on-device updater, so patches couldn't apply. The build now maps the vanilla engine to the QuickPatch Android engine (which carries the updater) for the duration of the build, so `libflutter` supports OTA and the snapshot stays consistent. Device-proven: an OTA code patch applies over-the-air, and a patch signed with an untrusted key is rejected (no brick).
- **`QUICKPATCH_PUBLIC_KEYS` environment variable** for signing-key rotation (the previous `SHOREBIRD_PUBLIC_KEYS` name is still accepted as a fallback, so existing setups keep working).
- **Fix: iOS `--interpreter` apps that use `quickpatch_code_push` crashed at module load (`Unable to find function ... in dart:isolate / dart:ffi`).** The generated dynamic-interface (which marks the AOT framework/SDK surface the interpreted app module may call) omitted `dart:isolate` and `dart:ffi`, so `Isolate.run` and the FFI symbols (`nullptr`/`Pointer`) that `quickpatch_code_push` uses were tree-shaken out of the base AOT image and the interpreter FATAL'd at module load. The release build now adds `dart:isolate` and `dart:ffi` to the interface's `callable` + `can-be-used-as-type` sections, so they are retained and resolvable. Rebuild the release with this version.
- **Fix: iOS engine overlay could silently revert to the stock Flutter engine (white screen).** `ensureQuickPatchIosEngine` treated its `.quickpatch-engine-rev` stamp as sufficient proof the overlay was intact. But a partial overlay (interrupted mid-copy) or a `flutter precache` / artifact re-materialization can leave the stamp in place while `gen_snapshot_arm64` reverts to the stock Flutter build. An app AOT-compiled by a stock gen_snapshot produces a snapshot whose version hash the QuickPatch runtime engine refuses to load — the app boots to a white screen. `ensure` now also verifies the on-disk `gen_snapshot_arm64` actually embeds the engine revision, and re-installs the engine if it doesn't. This most commonly affected a second Flutter version's cache dir (e.g. stable 3.44.0), whose engine had been partially overlaid.

## 1.6.127

- **Support for Flutter 3.44.0 stable**: `quickpatch release`/`patch` now work on apps built with **stable Flutter 3.44.0** (revision `559ffa3f75…`), in addition to the 3.44.0-rc3 pin. Stable 3.44.0 pins the identical Dart SDK revision as the rc3 fork, so it reuses the same on-device engine revision (snapshot hash unchanged) — no new engine download is required. Target it by revision: `quickpatch release ios --interpreter --flutter-version 559ffa3f75e7402d65a8def9c28389a9b2e6fe42`. (`getRevisionForVersion` also gained an upstream-tag fallback so a plain `--flutter-version 3.44.0` resolves to stable on a vanilla-Flutter clone; on the legacy Shorebird-fork clone the fork's `flutter_release/3.44.0` branch still points at the rc3 pin, so use the revision there.)

## 1.6.126

- **Reliable large-artifact uploads (direct-to-R2)**: release & patch artifacts now upload **directly to object storage via a presigned URL** instead of being proxied through the API server. Large release artifacts (the iOS interpreter base is ~40MB+) previously failed with a connection reset when the API server ran behind a memory/edge-limited host (e.g. Railway); they now upload reliably regardless of artifact size or host. Requires the matching server update that returns presigned upload URLs.

## 1.6.125

- **Publish-time smoke-test gate (Android)**: before an Android patch is uploaded, `quickpatch patch` now builds the patched app as an APK, installs and launches it on a connected device/emulator, and verifies it reaches its first frame. If the patched app **crashes or hangs on startup**, the patch is **not published** (the command exits non-zero) — so a startup-crashing patch never reaches your users. Detection uses the OS first-frame signal (`ActivityManager: Displayed`) for success, and logcat crash markers / a render timeout for failure. Runs automatically when a device is connected; skipped (with a warning for the `stable` track) when none is. Control it with `--no-smoke-test` and `--smoke-test-timeout=<seconds>` (default 45). Device-proven: a startup-crash patch is blocked; a healthy patch passes and publishes.

## 1.6.124

- **iOS `--interpreter` patches now support ANY code change, including new classes/screens** (device-proven: a patch that adds a whole new screen opens on a physical iPhone via OTA, no reinstall). The patch is now built as a **full app module** (the whole changed app behind a `dyn-module:entry-point` wrapper, like the release's base module) and the on-device bootstrapper **loads + runs it via `loadModuleFromBytes`** on the next launch (whole-program replacement) instead of the previous function-merge loader, which could only swap existing functions and crashed when a patch added a new top-level class.
- **Self-heal against a bad staged patch**: a boot-failure counter (bumped before applying a staged patch, reset once the first frame renders) drops a staged patch that crashes repeatedly at load, falling back to the base — so a bad patch can no longer permanently brick the app.
- **Note:** the bootstrapper is baked into the release, so rebuild your release with this version (`quickpatch release ios --interpreter`) before publishing full-module patches to it.

## 1.6.123

- **iOS `--interpreter` release & patch now build end-to-end** (device-proven: an arbitrary Dart code change applied over-the-air on a physical iPhone with no reinstall). Completes the `dynamic_modules` resolution work from 1.6.122 by fixing three follow-on issues:
  - The generated `package_config.json` is written to the build dir, so its relative `rootUri`s are now rebased to absolute — previously the app's own `package:<app>/...` imports resolved against the wrong base.
  - The interpreter release now declares `dynamic_modules` as a `path:` dependency so the `flutter build ipa` step (which compiles the bootstrapper via the project's own package_config) can resolve it.
  - The interpreter patch now runs a `flutter pub get` with the vended Flutter before compiling, so `package:flutter` resolves to the engine-matched framework instead of a different system Flutter that fails to compile against the vended platform.

## 1.6.122

- **Fix iOS `--interpreter` patch/release builds**: `quickpatch patch ios --interpreter` (and the interpreter release path) failed at `gen_kernel` with `Couldn't resolve the package 'dynamic_modules'`. The bootstrapper imports `package:dynamic_modules`, whose functions wrap `dart:_internal` dynamic-module natives that are already present in the engine's platform dill — but the wrapper package itself wasn't resolvable. The CLI now generates that wrapper and an augmented `package_config.json` automatically before compiling, so no engine change or extra setup is needed. Your project's `.dart_tool/package_config.json` is left untouched.

## 1.6.121

- **`quickpatch init --channel`**: choose the update channel a build listens to (defaults to `stable`). Ship a beta build with `--channel=beta`, publish to it with `quickpatch patch --track=beta`, and your store build (on `stable`) stays untouched. The flag writes `channel:` into `quickpatch.yaml`; the on-device updater already honors it. Stable builds keep a clean config (no channel line written for the default).

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
