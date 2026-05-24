import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/config/config.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/validators/validators.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  group(FlavorValidator, () {
    const appId = 'app-id';
    const flavors = {'flavorA': 'flavorA', 'flavorB': 'flavorB'};
    const quickpatchYamlWithoutFlavors = QuickPatchYaml(appId: appId);
    const quickpatchYamlWithFlavors = QuickPatchYaml(
      appId: appId,
      flavors: flavors,
    );
    late QuickPatchEnv quickpatchEnv;

    late FlavorValidator validator;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {quickpatchEnvRef.overrideWith(() => quickpatchEnv)},
      );
    }

    setUp(() {
      quickpatchEnv = MockQuickPatchEnv();
      validator = FlavorValidator(flavorArg: 'flavor');
    });

    group('description', () {
      test('is not empty', () {
        expect(validator.description, isNotEmpty);
      });
    });

    group('validate', () {
      group('when project does not have flavors', () {
        setUp(() {
          when(
            () => quickpatchEnv.getQuickPatchYaml(),
          ).thenReturn(quickpatchYamlWithoutFlavors);
        });

        group('when flavor arg is provided', () {
          setUp(() {
            validator = FlavorValidator(flavorArg: 'flavor');
          });

          test('returns no validation issues', () async {
            final issues = await runWithOverrides(validator.validate);
            expect(issues, isNot(isEmpty));
            expect(
              issues.first.message,
              equals(
                '''The project does not have any flavors defined, but the --flavor argument was provided''',
              ),
            );
          });
        });

        group('when no flavor arg is provided', () {
          setUp(() {
            validator = FlavorValidator(flavorArg: null);
          });

          test('returns no validation issues', () async {
            final issues = await runWithOverrides(validator.validate);
            expect(issues, isEmpty);
          });
        });
      });

      group('when project has flavors', () {
        setUp(() {
          when(
            () => quickpatchEnv.getQuickPatchYaml(),
          ).thenReturn(quickpatchYamlWithFlavors);
        });

        group('when flavor arg is provided', () {
          group('when flavor exists in project', () {
            setUp(() {
              validator = FlavorValidator(flavorArg: 'flavorA');
            });

            test('returns no issues', () async {
              final issues = await runWithOverrides(validator.validate);
              expect(issues, isEmpty);
            });
          });

          group('when flavor does not exist in project', () {
            setUp(() {
              validator = FlavorValidator(flavorArg: 'flavorC');
            });

            test('returns validation error', () async {
              final issues = await runWithOverrides(validator.validate);
              expect(
                issues,
                equals([
                  ValidationIssue.error(
                    message:
                        '''This project does not have a flavor named "flavorC". Available flavors: (flavorA, flavorB)''',
                  ),
                ]),
              );
            });
          });
        });

        group('when no flavor arg is provided', () {
          setUp(() {
            validator = FlavorValidator(flavorArg: null);
          });

          test('returns validation warning', () async {
            final issues = await runWithOverrides(validator.validate);
            expect(
              issues,
              equals([
                ValidationIssue.warning(
                  message: '''
The project has flavors (flavorA, flavorB), but no --flavor argument was provided.
The default app id $appId will be used.''',
                ),
              ]),
            );
          });
        });
      });
    });
  });
}
