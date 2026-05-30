import 'dart:io' hide Platform;

import 'package:checked_yaml/checked_yaml.dart';
import 'package:cli_util/cli_util.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/config/quickpatch_yaml.dart';
import 'package:quickpatch_cli/src/json_output.dart';
import 'package:quickpatch_cli/src/platform.dart';
import 'package:quickpatch_cli/src/quickpatch_cli_command_runner.dart';
import 'package:quickpatch_code_push_client/quickpatch_code_push_client.dart';

/// Exception thrown when the QuickPatch cache appears to be corrupted.
///
/// Surfaces a user-actionable message directing the user to run
/// `quickpatch cache clean` and retry.
class CacheCorruptedException implements Exception {
  /// Creates a [CacheCorruptedException] explaining why the cache is
  /// considered corrupted via [reason] (a complete sentence).
  const CacheCorruptedException(this.reason);

  /// Human-readable explanation of why the cache is considered corrupted.
  final String reason;

  @override
  String toString() =>
      '$reason Your QuickPatch installation may be corrupted. '
      "Try running 'quickpatch cache clean' and retrying.";
}

/// A reference to a [QuickPatchEnv] instance.
final quickpatchEnvRef = create(QuickPatchEnv.new);

/// The [QuickPatchEnv] instance available in the current zone.
QuickPatchEnv get quickpatchEnv => read(quickpatchEnvRef);

/// {@template quickpatch_env}
/// A class that provides access to quickpatch environment metadata.
/// {@endtemplate}
class QuickPatchEnv {
  /// {@macro quickpatch_env}
  const QuickPatchEnv({
    String? flutterRevisionOverride,
    String? flutterProjectRootOverride,
  }) : _flutterRevisionOverride = flutterRevisionOverride,
       _flutterProjectRootOverride = flutterProjectRootOverride;

  /// Copy the [QuickPatchEnv] and optionally override the flutter revision.
  QuickPatchEnv copyWith({String? flutterRevisionOverride}) => QuickPatchEnv(
    flutterRevisionOverride:
        flutterRevisionOverride ?? _flutterRevisionOverride,
  );

  final String? _flutterRevisionOverride;
  final String? _flutterProjectRootOverride;

  /// The application config directory for the QuickPatch CLI.
  Directory get configDirectory {
    return Directory(applicationConfigHome(executableName));
  }

  /// The directory where quickpatch logs are stored.
  Directory get logsDirectory {
    return Directory(p.join(configDirectory.path, 'logs'));
  }

  /// The root directory of the QuickPatch install.
  ///
  /// Resolved from QUICKPATCH_ROOT env var when set; otherwise assumes the
  /// binary lives at $ROOT/bin/cache/quickpatch.
  Directory get quickpatchRoot {
    final envRoot = platform.environment['QUICKPATCH_ROOT'];
    if (envRoot != null && envRoot.isNotEmpty) return Directory(envRoot);
    return File(platform.script.toFilePath()).parent.parent.parent;
  }

  /// The QuickPatch engine revision.
  ///
  /// Prefers the `engine.version` inside the bootstrapped Flutter checkout
  /// (authoritative once Flutter is installed). Before the first
  /// `release`/`patch` clones Flutter, falls back to the pinned copy shipped at
  /// the install root (`bin/internal/engine.version`) so commands like
  /// `--version` work on a fresh install instead of throwing.
  String get quickpatchEngineRevision {
    final candidates = [
      File(p.join(flutterDirectory.path, 'bin', 'internal', 'engine.version')),
      File(p.join(quickpatchRoot.path, 'bin', 'internal', 'engine.version')),
    ];
    for (final file in candidates) {
      try {
        if (file.existsSync()) return file.readAsStringSync().trim();
      } on FileSystemException {
        // Try the next candidate.
      }
    }
    throw CacheCorruptedException(
      'Could not read engine.version from ${candidates.first.path}.',
    );
  }

  /// Get the QuickPatch Flutter revision.
  String get flutterRevision {
    if (_flutterRevisionOverride != null) return _flutterRevisionOverride;
    final file = File(
      p.join(quickpatchRoot.path, 'bin', 'internal', 'flutter.version'),
    );
    try {
      return file.readAsStringSync().trim();
    } on FileSystemException {
      throw CacheCorruptedException('Could not read ${file.path}.');
    }
  }

  /// Whether the project uses package:quickpatch_code_push.
  bool get usesQuickPatchCodePushPackage {
    final pubspec = getPubspecYaml();
    return pubspec?.dependencies.containsKey('quickpatch_code_push') ?? false;
  }

  /// The root of the QuickPatch-vended Flutter git checkout.
  Directory get flutterDirectory {
    return Directory(
      p.join(quickpatchRoot.path, 'bin', 'cache', 'flutter', flutterRevision),
    );
  }

  /// The QuickPatch-vended Flutter binary.
  File get flutterBinaryFile {
    final flutter = platform.isWindows ? 'flutter.bat' : 'flutter';
    return File(p.join(flutterDirectory.path, 'bin', flutter));
  }

