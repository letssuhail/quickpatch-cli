import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:quickpatch_cli/src/archive/archive.dart';
import 'package:quickpatch_cli/src/artifact_builder/artifact_builder.dart';
import 'package:quickpatch_cli/src/artifact_manager.dart';
import 'package:quickpatch_cli/src/code_push_client_wrapper.dart';
import 'package:quickpatch_cli/src/commands/patch/apple_patcher_mixin.dart';
import 'package:quickpatch_cli/src/commands/patch/patcher.dart';
import 'package:quickpatch_cli/src/common_arguments.dart';
import 'package:quickpatch_cli/src/doctor.dart';
import 'package:quickpatch_cli/src/engine_bootstrap.dart';
import 'package:quickpatch_cli/src/executables/executables.dart';
import 'package:quickpatch_cli/src/interpreter/interpreter_build.dart';
import 'package:quickpatch_cli/src/interpreter/interpreter_patcher.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';
import 'package:quickpatch_cli/src/extensions/arg_results.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/platform.dart';
import 'package:quickpatch_cli/src/platform/platform.dart';
import 'package:quickpatch_cli/src/release_type.dart';
import 'package:quickpatch_cli/src/quickpatch_artifacts.dart';
import 'package:quickpatch_cli/src/quickpatch_documentation.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_flutter.dart';
import 'package:quickpatch_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:quickpatch_cli/src/validators/validators.dart';
import 'package:quickpatch_code_push_client/quickpatch_code_push_client.dart';
import 'package:quickpatch_code_push_protocol/quickpatch_code_push_protocol.dart';

