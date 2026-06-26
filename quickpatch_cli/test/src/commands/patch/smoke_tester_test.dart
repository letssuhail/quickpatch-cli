import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/android_sdk.dart';
import 'package:quickpatch_cli/src/commands/patch/smoke_tester.dart';
import 'package:quickpatch_cli/src/executables/adb.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';
import 'package:test/test.dart';

import '../../mocks.dart';

void main() {
  group(SmokeTester, () {
    late Adb adb;
    late AndroidSdk androidSdk;
    late QuickPatchProcess process;
    late SmokeTester smokeTester;

    const packageName = 'com.example.app';
    final apk = File('app-release.apk');

    setUpAll(() {
      registerFallbackValue(File(''));
      registerFallbackValue(<String>[]);
    });

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        body,
        values: {
          adbRef.overrideWith(() => adb),
          androidSdkRef.overrideWith(() => androidSdk),
          processRef.overrideWith(() => process),
        },
      );
    }

    setUp(() {
      adb = MockAdb();
      androidSdk = MockAndroidSdk();
      process = MockQuickPatchProcess();
      smokeTester = SmokeTester();

      when(() => adb.installApk(any(), deviceId: any(named: 'deviceId')))
          .thenAnswer((_) async {});
      when(
        () => adb.startApp(
          package: any(named: 'package'),
          deviceId: any(named: 'deviceId'),
        ),
      ).thenAnswer((_) async {});
      when(
        () => adb.uninstall(
          package: any(named: 'package'),
          deviceId: any(named: 'deviceId'),
        ),
      ).thenAnswer((_) async {});
    });

    /// Wires `adb.logcat` to a process whose stdout emits [lines].
    void stubLogcat(Stream<String> lines) {
      final fakeProcess = MockProcess();
      when(() => fakeProcess.stdout).thenAnswer(
        (_) => lines.map(utf8.encode),
      );
      when(fakeProcess.kill).thenReturn(true);
      when(() => adb.logcat(deviceId: any(named: 'deviceId')))
          .thenAnswer((_) async => fakeProcess);
    }

    group('packageNameFromApk', () {
      test('returns null when aapt is not found', () async {
        when(() => androidSdk.aaptPath).thenReturn(null);
        final result = await runWithOverrides(
          () => smokeTester.packageNameFromApk(apk),
        );
        expect(result, isNull);
      });

      test('parses the package name from aapt badging output', () async {
        when(() => androidSdk.aaptPath).thenReturn('/sdk/aapt');
        when(
          () => process.run(
            any(),
            any(),
            useVendedFlutter: any(named: 'useVendedFlutter'),
          ),
        ).thenAnswer(
          (_) async => const QuickPatchProcessResult(
            exitCode: 0,
            stdout:
                "package: name='com.example.app' versionCode='1' "
                "versionName='1.0'",
            stderr: '',
          ),
        );
        final result = await runWithOverrides(
          () => smokeTester.packageNameFromApk(apk),
        );
        expect(result, equals('com.example.app'));
      });

      test('returns null when aapt exits non-zero', () async {
        when(() => androidSdk.aaptPath).thenReturn('/sdk/aapt');
        when(
          () => process.run(
            any(),
            any(),
            useVendedFlutter: any(named: 'useVendedFlutter'),
          ),
        ).thenAnswer(
          (_) async => const QuickPatchProcessResult(
            exitCode: 1,
            stdout: '',
            stderr: 'boom',
          ),
        );
        final result = await runWithOverrides(
          () => smokeTester.packageNameFromApk(apk),
        );
        expect(result, isNull);
      });
    });

    group('run', () {
      test('passes when the app reports a displayed first frame', () async {
        stubLogcat(
          Stream.fromIterable([
            'I/flutter: starting up',
            'I/ActivityManager: Displayed $packageName/.MainActivity: +400ms',
          ]),
        );
        final result = await runWithOverrides(
          () => smokeTester.run(apk: apk, packageName: packageName),
        );
        expect(result.passed, isTrue);
        verify(() => adb.installApk(apk, deviceId: null)).called(1);
        verify(() => adb.uninstall(package: packageName, deviceId: null))
            .called(1);
      });

      test('fails when the app crashes on startup', () async {
        stubLogcat(
          Stream.fromIterable([
            'I/flutter: starting up',
            'E/flutter: Unhandled Exception: Bad state: boom',
          ]),
        );
        final result = await runWithOverrides(
          () => smokeTester.run(apk: apk, packageName: packageName),
        );
        expect(result.passed, isFalse);
        expect(result.reason, contains('crashed on startup'));
        // Cleanup still runs.
        verify(() => adb.uninstall(package: packageName, deviceId: null))
            .called(1);
      });

      test('fails (timeout) when no frame is rendered in time', () async {
        stubLogcat(const Stream.empty());
        final result = await runWithOverrides(
          () => smokeTester.run(
            apk: apk,
            packageName: packageName,
            timeout: const Duration(milliseconds: 200),
          ),
        );
        expect(result.passed, isFalse);
        expect(result.reason, contains('did not render'));
      });

      test('fails when the apk cannot be installed', () async {
        when(() => adb.installApk(any(), deviceId: any(named: 'deviceId')))
            .thenThrow(Exception('no device'));
        final result = await runWithOverrides(
          () => smokeTester.run(apk: apk, packageName: packageName),
        );
        expect(result.passed, isFalse);
        expect(result.reason, contains('Failed to install'));
      });
    });
  });
}
