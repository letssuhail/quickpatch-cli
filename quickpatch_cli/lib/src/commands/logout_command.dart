import 'package:mason_logger/mason_logger.dart';
import 'package:quickpatch_cli/src/auth/auth.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';

/// {@template logout_command}
///
/// `quickpatch logout`
/// Logout of the current QuickPatch user.
/// {@endtemplate}
class LogoutCommand extends QuickPatchCommand {
  @override
  String get description => 'Logout of the current QuickPatch user.';

  @override
  String get name => 'logout';

  @override
  Future<int> run() async {
    if (!auth.isAuthenticated) {
      logger.info('You are already logged out.');
      return ExitCode.success.code;
    }

    final logoutProgress = logger.progress('Logging out of quickpatch.dev');
    await auth.logout();
    logoutProgress.complete();

    logger.info('${lightGreen.wrap('You are now logged out.')}');

    return ExitCode.success.code;
  }
}
