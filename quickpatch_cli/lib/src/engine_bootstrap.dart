import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/platform.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';

/// The QuickPatch iOS engine (snapshot) revision pinned to each supported
/// Flutter revision. The on-device VM only loads snapshots whose version hash
/// matches the engine, so a release + its patches + the engine must all share
/// this revision. Extend this map when a new Flutter version is supported.
const _engineRevisionForFlutterRevision = <String, String>{
  // Re-baselined 2026-05-30 from dd03f6ff... to the merge-loader engine, which
  // adds arbitrary-code-push (Dart interpreter / dynamic modules) ON TOP of the
  // data-only instruction-reuse path — a strict superset. Releases + patches
  // built against the old dd03f6ff engine must be rebuilt on this revision.
  '1a55eb72b61a6c8acac0bf7f7d4738f399f83a0f':
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
  final engineRevision =
      platform.environment['QUICKPATCH_ENGINE_REV'] ??
      _engineRevisionForFlutterRevision[flutterRevision];
  if (engineRevision == null) {
    final supported = _engineRevisionForFlutterRevision.keys.join(', ');
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
  if (stamp.existsSync() && stamp.readAsStringSync().trim() == engineRevision) {
    logger.detail('[engine] QuickPatch iOS engine $engineRevision present.');
    return;
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
    File(p.join(tmp.path, 'SHA256SUMS.txt'))
        .copySync(p.join(extract.path, 'SHA256SUMS.txt'));
    await _run('tar', ['-xzf', tarball, '-C', extract.path]);
    // Integrity: SHA256SUMS.txt lists ios-release/* relative paths.
    await _run(
      'shasum',
      ['-a', '256', '-c', 'SHA256SUMS.txt'],
      workingDirectory: extract.path,
    );

    // Overlay the QuickPatch-built files into the Flutter cache.
    final src = p.join(extract.path, 'ios-release');
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

/// Ensures the cloned Flutter SDK's `flutter_tools` embeds the patch public key
/// into a QuickPatch project's `quickpatch.yaml` asset.
///
/// The upstream Flutter fork's asset pipeline only injected the build-time
/// public key into its own legacy config filename, not `quickpatch.yaml`. Since
/// QuickPatch projects use `quickpatch.yaml`, the public key was never embedded
/// and the on-device updater ran fail-open: UNSIGNED patches applied. We consume
/// the Flutter SDK at a pinned upstream revision we don't own, so the fix is
/// applied to the local checkout at build time — idempotently. When it patches,
/// it deletes the compiled `flutter_tools` snapshot so the change is recompiled
/// on the next `flutter` run (Flutter keys that snapshot on the SDK revision,
/// which is unchanged, so it must be removed to force a rebuild).
void ensureQuickPatchFlutterToolsPatched() {
  final assetsTarget = File(
    p.join(
      quickpatchEnv.flutterDirectory.path,
      'packages', 'flutter_tools', 'lib', 'src', 'build_system', 'targets',
      'assets.dart',
    ),
  );
  if (!assetsTarget.existsSync()) return;
  final source = assetsTarget.readAsStringSync();
  if (source.contains("file.basename == 'quickpatch.yaml'")) {
    return; // already patched — idempotent, no snapshot invalidation
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
    return;
  }
  assetsTarget.writeAsStringSync(
    source.replaceFirst(guard, "if (file.basename == 'quickpatch.yaml') {"),
  );
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
  logger.detail('[engine] Applied QuickPatch patch-signing fix to flutter_tools.');
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
