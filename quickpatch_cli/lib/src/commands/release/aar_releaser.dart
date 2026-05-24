import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:io/io.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:quickpatch_cli/src/artifact_builder/artifact_builder.dart';
import 'package:quickpatch_cli/src/code_push_client_wrapper.dart';
import 'package:quickpatch_cli/src/commands/release/releaser.dart';
import 'package:quickpatch_cli/src/extensions/arg_results.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/platform/platform.dart';
import 'package:quickpatch_cli/src/release_type.dart';
import 'package:quickpatch_cli/src/quickpatch_android_artifacts.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_validator.dart';
import 'package:quickpatch_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:quickpatch_code_push_client/quickpatch_code_push_client.dart';

/// {@template aar_releaser}
/// Functions to create an aar release.
/// {@endtemplate}
class AarReleaser extends Releaser {
  /// {@macro aar_releaser}
  AarReleaser({
    required super.argResults,
    required super.flavor,
    required super.target,
  });

  /// The build number of the aar (1.0). Forwarded to the --build-number
  /// argument of the flutter build aar command.
  String get buildNumber => argResults['build-number'] as String;

  /// The architectures to build the aar for.
  Set<Arch> get architectures => (argResults['target-platform'] as List<String>)
      .map(
        (platform) => AndroidArch.availableAndroidArchs.firstWhere(
          (arch) => arch.targetPlatformCliArg == platform,
        ),
      )
      .toSet();

  @override
  ReleaseType get releaseType => ReleaseType.aar;

  @override
  String get supplementPlatformSubdir => 'android';

  @override
  String get supplementArtifactArch => 'aar_supplement';

  @override
  String get artifactDisplayName => 'Android archive';

  @override
  Future<void> assertPreconditions() async {
    try {
      await quickpatchValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
        checkQuickPatchInitialized: true,
      );
    } on PreconditionFailedException catch (e) {
      throw ProcessExit(e.exitCode.code);
    }

    if (quickpatchEnv.androidPackageName == null) {
      logger.err('Could not find androidPackage in pubspec.yaml.');
      throw ProcessExit(ExitCode.config.code);
    }
  }

  @override
  Future<void> assertArgsAreValid() async {
    if (!argResults.wasParsed('release-version')) {
      logger.err('Missing required argument: --release-version');
      throw ProcessExit(ExitCode.usage.code);
    }

    await assertObfuscationIsSupported();
  }

  @override
  Future<FileSystemEntity> buildReleaseArtifacts() async {
    final base64PublicKey = await getEncodedPublicKey();
    final buildArgs = [...argResults.forwardedArgs];
    addSplitDebugInfoDefault(buildArgs);
    await addObfuscationMapArgs(buildArgs);
    await artifactBuilder.buildAar(
      buildNumber: buildNumber,
      targetPlatforms: architectures,
      args: buildArgs,
      base64PublicKey: base64PublicKey,
    );
    verifyObfuscationMap();

    // Copy release AAR to a new directory to avoid overwriting with
    // subsequent patch builds.
    final sourceLibraryDirectory = Directory(
      QuickPatchAndroidArtifacts.aarLibraryPath,
    );
    final targetLibraryDirectory = Directory(
      p.join(quickpatchEnv.getQuickPatchProjectRoot()!.path, 'release'),
    );
    await copyPath(sourceLibraryDirectory.path, targetLibraryDirectory.path);

    return targetLibraryDirectory;
  }

  @override
  Future<String> getReleaseVersion({
    required FileSystemEntity releaseArtifactRoot,
  }) async {
    return argResults['release-version'] as String;
  }

  @override
  Future<void> uploadReleaseArtifacts({
    required Release release,
    required String appId,
  }) async {
    final extractAarProgress = logger.progress('Creating artifacts');
    final extractedAarDir = await quickpatchAndroidArtifacts.extractAar(
      packageName: quickpatchEnv.androidPackageName!,
      buildNumber: buildNumber,
      unzipFn: extractFileToDisk,
    );
    extractAarProgress.complete();

    await codePushClientWrapper.createAndroidArchiveReleaseArtifacts(
      appId: appId,
      releaseId: release.id,
      platform: releaseType.releasePlatform,
      aarPath: QuickPatchAndroidArtifacts.aarArtifactPath(
        packageName: quickpatchEnv.androidPackageName!,
        buildNumber: buildNumber,
      ),
      extractedAarDir: extractedAarDir.path,
      architectures: architectures,
    );

    await uploadSupplementArtifact(appId: appId, releaseId: release.id);
  }

  @override
  String get postReleaseInstructions {
    final targetLibraryDirectory = Directory(
      p.join(quickpatchEnv.getQuickPatchProjectRoot()!.path, 'release'),
    );

    return '''

Your next steps:

1. Add the aar repo and QuickPatch's maven url to your app's settings.gradle:

Note: The maven url needs to be a relative path from your settings.gradle file to the aar library. The code below assumes your Flutter module is in a sibling directory of your Android app.

${lightCyan.wrap('''
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
+       maven {
+           url '../${p.basename(quickpatchEnv.getQuickPatchProjectRoot()!.path)}/${p.relative(targetLibraryDirectory.path)}'
+       }
+       maven {
-           url 'https://storage.googleapis.com/download.flutter.io'
+           url 'https://download.quickpatch.dev/download.flutter.io'
+       }
    }
}
''')}

2. Add this module as a dependency in your app's build.gradle:
${lightCyan.wrap('''
dependencies {
  // ...
  releaseImplementation '${quickpatchEnv.androidPackageName}:flutter_release:$buildNumber'
  // ...
}''')}
''';
  }
}
