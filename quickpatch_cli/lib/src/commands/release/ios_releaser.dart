import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:quickpatch_cli/src/artifact_builder/artifact_builder.dart';
import 'package:quickpatch_cli/src/artifact_manager.dart';
import 'package:quickpatch_cli/src/code_push_client_wrapper.dart';
import 'package:quickpatch_cli/src/commands/release/apple_releaser_mixin.dart';
import 'package:quickpatch_cli/src/commands/release/releaser.dart';
import 'package:quickpatch_cli/src/common_arguments.dart';
import 'package:quickpatch_cli/src/doctor.dart';
import 'package:quickpatch_cli/src/engine_bootstrap.dart';
import 'package:quickpatch_cli/src/extensions/arg_results.dart';
import 'package:quickpatch_cli/src/interpreter/interpreter_build.dart';
import 'package:quickpatch_cli/src/quickpatch_artifacts.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';
import 'package:quickpatch_cli/src/flutter_version_constraints.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/platform/apple/apple.dart';
import 'package:quickpatch_cli/src/release_type.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/third_party/flutter_tools/lib/flutter_tools.dart';
import 'package:quickpatch_cli/src/validators/validators.dart';
import 'package:quickpatch_code_push_client/quickpatch_code_push_client.dart';

/// {@template ios_releaser}
/// Functions to build and publish an iOS release.
/// {@endtemplate}
class IosReleaser extends Releaser with AppleReleaserMixin {
  /// {@macro ios_releaser}
  IosReleaser({
    required super.argResults,
    required super.flavor,
    required super.target,
  });

  /// Whether to codesign the release.
  bool get codesign => argResults['codesign'] == true;

  @override
  ReleaseType get releaseType => ReleaseType.ios;

  @override
  String get supplementPlatformSubdir => 'ios';

  @override
  String get supplementArtifactArch => 'ios_supplement';

  @override
  String get artifactDisplayName => 'iOS app';

  @override
  List<Validator> get applePlatformValidators => doctor.iosCommandValidators;

