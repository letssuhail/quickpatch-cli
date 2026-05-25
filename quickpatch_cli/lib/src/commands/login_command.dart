import 'package:mason_logger/mason_logger.dart';
import 'package:quickpatch_cli/src/auth/auth.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';

/// {@template login_command}
/// `quickpatch login`
/// Login as a new QuickPatch user.
/// {@endtemplate}
class LoginCommand extends QuickPatchCommand {
  @override
  String get description => 'Login as a new QuickPatch user.';

  @override
  String get name => 'login';

  @override
  Future<int> run() async {
    if (auth.isAuthenticated) {
      final emailDisplay = auth.email;
      logger
        ..info(
          emailDisplay != null
              ? 'You are already logged in as <$emailDisplay>.'
              : 'You are already authenticated via API key.',
        )
        ..info(
          'Run ${lightCyan.wrap('quickpatch logout')} to log out and try again.',
        );
      return ExitCode.success.code;
    }

    logger.info('''
To log in, generate an API key from the QuickPatch console:

  ${styleBold.wrap(lightCyan.wrap('https://quickpatch.vercel.app'))}

Then paste it below.''');

    final apiKey = logger.prompt('? Enter your API key (qp_api_...):').trim();

    if (!apiKey.startsWith('qp_api_')) {
      logger.err(
        'Invalid API key format. Expected a key starting with "qp_api_".',
      );
      return ExitCode.usage.code;
    }

    try {
      await auth.loginWithApiKey(apiKey);
    } on ApiKeyNotFoundException {
      logger.err(
        'API key not recognized. Please check the key and try again.',
      );
      return ExitCode.software.code;
    } on Exception catch (error) {
      logger.err(error.toString());
      return ExitCode.software.code;
    }

    logger.info('''

${lightGreen.wrap('You are now logged in.')}

${'🔑'} Credentials are stored in ${lightCyan.wrap(auth.credentialsFilePath)}.
${'🚪'} To logout use: "${lightCyan.wrap('quickpatch logout')}".''');
    return ExitCode.success.code;
  }
}
