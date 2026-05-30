# Adding support for a new Flutter version (multi-version)

QuickPatch's iOS arbitrary-code-push works only with a **QuickPatch-fork engine
built for the exact Flutter revision** the app uses (the on-device VM only loads
snapshots whose version hash matches the engine). The CLI is already built to
support many Flutter versions side by side — each one just needs its engine
built, published, and registered.

**The CLI side is done.** Supporting a new version is the four steps below,
repeated per version. Steps 1–2 are the heavy part (an engine build); steps 3–4
are minutes.

---

## How the pieces fit

| Piece | Where | Role |
|---|---|---|
| Flutter rev → engine rev map | `lib/src/engine_bootstrap.dart` → `_engineRevisionForFlutterRevision` | Single source of truth for "which engine for which Flutter" |
| Engine bundle hosting | R2 `engine/ios/<engineRev>/` (public CDN) | Auto-downloaded by `ensureQuickPatchIosEngine()` |
| Version gating | `lib/src/flutter_version_constraints.dart` → `FlutterSupportConstraint` | Min-version floor + allowlist bridge |
| Version selection | `quickpatch release --flutter-version <X>` → `resolveTargetFlutterRevision()` | Installs the chosen Flutter, then ensures its engine |
| Engine source + patches | repo `letssuhail/quickpatch-engine` (`engine_patches/`, `BUILD.md`) | The clean-room patch set + reproducible build recipe |

---

## Step 1 — Build the patched engine for the new Flutter revision

This is the only hard/slow step (hours, macOS + Xcode + depot_tools).

1. Pick the target **upstream Flutter revision** `F` you want to support (the
   `flutter --version` revision, e.g. a `flutter_release/3.x` branch HEAD of the
   QuickPatch fork).
2. Follow `quickpatch-engine/engine_patches/BUILD.md`:
   - `gclient` sync the engine at the Flutter `F`'s engine + the pinned Dart SDK.
   - Apply `engine_patches/` (flutter-engine.patch, dart-sdk.patch, new files).
   - `gn` (build Dart from source) + `ninja` the three targets
     (`Flutter.framework` ios-arm64, `gen_snapshot_arm64`, `analyze_snapshot_arm64`).
   - Build the merge-loader toolchain pieces (`gen_dynamic_interface.aot`,
     `gen_kernel_aot`, etc.) the interpreter path needs.
3. **Record the snapshot version hash** the build produces — this is the new
   `engineRev` (e.g. `76ba1f79…`). Releases, patches, and the engine must all
   share it.

> Don't assume a one-shot CI YAML works — the engine build is environment-specific
> (Xcode SDK paths, content_hash). Iterate on a real runner. `build_engine_artifacts.yml`
> is the closest scaffold.

## Step 2 — Package + publish the engine bundle to R2

```bash
# In the engine working tree:
./package_interpreter_engine.sh          # → quickpatch-engine-ios-arm64-<engineRev8>.tar.gz + SHA256SUMS

# Publish to the public R2 CDN (server repo has the creds in .env):
cd <quickpatch-server>
node --env-file=.env scripts/upload_engine.mjs <engineRev> <tarball> SHA256SUMS.txt
# → engine/ios/<engineRev>/  (verify the public no-auth download + sha256 match)
```

The CLI downloads from `https://pub-…r2.dev/engine/ios/<engineRev>/` (override via
`QUICKPATCH_ENGINE_CDN`). Also mirror to the GitHub release for durability.

## Step 3 — Register the version in the CLI (trivial)

Add the mapping in `lib/src/engine_bootstrap.dart`:

```dart
const _engineRevisionForFlutterRevision = <String, String>{
  '1a55eb72b61a6c8acac0bf7f7d4738f399f83a0f': '76ba1f79062a25f3e339546db98d259d',
  '<new Flutter revision F>':                  '<new engineRev>',   // ← add this
};
```

If `F` is below an existing min-version floor but ships the needed feature, also
add its `engineRev` to the relevant `FlutterSupportConstraint.allowedRevisions`
in `flutter_version_constraints.dart` (see the doc-comment there).

## Step 4 — Verify + ship the CLI

1. **Device test** the new version end to end:
   ```bash
   quickpatch release ios --interpreter --flutter-version <X> --public-key-path=public.pem
   quickpatch patch   ios --interpreter --flutter-version <X> --release-version=<v> \
     --private-key-path=private.pem --public-key-path=public.pem
   ```
   Confirm the two-launch staged-apply flip on a real device.
2. Bump `quickpatch_cli` version + CHANGELOG, commit, push `main`, `dart pub publish`.
   (curl|bash users get it from `main`; pub.dev users get the new version.)

---

## Checklist (per version)

- [ ] Engine built for Flutter rev `F`; snapshot hash recorded (`engineRev`)
- [ ] Bundle published to R2 `engine/ios/<engineRev>/` (sha256 verified) + GitHub mirror
- [ ] `_engineRevisionForFlutterRevision` entry added
- [ ] `FlutterSupportConstraint.allowedRevisions` updated if below a floor
- [ ] Device-verified release + patch on the new version (two-launch, no flash)
- [ ] CLI version bumped, published to both channels

---

## Roadmap note

Supporting the *current N most-recent stable Flutter versions* means keeping N
engine builds current. As Flutter releases, the maintenance cost is **one engine
build per new version** plus dropping the oldest. Automating step 1 on CI is the
biggest lever for scaling this — but treat it as iterative infra, not a one-shot.
