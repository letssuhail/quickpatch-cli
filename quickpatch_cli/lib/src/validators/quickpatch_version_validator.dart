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
    } on ProcessException {
      // The version check shells out to git against the install directory.
      // Binary installs (via install.sh) are not git checkouts, so git fails
      // here — that's expected, not an error. Skip the check silently rather
      // than surfacing a scary "Failed to get quickpatch version" message.
      return [];
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
