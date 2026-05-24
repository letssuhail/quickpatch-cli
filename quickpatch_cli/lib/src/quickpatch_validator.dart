import 'package:collection/collection.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/auth/auth.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/platform.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/validators/validators.dart';
import 'package:quickpatch_code_push_client/quickpatch_code_push_client.dart';

/// An exception thrown when a precondition for running a command is not met.
abstract interface class PreconditionFailedException implements Exception {
  /// The exit code to use when the precondition fails.
  ExitCode get exitCode;
}

/// An exception thrown when QuickPatch has not been initialized.
class ShorebirdNotInitializedException implements PreconditionFailedException {
  @override
  ExitCode get exitCode => ExitCode.config;
}

/// An exception thrown when the user is not authorized to run a command.
class UserNotAuthorizedException implements PreconditionFailedException {
  @override
  ExitCode get exitCode => ExitCode.noUser;
}

/// An exception thrown when validation fails.
class ValidationFailedException implements PreconditionFailedException {
  @override
  ExitCode get exitCode => ExitCode.config;
}

/// An exception thrown when a command is run in an unsupported context.
class UnsupportedContextException implements PreconditionFailedException {
  // coverage:ignore-start
  @override
  ExitCode get exitCode => ExitCode.unavailable;
  // coverage:ignore-end
}

/// An exception thrown when the operating system is not supported.
class UnsupportedOperatingSystemException
    implements PreconditionFailedException {
  @override
  ExitCode get exitCode => ExitCode.unavailable;
}

/// A reference to a [QuickPatchValidator] instance.
final quickpatchValidatorRef = create(QuickPatchValidator.new);

/// The [QuickPatchValidator] instance available in the current zone.
QuickPatchValidator get quickpatchValidator => read(quickpatchValidatorRef);

/// {@template quickpatch_validator}
/// A class that provides common validation functionality for commands.
/// {@endtemplate}
class QuickPatchValidator {
  /// {@macro quickpatch_validator}
  const QuickPatchValidator();

  /// Checks common preconditions for running a command and throws an
  /// appropriate [PreconditionFailedException] if any of them fail.
  Future<void> validatePreconditions({
    bool checkShorebirdInitialized = false,
    bool checkUserIsAuthenticated = false,
    List<Validator> validators = const [],
    Set<String>? supportedOperatingSystems,
  }) async {
    if (supportedOperatingSystems != null &&
        !supportedOperatingSystems.contains(platform.operatingSystem)) {
      logger.err(
        '''This command is only supported on ${supportedOperatingSystems.join(' ,')}.''',
      );
      throw UnsupportedOperatingSystemException();
    }

    if (checkUserIsAuthenticated && !auth.isAuthenticated) {
      logger
        ..err('You must be logged in to run this command.')
        ..info(
          '''If you already have an account, run ${lightCyan.wrap('quickpatch login')} to sign in.''',
        )
        ..info(
          '''If you don't have a QuickPatch account, go to ${link(uri: Uri.parse('https://console.quickpatch.dev'))} to create one.''',
        );
      throw UserNotAuthorizedException();
    }

    if (checkShorebirdInitialized) {
      if (!quickpatchEnv.hasQuickPatchYaml) {
        logger
          ..err(
            '''Unable to find quickpatch.yaml. Are you in a quickpatch app directory?''',
          )
          ..info(
            '''If you have not yet initialized your app, run ${lightCyan.wrap('quickpatch init')} to get started.''',
          );
        throw ShorebirdNotInitializedException();
      }

      if (!quickpatchEnv.pubspecContainsQuickPatchYaml) {
        logger
          ..err(
            '''Your pubspec.yaml does not have quickpatch.yaml as a flutter asset.''',
          )
          ..info('''
To fix, update your pubspec.yaml to include the following:

  flutter:
    assets:
      - quickpatch.yaml # Add this line
''');
        throw ShorebirdNotInitializedException();
      }
    }

    for (final validator in validators) {
      if (!validator.canRunInCurrentContext()) {
        logger.err(validator.incorrectContextMessage);
        throw UnsupportedContextException();
      }
    }

    final validationIssues = await runValidators(validators);
    if (validationIssuesContainsError(validationIssues)) {
      logValidationFailure(issues: validationIssues);
      throw ValidationFailedException();
    }
  }

  /// Runs [Validator.validate] on all [validators] and writes results to
  /// stdout.
  Future<List<ValidationIssue>> runValidators(
    List<Validator> validators,
  ) async {
    final validationIssues = (await Future.wait(
      validators.map((v) => v.validate()),
    )).flattened.toList();

    for (final issue in validationIssues) {
      logger.info(issue.displayMessage);
    }

    return validationIssues;
  }

  /// Runs [FlavorValidator] and throws a [ValidationFailedException] if any
  /// issues are found.
  Future<void> validateFlavors({
    required String? flavorArg,
    required ReleasePlatform releasePlatform,
  }) async {
    if (!releasePlatform.supportsFlavors) {
      if (flavorArg != null) {
        logger
          ..err('Flavors are not supported on this platform.')
          ..info(
            '''Please re-run this command without the --flavor argument. The app id ${lightCyan.wrap(quickpatchEnv.getQuickPatchYaml()!.appId)} will be used.''',
          );

        throw ValidationFailedException();
      }

      return;
    }

    final flavorValidator = FlavorValidator(flavorArg: flavorArg);
    final issues = await flavorValidator.validate();
    if (validationIssuesContainsError(issues)) {
      for (final issue in issues) {
        logger.err(issue.message);
      }

      throw ValidationFailedException();
    }

    if (validationIssuesContainsWarning(issues)) {
      for (final issue in issues) {
        logger.warn(issue.message);
      }
    }
  }

  /// Whether any [ValidationIssue]s have a severity of
  /// [ValidationIssueSeverity.error].
  bool validationIssuesContainsError(List<ValidationIssue> issues) =>
      issues.any((issue) => issue.severity == ValidationIssueSeverity.error);

  /// Whether any [ValidationIssue]s have a severity of
  /// [ValidationIssueSeverity.warning].
  bool validationIssuesContainsWarning(List<ValidationIssue> issues) =>
      issues.any((issue) => issue.severity == ValidationIssueSeverity.warning);

  /// Logs a message indicating that validation failed. If any of the issues
  /// can be automatically fixed, this also prompts the user to run
  /// `quickpatch doctor --fix`.
  void logValidationFailure({required List<ValidationIssue> issues}) {
    logger.err('Aborting due to validation errors.');

    final fixableIssues = issues.where((issue) => issue.fix != null);
    if (fixableIssues.isNotEmpty) {
      logger.info(
        '''${fixableIssues.length} issue${fixableIssues.length == 1 ? '' : 's'} can be fixed automatically with ${lightCyan.wrap('quickpatch doctor --fix')}.''',
      );
    }
  }
}
