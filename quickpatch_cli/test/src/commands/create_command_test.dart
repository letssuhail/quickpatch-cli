import 'package:args/args.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/commands/commands.dart';
import 'package:quickpatch_cli/src/quickpatch_cli_command_runner.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';
import 'package:quickpatch_cli/src/quickpatch_validator.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  group(CreateCommand, () {
    const args = ['my_app'];
    late QuickPatchProcess process;
    late ArgResults argResults;
    late QuickPatchCliCommandRunner runner;
    late QuickPatchValidator quickpatchValidator;
    late CreateCommand command;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          processRef.overrideWith(() => process),
          quickpatchValidatorRef.overrideWith(() => quickpatchValidator),
        },
      );
    }

    setUp(() {
      argResults = MockArgResults();
      process = MockQuickPatchProcess();
      runner = MockQuickPatchCliCommandRunner();
      quickpatchValidator = MockQuickPatchValidator();
      command = runWithOverrides(CreateCommand.new)
        ..testArgResults = argResults
        ..testRunner = runner;

      when(() => argResults.rest).thenReturn(args);

      when(
        () => runner.run(any()),
      ).thenAnswer((_) async => ExitCode.success.code);

      when(
        () => process.stream('flutter', ['create', ...args]),
      ).thenAnswer((_) async => ExitCode.success.code);

      when(
        () => quickpatchValidator.validatePreconditions(
          checkUserIsAuthenticated: true,
        ),
      ).thenAnswer((_) async {});
    });

    test('has correct name and description', () {
      expect(command.name, equals('create'));
      expect(
        command.description,
        equals('Create a new Flutter project with QuickPatch.'),
      );
    });

    test('runs the `flutter create` command', () async {
      await expectLater(
        runWithOverrides(command.run),
        completion(equals(ExitCode.success.code)),
      );

      verify(() => process.stream('flutter', ['create', ...args])).called(1);
    });

    group('when validation fails', () {
      setUp(() {
        when(
          () => quickpatchValidator.validatePreconditions(
            checkUserIsAuthenticated: true,
          ),
        ).thenThrow(ValidationFailedException());
      });

      test('exits with code 70', () async {
        await expectLater(
          runWithOverrides(command.run),
          completion(equals(ExitCode.config.code)),
        );

        verify(
          () => quickpatchValidator.validatePreconditions(
            checkUserIsAuthenticated: true,
          ),
        ).called(1);
      });
    });

    test('runs the quickpatch init command', () async {
      when(() => runner.run(any())).thenAnswer((invocation) async {
        final runnerArgs = invocation.positionalArguments.first as List;
        if (runnerArgs.first == 'init') {
          expect(
            p.basename(quickpatchEnv.getFlutterProjectRoot()!.path),
            args.first,
          );
        }
        return ExitCode.success.code;
      });
      await expectLater(
        runWithOverrides(command.run),
        completion(equals(ExitCode.success.code)),
      );

      verify(() => runner.run(['init'])).called(1);
    });

    group('when passing --help', () {
      setUp(() {
        when(() => argResults.rest).thenReturn(['--help']);
        when(
          () => process.stream('flutter', ['create', '--help']),
        ).thenAnswer((_) async => ExitCode.success.code);
      });

      test('only runs flutter create', () async {
        await expectLater(
          runWithOverrides(command.run),
          completion(equals(ExitCode.success.code)),
        );

        verify(() => process.stream('flutter', ['create', '--help'])).called(1);
        verifyNever(() => runner.run(any()));
      });
    });

    group('when flutter create fails', () {
      setUp(() {
        when(
          () => process.stream('flutter', ['create', ...args]),
        ).thenAnswer((_) async => 1);
      });

      test('exits', () async {
        await expectLater(
          runWithOverrides(command.run),
          completion(equals(1)),
        );

        verify(() => process.stream('flutter', ['create', ...args])).called(1);
        verifyNever(() => runner.run(any()));
      });
    });
  });
}
