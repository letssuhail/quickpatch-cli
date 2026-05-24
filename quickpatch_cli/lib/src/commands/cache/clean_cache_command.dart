import 'dart:async';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:quickpatch_cli/src/cache.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/platform.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';

/// {@template clean_cache_command}
/// `quickpatch cache clean`
/// Clears the QuickPatch cache directory.
/// {@endtemplate}
class CleanCacheCommand extends QuickPatchCommand {
  /// {@macro clean_cache_command}
  CleanCacheCommand();

  @override
  String get description => 'Clears the QuickPatch cache directory.';

  @override
  String get name => 'clean';

  @override
  List<String> get aliases => ['clear'];

  @override
  Future<int> run() async {
    final progress = logger.progress('Clearing cache');
    try {
      await cache.clear();
    } on FileSystemException catch (error) {
      final cachePath = Cache.quickpatchCacheDirectory.path;
      progress.fail('''Failed to delete cache directory $cachePath: $error''');

      if (!platform.isWindows) {
        return ExitCode.software.code;
      }

      final superuserLink = link(
        uri: Uri.parse(
          'https://superuser.com/questions/1333118/cant-delete-empty-folder-because-it-is-used',
        ),
      );

      logger.info('''
This could be because a program is using a file in the cache directory. To find and stop such a program, see:
    ${lightCyan.wrap(superuserLink)}
''');
      return ExitCode.software.code;
    }

    progress.complete('Cleared cache');
    return ExitCode.success.code;
  }
}
