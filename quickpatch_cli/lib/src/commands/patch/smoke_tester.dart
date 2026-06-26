import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/android_sdk.dart';
import 'package:quickpatch_cli/src/executables/adb.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';

/// A reference to a [SmokeTester] instance.
final smokeTesterRef = create(SmokeTester.new);

/// The [SmokeTester] instance available in the current zone.
SmokeTester get smokeTester => read(smokeTesterRef);

/// The outcome of a [SmokeTester.run].
class SmokeTestResult {
  /// {@macro smoke_test_result}
  const SmokeTestResult({
    required this.passed,
    required this.reason,
    this.details,
  });

  /// Whether the app reached its first frame without crashing.
  final bool passed;

  /// A human-readable summary of the outcome.
  final String reason;

  /// Relevant log excerpt (e.g. the crash) when [passed] is false.
  final String? details;
}

/// Installs a built APK on a connected device/emulator, launches it, and
/// watches logcat to confirm the app reaches its first frame without crashing
/// on startup. Used as a publish-time gate so a patch that crashes (or hangs)
/// on launch never reaches users.
class SmokeTester {
  /// Lines in logcat that indicate a startup crash.
  static final RegExp _crashPattern = RegExp(
    r'FATAL EXCEPTION'
    r'|Unhandled Exception'
    r'|Error while initializing the Dart VM'
    r'|E AndroidRuntime'
    r'|signal 11 \(SIGSEGV\)'
    r'|signal 6 \(SIGABRT\)',
    caseSensitive: false,
  );

  /// Reads the application id (package name) from [apk] using `aapt`.
  ///
  /// Returns null if `aapt` cannot be located or the package can't be parsed.
  Future<String?> packageNameFromApk(File apk) async {
    final aaptPath = androidSdk.aaptPath;
    if (aaptPath == null) return null;
    final QuickPatchProcessResult result;
    try {
      result = await process.run(
        aaptPath,
        ['dump', 'badging', apk.path],
        useVendedFlutter: false,
      );
    } on Exception {
      return null;
    }
    if (result.exitCode != 0) return null;
    // e.g. `package: name='com.example.app' versionCode='1' ...`
    final match = RegExp(
      "package: name='([^']+)'",
    ).firstMatch('${result.stdout}');
    return match?.group(1);
  }

  /// Installs and launches [apk], confirming it renders a first frame within
  /// [timeout] without a startup crash. The app is uninstalled afterwards.
  Future<SmokeTestResult> run({
    required File apk,
    required String packageName,
    Duration timeout = const Duration(seconds: 45),
    String? deviceId,
  }) async {
    try {
      await adb.installApk(apk, deviceId: deviceId);
    } on Exception catch (error) {
      return SmokeTestResult(
        passed: false,
        reason: 'Failed to install the patched app for smoke testing.',
        details: '$error',
      );
    }

    // The OS logs `ActivityManager: Displayed <package>/<activity>` once the
    // first frame is actually drawn — a render-confirmed signal that works
    // regardless of the engine and that a startup crash can never produce.
    final firstFramePattern = RegExp(
      'Displayed ${RegExp.escape(packageName)}/',
    );

    final recentLines = <String>[];
    final completer = Completer<SmokeTestResult>();
    Process? logcatProcess;
    StreamSubscription<String>? subscription;
    Timer? timer;

    void finish(SmokeTestResult result) {
      if (!completer.isCompleted) completer.complete(result);
    }

    try {
      logcatProcess = await adb.logcat(deviceId: deviceId);
      subscription = logcatProcess.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            recentLines.add(line);
            if (recentLines.length > 60) recentLines.removeAt(0);
            if (_crashPattern.hasMatch(line)) {
              finish(
                SmokeTestResult(
                  passed: false,
                  reason: 'The patched app crashed on startup.',
                  details: recentLines.join('\n'),
                ),
              );
            } else if (firstFramePattern.hasMatch(line)) {
              finish(
                const SmokeTestResult(
                  passed: true,
                  reason: 'The patched app launched and rendered its first '
                      'frame.',
                ),
              );
            }
          });

      timer = Timer(timeout, () {
        finish(
          SmokeTestResult(
            passed: false,
            reason:
                'The patched app did not render a frame within '
                '${timeout.inSeconds}s — it may be stuck on a splash/blank '
                'screen or hung on startup.',
            details: recentLines.isEmpty ? null : recentLines.join('\n'),
          ),
        );
      });

      await adb.startApp(package: packageName, deviceId: deviceId);

      return await completer.future;
    } finally {
      timer?.cancel();
      await subscription?.cancel();
      logcatProcess?.kill();
      await adb.uninstall(package: packageName, deviceId: deviceId);
    }
  }
}
