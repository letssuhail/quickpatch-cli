import 'package:quickpatch_cli/src/commands/account/account.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';

/// {@template account_command}
/// Commands for inspecting the current QuickPatch account.
/// {@endtemplate}
class AccountCommand extends QuickPatchCommand {
  /// {@macro account_command}
  AccountCommand() {
    addSubcommand(AppsCommand());
    addSubcommand(OrgsCommand());
    addSubcommand(WhoamiCommand());
  }

  @override
  String get name => 'account';

  @override
  String get description => 'Manage your QuickPatch account.';
}
