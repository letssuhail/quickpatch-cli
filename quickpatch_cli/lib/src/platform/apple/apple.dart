import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/archive/directory_archive.dart';
import 'package:quickpatch_cli/src/commands/patch/patcher.dart';
import 'package:quickpatch_cli/src/executables/aot_tools.dart';
import 'package:quickpatch_cli/src/logging/quickpatch_logger.dart';
import 'package:quickpatch_cli/src/platform.dart';
import 'package:quickpatch_cli/src/platform/apple/apple_platform.dart';
import 'package:quickpatch_cli/src/platform/apple/link_result.dart';
import 'package:quickpatch_cli/src/platform/apple/missing_xcode_project_exception.dart';
import 'package:quickpatch_cli/src/quickpatch_artifacts.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:xml/xml.dart';

export 'apple_platform.dart';
export 'export_method.dart';
export 'invalid_export_options_plist_exception.dart';
export 'link_result.dart';
export 'macho.dart';
export 'missing_xcode_project_exception.dart';
export 'plist.dart';

/// A reference to a [Apple] instance.
final appleRef = create(Apple.new);

/// The [Apple] instance available in the current zone.
Apple get apple => read(appleRef);

/// A class that provides information about the iOS platform.
class Apple {
  /// Copies the supplement files into the build directory.
  /// Currently we run gen_snapshot from `flutter`, both for the release and
  /// patch builds. Both times it produces supplement files in a directory.
  /// In the release case, these files are zipped up and stored as an artifact
  /// on our servers for later use. In the patch case, they were created on
  /// disk just before this call by XCode calling flutter calling gen_snapshot.
  /// In both cases we need to copy the supplement files from these directories
  /// to right next to where the snapshot files are before calling into
  /// `aot_tools` to link the two snapshots together.
  // TODO(eseidel): We should pass the entire supplement directories to
  // `aot_tools` rather than having to know the contents within `quickpatch`.
  void copySupplementFilesToSnapshotDirs({
    required Directory releaseSupplementDir,
    required Directory releaseSnapshotDir,
    required Directory patchSupplementDir,
    required Directory patchSnapshotDir,
  }) {
    // All known supplement files names seen across all Flutter versions.
    final supplementFileNames = <String>[
      'App.ct.link',
      'App.class_table.json',
      'App.ft.link',
      'App.field_table.json',
      'App.dt.link',
      'App.dispatch_table.json',
      // DD table files for cascade limiter (produced by 2-pass release build).
      'App.dd.link',
      'App.dd_callers.link',
      // QuickPatch Function-Instruction Map (base release's per-function
      // instruction content hashes + offsets). Copied next to the release
      // snapshot so the patcher can detect instruction (code) changes on iOS.
      'App.dd_identity.link',
      // Per-slot DD resolution outcome diagnostic (TSV).
      'App.dd_resolution.tsv',
    ];

    // This uses maybeCopy because not all versions of gen_snapshot/aot_tools
    // use the same supplement files. At the `quickpatch` level we don't know
    // which files should be present, so we just try to copy all.
    void maybeCopy(File file, Directory destDir, {String? newBaseName}) {
      logger.detail('Copying supplement file ${file.path} to ${destDir.path}');
      if (!file.existsSync()) {
        logger.detail('Unable to find supplement file at ${file.path}');
        return;
      }
      final baseName = p.basename(file.path);
      final destName = newBaseName != null
          ? baseName.replaceFirst('App', newBaseName)
          : baseName;
      file.copySync(p.join(destDir.path, destName));
    }

    final releaseSupplementFiles = supplementFileNames.map(
      (name) => File(p.join(releaseSupplementDir.path, name)),
    );
    for (final file in releaseSupplementFiles) {
      maybeCopy(file, releaseSnapshotDir);
    }

    final patchSupplementFiles = supplementFileNames.map(
      (name) => File(p.join(patchSupplementDir.path, name)),
    );
    const patchSnapshotBaseName = 'out';
    for (final file in patchSupplementFiles) {
      maybeCopy(file, patchSnapshotDir, newBaseName: patchSnapshotBaseName);
    }
  }

