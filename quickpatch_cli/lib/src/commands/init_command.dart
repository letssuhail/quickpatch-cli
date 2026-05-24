import 'dart:io';

import 'package:collection/collection.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:quickpatch_cli/src/code_push_client_wrapper.dart';
import 'package:quickpatch_cli/src/common_arguments.dart';
import 'package:quickpatch_cli/src/config/config.dart';
import 'package:quickpatch_cli/src/doctor.dart';
import 'package:quickpatch_cli/src/executables/executables.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/platform.dart';
import 'package:quickpatch_cli/src/platform/platform.dart';
import 'package:quickpatch_cli/src/pubspec_editor.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';
import 'package:quickpatch_cli/src/quickpatch_documentation.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_validator.dart';
import 'package:quickpatch_code_push_client/quickpatch_code_push_client.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// {@template init_command}
///
/// `quickpatch init`
/// Initialize QuickPatch.
/// {@endtemplate}
class InitCommand extends QuickPatchCommand {
  /// {@macro init_command}
  InitCommand() {
    argParser
      ..addFlag(
        'force',
        abbr: 'f',
        help: 'Initialize the app even if a "quickpatch.yaml" already exists.',
        negatable: false,
      )
      ..addOption(
        'display-name',
        help:
            'The app name shown in the QuickPatch dashboard '
            '(defaults to the package name in pubspec.yaml). '
            'Must be between 1 and '
            '${CommonArguments.appDisplayNameMaxLength} characters.',
      )
      ..addOption('organization-id', help: 'The organization ID to use.');
  }

  @override
  String get description => 'Initialize QuickPatch.';

  @override
  String get name => 'init';

  @override
  Future<int> run() async {
    try {
      await quickpatchValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
      );
    } on PreconditionFailedException catch (e) {
      return e.exitCode.code;
    }

    try {
      if (!quickpatchEnv.hasPubspecYaml) {
        logger.err('''
Could not find a "pubspec.yaml".
Please make sure you are running "quickpatch init" from within your Flutter project.
''');
        return ExitCode.noInput.code;
      }
    } on Exception catch (error) {
      logger.err('Error parsing "pubspec.yaml": $error');
      return ExitCode.software.code;
    }

    final organizationMemberships = await codePushClientWrapper
        .getOrganizationMemberships();
    if (organizationMemberships.isEmpty) {
      logger.err(
        '''You do not have any organizations. This should never happen. Please contact us on Discord or send us an email at contact@quickpatch.dev.''',
      );
      return ExitCode.software.code;
    }

    final Organization organization;
    final orgIdArg = results['organization-id'] as String?;
    if (orgIdArg != null) {
      final orgId = int.tryParse(orgIdArg);
      if (orgId == null) {
        logger.err('Invalid organization ID: "$orgIdArg"');
        return ExitCode.usage.code;
      }

      final organizationMembership = organizationMemberships.firstWhereOrNull(
        (o) => o.organization.id == orgId,
      );
      if (organizationMembership == null) {
        logger.err('Organization with ID "$orgId" not found.');
        _logAvailableOrganizations(organizationMemberships);
        return ExitCode.usage.code;
      }
      organization = organizationMembership.organization;
    } else if (organizationMemberships.length > 1) {
      if (!quickpatchEnv.canAcceptUserInput) {
        logger.err(
          'Multiple organizations found. '
          'Use --organization-id to specify one:',
        );
        _logAvailableOrganizations(organizationMemberships);
        return ExitCode.usage.code;
      }
      organization = logger.chooseOne(
        'Which organization should this app belong to?',
        choices: organizationMemberships.map((o) => o.organization).toList(),
        display: (o) => o.name,
        hint:
            'Pass --organization-id=<id> to select an organization without '
            'prompting.',
      );
    } else {
      organization = organizationMemberships.first.organization;
    }

    final force = results['force'] == true;

    Set<String>? androidFlavors;
    Set<String>? iosFlavors;
    Set<String>? macosFlavors;
    var productFlavors = <String>{};
    final projectRoot = quickpatchEnv.getFlutterProjectRoot()!;
    final initializeGradleProgress = logger.progress('Initializing gradlew');
    final bool shouldStartGradleDaemon;
    try {
      shouldStartGradleDaemon = await _shouldStartGradleDaemon(
        projectRoot.path,
      );
    } on Exception {
      initializeGradleProgress.fail();
      logger.err('Unable to initialize gradlew.');
      return ExitCode.software.code;
    }
    initializeGradleProgress.complete();

    if (shouldStartGradleDaemon) {
      try {
        await gradlew.startDaemon(projectRoot.path);
      } on Exception {
        logger.err('Unable to start gradle daemon.');
        return ExitCode.software.code;
      }
    }

