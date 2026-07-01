import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/platform.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';

/// Built-in FALLBACK map of Flutter revision -> QuickPatch iOS engine (snapshot)
/// revision, used only when the server registry can't be reached. The on-device
/// VM only loads snapshots whose version hash matches the engine, so a release +
/// its patches + the engine must all share this revision.
///
/// The live source is the server's `/api/v1/engine-versions` registry (see
/// [_fetchEngineVersionMap]); a newly-built Flutter version is published there,
/// so it becomes usable WITHOUT shipping a new CLI. This constant only needs to
/// list versions that must work offline / if the server is down.
const _engineRevisionForFlutterRevision = <String, String>{
  // Re-baselined 2026-05-30 from dd03f6ff... to the merge-loader engine, which
  // adds arbitrary-code-push (Dart interpreter / dynamic modules) ON TOP of the
  // data-only instruction-reuse path — a strict superset. Releases + patches
  // built against the old dd03f6ff engine must be rebuilt on this revision.
  // Flutter 3.44.0-rc3 fork.
  '1a55eb72b61a6c8acac0bf7f7d4738f399f83a0f':
      '76ba1f79062a25f3e339546db98d259d',
  // Flutter 3.44.0 STABLE. Maps to the SAME engine revision as the rc3 entry
  // above because stable 3.44.0 pins the IDENTICAL Dart SDK revision
  // (98116461144f4429ab873f8497023a5ec3b08127) as the rc3 fork. The on-device
  // snapshot-version hash is derived purely from the Dart VM source, so it is
  // unchanged (76ba1f79...) — the entire Dart toolchain (gen_snapshot,
  // dart2bytecode, gen_kernel, gen_dynamic_interface.aot) and the published
  // engine bundle are reused as-is. Only the Flutter engine C++ commit differs
  // (rc3 6500c84e -> stable 4c525dac5e), an ABI-compatible same-minor delta.
  '559ffa3f75e7402d65a8def9c28389a9b2e6fe42':
      '76ba1f79062a25f3e339546db98d259d',
};

/// Public base URL of the R2 bucket that hosts the prebuilt engine bundles.
/// Override with `QUICKPATCH_ENGINE_CDN` (e.g. a custom domain).
const _defaultCdnBase = 'https://pub-110a0f73321f42dcb93e02c2503b992a.r2.dev';