  /// Returns the set of flavors for the Xcode project associated with
  /// [platform], if this project has that platform configured.
  Set<String>? flavors({required ApplePlatform platform}) {
    final projectRoot = quickpatchEnv.getFlutterProjectRoot()!;
    // Ideally, we would use `xcodebuild -list` to detect schemes/flavors.
    // Unfortunately, many projects contain schemes that are not flavors, and we
    // don't want to create flavors for these schemes. See
    // https://github.com/letssuhail/quickpatch/issues/1703 for an example.
    // Instead, we look in `[platform]/Runner.xcodeproj/xcshareddata/xcschemes`
    // for xcscheme files (which seem to be 1-to-1 with schemes in Xcode) and
    // filter out schemes that are marked as "wasCreatedForAppExtension".
    final platformDirName = switch (platform) {
      ApplePlatform.ios => 'ios',
      ApplePlatform.macos => 'macos',
    };
    final platformDir = Directory(p.join(projectRoot.path, platformDirName));
    if (!platformDir.existsSync()) {
      return null;
    }

    final xcodeProjDirectory = platformDir
        .listSync()
        .whereType<Directory>()
        .firstWhereOrNull((d) => p.extension(d.path) == '.xcodeproj');
    if (xcodeProjDirectory == null) {
      throw MissingXcodeProjectException(
        platformFolderPath: platformDir.path,
        platform: platform,
      );
    }

    final xcschemesDir = Directory(
      p.join(xcodeProjDirectory.path, 'xcshareddata', 'xcschemes'),
    );
    if (!xcschemesDir.existsSync()) {
      throw Exception('Unable to detect schemes in $xcschemesDir');
    }

    return xcschemesDir
        .listSync()
        .whereType<File>()
        .where((e) => p.extension(e.path) == '.xcscheme')
        .where((e) => p.basenameWithoutExtension(e.path) != 'Runner')
        .whereNot((e) => _isExtensionScheme(schemeFile: e))
        .map((file) => p.basenameWithoutExtension(file.path).toLowerCase())
        .toSet();
  }

