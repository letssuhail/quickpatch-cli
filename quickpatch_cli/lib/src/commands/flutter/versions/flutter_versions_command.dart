import 'package:quickpatch_cli/src/commands/commands.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';

/// {@template flutter_versions_command}
/// `quickpatch flutter versions`
/// Manage your QuickPatch Flutter versions.
/// {@endtemplate}
class FlutterVersionsCommand extends QuickPatchCommand {
  /// {@macro flutter_versions_command}
  FlutterVersionsCommand() {
    addSubcommand(FlutterVersionsListCommand());
  }

  @override
  String get description => 'Manage your QuickPatch Flutter versions.';

  @override
  String get name => 'versions';
}
