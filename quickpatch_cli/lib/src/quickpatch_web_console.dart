/// QuickPatch Web Console URLs.
class QuickPatchWebConsole {
  /// Returns a [Uri] for the QuickPatch Web Console.
  static Uri uri(String path) {
    return Uri.parse('https://console.quickpatch.dev/$path');
  }

  /// Returns a [Uri] to manage a release in the QuickPatch dashboard.
  ///
  /// The dashboard is a single page, so [appId]/[releaseId] are not encoded in
  /// the path today; they are kept in the signature for forward compatibility
  /// if per-release deep links are added later.
  static Uri appReleaseUri(String appId, int releaseId) {
    return QuickPatchWebConsole.uri('dashboard');
  }
}
