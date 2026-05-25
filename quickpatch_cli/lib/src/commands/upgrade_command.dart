import 'package:mason_logger/mason_logger.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';
import 'package:quickpatch_cli/src/version.dart';

/// {@template upgrade_command}
/// `quickpatch upgrade`
/// A command which upgrades your copy of QuickPatch.
/// {@endtemplate}
class UpgradeCommand extends QuickPatchCommand {
  @override
  String get description => 'Upgrade your copy of QuickPatch.';

  static const String commandName = 'upgrade';

  @override
  String get name => commandName;

  @override
  Future<int> run() async {
    logger.info(
      'Current version: ${lightCyan.wrap(packageVersion)}',
    );
    logger.info(
      '\nTo upgrade, run:\n'
      '  ${lightCyan.wrap('dart pub global activate quickpatch_cli')}\n'
      '\nOr visit: ${lightCyan.wrap('https://quickpatch.vercel.app/docs')}',
    );
    return ExitCode.success.code;
  }
}
