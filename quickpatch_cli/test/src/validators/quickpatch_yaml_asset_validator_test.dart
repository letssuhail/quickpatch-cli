import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/pubspec_editor.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/validators/validators.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  group(QuickPatchYamlAssetValidator, () {
    late QuickPatchEnv quickpatchEnv;
    late PubspecEditor pubspecEditor;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          quickpatchEnvRef.overrideWith(() => quickpatchEnv),
          pubspecEditorRef.overrideWith(() => pubspecEditor),
        },
      );
    }

    setUp(() {
      quickpatchEnv = MockQuickPatchEnv();
      pubspecEditor = MockPubspecEditor();
    });

    test('has a non-empty description', () {
      expect(QuickPatchYamlAssetValidator().description, isNotEmpty);
    });

    test('has a non-empty incorrectContextMessage', () {
      expect(QuickPatchYamlAssetValidator().incorrectContextMessage, isNotEmpty);
    });

    group('canRunInContext', () {
      test('returns false if no pubspec.yaml file exists', () {
        when(() => quickpatchEnv.hasPubspecYaml).thenReturn(false);
        final result = runWithOverrides(
          () => QuickPatchYamlAssetValidator().canRunInCurrentContext(),
        );
        expect(result, isFalse);
      });

      test('returns true if a pubspec.yaml file exists', () {
        when(() => quickpatchEnv.hasPubspecYaml).thenReturn(true);
        final result = runWithOverrides(
          () => QuickPatchYamlAssetValidator().canRunInCurrentContext(),
        );
        expect(result, isTrue);
      });
    });

    group('validate', () {
      test(
        'returns with no errors if pubspec.yaml has quickpatch.yaml in assets',
        () async {
          when(() => quickpatchEnv.hasPubspecYaml).thenReturn(true);
          when(
            () => quickpatchEnv.pubspecContainsQuickPatchYaml,
          ).thenReturn(true);
          final results = await runWithOverrides(
            QuickPatchYamlAssetValidator().validate,
          );
          expect(results.map((res) => res.severity), isEmpty);
        },
      );

      test('returns an error if pubspec.yaml file does not exist', () async {
        when(() => quickpatchEnv.hasPubspecYaml).thenReturn(false);
        final results = await runWithOverrides(
          QuickPatchYamlAssetValidator().validate,
        );
        expect(results, hasLength(1));
        expect(results.first.severity, ValidationIssueSeverity.error);
        expect(results.first.message, startsWith('No pubspec.yaml file found'));
        expect(results.first.fix, isNull);
      });

      test('returns error if quickpatch.yaml is missing from assets', () async {
        when(() => quickpatchEnv.hasPubspecYaml).thenReturn(true);
        when(() => quickpatchEnv.pubspecContainsQuickPatchYaml).thenReturn(false);
        final results = await runWithOverrides(
          QuickPatchYamlAssetValidator().validate,
        );
        expect(results, hasLength(1));
        expect(
          results.first,
          equals(
            const ValidationIssue(
              severity: ValidationIssueSeverity.error,
              message: 'No quickpatch.yaml found in pubspec.yaml assets',
            ),
          ),
        );
      });
    });

    group('fix', () {
      test('adds quickpatch.yaml to pubspec.yaml', () async {
        when(() => quickpatchEnv.hasPubspecYaml).thenReturn(true);
        when(() => quickpatchEnv.pubspecContainsQuickPatchYaml).thenReturn(false);
        when(
          () => pubspecEditor.addQuickPatchYamlToPubspecAssets(),
        ).thenAnswer((_) {});
        final results = await runWithOverrides(
          QuickPatchYamlAssetValidator().validate,
        );
        expect(results, hasLength(1));
        expect(results.first.fix, isNotNull);
        await runWithOverrides(() => results.first.fix!());
        verify(pubspecEditor.addQuickPatchYamlToPubspecAssets).called(1);
      });
    });
  });
}
