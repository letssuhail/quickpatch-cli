import 'package:quickpatch_cli/src/commands/patches/patches.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';

/// {@template patches_command}
/// Commands for managing QuickPatch patches.
/// {@endtemplate}
class PatchesCommand extends QuickPatchCommand {
  /// {@macro patches_command}
  PatchesCommand() {
    addSubcommand(PatchesInfoCommand());
    addSubcommand(PatchesListCommand());
    addSubcommand(PromoteCommand());
    addSubcommand(SetTrackCommand());
  }

  @override
  String get name => 'patches';

  @override
  String get description => 'Manage QuickPatch patches.';
}
