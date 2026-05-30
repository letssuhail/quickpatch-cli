import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';
import 'package:quickpatch_cli/src/quickpatch_version.dart';

/// {@template upgrade_command}
/// `quickpatch upgrade`
///
/// Upgrades QuickPatch to the latest version by fast-forwarding the
/// `~/.quickpatch` git checkout to the upstream HEAD. The `quickpatch` wrapper
/// recompiles the CLI snapshot on the next invocation, so the new version takes
/// effect on the following command.
/// {@endtemplate}
class UpgradeCommand extends QuickPatchCommand {
  /// {@macro upgrade_command}
  @override
  String get description => 'Upgrade your copy of QuickPatch.';

  static const String commandName = 'upgrade';

  @override
  String get name => commandName;

  @override
  Future<int> run() async {
    final updateCheckProgress = logger.progress('Checking for updates');

    final String currentVersion;
    try {
      currentVersion = await quickpatchVersion.fetchCurrentGitHash();
    } on ProcessException catch (error) {
      updateCheckProgress.fail();
      logger.err('Fetching current version failed: ${error.message}');
      return ExitCode.software.code;
    }

    final String latestVersion;
    try {
      latestVersion = await quickpatchVersion.fetchLatestGitHash();
    } on ProcessException catch (error) {
      updateCheckProgress.fail();
      logger.err('Checking for updates failed: ${error.message}');
      return ExitCode.software.code;
    }

    updateCheckProgress.complete();

    if (currentVersion == latestVersion) {
      logger.info('QuickPatch is already at the latest version.');
      return ExitCode.success.code;
    }

    final updateProgress = logger.progress('Updating');
    try {
      await quickpatchVersion.attemptReset(revision: latestVersion);
    } on ProcessException catch (error) {
      updateProgress.fail();
      logger.err('Updating failed: ${error.message}');
      return ExitCode.software.code;
    }
    updateProgress.complete('Updated QuickPatch.');
    logger.info(
      'The new version takes effect on your next quickpatch command.',
    );
    return ExitCode.success.code;
  }
}
