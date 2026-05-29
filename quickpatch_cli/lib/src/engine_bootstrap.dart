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
  '1a55eb72b61a6c8acac0bf7f7d4738f399f83a0f':
      'dd03f6ff5f94f8a3fca41f85e66ad225',
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
    logger.detail(
      '[engine] No pinned QuickPatch engine for Flutter $flutterRevision; '
      'using the existing cache as-is.',
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