/// Ensures the prebuilt QuickPatch iOS engine for the active Flutter revision is
/// installed in the Flutter SDK cache, downloading + verifying it from the CDN
/// if missing. Idempotent via a `.quickpatch-engine-rev` stamp. iOS builds are
/// macOS-only, so this relies on `curl`/`tar`/`shasum`/`codesign` being present.
Future<void> ensureQuickPatchIosEngine() async {
  final flutterRevision = quickpatchEnv.flutterRevision;
  // Resolve the engine revision: explicit override, then the server registry
  // (so new versions work without a CLI release), then the built-in fallback.
  final remoteMap = await _fetchEngineVersionMap();
  final engineRevision =
      platform.environment['QUICKPATCH_ENGINE_REV'] ??
      remoteMap[flutterRevision] ??
      _engineRevisionForFlutterRevision[flutterRevision];
  if (engineRevision == null) {
    final supported = <String>{
      ...remoteMap.keys,
      ..._engineRevisionForFlutterRevision.keys,
    }.join(', ');
    logger.warn(
      '[engine] No QuickPatch iOS engine is published for Flutter revision '
      '$flutterRevision, so iOS code push (especially --interpreter) will not '
      'work on this version.\n'
      'Supported Flutter revision(s): $supported\n'
      'Run `quickpatch flutter versions list`, or build on a supported version '
      'with `quickpatch release ios --flutter-version <version>`.',
    );
    return;
  }

  final cacheDir = Directory(
    p.join(
      quickpatchEnv.flutterDirectory.path,
      'bin', 'cache', 'artifacts', 'engine', 'ios-release',
    ),
  );
  final stamp = File(p.join(cacheDir.path, '.quickpatch-engine-rev'));
  final genSnapshot = File(p.join(cacheDir.path, 'gen_snapshot_arm64'));
  // The stamp alone is NOT proof the overlay is intact. A prior partial overlay
  // (interrupted mid-copy) or a `flutter precache` / artifact re-materialization
  // can leave the stamp in place while `gen_snapshot_arm64` has reverted to the
  // STOCK Flutter build. An app AOT-compiled by a stock gen_snapshot produces a
  // snapshot whose version hash the QuickPatch runtime engine refuses to load
  // (-> white screen / "Wrong full snapshot version"). So also verify the
  // on-disk gen_snapshot actually embeds the engine revision before trusting the
  // stamp. gen_snapshot is copied after the framework in the overlay below, so
  // if it carries the rev the rest of the overlay completed too.
  if (stamp.existsSync() &&
      stamp.readAsStringSync().trim() == engineRevision &&
      genSnapshot.existsSync() &&
      binaryEmbedsRevision(genSnapshot, engineRevision)) {
    logger.detail('[engine] QuickPatch iOS engine $engineRevision present.');
    return;
  }
  if (stamp.existsSync()) {
    logger.detail(
      '[engine] iOS engine stamp present but gen_snapshot is stale/stock — '
      're-installing $engineRevision.',
    );
  }

  final progress = logger.progress(
    'Fetching QuickPatch iOS engine ($engineRevision)',
  );
  final tmp = Directory.systemTemp.createTempSync('qp_engine');
  try {
    final cdn = (platform.environment['QUICKPATCH_ENGINE_CDN'] ?? _defaultCdnBase)
        .replaceAll(RegExp(r'/+$'), '');
    final asset =
        'quickpatch-engine-ios-arm64-${engineRevision.substring(0, 8)}.tar.gz';
    final base = '$cdn/engine/ios/$engineRevision';

    final tarball = p.join(tmp.path, asset);
    await _run('curl', ['-fSL', '--retry', '3', '-o', tarball, '$base/$asset']);
    await _run('curl', [
      '-fSL', '--retry', '3', '-o',
      p.join(tmp.path, 'SHA256SUMS.txt'), '$base/SHA256SUMS.txt',
    ]);

    final extract = Directory(p.join(tmp.path, 'extract'))
      ..createSync(recursive: true);
    await _run('tar', ['-xzf', tarball, '-C', extract.path]);
    // The tarball unpacks into an `ios-release/` subdirectory, and
    // SHA256SUMS.txt lists paths RELATIVE TO THAT DIRECTORY (e.g.
    // `./gen_snapshot_arm64`, `./Flutter.xcframework/...`). So verify from
    // inside `ios-release/` — copy the separately-downloaded sums file there
    // and run shasum with that as the working directory.
    final src = p.join(extract.path, 'ios-release');
    // Integrity check. The published SHA256SUMS.txt lists paths relative to the
    // `ios-release/` directory, but it also records a hash of ITSELF — a
    // self-referential entry that can never verify (writing that line changes
    // the file). Verify only the engine files: write a filtered copy that drops
    // the self-entry, then run shasum from inside `ios-release/`.
    final sumsLines = File(p.join(tmp.path, 'SHA256SUMS.txt')).readAsLinesSync();
    File(p.join(src, 'SHA256SUMS.check')).writeAsStringSync(
      '${sumsLines.where((l) => !l.trimRight().endsWith('SHA256SUMS.txt')).join('\n')}\n',
    );
    await _run(
      'shasum',
      ['-a', '256', '-c', 'SHA256SUMS.check'],
      workingDirectory: src,
    );
    final fwDir = Directory(
      p.join(cacheDir.path, 'Flutter.xcframework', 'ios-arm64',
          'Flutter.framework'),
    )..createSync(recursive: true);
    File(p.join(src, 'Flutter.xcframework', 'ios-arm64', 'Flutter.framework',
            'Flutter'))
        .copySync(p.join(fwDir.path, 'Flutter'));
    for (final tool in ['gen_snapshot_arm64', 'analyze_snapshot_arm64']) {
      File(p.join(src, tool)).copySync(p.join(cacheDir.path, tool));
      // Host tools must be (ad-hoc) signed to run on macOS.
      await Process.run('codesign', ['-f', '-s', '-', p.join(cacheDir.path, tool)]);
    }

    // Interpreter (arbitrary-code-push) toolchain, shipped in the bundle since
    // the merge-loader engine. Optional for backwards-compat with older
    // bundles that predate these files. Resolved via QuickPatchArtifact.
    // {dart2bytecodeIos, genKernelIos, flutterPlatformDillIos,
    // genInterfaceScriptIos}.
    for (final tool in const [
      'dart2bytecode.dart.snapshot',
      'gen_kernel_aot.dart.snapshot',
      'platform_strong.dill',
      'gen_dynamic_interface.dart',
      'gen_dynamic_interface.aot',
      'dartaotruntime',
    ]) {
      final f = File(p.join(src, tool));
      if (f.existsSync()) {
        final dest = p.join(cacheDir.path, tool);
        f.copySync(dest);
        // dartaotruntime is an executable → must be (ad-hoc) signed on macOS.
        if (tool == 'dartaotruntime') {
          await Process.run('codesign', ['-f', '-s', '-', dest]);
        }
      }
    }

    // Overlay the merge-loader platform into the Flutter SDK's patched-sdk(s)
    // so flutter build's frontend_server knows the interpreter natives
    // (loadDynamicModulePatch) when compiling an --interpreter bootstrapper.
    // Additive (the merge-loader platform is a superset of the stock one).
    final mlPlatform = File(p.join(src, 'platform_strong.dill'));
    if (mlPlatform.existsSync()) {
      for (final sdk in ['flutter_patched_sdk', 'flutter_patched_sdk_product']) {
        final dest = File(
          p.join(
            quickpatchEnv.flutterDirectory.path,
            'bin', 'cache', 'artifacts', 'engine', 'common', sdk,
            'platform_strong.dill',
          ),
        );
        if (dest.parent.existsSync()) {
          if (!File('${dest.path}.qpbak').existsSync() && dest.existsSync()) {
            dest.copySync('${dest.path}.qpbak');
          }
          mlPlatform.copySync(dest.path);
        }
      }
    }

    stamp.writeAsStringSync(engineRevision);
    progress.complete('QuickPatch iOS engine $engineRevision installed');
  } on Exception catch (error) {
    progress.fail('Failed to fetch QuickPatch iOS engine: $error');
    rethrow;
  } finally {
    try {
      tmp.deleteSync(recursive: true);
    } on Exception {
      // best-effort cleanup
    }
  }
}

