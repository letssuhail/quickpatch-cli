import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:quickpatch_cli/src/engine_bootstrap.dart';
import 'package:quickpatch_cli/src/json_output.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';
import 'package:quickpatch_cli/src/quickpatch_flutter.dart';

/// {@template flutter_versions_list_command}
/// `quickpatch flutter versions list`
/// List the Flutter versions QuickPatch supports.
/// {@endtemplate}
class FlutterVersionsListCommand extends QuickPatchCommand {
  /// {@macro flutter_versions_list_command}
  FlutterVersionsListCommand();

  @override
  String get description => 'List the Flutter versions QuickPatch supports.';

  @override
  String get name => 'list';

  @override
  Future<int> run() async {
    final progress = isJsonMode
        ? null
        : logger.progress('Fetching Flutter versions');

    String? currentVersion;
    try {
      currentVersion = await quickpatchFlutter.getVersionString();
    } on ProcessException catch (error) {
      logger.detail('Unable to determine Flutter version.\n${error.message}');
    }

    // The authoritative list: the server's engine-version registry. Only these
    // versions have a QuickPatch engine built + hosted, so only these can
    // actually `release`/`patch`. The pinned fork's git tags are a superset
    // (they include versions with NO QuickPatch engine) and used to be listed
    // here, which was misleading.
    final supported = await fetchEngineVersionRegistry();

    if (supported.isNotEmpty) {
      progress?.cancel();
      if (isJsonMode) {
        emitJsonSuccess({
          'current_version': currentVersion,
          'versions': [for (final e in supported) e.flutterVersion],
          'supported_versions': [
            for (final e in supported)
              {
                'flutter_version': e.flutterVersion,
                'flutter_revision': e.flutterRevision,
                'engine_revision': e.engineRevision,
              },
          ],
        });
        return ExitCode.success.code;
      }
      logger.info('📦 Flutter versions supported by QuickPatch');
      for (final e in supported) {
        final isCurrent =
            e.flutterVersion == currentVersion ||
            e.flutterRevision == currentVersion;
        final line =
            '${e.flutterVersion}  ${darkGray.wrap('(revision ${e.flutterRevision.substring(0, 10)})')}';
        logger.info(isCurrent ? lightCyan.wrap('✓ $line') : '  $line');
      }
      return ExitCode.success.code;
    }

    // Registry unreachable (offline / self-hosted without it): fall back to
    // the fork's tags, clearly labeled as such.
    final List<String> versions;
    try {
      versions = await quickpatchFlutter.getVersions();
      progress?.cancel();
    } on Exception catch (error) {
      if (isJsonMode) {
        emitJsonError(
          code: JsonErrorCode.fetchFailed,
          message: 'Failed to fetch Flutter versions: $error',
        );
        return ExitCode.software.code;
      }
      progress?.fail('Failed to fetch Flutter versions.');
      logger.err('$error');
      return ExitCode.software.code;
    }

    if (isJsonMode) {
      emitJsonSuccess({
        'current_version': currentVersion,
        'versions': versions.reversed.toList(),
      });
      return ExitCode.success.code;
    }

    logger.warn(
      'Could not reach the QuickPatch version registry; listing the Flutter '
      "fork's tags instead. Not all of these have a QuickPatch engine.",
    );
    logger.info('📦 Flutter Versions');
    for (final version in versions) {
      logger.info(
        version == currentVersion ? lightCyan.wrap('✓ $version') : '  $version',
      );
    }
    return ExitCode.success.code;
  }
}
