import 'package:collection/collection.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:quickpatch_cli/src/code_push_client_wrapper.dart';
import 'package:quickpatch_cli/src/common_arguments.dart';
import 'package:quickpatch_cli/src/config/config.dart';
import 'package:quickpatch_cli/src/deployment_track.dart';
import 'package:quickpatch_cli/src/extensions/arg_results.dart';
import 'package:quickpatch_cli/src/json_output.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_validator.dart';

/// {@template promote_command}
/// Promotes a patch to the production channel.
/// {@endtemplate}
class PromoteCommand extends QuickPatchCommand {
  /// {@macro promote_command}
  PromoteCommand() {
    argParser
      ..addOption(
        'flavor',
        help: 'The product flavor to use when building the app.',
      )
      ..addOption(
        'release-version',
        help: CommonArguments.patchReleaseVersionDescription,
        mandatory: true,
      )
      ..addOption(
        'patch-number',
        help: 'The number of the patch to promote to the stable channel.',
        mandatory: true,
      );
  }

  @override
  String get name => 'promote';

  @override
  String get description => 'Promotes a patch to the "stable" channel.';

  @override
  Future<int> run() async {
    // Deprecated commands don't grow new surface area. Refuse --json with
    // a structured envelope that points to the replacement command, instead
    // of leaking a free-form deprecation warning to stdout.
    if (isJsonMode) {
      emitJsonError(
        code: JsonErrorCode.usageError,
        message:
            'quickpatch patches promote is deprecated and does not support '
            '--json output.',
        hint: 'Use `quickpatch patches set-track --track=stable` instead.',
      );
      return ExitCode.usage.code;
    }

    logger.warn(
      '''This command is deprecated and will be removed in a future release. Use `quickpatch patches set-track --track=stable` instead.''',
    );

    try {
      await quickpatchValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
        checkShorebirdInitialized: true,
      );
    } on PreconditionFailedException catch (error) {
      return error.exitCode.code;
    }

    final releaseVersion = results['release-version'] as String;
    final patchNumber = int.parse(results['patch-number'] as String);
    final flavor = results.findOption('flavor', argParser: argParser);
    final appId = quickpatchEnv.getQuickPatchYaml()!.getAppId(flavor: flavor);

    final release = await codePushClientWrapper.getRelease(
      appId: appId,
      releaseVersion: releaseVersion,
    );
    final patches = await codePushClientWrapper.getReleasePatches(
      appId: appId,
      releaseId: release.id,
    );
    final patchToPromote = patches.firstWhereOrNull(
      (patch) => patch.number == patchNumber,
    );
    if (patchToPromote == null) {
      logger
        ..err('No patch found with number $patchNumber')
        ..info(
          '''Available patches: ${patches.map((patch) => patch.number).join(', ')}''',
        );

      return ExitCode.usage.code;
    }

    if (patchToPromote.channel == DeploymentTrack.stable.channel) {
      logger.err('Patch ${patchToPromote.number} is already live');
      return ExitCode.usage.code;
    }

    final channel = await codePushClientWrapper.maybeGetChannel(
      appId: appId,
      name: DeploymentTrack.stable.channel,
    );
    if (channel == null) {
      // This is a symptom that something bigger is wrong. Apps should always
      // have a production channel.
      logger.err(
        '''
No production channel found for app $appId.
      
This is a bug and should never happen. Please file an issue at https://github.com/letssuhail/quickpatch/issues/new?assignees=&labels=bug&projects=&template=bug_report.md&title=fix%3A+''',
      );
      return ExitCode.software.code;
    }

    await codePushClientWrapper.promotePatch(
      appId: appId,
      patchId: patchToPromote.id,
      channel: channel,
    );

    logger.success(
      'Patch ${patchToPromote.number} is now live for release $releaseVersion!',
    );

    return ExitCode.success.code;
  }
}