  // TODO(eseidel): Move this into a "linker" class rather than Apple.
  /// Runs the linking step to minimize differences between patch and release
  /// and maximize code that can be executed on the CPU.
  Future<LinkResult> runLinker({
    required File kernelFile,
    required File releaseArtifact,
    required List<String> splitDebugInfoArgs,
    required File aotOutputFile,
    required File vmCodeFile,
    int? ddMaxBytes,
  }) async {
    final patch = aotOutputFile;
    final buildDirectory = quickpatchEnv.buildDirectory;

    if (!patch.existsSync()) {
      logger.err('Unable to find patch AOT file at ${patch.path}');
      return const LinkResult.failure();
    }

    final analyzeSnapshot = File(
      quickpatchArtifacts.getArtifactPath(
        artifact: QuickPatchArtifact.analyzeSnapshotIos,
      ),
    );

    if (!analyzeSnapshot.existsSync()) {
      logger.err('Unable to find analyze_snapshot at ${analyzeSnapshot.path}');
      return const LinkResult.failure();
    }

    // The IPA build uses the engine's stock gen_snapshot (which has the fork's
    // --print_*_link_info_to writers). The LINK step needs a gen_snapshot with
    // our --read_class_table_link_info_from reader. These are different binaries,
    // so allow overriding only the linker's gen_snapshot via env, leaving the
    // build's untouched.
    final linkerGenSnapshotOverride =
        platform.environment['QUICKPATCH_LINKER_GEN_SNAPSHOT'];
    final usingQuickPatchLinker = linkerGenSnapshotOverride != null;
    final genSnapshot = linkerGenSnapshotOverride ??
        quickpatchArtifacts.getArtifactPath(
          artifact: QuickPatchArtifact.genSnapshotIos,
        );

    final linkProgress = logger.progress('Linking AOT files');
    double? linkPercentage;
    final dumpDebugInfoDir = await aotTools.isLinkDebugInfoSupported()
        ? Directory.systemTemp.createTempSync()
        : null;

    Future<void> dumpDebugInfo() async {
      if (dumpDebugInfoDir == null) return;

      // Copy snapshots into the debug dump for offline diagnosis.
      // 1 release snapshot + up to 5 patch compilation stages:
      //   - out.aot:                 initial patch gen_snapshot output
      //   - out.ct.aot:              CT-sorted intermediate
      //   - out.preDdOptimized.aot:  CT + OP sort, no DD activation (voted on)
      //   - out.ddOnly.aot:          CT + DD activation, no OP sort
      //                              (source of the patch op.link consumed
      //                               by the final pass's VM linker)
      //   - out.optimized.aot:       final CT + OP sort + DD activation
      final snapshotsDir = Directory(p.join(dumpDebugInfoDir.path, 'snapshots'))
        ..createSync(recursive: true);
      void maybeCopySnapshot(File file, {String? destName}) {
        if (file.existsSync()) {
          file.copySync(
            p.join(snapshotsDir.path, destName ?? p.basename(file.path)),
          );
        }
      }

      maybeCopySnapshot(releaseArtifact, destName: 'App');
      maybeCopySnapshot(aotOutputFile);
      // Intermediate snapshots created by aot_tools during linking.
      final patchDir = aotOutputFile.parent.path;
      final patchBaseName = p.basenameWithoutExtension(aotOutputFile.path);
      maybeCopySnapshot(
        File(p.join(patchDir, '$patchBaseName.ct.aot')),
      );
      maybeCopySnapshot(
        File(p.join(patchDir, '$patchBaseName.preDdOptimized.aot')),
      );
      maybeCopySnapshot(
        File(p.join(patchDir, '$patchBaseName.ddOnly.aot')),
      );
      maybeCopySnapshot(
        File(p.join(patchDir, '$patchBaseName.optimized.aot')),
      );

      final debugInfoZip = await dumpDebugInfoDir.zipToTempFile();
      debugInfoZip.copySync(p.join('build', Patcher.debugInfoFile.path));
      logger.detail('Link debug info saved to ${Patcher.debugInfoFile.path}');

      // If we're running on codemagic, export the patch-debug.zip artifact.
      // https://docs.codemagic.io/knowledge-others/upload-custom-artifacts
      final codemagicExportDir = platform.environment['CM_EXPORT_DIR'];
      if (codemagicExportDir != null) {
        logger.detail(
          '''Codemagic environment detected. Exporting ${Patcher.debugInfoFile.path} to $codemagicExportDir''',
        );
        try {
          debugInfoZip.copySync(
            p.join(codemagicExportDir, p.basename(Patcher.debugInfoFile.path)),
          );
        } on Exception catch (error) {
          logger.detail('''
Failed to export ${Patcher.debugInfoFile.path} to $codemagicExportDir.
$error''');
        }
      }
    }

    // QuickPatch iOS linker extras — ONLY when our clean-room linker
    // gen_snapshot is in use (QUICKPATCH_LINKER_GEN_SNAPSHOT set). The stock
    // fork pipeline must not receive these flags: the fork's aot_tools.dill does
    // not understand --base-link-info / --snapshot-version and aborts on them.
    String? baseLinkInfo;
    String? snapshotVersion;
    String? kernelForLink;
    if (usingQuickPatchLinker) {
      // The base release's class-table link file sits next to the release
      // snapshot (copied by copySupplementFilesToSnapshotDirs). Passing it pins
      // patch class IDs to the base. The snapshot version embedded in the base
      // is forced onto the patch so the on-device VM accepts it.
      final baseCtLink = File(
        p.join(releaseArtifact.parent.path, 'App.ct.link'),
      );
      baseLinkInfo = baseCtLink.existsSync() ? baseCtLink.path : null;
      snapshotVersion = _readSnapshotVersion(releaseArtifact);
      if (baseLinkInfo != null) {
        logger.detail('[linker] Using base class-table link: $baseLinkInfo');
      }
      if (snapshotVersion != null) {
        logger.detail('[linker] Forcing snapshot version: $snapshotVersion');
      }

      // Our clean-room gen_snapshot is built from PUBLIC Dart and cannot read
      // kernel produced by the private fork frontend. Point the linker at a
      // public-frontend-compiled dill of the same sources via
      // QUICKPATCH_PUBLIC_DILL when provided.
      final publicDill = platform.environment['QUICKPATCH_PUBLIC_DILL'];
      if (publicDill != null && File(publicDill).existsSync()) {
        kernelForLink = publicDill;
        logger.detail('[linker] Using public-frontend kernel: $kernelForLink');
      }
    }
    kernelForLink ??= kernelFile.path;

    // QuickPatch direct-link mode (QUICKPATCH_DIRECT_LINK=1): bypass aot_tools
    // entirely. Our self-hosted gen_snapshot writes a raw ELF that the on-device
    // updater can load directly (our Shorebird_ReadLinkHeader shim returns 0 =
    // no Shorebird header prefix, so Dart_LoadELF reads from byte 0). This
    // unblocks patches without depending on the fork's aot_tools.dill, which
    // doesn't run on our public-dart-3.12 dartaotruntime.
    final directLink = platform.environment['QUICKPATCH_DIRECT_LINK'] == '1';
    if (directLink) {
      if (baseLinkInfo == null) {
        linkProgress.fail(
          'QUICKPATCH_DIRECT_LINK=1 but no App.ct.link found next to release. '
          'Make sure the release was cut with our toolchain so .link files '
          'were emitted alongside App.framework/App.',
        );
        return const LinkResult.failure();
      }
      try {
        logger.detail(
          '[linker] direct mode: invoking $genSnapshot with '
          '--read_class_table_link_info_from=$baseLinkInfo on $kernelForLink '
          '-> ${vmCodeFile.path}',
        );
        // Emit the patch's Function-Instruction Map so the patcher can compare
        // it byte-for-byte against the base release's map and detect whether the
        // patch changes any INSTRUCTIONS (vs. data-only). On iOS the patch
        // reuses the signed base instructions, so a code change would silently
        // run stale base code — the patcher blocks such patches.
        final patchFimPath =
            p.join(buildDirectory.path, 'out.dd_identity.link');
        final result = await Process.run(genSnapshot, [
          '--deterministic',
          '--read_class_table_link_info_from=$baseLinkInfo',
          '--print_dd_function_identity_to=$patchFimPath',
          '--snapshot_kind=app-aot-elf',
          '--elf=${vmCodeFile.path}',
          '--strip',
          kernelForLink,
        ], workingDirectory: buildDirectory.path);
        if (result.exitCode != 0) {
          linkProgress.fail(
            'Direct link gen_snapshot failed (exit ${result.exitCode}): '
            '${result.stderr}',
          );
          return const LinkResult.failure();
        }
        // Print the QuickPatch: pinned ... line that gen_snapshot emitted to
        // stdout so the user sees the pin count.
        final pinned = (result.stdout as String)
            .split('\n')
            .firstWhere((l) => l.contains('QuickPatch: pinned'),
                orElse: () => '');
        if (pinned.isNotEmpty) logger.detail('[linker] $pinned');
        linkProgress.complete('Linked AOT files (direct mode)');
        // Direct mode can't easily compute link percentage; leave null.
      } on Exception catch (error) {
        linkProgress.fail('Direct link failed: $error');
        return const LinkResult.failure();
      }
      return const LinkResult.success(linkPercentage: null);
    }

    try {
      linkPercentage = await aotTools.link(
        base: releaseArtifact.path,
        patch: patch.path,
        analyzeSnapshot: analyzeSnapshot.path,
        genSnapshot: genSnapshot,
        outputPath: vmCodeFile.path,
        workingDirectory: buildDirectory.path,
        kernel: kernelForLink,
        dumpDebugInfoPath: dumpDebugInfoDir?.path,
        ddMaxBytes: ddMaxBytes,
        baseLinkInfo: baseLinkInfo,
        snapshotVersion: snapshotVersion,
        additionalArgs: splitDebugInfoArgs,
      );
    } on Exception catch (error) {
      linkProgress.fail('Failed to link AOT files: $error');
      return const LinkResult.failure();
    } finally {
      await dumpDebugInfo();
    }
    Map<String, dynamic>? linkMetadata;
    try {
      if (dumpDebugInfoDir != null) {
        linkMetadata = await aotTools.getLinkMetadata(
          debugDir: dumpDebugInfoDir.path,
          workingDirectory: buildDirectory.path,
        );
      }
    } on Exception catch (error) {
      logger.detail('[aot_tools] Failed to get link metadata: $error');
    }

    linkProgress.complete();
    return LinkResult.success(
      linkPercentage: linkPercentage,
      linkMetadata: linkMetadata,
    );
  }

