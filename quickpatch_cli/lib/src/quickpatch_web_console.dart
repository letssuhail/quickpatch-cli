/// QuickPatch Web Console URLs.
class QuickPatchWebConsole {
  /// Returns a [Uri] for the QuickPatch Web Console.
  static Uri uri(String path) {
    return Uri.parse('https://console.quickpatch.dev/$path');
  }

  /// Returns a [Uri] for the QuickPatch Web Console login page.
  static Uri appReleaseUri(String appId, int releaseId) {
    return QuickPatchWebConsole.uri('apps/$appId/releases/$releaseId');
  }
}
