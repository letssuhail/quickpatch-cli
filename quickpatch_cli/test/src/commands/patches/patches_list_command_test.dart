import 'dart:convert';

import 'package:args/args.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/code_push_client_wrapper.dart';
import 'package:quickpatch_cli/src/commands/patches/patches_list_command.dart';
import 'package:quickpatch_cli/src/config/config.dart';
import 'package:quickpatch_cli/src/json_output.dart';
import 'package:quickpatch_cli/src/logging/quickpatch_logger.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_validator.dart';
import 'package:quickpatch_cli/src/third_party/flutter_tools/lib/src/base/process.dart';
import 'package:quickpatch_code_push_client/quickpatch_code_push_client.dart';
import 'package:test/test.dart';

import '../../helpers.dart';
import '../../mocks.dart';

void main() {
  group(PatchesListCommand, () {
    const appId = 'test-app-id';
    const releaseVersion = '1.0.0+1';
    const releaseId = 42;
    const quickpatchYaml = QuickPatchYaml(appId: appId);
    final release = Release(
      id: releaseId,
      appId: appId,
      version: releaseVersion,
      flutterRevision: 'abc123',
      flutterVersion: '3.27.0',
      displayName: releaseVersion,
      platformStatuses: const {ReleasePlatform.android: ReleaseStatus.active},
      createdAt: DateTime(2026, 1, 15),
      updatedAt: DateTime(2026, 1, 16),
    );
    const patch = ReleasePatch(
      id: 7,
      number: 1,
      channel: 'stable',
      isRolledBack: false,
      artifacts: [],
    );

    late ArgResults argResults;
    late CodePushClientWrapper codePushClientWrapper;
    late QuickPatchEnv quickpatchEnv;
    late QuickPatchValidator quickpatchValidator;
    late QuickPatchLogger logger;
    late Progress progress;
    late PatchesListCommand command;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          codePushClientWrapperRef.overrideWith(() => codePushClientWrapper),
          isJsonModeRef.overrideWith(() => false),
          loggerRef.overrideWith(() => logger),
          quickpatchEnvRef.overrideWith(() => quickpatchEnv),
          quickpatchValidatorRef.overrideWith(() => quickpatchValidator),
        },
      );
    }

    setUp(() {
      argResults = MockArgResults();
      codePushClientWrapper = MockCodePushClientWrapper();
      logger = MockQuickPatchLogger();
      progress = MockProgress();
      quickpatchEnv = MockQuickPatchEnv();
      quickpatchValidator = MockQuickPatchValidator();
      command = runWithOverrides(PatchesListCommand.new)
        ..testArgResults = argResults;

      when(() => logger.progress(any())).thenReturn(progress);
      when(() => argResults.wasParsed(any())).thenReturn(false);
      when(() => argResults.rest).thenReturn([]);
      when(() => argResults['app-id']).thenReturn(null);
      when(() => argResults['flavor']).thenReturn(null);
      when(() => argResults['release-version']).thenReturn(releaseVersion);
      when(() => quickpatchEnv.getQuickPatchYaml()).thenReturn(quickpatchYaml);
      when(
        () => quickpatchValidator.validatePreconditions(
          checkUserIsAuthenticated: any(named: 'checkUserIsAuthenticated'),
          checkQuickPatchInitialized: any(named: 'checkQuickPatchInitialized'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => codePushClientWrapper.getRelease(
          appId: any(named: 'appId'),
          releaseVersion: any(named: 'releaseVersion'),
        ),
      ).thenAnswer((_) async => release);
      when(
        () => codePushClientWrapper.getReleasePatches(
          appId: any(named: 'appId'),
          releaseId: any(named: 'releaseId'),
        ),
      ).thenAnswer((_) async => [patch]);
    });

    test('has correct description', () {
      expect(command.description, startsWith('List patches for a release.'));
    });

    group('when validation fails', () {
      final exception = QuickPatchNotInitializedException();

      setUp(() {
        when(
          () => quickpatchValidator.validatePreconditions(
            checkUserIsAuthenticated: any(named: 'checkUserIsAuthenticated'),
            checkQuickPatchInitialized: any(named: 'checkQuickPatchInitialized'),
          ),
        ).thenThrow(exception);
      });

      test('returns the precondition failure exit code', () async {
        final result = await runWithOverrides(command.run);
        expect(result, equals(exception.exitCode.code));
      });
    });

    group('when --app-id is provided', () {
      setUp(() {
        when(() => argResults['app-id']).thenReturn('explicit-app-id');
      });

      test('does not require quickpatch to be initialized', () async {
        await runWithOverrides(command.run);
        verify(
          () => quickpatchValidator.validatePreconditions(
            checkUserIsAuthenticated: true,
          ),
        ).called(1);
      });

      test('fetches patches for the explicit app id', () async {
        await runWithOverrides(command.run);
        verify(
          () => codePushClientWrapper.getRelease(
            appId: 'explicit-app-id',
            releaseVersion: releaseVersion,
          ),
        ).called(1);
      });
    });

    group('when --app-id is not provided', () {
      test('requires quickpatch to be initialized', () async {
        await runWithOverrides(command.run);
        verify(
          () => quickpatchValidator.validatePreconditions(
            checkUserIsAuthenticated: true,
            checkQuickPatchInitialized: true,
          ),
        ).called(1);
      });

      test('fetches patches using app id from quickpatch.yaml', () async {
        await runWithOverrides(command.run);
        verify(
          () => codePushClientWrapper.getRelease(
            appId: appId,
            releaseVersion: releaseVersion,
          ),
        ).called(1);
      });

      group('when --flavor is provided', () {
        const flavor = 'staging';
        const flavoredAppId = 'flavored-app-id';
        const flavoredYaml = QuickPatchYaml(
          appId: appId,
          flavors: {flavor: flavoredAppId},
        );

        setUp(() {
          when(() => quickpatchEnv.getQuickPatchYaml()).thenReturn(flavoredYaml);
          when(() => argResults['flavor']).thenReturn(flavor);
          when(() => argResults.wasParsed('flavor')).thenReturn(true);
          when(
            () => codePushClientWrapper.getRelease(
              appId: flavoredAppId,
              releaseVersion: releaseVersion,
            ),
          ).thenAnswer((_) async => release);
        });

        test('fetches patches for the flavored app id', () async {
          await runWithOverrides(command.run);
          verify(
            () => codePushClientWrapper.getRelease(
              appId: flavoredAppId,
              releaseVersion: releaseVersion,
            ),
          ).called(1);
        });
      });
    });

    group('when there are no patches', () {
      setUp(() {
        when(
          () => codePushClientWrapper.getReleasePatches(
            appId: any(named: 'appId'),
            releaseId: any(named: 'releaseId'),
          ),
        ).thenAnswer((_) async => []);
      });

      test('prints a message', () async {
        final result = await runWithOverrides(command.run);
        expect(result, equals(ExitCode.success.code));
        verify(() => logger.info('No patches found.')).called(1);
      });
    });

    group('human-readable output', () {
      test('prints each patch with id, number, and channel', () async {
        final result = await runWithOverrides(command.run);
        expect(result, equals(ExitCode.success.code));
        verify(
          () => logger.info(
            any(that: allOf(contains('7'), contains('#1'), contains('stable'))),
          ),
        ).called(1);
      });

      group('when patch has no track', () {
        setUp(() {
          when(
            () => codePushClientWrapper.getReleasePatches(
              appId: any(named: 'appId'),
              releaseId: any(named: 'releaseId'),
            ),
          ).thenAnswer(
            (_) async => [
              const ReleasePatch(
                id: 2,
                number: 2,
                isRolledBack: false,
                artifacts: [],
              ),
            ],
          );
        });

        test('indicates the patch has no track', () async {
          final result = await runWithOverrides(command.run);
          expect(result, equals(ExitCode.success.code));
          verify(
            () => logger.info(any(that: contains('[no track]'))),
          ).called(1);
        });
      });

      group('when patch is rolled back', () {
        setUp(() {
          when(
            () => codePushClientWrapper.getReleasePatches(
              appId: any(named: 'appId'),
              releaseId: any(named: 'releaseId'),
            ),
          ).thenAnswer(
            (_) async => [
              const ReleasePatch(
                id: 2,
                number: 2,
                channel: 'stable',
                isRolledBack: true,
                artifacts: [],
              ),
            ],
          );
        });

        test('indicates the patch is rolled back', () async {
          final result = await runWithOverrides(command.run);
          expect(result, equals(ExitCode.success.code));
          verify(
            () => logger.info(any(that: contains('[rolled back]'))),
          ).called(1);
        });
      });
    });

    group('when API fetch fails', () {
      setUp(() {
        when(
          () => codePushClientWrapper.getReleasePatches(
            appId: any(named: 'appId'),
            releaseId: any(named: 'releaseId'),
          ),
        ).thenThrow(ProcessExit(ExitCode.software.code));
      });

      test('in human-readable mode, rethrows ProcessExit', () async {
        await expectLater(
          () => runWithOverrides(command.run),
          throwsA(isA<ProcessExit>()),
        );
      });

      test('in --json mode, emits JSON error envelope', () async {
        final captured = <String>[];
        final result = await captureStdout(
          () => runScoped(
            command.run,
            values: {
              codePushClientWrapperRef.overrideWith(
                () => codePushClientWrapper,
              ),
              isJsonModeRef.overrideWith(() => true),
              loggerRef.overrideWith(() => logger),
              quickpatchEnvRef.overrideWith(() => quickpatchEnv),
              quickpatchValidatorRef.overrideWith(() => quickpatchValidator),
            },
          ),
          captured: captured,
        );
        expect(result, equals(ExitCode.software.code));
        expect(captured, hasLength(1));
        final decoded = jsonDecode(captured.first) as Map<String, dynamic>;
        expect(decoded['status'], 'error');
        expect(
          (decoded['error'] as Map<String, dynamic>)['code'],
          'fetch_failed',
        );
      });
    });

    group('--json', () {
      R runJsonMode<R>(R Function() body) {
        return runScoped(
          body,
          values: {
            codePushClientWrapperRef.overrideWith(() => codePushClientWrapper),
            isJsonModeRef.overrideWith(() => true),
            loggerRef.overrideWith(() => logger),
            quickpatchEnvRef.overrideWith(() => quickpatchEnv),
            quickpatchValidatorRef.overrideWith(() => quickpatchValidator),
          },
        );
      }

      test('emits JSON success with patches list', () async {
        final captured = <String>[];
        final result = await captureStdout(
          () => runJsonMode(command.run),
          captured: captured,
        );
        expect(result, equals(ExitCode.success.code));
        expect(captured, hasLength(1));
        final decoded = jsonDecode(captured.first) as Map<String, dynamic>;
        expect(decoded['status'], 'success');
        final data = decoded['data'] as Map<String, dynamic>;
        expect(data['patches'], isA<List<dynamic>>());
        expect((data['patches'] as List<dynamic>).length, 1);
      });

      test('does not use a progress spinner', () async {
        final captured = <String>[];
        await captureStdout(
          () => runJsonMode(command.run),
          captured: captured,
        );
        verifyNever(() => logger.progress(any()));
      });
    });
  });
}