  /// Reads the Dart snapshot version embedded in a release snapshot.
  ///
  /// The VM embeds the version as a 32-hex-char string immediately followed by
  /// the features string (which begins with "product " in release builds), e.g.
  /// `7d8fb82a698d78184f7d1e3bbc00540aproduct no-code_comments ...`. The patch
  /// gen_snapshot is told to embed this same version so the on-device VM (built
  /// from a different engine fork) accepts the patch. Returns null if not found.
  String? _readSnapshotVersion(File snapshot) {
    if (!snapshot.existsSync()) return null;
    final bytes = snapshot.readAsBytesSync();
    // Match a 32-char lowercase-hex run directly followed by "product ".
    final pattern = RegExp(r'([0-9a-f]{32})product ');
    final match = pattern.firstMatch(String.fromCharCodes(bytes));
    return match?.group(1);
  }

  /// Parses the .xcscheme file to determine if it was created for an app
  /// extension. We don't want to include these schemes as app flavors.
  ///
  /// xcschemes are XML files that contain metadata about the scheme, including
  /// whether it was created for an app extension. The top-level Scheme element
  /// has an optional attribute named `wasCreatedForAppExtension`.
  bool _isExtensionScheme({required File schemeFile}) {
    final xmlDocument = XmlDocument.parse(schemeFile.readAsStringSync());
    return xmlDocument.childElements
        .firstWhere((element) => element.name.local == 'Scheme')
        .attributes
        .any(
          (e) => e.localName == 'wasCreatedForAppExtension' && e.value == 'YES',
        );
  }
}