/// {@template ios_patcher}
/// Functions to create an iOS patch.
/// {@endtemplate}
class IosPatcher extends Patcher
    with ApplePatcherMixin, ApplePodfileLockPatcherMixin {
  /// {@macro ios_patcher}
  IosPatcher({
    required super.argResults,
    required super.argParser,
    required super.flavor,
    required super.target,
  });

  String get _aotOutputPath =>
      p.join(quickpatchEnv.buildDirectory.path, 'out.aot');

  String get _vmcodeOutputPath =>
      p.join(quickpatchEnv.buildDirectory.path, 'out.vmcode');

  String get _appDillCopyPath =>
      p.join(quickpatchEnv.buildDirectory.path, 'app.dill');

  /// The last build's link percentage.
  @visibleForTesting
  double? lastBuildLinkPercentage;

  /// The last build's link metadata.
  @visibleForTesting
  Json? lastBuildLinkMetadata;

  @override
  double? get linkPercentage => lastBuildLinkPercentage;

  @override
  Json? get linkMetadata => lastBuildLinkMetadata;

  @override
  ReleaseType get releaseType => ReleaseType.ios;

  @override
  String get primaryReleaseArtifactArch => 'xcarchive';

  @override
  String? get supplementaryReleaseArtifactArch => 'ios_supplement';

  @override
  List<Validator> get applePlatformValidators => doctor.iosCommandValidators;

  @override
  String? get localPodfileLockHash => quickpatchEnv.iosPodfileLockHash;

  @override
  String get podfileLockRelativePath => 'ios/Podfile.lock';

  @override
  Future<void> assertArgsAreValid() async {
    // Ensure the prebuilt QuickPatch iOS engine for this Flutter revision is
    // installed (download + verify from the CDN if missing) before we build.
    await ensureQuickPatchIosEngine();

    final exportOptionsPlistFile = argResults.file(
      CommonArguments.exportOptionsPlistArg.name,
    );
    if (exportOptionsPlistFile != null) {
      try {
        assertValidExportOptionsPlist(exportOptionsPlistFile);
      } on InvalidExportOptionsPlistException catch (error) {
        logger.err(error.message);
        throw ProcessExit(ExitCode.usage.code);
      }
    }
  }

  @override
  Future<File> buildPatchArtifact({String? releaseVersion}) async {
    final shouldCodesign = argResults['codesign'] == true;
    final (flutterVersionAndRevision, flutterVersion) = await (
      quickpatchFlutter.getVersionAndRevision(),
      quickpatchFlutter.getVersion(),
    ).wait;

    if ((flutterVersion ?? minimumSupportedIosFlutterVersion) <
        minimumSupportedIosFlutterVersion) {
      logger.err('''
iOS patches are not supported with Flutter versions older than $minimumSupportedIosFlutterVersion.
For more information see: ${supportedFlutterVersionsUrl.toLink()}''');
      throw ProcessExit(ExitCode.software.code);
    }

    final buildArgs = [
      ...argResults.forwardedArgs,
      ...extraBuildArgs,
      ...buildNameAndNumberArgsFromReleaseVersion(releaseVersion),
    ];

    if (interpreterMode) {
      // Match the interpreter release build's ergonomics: use CocoaPods (the
      // verification deps break SPM resolution) and skip icon tree-shaking
      // (ConstFinder crashes on the bootstrapper-style entry).
      await process.run('flutter', [
        'config',
        '--no-enable-swift-package-manager',
      ]);
      if (!buildArgs.contains('--no-tree-shake-icons')) {
        buildArgs.add('--no-tree-shake-icons');
      }
    }

    // If buildIpa is called with a different codesign value than the
    // release was, we will erroneously report native diffs.
    final ipaBuildResult = await artifactBuilder.buildIpa(
      codesign: shouldCodesign,
      flavor: flavor,
      target: target,
      args: buildArgs,
      base64PublicKey: argResults.encodedPublicKey,
    );

    // The interpreter patch builds its own bytecode module in
    // createPatchArtifacts and ignores the AOT diff entirely. The IPA build
    // above is kept only to produce the .xcarchive (release-version + gate),
    // so skip the unused AOT snapshot + kernel copy here.
    if (!interpreterMode) {
      if (splitDebugInfoPath != null) {
        Directory(splitDebugInfoPath!).createSync(recursive: true);
      }
      await artifactBuilder.buildElfAotSnapshot(
        appDillPath: ipaBuildResult.kernelFile.path,
        outFilePath: _aotOutputPath,
        genSnapshotArtifact: QuickPatchArtifact.genSnapshotIos,
        additionalArgs: [
          ...ApplePatcherMixin.splitDebugInfoArgs(splitDebugInfoPath),
          ...obfuscationGenSnapshotArgs,
        ],
      );

      // Copy the kernel file to the build directory so that it can be used
      // to generate a patch.
      ipaBuildResult.kernelFile.copySync(_appDillCopyPath);
    }

    return artifactManager.getXcarchiveDirectory()!.zipToTempFile();
  }

  @override
  Future<Map<Arch, PatchArtifactBundle>> createPatchArtifacts({
    required String appId,
    required int releaseId,
    required File releaseArtifact,
    Directory? supplementDirectory,
  }) async {
    // Verify that we have built a patch .xcarchive
    if (artifactManager.getXcarchiveDirectory()?.path == null) {
      logger.err('Unable to find .xcarchive directory');
      throw ProcessExit(ExitCode.software.code);
    }

    // Interpreter (arbitrary-code-push) path: build a bytecode patch module
    // instead of the data-only AOT diff. Requires the release to have an
    // interpreter (bytecode) base; the on-device merge-loader swaps the
    // changed functions. Bypasses the data-only gate by design.
    if (interpreterMode) {
      return _createInterpreterPatchArtifacts();
    }

    final unzipProgress = logger.progress('Extracting release artifact');

    late final String releaseXcarchivePath;
    {
      final tempDir = Directory.systemTemp.createTempSync();
      await artifactManager.extractZip(
        zipFile: releaseArtifact,
        outputDirectory: tempDir,
      );
      releaseXcarchivePath = tempDir.path;
    }

    final releaseSupplementDir =
        supplementDirectory ?? Directory.systemTemp.createTempSync();

    unzipProgress.complete();
    final appDirectory = artifactManager.getIosAppDirectory(
      xcarchiveDirectory: Directory(releaseXcarchivePath),
    );
    if (appDirectory == null) {
      logger.err('Unable to find release artifact .app directory');
      throw ProcessExit(ExitCode.software.code);
    }
    final releaseArtifactFile = File(
      p.join(appDirectory.path, 'Frameworks', 'App.framework', 'App'),
    );

    final useLinker = AotTools.usesLinker(quickpatchEnv.flutterRevision);
    if (useLinker) {
      apple.copySupplementFilesToSnapshotDirs(
        releaseSupplementDir: releaseSupplementDir,
        releaseSnapshotDir: releaseArtifactFile.parent,
        patchSupplementDir: quickpatchEnv.iosSupplementDirectory,
        patchSnapshotDir: quickpatchEnv.buildDirectory,
      );

      final result = await apple.runLinker(
        kernelFile: File(_appDillCopyPath),
        releaseArtifact: releaseArtifactFile,
        splitDebugInfoArgs: [
          ...ApplePatcherMixin.splitDebugInfoArgs(splitDebugInfoPath),
          ...obfuscationGenSnapshotArgs,
        ],
        aotOutputFile: File(_aotOutputPath),
        vmCodeFile: File(_vmcodeOutputPath),
        ddMaxBytes: int.tryParse(
          platform.environment['SHOREBIRD_PATCH_DD_MAX_BYTES'] ?? '',
        ),
      );
      final linkPercentage = result.linkPercentage;
      final exitCode = result.exitCode;
      if (exitCode != ExitCode.success.code) throw ProcessExit(exitCode);
      if (linkPercentage != null &&
          linkPercentage < Patcher.linkPercentageWarningThreshold) {
        logger.warn(Patcher.lowLinkPercentageWarning(linkPercentage));
      }
      lastBuildLinkPercentage = linkPercentage;
      lastBuildLinkMetadata = result.linkMetadata;
    }

    final patchBuildFile = File(useLinker ? _vmcodeOutputPath : _aotOutputPath);

    final File patchFile;
    // QuickPatch DIRECT_LINK mode: bypass the fork's aot_tools.dill, but STILL
    // produce the same stable diff base the on-device updater patches against.
    // Our clean-room `analyze_snapshot --dump_blobs` writes the four base
    // snapshot blobs (vm_data ++ isolate_data ++ vm_instructions ++
    // isolate_instructions) in the exact order/sizes the device's
    // SnapshotsDataHandle reads (shell/common/shorebird/snapshots_data_handle).
    // Diffing against THAT — not the raw App Mach-O — is what makes the
    // on-device bipatch reconstruct correctly (fixes the base_size mismatch).
    // QuickPatch iOS reuse linker is the default; QUICKPATCH_DIRECT_LINK=0 opts
    // out to the (fork) aot_tools diff-base path.
    final directLink = platform.environment['QUICKPATCH_DIRECT_LINK'] != '0';
    if (directLink && useLinker) {
      // Safety: a patch must be built with the SAME QuickPatch engine
      // (snapshot revision) as the release it targets — the "freeze ONE
      // toolchain" rule — or the on-device VM rejects it at load. Block early.
      _assertEngineRevisionMatches(
        releaseArtifact: releaseArtifactFile,
        patchArtifact: patchBuildFile,
      );

      // Safety: on iOS the patch reuses the signed base instructions, so a
      // patch that changes CODE would silently run stale base code. Block it.
      _assertDataOnlyPatch(releaseArtifact: releaseArtifactFile);

      final patchBaseFile = await _generateDirectLinkDiffBase(
        releaseArtifact: releaseArtifactFile,
      );
      patchFile = File(
        await artifactManager.createDiff(
          releaseArtifactPath: patchBaseFile.path,
          patchArtifactPath: patchBuildFile.path,
        ),
      );
    } else if (useLinker && await aotTools.isGeneratePatchDiffBaseSupported()) {
      final patchBaseProgress = logger.progress('Generating patch diff base');
      final analyzeSnapshotPath = quickpatchArtifacts.getArtifactPath(
        artifact: QuickPatchArtifact.analyzeSnapshotIos,
      );

      final File patchBaseFile;
      try {
        // If the aot_tools executable supports the dump_blobs command, we
        // can generate a stable diff base and use that to create a patch.
        patchBaseFile = await aotTools.generatePatchDiffBase(
          analyzeSnapshotPath: analyzeSnapshotPath,
          releaseSnapshot: releaseArtifactFile,
        );
        patchBaseProgress.complete();
      } on Exception catch (error) {
        patchBaseProgress.fail('$error');
        throw ProcessExit(ExitCode.software.code);
      }

      patchFile = File(
        await artifactManager.createDiff(
          releaseArtifactPath: patchBaseFile.path,
          patchArtifactPath: patchBuildFile.path,
        ),
      );
    } else {
      patchFile = patchBuildFile;
    }

    final patchFileSize = patchFile.statSync().size;
    final hash = sha256.convert(patchBuildFile.readAsBytesSync()).toString();
    final hashSignature = await signHash(hash);

    return {
      Arch.arm64: PatchArtifactBundle(
        arch: 'aarch64',
        path: patchFile.path,
        hash: hash,
        size: patchFileSize,
        hashSignature: hashSignature,
        podfileLockHash: quickpatchEnv.iosPodfileLockHash,
      ),
    };
  }

  /// Engine-revision (snapshot hash) embedded in an AOT snapshot/App binary,
  /// or null if not found. The 32-hex run directly precedes "product " in the
  /// snapshot's version+features string and uniquely identifies the QuickPatch
  /// engine/toolchain the artifact was built with.
  String? _readEngineRevision(File f) {
    if (!f.existsSync()) return null;
    final match = RegExp(r'([0-9a-f]{32})product ')
        .firstMatch(String.fromCharCodes(f.readAsBytesSync()));
    return match?.group(1);
  }

  /// Enforcement of the "freeze ONE toolchain" rule: the patch's engine
  /// revision must match the release's. A patch built with a different engine
  /// embeds a different snapshot version, which the on-device VM rejects at
  /// load (fail-open revert) — so we block it at publish time with a clear
  /// ENGINE_MISMATCH error instead of shipping a patch that can never apply.
  void _assertEngineRevisionMatches({
    required File releaseArtifact,
    required File patchArtifact,
  }) {
    final releaseRev = _readEngineRevision(releaseArtifact);
    final patchRev = _readEngineRevision(patchArtifact);
    if (releaseRev == null || patchRev == null) {
      logger.warn(
        'Cannot verify engine revision (release: $releaseRev, patch: '
        '$patchRev). Proceeding without the check.',
      );
      return;
    }
    if (releaseRev == patchRev) {
      logger.detail('[linker] engine revision matches release ($releaseRev).');
      return;
    }
    logger.err('''
ENGINE_MISMATCH: this patch was built with a different QuickPatch engine than
the release it targets.
  release engine revision: $releaseRev
  patch engine revision:   $patchRev
A patch must be built with the SAME engine/toolchain as its release, or the
device will reject it at load. Rebuild the patch with the toolchain that
produced this release (QuickPatch freezes one engine per release).''');
    throw ProcessExit(ExitCode.software.code);
  }

  /// Safety gate for iOS instruction reuse. The patch reuses the signed base
  /// app's instructions (Apple forbids executing new native code at runtime),
  /// so a patch that changes compiled CODE would silently run stale base code
  /// on device. We detect this by comparing the patch's Function-Instruction
  /// Map (emitted by the linker as `out.dd_identity.link`) against the base
  /// release's (`App.dd_identity.link`, copied next to the release snapshot).
  /// Identical maps ⇒ instructions unchanged ⇒ a safe data-only patch.
  void _assertDataOnlyPatch({required File releaseArtifact}) {
    final baseFim = File(
      p.join(releaseArtifact.parent.path, 'App.dd_identity.link'),
    );
    final patchFim = File(
      p.join(quickpatchEnv.buildDirectory.path, 'out.dd_identity.link'),
    );

    if (!baseFim.existsSync() || !patchFim.existsSync()) {
      logger.warn(
        'Cannot verify iOS code-change safety: instruction map missing '
        '(base: ${baseFim.existsSync()}, patch: ${patchFim.existsSync()}). '
        'Proceeding without the check.',
      );
      return;
    }

    final baseHash = sha256.convert(baseFim.readAsBytesSync()).toString();
    final patchHash = sha256.convert(patchFim.readAsBytesSync()).toString();
    if (baseHash == patchHash) {
      logger.detail(
        '[linker] instruction map matches base — data-only patch (safe).',
      );
      return;
    }

    const message = '''
This patch changes compiled CODE, not just data/config.

On iOS a patch reuses the signed base app's instructions — Apple forbids
executing new native code at runtime — so changed code will NOT take effect on
device (the original code keeps running for changed functions). Only
data/const/string/config changes are supported on iOS today.

If you intended a data-only change, the difference is likely from a non-data
edit (new/removed/reordered code or dependencies). Revert it and re-run.''';

    final allowOverride =
        platform.environment['QUICKPATCH_ALLOW_CODE_CHANGE'] == '1';
    if (allowOverride) {
      logger.warn(
        '$message\n\nQUICKPATCH_ALLOW_CODE_CHANGE=1 is set — publishing anyway. '
        'The code change will NOT apply on device.',
      );
      return;
    }
    logger.err(message);
    throw ProcessExit(ExitCode.software.code);
  }

  /// DIRECT_LINK diff base: extract the base snapshot blobs from the release
  /// App binary using our clean-room `analyze_snapshot --dump_blobs`, producing
  /// the exact byte stream the on-device base reader patches against.
  ///
  /// The App.framework/App is usually a fat (universal) Mach-O, whose
  /// `0xcafebabe` header our analyze_snapshot's magic sniffer doesn't recognize
  /// (it expects a thin Mach-O), so we thin the arm64 slice first via `lipo`.
  Future<File> _generateDirectLinkDiffBase({required File releaseArtifact}) async {
    final progress = logger.progress('Generating patch diff base (dump_blobs)');
    final tmpDir = Directory.systemTemp.createTempSync('qp_diff_base');
    final analyzeSnapshotPath = quickpatchArtifacts.getArtifactPath(
      artifact: QuickPatchArtifact.analyzeSnapshotIos,
    );

    // Thin to the arm64 slice if the App is a fat binary. `lipo -thin` fails on
    // an already-thin binary, so fall back to the original path in that case.
    var snapshotInput = releaseArtifact.path;
    final thinPath = p.join(tmpDir.path, 'App.thin.arm64');
    final lipo = await Process.run('lipo', [
      '-thin',
      'arm64',
      releaseArtifact.path,
      '-output',
      thinPath,
    ]);
    if (lipo.exitCode == 0 && File(thinPath).existsSync()) {
      snapshotInput = thinPath;
    }

    final outFile = File(p.join(tmpDir.path, 'diff_base'));
    final result = await Process.run(analyzeSnapshotPath, [
      '--dump_blobs',
      '--out=${outFile.path}',
      snapshotInput,
    ]);
    if (result.exitCode != 0 || !outFile.existsSync()) {
      progress.fail(
        'analyze_snapshot --dump_blobs failed (exit ${result.exitCode}): '
        '${result.stderr}',
      );
      throw ProcessExit(ExitCode.software.code);
    }
    progress.complete(
      'Generated patch diff base (${outFile.statSync().size} bytes)',
    );
    return outFile;
  }

  /// Builds an iOS arbitrary-code-push patch via the Dart interpreter (dynamic
  /// modules): compiles the changed app entry to an UNPREFIXED bytecode module
  /// against a freshly-generated framework import-dill. The on-device
  /// same-URI merge-loader swaps the changed functions onto the live app.
  /// Bypasses the data-only gate — this IS a code change, shipped as bytecode.
  ///
  /// EXPERIMENTAL (--interpreter). Requires the release to have been built with
  /// an interpreter (bytecode) base and the merge-loader engine
  /// (QuickPatch engine >= 76ba1f79...). The toolchain ships in the iOS bundle.
  Future<Map<Arch, PatchArtifactBundle>>
  _createInterpreterPatchArtifacts() async {
    final progress = logger.progress('Building interpreter (bytecode) patch');
    final buildDir = quickpatchEnv.buildDirectory.path;

    String tool(QuickPatchArtifact a) =>
        quickpatchArtifacts.getArtifactPath(artifact: a);
    final aotRuntime = tool(QuickPatchArtifact.dartAotRuntimeIos);
    final dart2bytecode = tool(QuickPatchArtifact.dart2bytecodeIos);
    final genKernel = tool(QuickPatchArtifact.genKernelIos);
    final platformDill = tool(QuickPatchArtifact.flutterPlatformDillIos);
    for (final f in [aotRuntime, dart2bytecode, genKernel, platformDill]) {
      if (!File(f).existsSync()) {
        progress.fail(
          'Interpreter toolchain not installed ($f). This requires the '
          'merge-loader QuickPatch engine — update the engine and retry.',
        );
        throw ProcessExit(ExitCode.software.code);
      }
    }

    final packageConfig = p.join(
      Directory.current.path,
      '.dart_tool',
      'package_config.json',
    );
    final entry = p.join(Directory.current.path, target ?? p.join('lib', 'main.dart'));

    // 1. Generate a bootstrapper + its no-link import-dill (supplies the
    //    framework so the patch module REFERENCES it, unprefixed).
    File(p.join(buildDir, 'qp_bootstrap_main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        InterpreterBuild.generateBootstrapperMain(),
      );
    final importDill = p.join(buildDir, 'qp_bootstrap_import.dill');
    final genKernelResult = await process.run(
      aotRuntime,
      InterpreterBuild.genKernelArgs(
        genKernelSnapshot: genKernel,
        platformDill: platformDill,
        packageConfig: packageConfig,
        entry: p.join(buildDir, 'qp_bootstrap_main.dart'),
        output: importDill,
        noLinkPlatform: true,
        product: true,
      ),
    );
    if (genKernelResult.exitCode != 0) {
      progress.fail('gen_kernel (bootstrapper) failed: ${genKernelResult.stderr}');
      throw ProcessExit(ExitCode.software.code);
    }

    // 2. Compile the changed app entry → UNPREFIXED bytecode patch.
    final patcher = InterpreterPatcher(
      process: process,
      aotRuntimePath: aotRuntime,
      dart2bytecodeSnapshotPath: dart2bytecode,
      platformDillPath: platformDill,
    );
    final File patchFile;
    try {
      patchFile = await patcher.buildBytecodePatch(
        packageConfigPath: packageConfig,
        importDillPath: importDill,
        entry: entry,
        outputPath: p.join(buildDir, 'out.qppatch'),
      );
    } on InterpreterPatchException catch (e) {
      progress.fail(e.message);
      throw ProcessExit(ExitCode.software.code);
    }

    final size = patchFile.statSync().size;
    final hash = sha256.convert(patchFile.readAsBytesSync()).toString();
    final hashSignature = await signHash(hash);
    progress.complete('Interpreter patch built ($size bytes)');
    return {
      Arch.arm64: PatchArtifactBundle(
        arch: 'aarch64',
        path: patchFile.path,
        hash: hash,
        size: size,
        hashSignature: hashSignature,
        podfileLockHash: quickpatchEnv.iosPodfileLockHash,
      ),
    };
  }

  @override
  Future<String> extractReleaseVersionFromArtifact(File artifact) async {
    final archivePath = artifactManager.getXcarchiveDirectory()?.path;
    if (archivePath == null) {
      logger.err('Unable to find .xcarchive directory');
      throw ProcessExit(ExitCode.software.code);
    }

    final plistFile = File(p.join(archivePath, 'Info.plist'));
    if (!plistFile.existsSync()) {
      logger.err('No Info.plist file found at ${plistFile.path}.');
      throw ProcessExit(ExitCode.software.code);
    }

    final plist = Plist(file: plistFile);
    try {
      return plist.versionNumber;
    } on Exception catch (error) {
      logger.err(
        'Failed to determine release version from ${plistFile.path}: $error',
      );
      throw ProcessExit(ExitCode.software.code);
    }
  }
}
