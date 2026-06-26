import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/android_sdk.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';

/// A reference to a [Adb] instance.
final adbRef = create(Adb.new);

/// The [Adb] instance available in the current zone.
Adb get adb => read(adbRef);

/// A wrapper around the `adb` command.
class Adb {
  Future<QuickPatchProcessResult> _exec(String command) async {
    final adbPath = androidSdk.adbPath;
    if (adbPath == null) throw Exception('Unable to locate adb.');

    return process.run(adbPath, command.split(' '));
  }

  Future<Process> _stream(String command) async {
    final adbPath = androidSdk.adbPath;
    if (adbPath == null) throw Exception('Unable to locate adb.');

    return process.start(adbPath, command.split(' '));
  }

  /// Clears the app data for the given [package] name.
  Future<void> clearAppData({required String package, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'shell',
      'pm',
      'clear',
      package,
    ];
    final result = await _exec(args.join(' '));
    if (result.exitCode != 0) {
      throw Exception('Unable to clear app data: ${result.stderr}');
    }
  }

  /// Starts the app with the given [package] name.
  Future<void> startApp({required String package, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'shell',
      'monkey',
      // Adjust percentage of "system" key events to 0.
      // This is needed to support Android systems with no hardware keys.
      '--pct-syskeys 0',
      '-p $package',
      '1',
    ];
    final result = await _exec(args.join(' '));
    if (result.exitCode != 0) {
      throw Exception('Unable to start app: ${result.stderr}');
    }
  }

  /// Runs `adb logcat`.
  ///
  /// When [filter] is provided it is passed as `-s <filter>` (tag filter).
  /// Omit it to stream all logs (needed to observe system tags such as
  /// `ActivityManager`).
  Future<Process> logcat({String? filter, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'logcat',
      // This arg prevents old logs from being displayed.
      ...['-T', '1'],
      if (filter != null) ...['-s', filter],
    ];
    return _stream(args.join(' '));
  }

  /// Returns the ids of currently-connected devices/emulators (those in the
  /// `device` state). Empty when none are connected.
  Future<List<String>> connectedDevices() async {
    final result = await _exec('devices');
    if (result.exitCode != 0) return [];
    return const LineSplitter()
        .convert('${result.stdout}')
        .skip(1) // Skip the "List of devices attached" header.
        .map((line) => line.trim())
        .where((line) => line.endsWith('\tdevice'))
        .map((line) => line.split('\t').first.trim())
        .where((id) => id.isNotEmpty)
        .toList();
  }

  /// Installs (or reinstalls, with `-r`) the given [apk] on a device.
  Future<void> installApk(File apk, {String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'install',
      '-r',
      apk.path,
    ];
    final result = await _exec(args.join(' '));
    if (result.exitCode != 0) {
      throw Exception('Unable to install apk: ${result.stderr}');
    }
  }

  /// Uninstalls the app with the given [package] name. Never throws (best
  /// effort cleanup).
  Future<void> uninstall({required String package, String? deviceId}) async {
    final args = [
      if (deviceId != null) ...['-s', deviceId],
      'uninstall',
      package,
    ];
    await _exec(args.join(' '));
  }
}