/// Whether [file] (a Mach-O binary) embeds the [revision] string. The Dart VM
/// snapshot-version hash is compiled into gen_snapshot / analyze_snapshot /
/// Flutter as an ASCII string, so a byte-substring scan reliably distinguishes
/// the QuickPatch engine build from the stock Flutter one that a `flutter
/// precache` may have restored. latin1 maps each byte 1:1 to a code unit, so
/// `contains` on the decoded text is an exact byte-substring search. Best-effort:
/// returns false on any read error (treated as "needs re-install").
@visibleForTesting
bool binaryEmbedsRevision(File file, String revision) {
  try {
    final bytes = file.readAsBytesSync();
    return latin1.decode(bytes, allowInvalid: true).contains(revision);
  } on Object {
    return false;
  }
}

/// Fetches the server's engine-version registry as a `flutterRevision ->
/// engineRevision` map, so a Flutter version built + published after this CLI
/// shipped is still usable (no CLI release needed per version). Best-effort:
/// returns an empty map on any failure (no network, server down, bad JSON), and
/// the caller falls back to [_engineRevisionForFlutterRevision]. Uses `curl`
/// (already required for the engine download) with a short timeout so a slow or
/// unreachable server never stalls a build.
Future<Map<String, String>> _fetchEngineVersionMap() async {
  try {
    final base = quickpatchEnv.hostedUri;
    if (base == null) return const {};
    final url =
        '${base.toString().replaceAll(RegExp(r'/+$'), '')}/api/v1/engine-versions';
    final result = await Process.run('curl', [
      '-fsSL', '--max-time', '10', url,
    ]);
    if (result.exitCode != 0) return const {};
    final decoded = jsonDecode(result.stdout as String);
    if (decoded is! Map<String, dynamic>) return const {};
    final versions = decoded['versions'];
    if (versions is! List) return const {};
    final map = <String, String>{};
    for (final v in versions) {
      if (v is Map<String, dynamic>) {
        final fr = v['flutterRevision'];
        final er = v['engineRevision'];
        if (fr is String && er is String && fr.isNotEmpty && er.isNotEmpty) {
          map[fr] = er;
        }
      }
    }
    return map;
  } on Object {
    // Never let registry resolution break a build — fall back to the constant.
    return const {};
  }
}

