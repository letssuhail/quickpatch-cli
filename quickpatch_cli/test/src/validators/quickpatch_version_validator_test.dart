import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/quickpatch_version.dart';
import 'package:quickpatch_cli/src/validators/validators.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  group('QuickPatchVersionValidator', () {
    late QuickPatchVersion quickpatchVersion;
    late QuickPatchVersionValidator validator;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {quickpatchVersionRef.overrideWith(() => quickpatchVersion)},
      );
    }

    setUp(() {
      quickpatchVersion = MockQuickPatchVersion();
      validator = QuickPatchVersionValidator();

      when(quickpatchVersion.isLatest).thenAnswer((_) async => false);
    });

    test('has a non-empty description', () {
      expect(validator.description, isNotEmpty);
    });

    test('canRunInContext always returns true', () {
      expect(validator.canRunInCurrentContext(), isTrue);
    });

    test('returns no issues when quickpatch is up-to-date', () async {
      when(quickpatchVersion.isLatest).thenAnswer((_) async => true);

      final results = await runWithOverrides(validator.validate);

      expect(results, isEmpty);
    });

    test(
      'skips the check silently when the version cannot be determined '
      '(e.g. a binary install that is not a git checkout)',
      () async {
        when(
          quickpatchVersion.isLatest,
        ).thenThrow(const ProcessException('git', ['rev-parse', 'HEAD']));

        final results = await runWithOverrides(validator.validate);

        expect(results, isEmpty);
      },
    );

    test('returns a warning when a newer quickpatch is available', () async {
      when(quickpatchVersion.isLatest).thenAnswer((_) async => false);

      final results = await runWithOverrides(validator.validate);

      expect(results, hasLength(1));
      expect(results.first.severity, ValidationIssueSeverity.warning);
      expect(
        results.first.message,
        contains('A new version of quickpatch is available!'),
      );
    });
  });
}