    final detectFlavorsProgress = logger.progress('Detecting product flavors');
    try {
      androidFlavors = await _maybeGetAndroidFlavors(projectRoot.path);
      iosFlavors = apple.flavors(platform: ApplePlatform.ios);
      macosFlavors = apple.flavors(platform: ApplePlatform.macos);
      productFlavors = <String>{
        if (androidFlavors != null) ...androidFlavors,
        if (iosFlavors != null) ...iosFlavors,
        if (macosFlavors != null) ...macosFlavors,
      };
      if (productFlavors.isEmpty) {
        detectFlavorsProgress.complete('No product flavors detected.');
      } else {
        detectFlavorsProgress.complete(
          '${productFlavors.length} product flavors detected:',
        );
        for (final flavor in productFlavors) {
          logger.info('  - $flavor');
        }
      }
    } on Exception catch (error) {
      detectFlavorsProgress.fail();
      logger.err('Unable to extract product flavors.\n$error');
      return ExitCode.software.code;
    }

    final quickpatchYaml = quickpatchEnv.getQuickPatchYaml();
    final existingFlavors = quickpatchYaml?.flavors;
    Set<String> newFlavors;
    if (existingFlavors != null) {
      final existingFlavorNames = existingFlavors.keys.toSet();
      newFlavors = productFlavors.difference(existingFlavorNames);
    } else if (quickpatchYaml != null) {
      // Existing quickpatch.yaml without flavors — treat all detected flavors
      // as new so they can be added without resetting the base app_id.
      newFlavors = productFlavors;
    } else {
      newFlavors = {};
    }

    // New flavors not being empty means that there is already an existing app
    // and we just need to add the new flavor entries.
    // If the --force flag is present, we will completely reinit the app and
    // don't care about which flavors are new.
    if (!force && newFlavors.isNotEmpty) {
      logger.info('New flavors detected: ${newFlavors.join(', ')}');
      final updateQuickPatchYamlProgress = logger.progress(
        'Adding flavors to quickpatch.yaml',
      );

      final AppMetadata existingApp;
      try {
        existingApp = await codePushClientWrapper.getApp(
          appId: quickpatchYaml!.appId,
        );
      } on Exception catch (e) {
        updateQuickPatchYamlProgress.fail('Failed to get existing app info: $e');
        return ExitCode.software.code;
      }

      final deflavoredAppName = existingApp.displayName
          .replaceAll(RegExp(r'\(.*\)'), '')
          .trim();
      final flavorsToAppIds = quickpatchYaml.flavors ?? {};
      for (final flavor in newFlavors) {
        final app = await codePushClientWrapper.createApp(
          appName: '$deflavoredAppName ($flavor)',
          organizationId: organization.id,
        );
        flavorsToAppIds[flavor] = app.id;
      }
      _addQuickPatchYamlToProject(
        projectRoot: projectRoot,
        appId: quickpatchYaml.appId,
        flavors: flavorsToAppIds,
      );
      updateQuickPatchYamlProgress.complete('Flavors added to quickpatch.yaml');
      return ExitCode.success.code;
    }

    if (!force && quickpatchEnv.hasQuickPatchYaml) {
      logger
        ..err('A "quickpatch.yaml" file already exists and seems up-to-date.')
        ..info(
          '''If you want to reinitialize QuickPatch, please run ${lightCyan.wrap('quickpatch init --force')}.''',
        );
      return ExitCode.software.code;
    }

    final String appId;
    Map<String, String>? flavors;
    try {
      final needsConfirmation = !force && quickpatchEnv.canAcceptUserInput;
      final pubspecName = quickpatchEnv.getPubspecYaml()!.name;
      var displayName = results['display-name'] as String?;
      displayName ??= needsConfirmation
          ? logger.prompt(
              '${lightGreen.wrap('?')} How should we refer to this app?',
              defaultValue: pubspecName,
              hint:
                  'Pass --display-name=<name> to set the app name without '
                  'prompting.',
            )
          : pubspecName;
      if (displayName.isEmpty ||
          displayName.length > CommonArguments.appDisplayNameMaxLength) {
        logger.err(
          'App display name must be between 1 and '
          '${CommonArguments.appDisplayNameMaxLength} characters.',
        );
        return ExitCode.usage.code;
      }
      final hasNoFlavors = productFlavors.isEmpty;
      final hasSomeFlavors =
          productFlavors.isNotEmpty &&
          ((androidFlavors?.isEmpty ?? false) ||
              (iosFlavors?.isEmpty ?? false));

      if (hasNoFlavors) {
        // No platforms have any flavors so we just create a single app
        // and assign it as the default.
        final app = await codePushClientWrapper.createApp(
          appName: displayName,
          organizationId: organization.id,
        );
        appId = app.id;
      } else if (hasSomeFlavors) {
        // Some platforms have flavors and some do not so we create an app
        // for the default (no flavor) and then create an app per flavor.
        final app = await codePushClientWrapper.createApp(
          appName: displayName,
          organizationId: organization.id,
        );
        appId = app.id;
        final values = <String, String>{};
        for (final flavor in productFlavors) {
          final app = await codePushClientWrapper.createApp(
            appName: '$displayName ($flavor)',
            organizationId: organization.id,
          );
          values[flavor] = app.id;
        }
        flavors = values;
      } else {
        // All platforms have flavors so we create an app per flavor
        // and assign the default to the first flavor.
        final values = <String, String>{};
        for (final flavor in productFlavors) {
          final app = await codePushClientWrapper.createApp(
            appName: '$displayName ($flavor)',
            organizationId: organization.id,
          );
          values[flavor] = app.id;
        }
        flavors = values;
        appId = flavors.values.first;
      }
    } on Exception catch (error) {
      logger.err('$error');
      return ExitCode.software.code;
    }