  /// The QuickPatch-vended Dart binary.
  File get dartBinaryFile {
    final dart = platform.isWindows ? 'dart.bat' : 'dart';
    return File(p.join(flutterDirectory.path, 'bin', dart));
  }

  /// The Cocoapods lockfile for this project's iOS app.
  File get iosPodfileLockFile {
    return File(p.join(getFlutterProjectRoot()!.path, 'ios', 'Podfile.lock'));
  }

  /// The hash of the Podfile.lock file for this project's iOS app. Will be null
  /// if the file does not exist.
  String? get iosPodfileLockHash {
    if (!iosPodfileLockFile.existsSync()) return null;
    return sha256.convert(iosPodfileLockFile.readAsBytesSync()).toString();
  }

  /// The Cocoapods lockfile for this project's macOS app.
  File get macosPodfileLockFile {
    return File(p.join(getFlutterProjectRoot()!.path, 'macos', 'Podfile.lock'));
  }

  /// The hash of the Podfile.lock file for this project's macOS app. Will be
  /// null if the file does not exist.
  String? get macosPodfileLockHash {
    if (!macosPodfileLockFile.existsSync()) return null;
    return sha256.convert(macosPodfileLockFile.readAsBytesSync()).toString();
  }

  /// The build directory of the current quickpatch project.
  Directory get buildDirectory {
    return Directory(p.join(getFlutterProjectRoot()!.path, 'build'));
  }

  /// Where the link supplement files are stored.
  // TODO(eseidel): Make this not iOS specific.
  Directory get iosSupplementDirectory =>
      Directory(p.join(buildDirectory.path, 'ios', 'quickpatch'));

  /// The `quickpatch.yaml` file for this project.
  File getQuickPatchYamlFile({required Directory cwd}) {
    return File(p.join(cwd.path, 'quickpatch.yaml'));
  }

  /// Backward-compat sync for LEGACY projects only.
  ///
  /// The native engine reads its config from `flutter_assets/quickpatch.yaml`
  /// (preferred) and falls back to `flutter_assets/shorebird.yaml`. New projects
  /// bundle `quickpatch.yaml` directly, so there is nothing to mirror. Older
  /// projects still list `shorebird.yaml` as the bundled asset; for those we
  /// keep it in sync with `quickpatch.yaml` at build time so they keep working.
  /// Returns silently when there is no legacy `shorebird.yaml` to maintain.
  void syncEngineConfig() {
    final root = getQuickPatchProjectRoot();
    if (root == null) return;
    final legacy = File(p.join(root.path, 'shorebird.yaml'));
    if (!legacy.existsSync()) return; // new project: quickpatch.yaml is bundled
    final source = getQuickPatchYamlFile(cwd: root);
    if (!source.existsSync()) return;
    legacy.writeAsStringSync(source.readAsStringSync());
  }

  /// The `pubspec.yaml` file for this project.
  File getPubspecYamlFile({required Directory cwd}) {
    return File(p.join(cwd.path, 'pubspec.yaml'));
  }

  /// Finds nearest ancestor file
  /// relative to the [cwd] that satisfies [where].
  File? findNearestAncestor({
    required File? Function(String path) where,
    Directory? cwd,
  }) {
    Directory? prev;
    var dir = cwd ?? Directory.current;
    while (prev?.path != dir.path) {
      final file = where(dir.path);
      if (file?.existsSync() ?? false) return file;
      prev = dir;
      dir = dir.parent;
    }
    return null;
  }

  /// Returns the root directory of the nearest QuickPatch project.
  Directory? getQuickPatchProjectRoot() {
    final file = findNearestAncestor(
      where: (path) => getQuickPatchYamlFile(cwd: Directory(path)),
    );
    if (file == null || !file.existsSync()) return null;
    return Directory(p.dirname(file.path));
  }

  /// Returns the root directory of the nearest Flutter project.
  Directory? getFlutterProjectRoot() {
    if (_flutterProjectRootOverride != null) {
      return Directory(_flutterProjectRootOverride);
    }
    final file = findNearestAncestor(
      where: (path) => getPubspecYamlFile(cwd: Directory(path)),
    );
    if (file == null || !file.existsSync()) return null;
    return Directory(p.dirname(file.path));
  }

  /// The `quickpatch.yaml` file for this project, parsed into a [QuickPatchYaml]
  /// object.
  ///
  /// Returns `null` if the file does not exist.
  /// Throws a [ParsedYamlException] if the file exists but is invalid.
  QuickPatchYaml? getQuickPatchYaml() {
    final root = getQuickPatchProjectRoot();
    if (root == null) return null;
    final yaml = getQuickPatchYamlFile(cwd: root).readAsStringSync();
    return checkedYamlDecode(yaml, (m) => QuickPatchYaml.fromJson(m!));
  }

  /// The `pubspec.yaml` file for this project, parsed into a [Pubspec] object.
  ///
  /// Returns `null` if the file does not exist.
  /// Throws a [ParsedYamlException] if the file exists but is invalid.
  Pubspec? getPubspecYaml() {
    final root = getFlutterProjectRoot();
    if (root == null) return null;
    try {
      final yaml = getPubspecYamlFile(cwd: root).readAsStringSync();
      return Pubspec.parse(yaml, lenient: true);
    } on Exception {
      return null;
    }
  }

