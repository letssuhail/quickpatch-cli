import 'package:quickpatch_cli/src/commands/commands.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';

/// {@template cache_command}
/// `quickpatch cache`
/// Manage the QuickPatch cache.
/// {@endtemplate}
class CacheCommand extends QuickPatchCommand {
  /// {@macro cache_command}
  CacheCommand() {
    addSubcommand(CleanCacheCommand());
  }

  @override
  String get description => 'Manage the QuickPatch cache.';

  @override
  String get name => 'cache';
}
