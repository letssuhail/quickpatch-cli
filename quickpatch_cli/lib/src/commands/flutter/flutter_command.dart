import 'package:quickpatch_cli/src/commands/commands.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';

/// {@template flutter_command}
/// `quickpatch flutter`
/// Manage your QuickPatch Flutter installation.
/// {@endtemplate}
class FlutterCommand extends QuickPatchCommand {
  /// {@macro flutter_command}
  FlutterCommand() {
    addSubcommand(FlutterVersionsCommand());
    addSubcommand(FlutterConfigCommand());
  }

  @override
  String get description => 'Manage your QuickPatch Flutter installation.';

  @override
  String get name => 'flutter';
}