/// Ensures the cloned Flutter SDK's `flutter_tools` embeds the patch public
/// key(s) into a QuickPatch project's `quickpatch.yaml` asset. Applies two
/// independent, idempotent fixes to the pinned upstream checkout (which we
/// consume but don't own) at build time:
///
///  1. **Asset guard** — the upstream asset pipeline only injected the
///     build-time public key into its own legacy config filename, not
///     `quickpatch.yaml`. Since QuickPatch projects use `quickpatch.yaml`, the
///     key was never embedded and the on-device updater ran fail-open: UNSIGNED
///     patches applied. Repointed to `quickpatch.yaml`.
///  2. **Rotation-key emit** — the upstream yaml compiler only emitted the
///     single `patch_public_key`. Signing-key rotation needs the comma-separated
///     `patch_public_keys` (from `SHOREBIRD_PUBLIC_KEYS`, forwarded by
///     [ArtifactBuilder.buildEnvironment]) emitted too, so a build can trust a
///     rotated key alongside the primary one. Without this, rotation keys are
///     silently dropped at build time and rotated-key patches fail on device.
///
/// If either fix changes a file, the compiled `flutter_tools` snapshot/stamp is
/// deleted so the change is recompiled on the next `flutter` run (Flutter keys
/// that snapshot on the SDK revision, which is unchanged, so it must be removed
/// to force a rebuild).
void ensureQuickPatchFlutterToolsPatched() {
  final changed = _patchAssetGuard() | _patchRotationKeyEmit();
  if (!changed) return;
  for (final name in const ['flutter_tools.snapshot', 'flutter_tools.stamp']) {
    final f = File(
      p.join(quickpatchEnv.flutterDirectory.path, 'bin', 'cache', name),
    );
    if (f.existsSync()) {
      try {
        f.deleteSync();
      } on FileSystemException {
        // best-effort; a stale snapshot only means the fix lands one run later
      }
    }
  }
}

/// Embeds the patch public key(s) into the project's `quickpatch.yaml` for the
/// duration of a build, so the bundled `flutter_assets/quickpatch.yaml` carries
/// them and the on-device updater can verify patch signatures.
///
/// The fork's `flutter_tools` injected the build-time key into the yaml asset
/// (see [_patchAssetGuard]); **vanilla** Flutter (e.g. stable 3.44.0) has no
/// such mechanism, so without this the bundled config has no key and the native
/// updater runs fail-open (accepts UNSIGNED patches). The public key is not
/// secret, so we write it into `quickpatch.yaml` at build time; the ORIGINAL
/// file is restored afterward via the returned callback (so the developer's
/// checked-in file is untouched). Engine reads `patch_public_key` (primary) +
/// `patch_public_keys` (comma-separated rotation keys) — see the updater's
/// `build_trusted_public_keys`.
///
/// Returns a restore callback; it is a no-op when there is no key, no project,
/// or no `quickpatch.yaml`.
void Function() embedPatchPublicKeysInProjectYaml({
  required String? base64PublicKey,
  List<String> rotationPublicKeys = const [],
}) {
  void noop() {}
  if (base64PublicKey == null || base64PublicKey.isEmpty) return noop;
  final root = quickpatchEnv.getQuickPatchProjectRoot();
  if (root == null) return noop;
  final yaml = File(p.join(root.path, 'quickpatch.yaml'));
  if (!yaml.existsSync()) return noop;
  final original = yaml.readAsStringSync();
  // Drop any pre-existing key line(s), then append this build's key(s).
  final kept = original
      .split('\n')
      .where((l) => !RegExp(r'^\s*patch_public_keys?\s*:').hasMatch(l))
      .join('\n')
      .trimRight();
  final buf = StringBuffer(kept)
    ..write('\npatch_public_key: $base64PublicKey\n');
  final rotation =
      rotationPublicKeys.map((k) => k.trim()).where((k) => k.isNotEmpty).join(',');
  if (rotation.isNotEmpty) buf.write('patch_public_keys: $rotation\n');
  yaml.writeAsStringSync(buf.toString());
  logger.detail('[engine] Embedded patch public key(s) into quickpatch.yaml.');
  return () {
    try {
      yaml.writeAsStringSync(original);
    } on FileSystemException {
      // best-effort restore
    }
  };
}

