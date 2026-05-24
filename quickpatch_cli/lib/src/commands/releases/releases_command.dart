import 'package:quickpatch_cli/src/commands/releases/releases.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';

/// {@template releases_command}
/// Commands for managing QuickPatch releases.
/// {@endtemplate}
class ReleasesCommand extends QuickPatchCommand {
  /// {@macro releases_command}
  ReleasesCommand() {
    addSubcommand(GetApksCommand());
    addSubcommand(ReleasesInfoCommand());
    addSubcommand(ReleasesListCommand());
  }

  @override
  String get name => 'releases';

  @override
  String get description => 'Manage QuickPatch releases.';
}
