import 'package:quickpatch_cli/src/quickpatch_web_console.dart';
import 'package:test/test.dart';

void main() {
  group(QuickPatchWebConsole, () {
    test('uri returns the correct uri with the received path', () {
      expect(
        QuickPatchWebConsole.uri('path'),
        Uri.parse('https://console.quickpatch.dev/path'),
      );
    });

    test('appReleaseUri returns the correct uri to an app release', () {
      expect(
        QuickPatchWebConsole.appReleaseUri('appId', 123),
        Uri.parse('https://console.quickpatch.dev/apps/appId/releases/123'),
      );
    });
  });
}