/// Maps a vanilla Flutter engine commit (as recorded in the checkout's
/// `bin/internal/engine.version`) to the QuickPatch-built Android engine commit
/// that carries the on-device updater. Stable Flutter ships a vanilla engine
/// with no code-push support, so Android code-push must swap in the QuickPatch
/// engine — the Android analog of how iOS reuses the QuickPatch engine bundle.
/// The mapped engine's gen_snapshot is served alongside it, so the built app is
/// snapshot-consistent with the runtime.
const _quickPatchAndroidEngineForVanilla = <String, String>{
  // stable 3.44.0 vanilla engine -> QuickPatch engine (carries the updater).
  '4c525dac5ebe5971c5708ef73558ed8edcf4a362':
      '6500c84eba818b598fb967bd0276e6e50cdd02c9',
};

/// For the duration of an Android build, repoints the Flutter SDK's
/// `bin/internal/engine.version` at the QuickPatch Android engine when the
/// checkout ships a vanilla engine (no updater) — see
/// [_quickPatchAndroidEngineForVanilla]. gradle then resolves the QuickPatch
/// `libflutter` (with the updater) from the mirror and Flutter fetches the
/// matching gen_snapshot, so the app is updater-equipped and snapshot-consistent
/// and OTA patches apply. Returns a restore callback that puts the original
/// `engine.version` back (no-op when no mapping applies).
void Function() ensureQuickPatchAndroidEngine() {
  void noop() {}
  final versionFile = File(
    p.join(quickpatchEnv.flutterDirectory.path, 'bin', 'internal',
        'engine.version'),
  );
  if (!versionFile.existsSync()) return noop;
  final original = versionFile.readAsStringSync();
  final current = original.trim();
  final mapped = _quickPatchAndroidEngineForVanilla[current];
  if (mapped == null || mapped == current) return noop;
  versionFile.writeAsStringSync(mapped);
  logger.detail(
    '[engine] Android: building against QuickPatch engine $mapped in place of '
    'the vanilla $current (adds the on-device updater for code push).',
  );
  return () {
    try {
      versionFile.writeAsStringSync(original);
    } on FileSystemException {
      // best-effort restore
    }
  };
}

/// Repoints the flutter_tools asset-injection guard at `quickpatch.yaml` so the
/// build-time public key is embedded in QuickPatch projects. Returns whether the
/// file was changed (false if absent, already patched, or not safely matchable).
bool _patchAssetGuard() {
  final assetsTarget = File(
    p.join(
      quickpatchEnv.flutterDirectory.path,
      'packages', 'flutter_tools', 'lib', 'src', 'build_system', 'targets',
      'assets.dart',
    ),
  );
  if (!assetsTarget.existsSync()) return false;
  final source = assetsTarget.readAsStringSync();
  if (source.contains("file.basename == 'quickpatch.yaml'")) {
    return false; // already patched — idempotent
  }
  // Match the upstream fork's asset-injection guard generically — a
  // `file.basename == '<name>.yaml'` test — rather than hard-coding the
  // upstream config filename, so the fix survives the filename changing across
  // Flutter revisions. The replacement points it at QuickPatch's config file.
  final guard = RegExp(r"if \(file\.basename == '\w+\.yaml'\) \{");
  final matches = guard.allMatches(source).length;
  if (matches != 1) {
    // 0 → the asset pipeline changed shape; >1 → the injection site is
    // ambiguous (which guard is the one we want?). Either way do NOT guess on a
    // signing-critical path — surface it rather than risk a fail-open build or
    // patching the wrong line. This is the per-Flutter-revision safety net.
    logger.warn(
      '[engine] Could not apply the QuickPatch patch-signing fix: expected '
      "exactly one config-asset guard in flutter_tools' assets.dart but found "
      '$matches. Patches for this Flutter revision may be built WITHOUT an '
      'embedded public key (unsigned). Please report this so the fix can be '
      'updated for this revision.',
    );
    return false;
  }
  assetsTarget.writeAsStringSync(
    source.replaceFirst(guard, "if (file.basename == 'quickpatch.yaml') {"),
  );
  logger.detail('[engine] Applied QuickPatch patch-signing fix to flutter_tools.');
  return true;
}