    _addQuickPatchYamlToProject(
      projectRoot: projectRoot,
      appId: appId,
      flavors: flavors,
    );

    if (!quickpatchEnv.pubspecContainsQuickPatchYaml) {
      pubspecEditor.addQuickPatchYamlToPubspecAssets();
    }

    logger.info(
      '''

${lightGreen.wrap('🐦 QuickPatch initialized successfully!')}

✅ A quickpatch app has been created.
✅ A "quickpatch.yaml" has been created.
✅ The "pubspec.yaml" has been updated to include "quickpatch.yaml" as an asset.

Reference the following commands to get started:

📦 To create a new release use: "${lightCyan.wrap('quickpatch release')}".
🚀 To push an update use: "${lightCyan.wrap('quickpatch patch')}".
👀 To preview a release use: "${lightCyan.wrap('quickpatch preview')}".

For more information about QuickPatch, visit ${link(uri: Uri.parse('https://quickpatch.dev'))}''',
    );

    await doctor.runValidators(
      doctor.initAndDoctorValidators,
      applyFixes: true,
    );

    return ExitCode.success.code;
  }

  Future<bool> _shouldStartGradleDaemon(String projectPath) async {
    try {
      final isAvailable = await gradlew.isDaemonAvailable(projectPath);
      return !isAvailable;
    } on MissingAndroidProjectException {
      return false;
    }
  }

  Future<Set<String>?> _maybeGetAndroidFlavors(String projectPath) async {
    try {
      return await gradlew.productFlavors(projectPath);
    } on MissingAndroidProjectException {
      return null;
    }
  }

  QuickPatchYaml _addQuickPatchYamlToProject({
    required String appId,
    required Directory projectRoot,
    Map<String, String>? flavors,
  }) {
    const content =
        '''
# This file is used to configure the QuickPatch updater used by your app.
# Learn more at $docsUrl
# This file does not contain any sensitive information and should be checked into version control.

# Your app_id is the unique identifier assigned to your app.
# It is used to identify your app when requesting patches from QuickPatch's servers.
# It is not a secret and can be shared publicly.
app_id:

# auto_update controls if QuickPatch should automatically update in the background on launch.
# If auto_update: false, you will need to use package:quickpatch_code_push to trigger updates.
# https://pub.dev/packages/quickpatch_code_push
# Uncomment the following line to disable automatic updates.
# auto_update: false
''';

    final editor = YamlEditor(content)..update(['app_id'], appId);

    // Bake the server URL into the config so the on-device updater queries the
    // right server. Derived from QUICKPATCH_HOSTED_URL (the same server the CLI
    // publishes to). Without this the updater uses its default.
    final hostedUrl = platform.environment['QUICKPATCH_HOSTED_URL'];
    if (hostedUrl != null && hostedUrl.isNotEmpty) {
      editor.update(['base_url'], hostedUrl);
    }

    if (flavors != null) editor.update(['flavors'], flavors);

    final yamlContents = editor.toString();
    quickpatchEnv
        .getQuickPatchYamlFile(cwd: projectRoot)
        .writeAsStringSync(yamlContents);

    // The native engine loads its config from flutter_assets as `shorebird.yaml`.
    // Mirror quickpatch.yaml -> shorebird.yaml so the engine initializes.
    // This file is auto-generated and hidden from version control via .gitignore.
    File(
      p.join(projectRoot.path, 'shorebird.yaml'),
    ).writeAsStringSync(yamlContents);

    // Hide shorebird.yaml from the user's git history — it's auto-generated.
    _ensureGitignored(projectRoot, 'shorebird.yaml');

    return QuickPatchYaml(appId: appId);
  }

  void _ensureGitignored(Directory projectRoot, String entry) {
    final gitignoreFile = File(p.join(projectRoot.path, '.gitignore'));
    final lines = gitignoreFile.existsSync()
        ? gitignoreFile.readAsStringSync()
        : '';
    if (!lines.split('\n').map((l) => l.trim()).contains(entry)) {
      final separator = lines.isNotEmpty && !lines.endsWith('\n') ? '\n' : '';
      gitignoreFile.writeAsStringSync('$lines$separator$entry\n');
    }
  }

  void _logAvailableOrganizations(
    List<OrganizationMembership> memberships,
  ) {
    logger.info('Available organizations:');
    for (final membership in memberships) {
      final org = membership.organization;
      logger.info('  ${org.name} (id: ${org.id})');
    }
  }
}
