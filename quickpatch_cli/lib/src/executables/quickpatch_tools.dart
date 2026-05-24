import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';

/// A reference to a [QuickPatchTools] instance.
final quickpatchToolsRef = create(QuickPatchTools.new);

/// The [QuickPatchTools] instance available in the current zone.
QuickPatchTools get quickpatchTools => read(quickpatchToolsRef);

/// {@template package_failed_exception}
/// An exception thrown when packaging a patch fails.
/// {@endtemplate}
class PackageFailedException implements Exception {
  /// {@macro package_failed_exception}
  PackageFailedException(this.message);

  /// The error message.
  final String message;

  @override
  String toString() => message;
}

/// A wrapper around the `quickpatch_tools` executable.
///
/// Used to access many commands related to QuickPatch's flutter tooling.
class QuickPatchTools {
  /// Returns whether the current flutter version supports this tool.
  ///
  /// This should be used to check if the tool is supported before running
  /// any commands.
  bool isSupported() {
    return quickpatchToolsDirectory.existsSync();
  }

  /// The directory containing the `quickpatch_tools` package.
  Directory get quickpatchToolsDirectory {
    final dir = Directory(
      p.join(quickpatchEnv.flutterDirectory.path, 'packages', 'quickpatch_tools'),
    );
    return dir;
  }

  Future<QuickPatchProcessResult> _run(List<String> args) {
    return process.run(
      quickpatchEnv.dartBinaryFile.path,
      ['run', 'quickpatch_tools', 'package', ...args],
      workingDirectory: quickpatchToolsDirectory.path,
    );
  }

  /// Creates a package with the [patchPath] and writes it to [outputPath].
  ///
  /// Packages contains all the information needed by QuickPatch for an update.
  Future<void> package({
    required String patchPath,
    required String outputPath,
  }) async {
    final packageArguments = ['-p', patchPath, '-o', outputPath];

    final result = await _run(packageArguments);

    if (result.exitCode != ExitCode.success.code) {
      throw PackageFailedException('''
Failed to create package (exit code ${result.exitCode}).
  stdout: ${result.stdout}
  stderr: ${result.stderr}''');
    }
  }
}