/// Injects emission of the comma-separated rotation public keys
/// (`patch_public_keys`) into the flutter_tools yaml compiler, right after the
/// existing single-key emit. Returns whether the file was changed (false if not
/// found, already patched, or not safely matchable).
bool _patchRotationKeyEmit() {
  // Locate the compiler by content, not by path: the file that emits
  // `compiled['patch_public_key']`. This avoids hard-coding the upstream
  // directory name and survives it moving across Flutter revisions.
  final target = _findYamlCompilerFile();
  if (target == null) return false;
  final source = target.readAsStringSync();
  if (source.contains("compiled['patch_public_keys']")) {
    return false; // already patched — idempotent
  }
  // Match the existing single-key emit block generically (any local variable
  // name, any interior whitespace) and append the rotation-key emit after it.
  final emitBlock = RegExp(
    r"final String\?\s+(\w+)\s*=\s*environment\['SHOREBIRD_PUBLIC_KEY'\];\s*"
    r"if \(\1 != null\) \{\s*"
    r"compiled\['patch_public_key'\] = \1;\s*"
    r'\}',
  );
  final matches = emitBlock.allMatches(source).length;
  if (matches != 1) {
    // Same signing-critical safety net as the asset guard: never guess. If we
    // can't find exactly one emit site, leave it and warn — rotation keys are
    // an enhancement, so the build still produces a (single-key) signed patch.
    logger.warn(
      '[engine] Could not enable signing-key rotation: expected exactly one '
      "patch_public_key emit in flutter_tools but found $matches. Rotation keys "
      '(SHOREBIRD_PUBLIC_KEYS) will be ignored for this Flutter revision; the '
      'primary key still signs patches. Please report this so the fix can be '
      'updated for this revision.',
    );
    return false;
  }
  target.writeAsStringSync(
    source.replaceFirstMapped(
      emitBlock,
      (m) =>
          '${m.group(0)}\n'
          '  // Trust additional comma-separated public keys for signing-key\n'
          '  // rotation; a patch verifies if its signature matches the primary\n'
          '  // key or any of these.\n'
          "  final String? quickPatchRotationKeys = environment['SHOREBIRD_PUBLIC_KEYS'];\n"
          '  if (quickPatchRotationKeys != null && quickPatchRotationKeys.isNotEmpty) {\n'
          "    compiled['patch_public_keys'] = quickPatchRotationKeys;\n"
          '  }',
    ),
  );
  logger.detail('[engine] Enabled signing-key rotation in flutter_tools.');
  return true;
}

/// Finds the flutter_tools Dart file that emits `compiled['patch_public_key']`
/// (the yaml compiler), searching by content under `flutter_tools/lib/src`.
/// Returns null if the tools tree or the emit site is absent.
File? _findYamlCompilerFile() {
  final toolsSrc = Directory(
    p.join(
      quickpatchEnv.flutterDirectory.path,
      'packages', 'flutter_tools', 'lib', 'src',
    ),
  );
  if (!toolsSrc.existsSync()) return null;
  for (final entity in toolsSrc.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      try {
        if (entity.readAsStringSync().contains("compiled['patch_public_key']")) {
          return entity;
        }
      } on FileSystemException {
        // unreadable file — skip
      }
    }
  }
  return null;
}

Future<void> _run(
  String exe,
  List<String> args, {
  String? workingDirectory,
}) async {
  final result = await Process.run(exe, args, workingDirectory: workingDirectory);
  if (result.exitCode != 0) {
    throw Exception(
      '$exe ${args.join(' ')} failed (${result.exitCode}): '
      '${result.stdout}${result.stderr}',
    );
  }
}