  @override
  Future<void> assertArgsAreValid() async {
    assertReleaseVersionFlagNotProvided();

    // Ensure the prebuilt QuickPatch iOS engine for this Flutter revision is
    // installed (download + verify from the CDN if missing) before we build.
    await ensureQuickPatchIosEngine();

    await assertObfuscationIsSupported();

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
  Version? get minimumFlutterVersion => minimumSupportedIosFlutterVersion;

  @override
  Future<FileSystemEntity> buildReleaseArtifacts() async {
    if (!codesign) {
      logger
        ..info(
          '''Building for device with codesigning disabled. You will have to manually codesign before deploying to device.''',
        )
        ..warn(
          '''quickpatch preview will not work for releases created with "--no-codesign". However, you can still preview your app by signing the generated .xcarchive in Xcode.''',
        )
        ..warn(
          '''
When you distribute the .xcarchive in Xcode, you MUST uncheck "Manage Version and Build Number" in the Distribute App dialog.

If left checked, Xcode will rewrite the build number in the uploaded IPA, so the version that ships to App Store Connect will not match the version QuickPatch recorded for this release. Patches will then fail to apply.''',
        );
    }

    // Delete the QuickPatch supplement directory if it exists.
    // This is to ensure that we don't accidentally upload stale artifacts
    // when building with older versions of Flutter.
    final quickpatchSupplementDir = artifactManager
        .getIosReleaseSupplementDirectory();
    if (quickpatchSupplementDir?.existsSync() ?? false) {
      quickpatchSupplementDir!.deleteSync(recursive: true);
    }

    final base64PublicKey = await getEncodedPublicKey();

    final buildArgs = [...argResults.forwardedArgs];
    addSplitDebugInfoDefault(buildArgs);
    await addObfuscationMapArgs(buildArgs);

    if (interpreterMode) {
      await _buildInterpreterBase(
        base64PublicKey: base64PublicKey,
        buildArgs: buildArgs,
      );
    } else {
      await artifactBuilder.buildIpa(
        codesign: codesign,
        flavor: flavor,
        target: target,
        args: buildArgs,
        base64PublicKey: base64PublicKey,
        ddMaxBytes: ddMaxBytes,
      );
    }

    verifyObfuscationMap();

    final xcarchiveDirectory = artifactManager.getXcarchiveDirectory();
    if (xcarchiveDirectory == null) {
      logger.err('Unable to find .xcarchive directory');
      throw ProcessExit(ExitCode.software.code);
    }

    final appDirectory = artifactManager.getIosAppDirectory(
      xcarchiveDirectory: xcarchiveDirectory,
    );

    if (appDirectory == null) {
      logger.err('Unable to find .app directory');
      throw ProcessExit(ExitCode.software.code);
    }

    return xcarchiveDirectory;
  }

  /// Builds the iOS interpreter (arbitrary-code-push) base: the app's own code
  /// ships as a `dart2bytecode` module (`assets/app.qpmod`) loaded by a
  /// generated server-OTA bootstrapper; the framework stays AOT (retained +
  /// open-dispatch via the generated dynamic_interface). Mirrors the proven
  /// `build_interpreter_ios.sh` using the cached engine toolchain. Transient
  /// files (bootstrapper, app-module wrapper, app.qpmod, pubspec asset) are
  /// removed afterward so the project is left untouched. EXPERIMENTAL.
  Future<void> _buildInterpreterBase({
    required String? base64PublicKey,
    required List<String> buildArgs,
  }) async {
    final progress = logger.progress('Building interpreter (bytecode) base');
    final root = quickpatchEnv.getQuickPatchProjectRoot()!.path;
    final work = Directory(p.join(quickpatchEnv.buildDirectory.path, 'qp_interp'))
      ..createSync(recursive: true);

    String tool(QuickPatchArtifact a) =>
        quickpatchArtifacts.getArtifactPath(artifact: a);
    final aot = tool(QuickPatchArtifact.dartAotRuntimeIos);
    final d2b = tool(QuickPatchArtifact.dart2bytecodeIos);
    final genk = tool(QuickPatchArtifact.genKernelIos);
    final plat = tool(QuickPatchArtifact.flutterPlatformDillIos);
    final genIface = tool(QuickPatchArtifact.genInterfaceAotIos);
    final genSnapshotIos = tool(QuickPatchArtifact.genSnapshotIos);

    String field(String file, String key) =>
        RegExp('^$key:\\s*(.+)\$', multiLine: true)
            .firstMatch(File(p.join(root, file)).readAsStringSync())
            ?.group(1)
            ?.trim() ??
        (throw StateError('missing $key in $file'));
    final appPkg = field('pubspec.yaml', 'name');
    final version = field('pubspec.yaml', 'version');
    final appId = field('quickpatch.yaml', 'app_id');
    final baseUrl = field('quickpatch.yaml', 'base_url');
    final pkgConfig = p.join(root, '.dart_tool', 'package_config.json');

    final bootFile = File(p.join(root, 'lib', 'qp_bootstrap_main.dart'));
    final appModFile = File(p.join(root, 'lib', 'qp_app_module.dart'));
    final qpmod = File(p.join(root, 'assets', 'app.qpmod'));
    final pubspec = File(p.join(root, 'pubspec.yaml'));
    final pubspecBackup = pubspec.readAsStringSync();

    Future<void> run(String exe, List<String> args, String label) async {
      final r = await process.run(exe, args);
      if (r.exitCode != 0) {
        progress.fail('$label failed (${r.exitCode}): ${r.stderr}');
        throw ProcessExit(ExitCode.software.code);
      }
    }

    try {
      // Transient sources: a server-OTA bootstrapper (AOT entrypoint) and an
      // app-module wrapper exposing the app's real main as the module entry.
      bootFile.writeAsStringSync(
        InterpreterBuild.generateBootstrapperMain(
          mode: 'server',
          serverBaseUrl: baseUrl,
          appId: appId,
          releaseVersion: version,
          // SECURITY: embed the release public key so the on-device bootstrapper
          // verifies each patch's signature before applying it. Empty when no
          // --public-key was provided (unsigned mode).
          publicKeyBase64: base64PublicKey ?? '',
        ),
      );
      appModFile.writeAsStringSync(
        "import 'package:$appPkg/main.dart' as app;\n"
        "@pragma('dyn-module:entry-point')\n"
        'void main() => app.main();\n',
      );

      // Ensure the bootstrapper's deps (signature verification + module load)
      // are declared and resolved BEFORE compiling it, so the package_config
      // the gen steps use can resolve them.
      _ensureDependencies(pubspec, const {
        'crypto': 'any',
        'pointycastle': 'any',
        'asn1lib': 'any',
      });
      // Use CocoaPods (not Swift Package Manager) for interpreter builds: the
      // signature-verification deps (pointycastle/asn1lib/crypto) trigger an
      // SPM re-resolution that fails inside the Xcode build. CocoaPods is the
      // stable path. Idempotent + global, but CocoaPods is a safe default.
      await process.run('flutter', [
        'config',
        '--no-enable-swift-package-manager',
      ]);
      // `flutter pub get` (vended flutter): resolves the package_config for the
      // gen steps AND regenerates the iOS ephemeral Swift Package (the local
      // FlutterFramework/FlutterGeneratedPluginSwiftPackage) so the subsequent
      // Xcode build's SPM resolution stays consistent. (A bare `dart pub get`
      // skips the ephemeral SPM setup and breaks the build's SPM resolve.)
      final pg = await process.run('flutter', ['pub', 'get']);
      if (pg.exitCode != 0) {
        progress.fail('flutter pub get failed: ${pg.stderr}');
        throw ProcessExit(ExitCode.software.code);
      }

      // 1. Bootstrapper import-dill (no-link) + framework interface.
      final importDill = p.join(work.path, 'boot_import.dill');
      await run(
        aot,
        InterpreterBuild.genKernelArgs(
          genKernelSnapshot: genk,
          platformDill: plat,
          packageConfig: pkgConfig,
          entry: bootFile.path,
          output: importDill,
          noLinkPlatform: true,
        ),
        'gen import-dill',
      );
      final iface = p.join(work.path, 'interface.yaml');
      await run(aot, [
        genIface,
        importDill,
        iface,
        '--app-package=$appPkg',
      ], 'gen interface');

      // 2. App bytecode module (the whole app), bundled as an asset.
      qpmod.parent.createSync(recursive: true);
      await run(
        aot,
        InterpreterBuild.dart2bytecodeArgs(
          dart2bytecodeSnapshot: d2b,
          platformDill: plat,
          packageConfig: pkgConfig,
          importDill: importDill,
          entry: appModFile.path,
          output: qpmod.path,
        ),
        'gen app.qpmod',
      );
      // Read the CURRENT pubspec (already has the deps added above) so we
      // don't clobber them.
      var newPubspec = pubspec.readAsStringSync();
      if (!newPubspec.contains('assets/app.qpmod')) {
        final assetsRe = RegExp(r'(\n[ \t]*assets:[ \t]*\n)');
        if (assetsRe.hasMatch(newPubspec)) {
          // Insert under the existing `assets:` list.
          newPubspec = newPubspec.replaceFirstMapped(
            assetsRe,
            (m) => '${m[1]}    - assets/app.qpmod\n',
          );
        } else {
          // No assets block yet — add one under `flutter:`.
          newPubspec = newPubspec.replaceFirstMapped(
            RegExp(r'(\nflutter:[ \t]*\n)'),
            (m) => '${m[1]}  assets:\n    - assets/app.qpmod\n',
          );
        }
        pubspec.writeAsStringSync(newPubspec);
      }

      // 3. Build the IPA from the bootstrapper (bundles app.qpmod).
      //    Disable icon tree-shaking: the ConstFinder walks the bootstrapper
      //    entrypoint (which doesn't reference the app's MaterialApp/icons the
      //    usual way) and crashes. The real icons ship inside the bytecode
      //    module, so tree-shaking here would be wrong anyway.
      if (!buildArgs.contains('--no-tree-shake-icons')) {
        buildArgs.add('--no-tree-shake-icons');
      }
      await artifactBuilder.buildIpa(
        codesign: codesign,
        flavor: flavor,
        target: bootFile.path,
        args: buildArgs,
        base64PublicKey: base64PublicKey,
        ddMaxBytes: ddMaxBytes,
      );

      // 4. Annotated App (framework retained/open-dispatch via --dynamic-interface)
      //    -> iOS AOT snapshot -> swap into the xcarchive's App.framework/App.
      final bootAot = p.join(work.path, 'boot_aot.dill');
      await run(
        aot,
        InterpreterBuild.genKernelArgs(
          genKernelSnapshot: genk,
          platformDill: plat,
          packageConfig: pkgConfig,
          entry: bootFile.path,
          output: bootAot,
          dynamicInterfacePath: iface,
          product: true,
          aot: true,
        ),
        'gen annotated AOT kernel',
      );
      final asm = p.join(work.path, 'snapshot.S');
      await run(genSnapshotIos, [
        '--deterministic',
        '--snapshot_kind=app-aot-assembly',
        '--assembly=$asm',
        bootAot,
      ], 'gen iOS App snapshot');
      final sdkPath = (await process.run('xcrun', [
        '--sdk',
        'iphoneos',
        '--show-sdk-path',
      ])).stdout.toString().trim();
      final appObj = p.join(work.path, 'snapshot.o');
      final appDylib = p.join(work.path, 'App');
      await run('xcrun', [
        '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-c', asm, '-o', appObj,
      ], 'compile App object');
      await run('xcrun', [
        '--sdk', 'iphoneos', 'clang', '-arch', 'arm64', '-dynamiclib',
        '-isysroot', sdkPath, '-miphoneos-version-min=13.0',
        '-Wl,-install_name,@rpath/App.framework/App', '-o', appDylib, appObj,
      ], 'link App dylib');

      final xc = artifactManager.getXcarchiveDirectory();
      final appDir = xc == null
          ? null
          : artifactManager.getIosAppDirectory(xcarchiveDirectory: xc);
      if (appDir == null) {
        progress.fail('Unable to find built .app to swap the interpreter App');
        throw ProcessExit(ExitCode.software.code);
      }
      final appFramework = Directory(
        p.join(appDir.path, 'Frameworks', 'App.framework'),
      );
      File(appDylib).copySync(p.join(appFramework.path, 'App'));

      // Re-sign the swapped App + frameworks + app with the same identity the
      // build used (only when codesigning).
      if (codesign) {
        final identity = await _signingIdentity(appDir);
        // Frameworks: plain re-sign. App bundle: preserve the build's
        // entitlements (application-identifier, etc.) — re-signing without them
        // makes the install fail ("missing application-identifier entitlement").
        await run('codesign', ['-f', '-s', identity, appFramework.path],
            'codesign App.framework');
        await run('codesign', [
          '-f', '-s', identity,
          p.join(appDir.path, 'Frameworks', 'Flutter.framework'),
        ], 'codesign Flutter.framework');
        await run('codesign', [
          '-f', '-s', identity,
          '--preserve-metadata=entitlements,flags',
          appDir.path,
        ], 'codesign Runner.app');
      }
      progress.complete('Interpreter base built (app.qpmod + bootstrapper)');
    } finally {
      // Restore the project: remove transient sources + asset, restore pubspec.
      for (final f in [bootFile, appModFile, qpmod]) {
        if (f.existsSync()) f.deleteSync();
      }
      pubspec.writeAsStringSync(pubspecBackup);
    }
  }

  /// Adds any missing `name: constraint` entries under the pubspec's
  /// `dependencies:` block (idempotent; only when not already present).
  void _ensureDependencies(File pubspec, Map<String, String> deps) {
    var text = pubspec.readAsStringSync();
    final missing = deps.entries.where((e) => !text.contains('\n  ${e.key}:'));
    if (missing.isEmpty) return;
    final block = missing.map((e) => '  ${e.key}: ${e.value}').join('\n');
    text = text.replaceFirstMapped(
      RegExp(r'(\ndependencies:[ \t]*\n)'),
      (m) => '${m[1]}$block\n',
    );
    pubspec.writeAsStringSync(text);
  }

  /// Extracts the codesigning identity (cert common name) from the already
  /// signed [appDir], to re-sign the swapped App with the same identity.
  Future<String> _signingIdentity(Directory appDir) async {
    final r = await process.run('codesign', ['-dvv', appDir.path]);
    final m = RegExp(r'Authority=(Apple Development:[^\n]+)')
        .firstMatch('${r.stdout}${r.stderr}');
    return m?.group(1)?.trim() ?? '-';
  }

  @override
  Future<String> getReleaseVersion({
    required FileSystemEntity releaseArtifactRoot,
  }) async {
    final plistFile = File(p.join(releaseArtifactRoot.path, 'Info.plist'));
    if (!plistFile.existsSync()) {
      logger.err('No Info.plist file found at ${plistFile.path}');
      throw ProcessExit(ExitCode.software.code);
    }

    try {
      return Plist(file: plistFile).versionNumber;
    } on Exception catch (error) {
      logger.err(
        '''Failed to determine release version from ${plistFile.path}: $error''',
      );
      throw ProcessExit(ExitCode.software.code);
    }
  }

  @override
  Future<void> uploadReleaseArtifacts({
    required Release release,
    required String appId,
  }) async {
    final xcarchiveDirectory = artifactManager.getXcarchiveDirectory()!;
    await codePushClientWrapper.createIosReleaseArtifacts(
      appId: appId,
      releaseId: release.id,
      xcarchivePath: xcarchiveDirectory.path,
      runnerPath: artifactManager
          .getIosAppDirectory(xcarchiveDirectory: xcarchiveDirectory)!
          .path,
      isCodesigned: codesign,
      podfileLockHash: quickpatchEnv.iosPodfileLockHash,
    );

    await uploadSupplementArtifact(appId: appId, releaseId: release.id);
  }

  @override
  String get postReleaseInstructions {
    final relativeArchivePath = p.relative(
      artifactManager.getXcarchiveDirectory()!.path,
    );
    if (codesign) {
      const ipaSearchString = 'build/ios/ipa/*.ipa';
      return '''

Your next step is to upload your app to App Store Connect.

To upload to the App Store, do one of the following:
    1. Open ${lightCyan.wrap(relativeArchivePath)} in Xcode and use the "Distribute App" flow.
    2. Drag and drop the ${lightCyan.wrap(ipaSearchString)} bundle into the Apple Transporter macOS app (https://apps.apple.com/us/app/transporter/id1450874784).
    3. Run ${lightCyan.wrap('xcrun altool --upload-app --type ios -f $ipaSearchString --apiKey your_api_key --apiIssuer your_issuer_id')}.
       See "man altool" for details about how to authenticate with the App Store Connect API key.
''';
    } else {
      return '''

Your next step is to submit the archive at ${lightCyan.wrap(relativeArchivePath)} to the App Store using Xcode.

You can open the archive in Xcode by running:
    ${lightCyan.wrap('open $relativeArchivePath')}

${styleBold.wrap('Make sure to uncheck "Manage Version and Build Number" in the Distribute App dialog.')}
If left checked, Xcode will rewrite the build number in the uploaded IPA, so the version that ships will not match the one QuickPatch recorded for this release, and patches will fail to apply.
''';
    }
  }
}
