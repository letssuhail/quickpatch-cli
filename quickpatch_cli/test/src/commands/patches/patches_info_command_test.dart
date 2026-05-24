import 'dart:convert';

import 'package:args/args.dart';
import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/code_push_client_wrapper.dart';
import 'package:quickpatch_cli/src/commands/patches/patches_info_command.dart';
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
  group(PatchesInfoCommand, () {
    const appId = 'test-app-id';
    const releaseVersion = '1.0.0+1';
    const releaseId = 42;
    const patchNumber = 3;
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
      id: 10,
      number: patchNumber,
      channel: 'stable',
      isRolledBack: false,
      artifacts: [],
      notes: 'A test patch.',
    );

    late ArgResults argResults;
    late CodePushClientWrapper codePushClientWrapper;
    late QuickPatchEnv quickpatchEnv;
    late QuickPatchValidator quickpatchValidator;
    late QuickPatchLogger logger;
    late Progress progress;
    late PatchesInfoCommand command;

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
      command = runWithOverrides(PatchesInfoCommand.new)
        ..testArgResults = argResults;

      when(() => logger.progress(any())).thenReturn(progress);
      when(() => argResults.wasParsed(any())).thenReturn(false);
      when(() => argResults.rest).thenReturn([]);
      when(() => argResults['app-id']).thenReturn(null);
      when(() => argResults['flavor']).thenReturn(null);
      when(() => argResults['release-version']).thenReturn(releaseVersion);
      when(
        () => argResults['patch-number'],
      ).thenReturn(patchNumber.toString());
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
      expect(
        command.description,
        startsWith('Show details for a specific patch.'),
      );
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

    group('when the patch number is not found', () {
      setUp(() {
        when(
          () => codePushClientWrapper.getReleasePatches(
            appId: any(named: 'appId'),
            releaseId: any(named: 'releaseId'),
          ),
        ).thenAnswer(
          (_) async => [
            const ReleasePatch(
              id: 99,
              number: 99,
              channel: 'stable',
              isRolledBack: false,
              artifacts: [],
            ),
          ],
        );
      });

      test('prints an error and returns usage exit code', () async {
        final result = await runWithOverrides(command.run);
        expect(result, equals(ExitCode.usage.code));
        verify(
          () => logger.err(
            any(that: contains('No patch found with number $patchNumber')),
          ),
        ).called(1);
        verify(
          () => logger.info(any(that: contains('Available patches'))),
        ).called(1);
      });
    });

    group('human-readable output', () {
      test('prints labelled patch fields in order', () async {
        final result = await runWithOverrides(command.run);
        expect(result, equals(ExitCode.success.code));
        verify(() => logger.info('ID:          10')).called(1);
        verify(() => logger.info('Number:      $patchNumber')).called(1);
        verify(() => logger.info('Track:       stable')).called(1);
        verify(() => logger.info('Rolled back: no')).called(1);
        verify(() => logger.info('Notes:       A test patch.')).called(1);
      });

      group('when patch has artifacts', () {
        setUp(() {
          when(
            () => codePushClientWrapper.getReleasePatches(
              appId: any(named: 'appId'),
              releaseId: any(named: 'releaseId'),
            ),
          ).thenAnswer(
            (_) async => [
              ReleasePatch(
                id: 10,
                number: patchNumber,
                channel: 'stable',
                isRolledBack: false,
                artifacts: [
                  PatchArtifact(
                    id: 1,
                    patchId: 10,
                    arch: 'arm64-v8a',
                    platform: ReleasePlatform.android,
                    hash: 'abc123',
                    size: 1258291,
                    createdAt: DateTime(2026, 1, 15),
                  ),
                ],
              ),
            ],
          );
        });

        test('prints column-padded artifact line w/ formatted size', () async {
          final result = await runWithOverrides(command.run);
          expect(result, equals(ExitCode.success.code));
          verify(() => logger.info('Artifacts:')).called(1);
          verify(
            () => logger.info('  android  arm64-v8a    1.20 MB'),
          ).called(1);
        });
      });

      group('when notes is null', () {
        setUp(() {
          when(
            () => codePushClientWrapper.getReleasePatches(
              appId: any(named: 'appId'),
              releaseId: any(named: 'releaseId'),
            ),
          ).thenAnswer(
            (_) async => [
              const ReleasePatch(
                id: 10,
                number: patchNumber,
                channel: 'stable',
                isRolledBack: false,
                artifacts: [],
              ),
            ],
          );
        });

        test('does not print Notes line', () async {
          final result = await runWithOverrides(command.run);
          expect(result, equals(ExitCode.success.code));
          verifyNever(() => logger.info(any(that: contains('Notes:'))));
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
                id: 10,
                number: patchNumber,
                channel: 'stable',
                isRolledBack: true,
                artifacts: [],
              ),
            ],
          );
        });

        test('prints "Rolled back: yes"', () async {
          final result = await runWithOverrides(command.run);
          expect(result, equals(ExitCode.success.code));
          verify(
            () => logger.info(any(that: contains('Rolled back: yes'))),
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

      test('emits JSON success with patch details', () async {
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
        expect(data['patch'], isA<Map<String, dynamic>>());
        final patchData = data['patch'] as Map<String, dynamic>;
        expect(patchData['number'], patchNumber);
      });

      group('when the patch number is not found', () {
        setUp(() {
          when(
            () => codePushClientWrapper.getReleasePatches(
              appId: any(named: 'appId'),
              releaseId: any(named: 'releaseId'),
            ),
          ).thenAnswer((_) async => []);
        });

        test('emits JSON error envelope and returns usage exit code', () async {
          final captured = <String>[];
          final result = await captureStdout(
            () => runJsonMode(command.run),
            captured: captured,
          );
          expect(result, equals(ExitCode.usage.code));
          expect(captured, hasLength(1));
          final decoded = jsonDecode(captured.first) as Map<String, dynamic>;
          expect(decoded['status'], 'error');
          expect(
            (decoded['error'] as Map<String, dynamic>)['code'],
            'usage_error',
          );
        });
      });
    });
  });
}
