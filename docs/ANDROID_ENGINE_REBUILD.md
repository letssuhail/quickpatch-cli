# Android engine rebuild — fix Android code-push (Bug 1 + Bug 2)

_Diagnosis 2026-05-31. Android code-push builds + installs but **patches never
take effect** (see [project-android-e2e]). Two engine-level bugs; both fixed by
one Android engine rebuild from the current source._

## Root cause (confirmed)

The **hosted Android engine artifacts are stale** — built from an older engine
whose Dart SDK differs from the Flutter the CLI now pins:

| | Dart SDK revision | abbrev |
|---|---|---|
| Pinned Flutter `1a55eb72` (produces the patch kernel) | `98116461144f4429ab873f8497023a5ec3b08127` | `9811646114` |
| Hosted Android `const_finder` (what it was built with) | `9dc12969f5…` | `9dc12969f5` |

→ the Android build fails `IconTreeShakerException: Unexpected Kernel SDK Version
9811646114 (expected 9dc12969f5)` (needs `--no-tree-shake-icons` to limp past),
and the **reassembled patch snapshot is engine-incompatible → the engine sets
the patch as active but silently boots the base** (`current_patch_number` stays
`None`).

**The fix is to rebuild the Android engine artifacts from the SAME source that
built the working iOS engine** — `/Volumes/SSD/sb_engine_src` (Dart SDK
`98116461…`, the iOS `ios_release_qp` was built here; it has no Android out dir,
i.e. Android was never built from this current source).

## Bug 1 — engine reads `shorebird.yaml`, CLI bundles `quickpatch.yaml`

The current source is NOT de-branded for the config read. Patch before building:

- **`engine/src/flutter/shell/platform/android/io/flutter/embedding/engine/FlutterJNI.java:235`**
  ```java
  InputStream yaml = context.getAssets().open("flutter_assets/shorebird.yaml");
  ```
  → try `flutter_assets/quickpatch.yaml` first, fall back to `shorebird.yaml`:
  ```java
  InputStream yaml;
  try {
    yaml = context.getAssets().open("flutter_assets/quickpatch.yaml");
  } catch (IOException e) {
    yaml = context.getAssets().open("flutter_assets/shorebird.yaml");
  }
  ```
- (Optional cosmetics, same file lines 242/244/245 + `shorebird.cc:149,152`
  log strings — not required for function.)

With this patch the CLI's existing `quickpatch.yaml` asset is found directly, so
**no per-project `shorebird.yaml` is needed** (drop the qpfreshtest test mirror
and the CLI's legacy `syncEngineConfig` once shipped).

## Bug 2 — rebuild the Android artifacts (matching Dart SDK)

Build the Android targets from `sb_engine_src` (already Dart SDK `98116461`):

1. **Toolchain:** depot_tools on PATH (`gn`, `ninja` — currently absent; the repo
   has `flutter/tools/gn` which supports `--target-os=android`). Use the engine's
   pinned depot_tools.
2. **gn gen** per ABI (release):
   ```
   ./flutter/tools/gn --target-os android --runtime-mode release --android-cpu arm64 --no-goma
   ./flutter/tools/gn --target-os android --runtime-mode release --android-cpu arm
   ./flutter/tools/gn --target-os android --runtime-mode release --android-cpu x64
   ```
3. **ninja** the Android outputs (per the 3 out dirs): `flutter_embedding_release`,
   `libflutter.so`, `gen_snapshot`, `const_finder`, `analyze_snapshot`.
   ⚠️ The const_finder + gen_snapshot are the ones that MUST come from this Dart
   SDK (`98116461`) so the kernel hash matches.
4. **Verify:** `gen_snapshot --version` / the snapshot-version hash; confirm
   const_finder no longer rejects the pinned Flutter's kernel.

> Per the iOS notes, the modern engine build is environment-specific (Xcode/NDK
> SDK paths, content_hash) — iterate on a real build, don't assume one-shot.

## Publish + wire up

5. **Package the Android Maven artifacts** (`.pom` + `.jar/.aar`): `flutter_embedding_release`,
   `arm64_v8a_release`, `armeabi_v7a_release`, `x86_64_release` — at the engine
   revision the Flutter expects (gradle asked for `io.flutter:*:1.0.0-6500c84eba…`;
   if the new engine commit differs, update `bin/internal/engine.version` in the
   vended Flutter and/or republish under the expected coordinates).
6. **Upload to the Maven mirror** the CLI uses: `${QUICKPATCH_HOSTED_URL}/storage/download.quickpatch.dev/download.flutter.io/io/flutter/…`
   (the server already serves this path — returns 200). Also host `gen_snapshot`/`const_finder`
   where the CLI fetches Android engine tools.
7. **CLI:** Android `release/patch` already work once artifacts resolve; the only
   CLI need is `QUICKPATCH_HOSTED_URL` set (consider deriving it from the app's
   `quickpatch.yaml base_url` automatically). Drop `--no-tree-shake-icons` once
   the const_finder matches.

## Verify on device (OPPO Reno8 5G, CPH2359)

```
quickpatch release android   (QUICKPATCH_HOSTED_URL set)
# install .aab via bundletool, confirm base renders
# change a Dart file, quickpatch patch android --release-version=<v>
# relaunch twice -> logcat should show patch_available:true -> Downloaded ->
#   next boot: current_patch_number advances + the patched UI renders
```

## Checklist
- [ ] Patch FlutterJNI.java config read (quickpatch.yaml → shorebird.yaml fallback)
- [ ] gn gen + ninja Android (arm64/arm/x64) from sb_engine_src (Dart SDK 98116461)
- [ ] const_finder/gen_snapshot version hash matches the pinned Flutter
- [ ] Package + upload Maven artifacts + engine tools to the mirror
- [ ] Device-verify two-launch patch actually boots (current_patch_number advances)
- [ ] Remove `--no-tree-shake-icons` + per-project shorebird.yaml workarounds