  /// Whether the current project has a `quickpatch.yaml` file.
  bool get hasQuickPatchYaml => getQuickPatchYaml() != null;

  /// Whether the current project has a `pubspec.yaml` file.
  bool get hasPubspecYaml => getPubspecYaml() != null;

  /// Whether the current project's `pubspec.yaml` file contains a reference to
  /// `quickpatch.yaml` in its `assets` section.
  bool get pubspecContainsQuickPatchYaml {
    final pubspec = getPubspecYaml();
    if (pubspec == null) return false;
    if (pubspec.flutter == null) return false;
    if (pubspec.flutter!['assets'] == null) return false;
    final assets = pubspec.flutter!['assets'] as List;
    // The native engine reads `quickpatch.yaml` from flutter_assets (preferred),
    // falling back to the legacy `shorebird.yaml`. Accept either so existing
    // projects keep validating; `quickpatch init` adds `quickpatch.yaml`.
    return assets.contains('quickpatch.yaml') ||
        assets.contains('shorebird.yaml');
  }

  /// Returns the Android package name from the pubspec.yaml file of a Flutter
  /// module.
  String? get androidPackageName {
    final pubspec = getPubspecYaml();
    final module = pubspec?.flutter?['module'] as Map?;
    return module?['androidPackage'] as String?;
  }

  /// The base URL for the QuickPatch auth service. Can be overridden with the
  /// `AUTH_SERVICE_URL` environment variable. Defaults to
  /// `https://auth.quickpatch.dev`.
  Uri get authServiceUri => Uri.parse(
    platform.environment['AUTH_SERVICE_URL'] ?? 'https://auth.quickpatch.dev',
  );

  /// The expected JWT issuer for QuickPatch-issued tokens. Can be overridden
  /// with the `QUICKPATCH_JWT_ISSUER` environment variable. Defaults to
  /// `https://auth.quickpatch.dev`.
  String get jwtIssuer =>
      platform.environment['QUICKPATCH_JWT_ISSUER'] ??
      'https://auth.quickpatch.dev';

  /// The base URL for the QuickPatch code push server that overrides the
  /// default used by [CodePushClient]. If none is provided, [CodePushClient]
  /// will use its default.
  Uri? get hostedUri {
    try {
      // Prefer QUICKPATCH_HOSTED_URL, then quickpatch.yaml base_url, then the
      // hosted QuickPatch server (so a real user needs no env var; `init` works
      // before a quickpatch.yaml exists). Override only for self-hosting.
      final baseUrl =
          platform.environment['QUICKPATCH_HOSTED_URL'] ??
          getQuickPatchYaml()?.baseUrl ??
          'https://quickpatch-server-production.up.railway.app';
      return Uri.tryParse(baseUrl);
    } on Exception {
      return null;
    }
  }

  /// Whether the CLI can accept user input via stdin.
  ///
  /// Returns `false` when stdin is not a terminal, when running on CI, or
  /// when the user has opted into non-interactive output via `--json`.
  bool get canAcceptUserInput =>
      stdin.hasTerminal && !isRunningOnCI && !isJsonMode;

  /// Whether platform.environment indicates that we are running on a CI
  /// platform. This implementation is intended to behave similar to the Flutter
  /// tool's:
  /// https://github.com/flutter/flutter/blob/0c10e1ca54ae74043909059e2ff56bf5dd0c3d23/packages/flutter_tools/lib/src/base/bot_detector.dart#L48-L69
  bool get isRunningOnCI =>
      platform.environment['BOT'] == 'true'
      // https://docs.travis-ci.com/user/environment-variables/#Default-Environment-Variables
      ||
      platform.environment['TRAVIS'] == 'true' ||
      platform.environment['CONTINUOUS_INTEGRATION'] == 'true' ||
      platform.environment.containsKey('CI') // Travis and AppVeyor
      // https://www.appveyor.com/docs/environment-variables/
      ||
      platform.environment.containsKey('APPVEYOR')
      // https://cirrus-ci.org/guide/writing-tasks/#environment-variables
      ||
      platform.environment.containsKey('CIRRUS_CI')
      // https://docs.aws.amazon.com/codebuild/latest/userguide/build-env-ref-env-vars.html
      ||
      (platform.environment.containsKey('AWS_REGION') &&
          platform.environment.containsKey('CODEBUILD_INITIATOR'))
      // https://wiki.jenkins.io/display/JENKINS/Building+a+software+project#Buildingasoftwareproject-belowJenkinsSetEnvironmentVariables
      ||
      platform.environment.containsKey('JENKINS_URL')
      // https://help.github.com/en/actions/configuring-and-managing-workflows/using-environment-variables#default-environment-variables
      ||
      platform.environment.containsKey('GITHUB_ACTIONS')
      // https://learn.microsoft.com/en-us/azure/devops/pipelines/build/variables?view=azure-devops&tabs=yaml
      ||
      platform.environment.containsKey('TF_BUILD');
}
