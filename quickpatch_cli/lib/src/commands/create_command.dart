import 'dart:async';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/quickpatch_command.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';
import 'package:quickpatch_cli/src/quickpatch_validator.dart';

/// {@template quickpatch_create_command}
/// `quickpatch create`
/// Create a new Flutter app with QuickPatch.
/// {@endtemplate}
class CreateCommand extends ShorebirdProxyCommand {
  @override
  String get name => 'create';

  @override
  String get description => 'Create a new Flutter project with QuickPatch.';

  @override
  Future<int> run() async {
    try {
      await quickpatchValidator.validatePreconditions(
        checkUserIsAuthenticated: true,
      );
    } on PreconditionFailedException catch (e) {
      return e.exitCode.code;
    }

    final createExitCode = await process.stream('flutter', [
      'create',
      ...results.rest,
    ]);

    if (createExitCode != ExitCode.success.code) {
      return createExitCode;
    }

    if (results.rest.contains('-h') || results.rest.contains('--help')) {
      return createExitCode;
    }

    return runScoped(
      () => runner!.run(['init']),
      values: {
        quickpatchEnvRef.overrideWith(
          () => QuickPatchEnv(
            flutterProjectRootOverride: p.absolute(
              p.normalize(results.rest.first),
            ),
          ),
        ),
      },
    );
  }
}
