import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:platform/platform.dart';
import 'package:quickpatch_cli/src/archive/archive.dart';
import 'package:quickpatch_cli/src/artifact_builder/artifact_builder.dart';
import 'package:quickpatch_cli/src/artifact_manager.dart';
import 'package:quickpatch_cli/src/code_push_client_wrapper.dart';
import 'package:quickpatch_cli/src/commands/release/releaser.dart';
import 'package:quickpatch_cli/src/doctor.dart';
import 'package:quickpatch_cli/src/executables/executables.dart';
import 'package:quickpatch_cli/src/extensions/arg_results.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/platform/platform.dart';
import 'package:quickpatch_cli/src/release_type.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_validator.dart';
import 'package:quickpatch_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:quickpatch_code_push_client/quickpatch_code_push_client.dart';

/// {@template windows_releaser}
/// Functions to create a Windows release.
/// {@endtemplate}
class WindowsReleaser extends Releaser {
  /// {@macro windows_releaser}
  WindowsReleaser({
    required super.argResults,
    required super.flavor,
    required super.target,
  });

  @override
  ReleaseType get releaseType => ReleaseType.windows;

  @override
  String get supplementPlatformSubdir => 'windows';

  @override
  String get supplementArtifactArch => 'windows_supplement';

  @override
  String get artifactDisplayName => 'Windows app';

  @override
  Future<void> assertArgsAreValid() async {
    if (argResults.wasParsed('release-version')) {
      logger.err(
        '''
The "--release-version" flag is only supported for aar and ios-framework releases.

To change the version of this release, change your app's version in your pubspec.yaml.''',
      );
      throw ProcessExit(ExitCode.usage.code);
    }

    await assertObfuscationIsSupported();
  }

  @override
  Version? get minimumFlutterVersion => minimumSupportedWindowsFlutterVersion;

  @override
  Future<void> assertPreconditions() async {
    try {
      await quickpatchValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
        checkQuickPatchInitialized: true,
        validators: doctor.windowsCommandValidators,
        supportedOperatingSystems: {Platform.windows},
      );
    } on PreconditionFailedException catch (e) {
      throw ProcessExit(e.exitCode.code);
    }
  }

  @override
  Future<FileSystemEntity> buildReleaseArtifacts() async {
    final base64PublicKey = await getEncodedPublicKey();
    final buildArgs = [...argResults.forwardedArgs];
    addSplitDebugInfoDefault(buildArgs);
    await addObfuscationMapArgs(buildArgs);
    final result = await artifactBuilder.buildWindowsApp(
      target: target,
      args: buildArgs,
      base64PublicKey: base64PublicKey,
    );
    verifyObfuscationMap();
    return result;
  }

  @override
  Future<String> getReleaseVersion({
    required FileSystemEntity releaseArtifactRoot,
  }) {
    final executable = windows.findExecutable(
      releaseDirectory: releaseArtifactRoot as Directory,
      projectName: quickpatchEnv.getPubspecYaml()!.name,
    );
    return powershell.getProductVersion(executable);
  }

  @override
  Future<void> uploadReleaseArtifacts({
    required Release release,
    required String appId,
  }) async {
    final projectRoot = quickpatchEnv.getQuickPatchProjectRoot()!;
    final releaseDir = artifactManager.getWindowsReleaseDirectory();

    if (!releaseDir.existsSync()) {
      logger.err('No release directory found at ${releaseDir.path}');
      throw ProcessExit(ExitCode.software.code);
    }

    final zippedRelease = await releaseDir.zipToTempFile();

    await codePushClientWrapper.createWindowsReleaseArtifacts(
      appId: appId,
      releaseId: release.id,
      projectRoot: projectRoot.path,
      releaseZipPath: zippedRelease.path,
    );

    await uploadSupplementArtifact(appId: appId, releaseId: release.id);
  }

  @override
  String get postReleaseInstructions =>
      '''

Windows executable created at ${artifactManager.getWindowsReleaseDirectory().path}.
''';
}
