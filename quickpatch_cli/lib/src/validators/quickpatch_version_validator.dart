import 'dart:io';

import 'package:quickpatch_cli/src/quickpatch_version.dart';
import 'package:quickpatch_cli/src/validators/validators.dart';

/// Verifies that the currently installed version of QuickPatch is the latest.
class QuickPatchVersionValidator extends Validator {
  /// Creates a new [QuickPatchVersionValidator].
  QuickPatchVersionValidator();

  @override
  String get description => 'QuickPatch is up-to-date';

  @override
  Future<List<ValidationIssue>> validate() async {
    final bool isQuickPatchUpToDate;

    try {
      isQuickPatchUpToDate = await quickpatchVersion.isLatest();
    } on ProcessException catch (e) {
      return [
        ValidationIssue(
          severity: ValidationIssueSeverity.error,
          message: 'Failed to get quickpatch version. Error: ${e.message}',
        ),
      ];
    }

    if (!isQuickPatchUpToDate) {
      return [
        const ValidationIssue(
          severity: ValidationIssueSeverity.warning,
          message: '''
A new version of quickpatch is available! Run `quickpatch upgrade` to upgrade.''',
        ),
      ];
    }

    return [];
  }
}
