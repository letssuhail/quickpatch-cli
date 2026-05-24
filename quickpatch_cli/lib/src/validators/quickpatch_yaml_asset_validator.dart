import 'package:quickpatch_cli/src/pubspec_editor.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/validators/validators.dart';

/// Verifies that the quickpatch.yaml is found in pubspec.yaml assets.
class QuickPatchYamlAssetValidator extends Validator {
  @override
  String get description => 'quickpatch.yaml found in pubspec.yaml assets';

  @override
  bool canRunInCurrentContext() => quickpatchEnv.hasPubspecYaml;

  @override
  String get incorrectContextMessage => '''
The pubspec.yaml file does not exist.
The command you are running must be run within a Flutter app project.''';

  @override
  Future<List<ValidationIssue>> validate() async {
    if (!canRunInCurrentContext()) {
      return [
        const ValidationIssue(
          severity: ValidationIssueSeverity.error,
          message: 'No pubspec.yaml file found',
        ),
      ];
    }

    if (quickpatchEnv.pubspecContainsQuickPatchYaml) {
      return [];
    }

    return [
      ValidationIssue(
        severity: ValidationIssueSeverity.error,
        message: 'No quickpatch.yaml found in pubspec.yaml assets',
        fix: () => pubspecEditor.addQuickPatchYamlToPubspecAssets(),
      ),
    ];
  }
}
