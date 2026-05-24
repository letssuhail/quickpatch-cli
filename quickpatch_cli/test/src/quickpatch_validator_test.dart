import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:platform/platform.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/auth/auth.dart';
import 'package:quickpatch_cli/src/config/config.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/platform.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_validator.dart';
import 'package:quickpatch_cli/src/validators/validators.dart';
import 'package:quickpatch_code_push_protocol/quickpatch_code_push_protocol.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group(QuickPatchValidator, () {
    late Auth auth;
    late QuickPatchLogger logger;
    late Platform platform;
    late Validator validator;
    late QuickPatchEnv quickpatchEnv;
    late QuickPatchValidator quickpatchValidator;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        () => body(),
        values: {
          authRef.overrideWith(() => auth),
          loggerRef.overrideWith(() => logger),
          platformRef.overrideWith(() => platform),
          quickpatchEnvRef.overrideWith(() => quickpatchEnv),
        },
      );
    }

    setUp(() {
      auth = MockAuth();
      logger = MockQuickPatchLogger();
      platform = MockPlatform();
      quickpatchEnv = MockQuickPatchEnv();
      validator = MockValidator();
      quickpatchValidator = runWithOverrides(QuickPatchValidator.new);
    });

    group('PreconditionFailedException', () {
      test('have correct exit codes', () {
        expect(ShorebirdNotInitializedException().exitCode, ExitCode.config);
        expect(UserNotAuthorizedException().exitCode, ExitCode.noUser);
        expect(ValidationFailedException().exitCode, ExitCode.config);
        expect(
          UnsupportedOperatingSystemException().exitCode,
          ExitCode.unavailable,
        );
      });
    });

    group('validatePreconditions', () {
      test('throws UnsupportedOperatingSystemException '
          'when the operating system is not supported', () async {
        when(() => platform.operatingSystem).thenReturn(Platform.linux);
        const supportedOperatingSystems = {Platform.macOS, Platform.windows};
        await expectLater(
          runWithOverrides(
            () => quickpatchValidator.validatePreconditions(
              supportedOperatingSystems: supportedOperatingSystems,
            ),
          ),
          throwsA(isA<UnsupportedOperatingSystemException>()),
        );
        verify(
          () => logger.err(
            '''This command is only supported on ${supportedOperatingSystems.join(' ,')}.''',
          ),
        ).called(1);
      });

      test('throws UserNotAuthorizedException '
          'when user is not authenticated', () async {
        when(() => auth.isAuthenticated).thenReturn(false);
        await expectLater(
          runWithOverrides(
            () => quickpatchValidator.validatePreconditions(
              checkUserIsAuthenticated: true,
            ),
          ),
          throwsA(isA<UserNotAuthorizedException>()),
        );
        verifyInOrder([
          () => logger.err('You must be logged in to run this command.'),
          () => logger.info(
            '''If you already have an account, run ${lightCyan.wrap('quickpatch login')} to sign in.''',
          ),
          () => logger.info(
            '''If you don't have a QuickPatch account, go to ${link(uri: Uri.parse('https://console.quickpatch.dev'))} to create one.''',
          ),
        ]);
      });

      group(
        '''when quickpatch has not been properly initialized for the current app''',
        () {
          group("when quickpatch.yaml doesn't exist", () {
            setUp(() {
              when(() => quickpatchEnv.hasQuickPatchYaml).thenReturn(false);
            });

            test(
              '''prints error message and throws ShorebirdNotInitializedException''',
              () async {
                await expectLater(
                  runWithOverrides(
                    () => quickpatchValidator.validatePreconditions(
                      checkShorebirdInitialized: true,
                    ),
                  ),
                  throwsA(isA<ShorebirdNotInitializedException>()),
                );
                verifyInOrder([
                  () => logger.err(
                    '''Unable to find quickpatch.yaml. Are you in a quickpatch app directory?''',
                  ),
                  () => logger.info(
                    '''If you have not yet initialized your app, run ${lightCyan.wrap('quickpatch init')} to get started.''',
                  ),
                ]);
              },
            );
          });

          group("when pubspec.yaml doesn't contain "
              'quickpatch.yaml as an asset', () {
            setUp(() {
              when(() => quickpatchEnv.hasQuickPatchYaml).thenReturn(true);
              when(
                () => quickpatchEnv.pubspecContainsQuickPatchYaml,
              ).thenReturn(false);
            });

            test(
              '''prints error message and throws ShorebirdNotInitializedException''',
              () async {
                await expectLater(
                  runWithOverrides(
                    () => quickpatchValidator.validatePreconditions(
                      checkShorebirdInitialized: true,
                    ),
                  ),
                  throwsA(isA<ShorebirdNotInitializedException>()),
                );
                verifyInOrder([
                  () => logger.err(
                    '''Your pubspec.yaml does not have quickpatch.yaml as a flutter asset.''',
                  ),
                  () => logger.info('''
To fix, update your pubspec.yaml to include the following:

  flutter:
    assets:
      - quickpatch.yaml # Add this line
'''),
                ]);
              },
            );
          });
        },
      );

      test('throws ValidationFailedException if validator fails', () async {
        final issue = ValidationIssue(
          message: 'test issue',
          severity: ValidationIssueSeverity.error,
          fix: () async {},
        );
        when(() => validator.canRunInCurrentContext()).thenReturn(true);
        when(() => validator.validate()).thenAnswer((_) async => [issue]);
        await expectLater(
          runWithOverrides(
            () => quickpatchValidator.validatePreconditions(
              validators: [validator],
            ),
          ),
          throwsA(isA<ValidationFailedException>()),
        );
        verify(() => validator.validate()).called(1);
        verify(
          () => logger.err('Aborting due to validation errors.'),
        ).called(1);
        verify(
          () => logger.info('${red.wrap('[✗]')} ${issue.message}'),
        ).called(1);
        verify(
          () => logger.info(
            '''1 issue can be fixed automatically with ${lightCyan.wrap('quickpatch doctor --fix')}.''',
          ),
        ).called(1);
      });

      test(
        '''throws UnsupportedContextException if validator cannot be run in current context''',
        () async {
          const errorMessage = 'Cannot run in this context';
          when(() => validator.canRunInCurrentContext()).thenReturn(false);
          when(
            () => validator.incorrectContextMessage,
          ).thenReturn(errorMessage);
          await expectLater(
            runWithOverrides(
              () => quickpatchValidator.validatePreconditions(
                validators: [validator],
              ),
            ),
            throwsA(isA<UnsupportedContextException>()),
          );
          verify(() => logger.err(errorMessage)).called(1);
        },
      );
    });

    group('validateFlavors', () {
      late QuickPatchYaml quickpatchYaml;

      setUp(() {
        when(
          () => quickpatchEnv.getQuickPatchYaml(),
        ).thenAnswer((_) => quickpatchYaml);

        when(() => platform.isWindows).thenReturn(false);
        when(() => platform.isLinux).thenReturn(false);
      });

      group('when quickpatch.yaml has flavors', () {
        setUp(() {
          quickpatchYaml = const QuickPatchYaml(
            appId: 'test',
            flavors: {'flavorA': 'flavorA'},
          );
        });

        setUp(() {
          when(() => quickpatchEnv.getQuickPatchYaml()).thenReturn(quickpatchYaml);
        });

        group('when platform does not support flavors', () {
          group('when a flavor arg is provided', () {
            test('validation fails', () async {
              await expectLater(
                runWithOverrides(
                  () => quickpatchValidator.validateFlavors(
                    flavorArg: 'flavorA',
                    releasePlatform: ReleasePlatform.windows,
                  ),
                ),
                throwsA(isA<ValidationFailedException>()),
              );

              verify(
                () => logger.err('Flavors are not supported on this platform.'),
              ).called(1);
              verify(
                () => logger.info(
                  '''Please re-run this command without the --flavor argument. The app id ${lightCyan.wrap('test')} will be used.''',
                ),
              ).called(1);
            });
          });

          group('when no flavor arg is provided', () {
            test('passes validation', () async {
              await expectLater(
                runWithOverrides(
                  () => quickpatchValidator.validateFlavors(
                    flavorArg: null,
                    releasePlatform: ReleasePlatform.windows,
                  ),
                ),
                completes,
              );
            });
          });
        });

        group('when platform supports flavors', () {
          group('when no flavor is specified', () {
            test('logs warning and fails validation', () async {
              await expectLater(
                runWithOverrides(
                  () => quickpatchValidator.validateFlavors(
                    flavorArg: null,
                    releasePlatform: ReleasePlatform.android,
                  ),
                ),
                completes,
              );
              verify(
                () => logger.warn(
                  '''
The project has flavors (flavorA), but no --flavor argument was provided.
The default app id test will be used.''',
                ),
              ).called(1);
            });
          });

          group('when a flavor arg is provided that exists in the project', () {
            test('passes validation', () async {
              await expectLater(
                runWithOverrides(
                  () => quickpatchValidator.validateFlavors(
                    flavorArg: 'flavorA',
                    releasePlatform: ReleasePlatform.android,
                  ),
                ),
                completes,
              );
            });
          });
        });
      });

      group('when quickpatch.yaml does not have flavors', () {
        setUp(() {
          quickpatchYaml = const QuickPatchYaml(appId: 'test');
        });

        group('when no flavor arg is provided', () {
          test('passes validation', () async {
            await expectLater(
              runWithOverrides(
                () => quickpatchValidator.validateFlavors(
                  flavorArg: null,
                  releasePlatform: ReleasePlatform.android,
                ),
              ),
              completes,
            );
          });

          group('when a flavor arg is provided', () {
            test('fails validation', () async {
              await expectLater(
                runWithOverrides(
                  () => quickpatchValidator.validateFlavors(
                    flavorArg: 'flavorA',
                    releasePlatform: ReleasePlatform.android,
                  ),
                ),
                throwsA(isA<ValidationFailedException>()),
              );
            });
          });
        });
      });
    });
  });
}
