import 'package:mason_logger/mason_logger.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';

/// {@template login_ci_command}
/// `quickpatch login:ci`
/// Removed — directs users to API keys instead.
/// {@endtemplate}
class LoginCiCommand extends QuickPatchCommand {
  @override
  String get description => 'Removed — use API keys instead.';

  @override
  String get name => 'login:ci';

  @override
  Future<int> run() async {
    logger.err(
      '''
quickpatch login:ci has been replaced by API keys.

Create an API key at ${link(uri: Uri.parse('https://console.quickpatch.dev'))} and set it as your ${lightCyan.wrap('SHOREBIRD_TOKEN')} environment variable.

Learn more: ${link(uri: Uri.parse('https://docs.quickpatch.dev/account/api-keys/'))}''',
    );
    return ExitCode.usage.code;
  }
}
