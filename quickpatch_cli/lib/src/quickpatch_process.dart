import 'dart:async';
import 'dart:io';

import 'package:mason_logger/mason_logger.dart';
import 'package:meta/meta.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/engine_config.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/platform.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';

/// A reference to a [QuickPatchProcess] instance.
final processRef = create(QuickPatchProcess.new);

/// The [QuickPatchProcess] instance available in the current zone.
QuickPatchProcess get process => read(processRef);

/// A wrapper around [Process] that replaces executables to QuickPatch-vended
/// versions.
// This may need a better name, since it returns "Process" it's more a
// "ProcessFactory" than a "Process".
class QuickPatchProcess {
  /// Creates a QuickPatchProcess.
  QuickPatchProcess({
    ProcessWrapper? processWrapper, // For mocking QuickPatchProcess.
  }) : processWrapper = processWrapper ?? ProcessWrapper();

  /// The underlying process wrapper.
  final ProcessWrapper processWrapper;

  /// Starts a process, streams the output in real-time, and returns the exit
  /// code.
  ///
  /// Uses `ProcessStartMode.inheritStdio` so the child (flutter, gradlew,
  /// gen_snapshot) shares our terminal fds and can render its spinner + ANSI
  /// output the way users expect. The cost: the child's bytes never pass
  /// through the `LoggingStdout` `IOOverrides` installed in
  /// `bin/quickpatch.dart`, so `flutter build` stderr is absent from the
  /// quickpatch log file — on a build failure users see the real error on
  /// screen but the log only has `Failed to build AAB. Exited with code 1`
  /// (https://github.com/letssuhail/quickpatch/issues/3703). Piping
  /// through Dart would capture stderr but turns `stdout.hasTerminal` false
  /// on the child side, regressing the interactive UX; a pty or per-fd
  /// shell tee would fix both but costs a dependency / POSIX-only path.
  /// Accepting the logging gap for now.
  Future<int> stream(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool? runInShell,
    String? workingDirectory,
    void Function(Process process)? onStart,
  }) async {
    final process = await start(
      executable,
      arguments,
      environment: environment,
      runInShell: runInShell,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.inheritStdio,
    );
    onStart?.call(process);
    return process.exitCode;
  }

  /// Runs the process and returns the result.
  Future<QuickPatchProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool? runInShell,
    String? workingDirectory,
    bool useVendedFlutter = true,
  }) async {
    final resolvedEnvironment = _resolveEnvironment(
      environment,
      executable: executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedExecutable = _resolveExecutable(
      executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedArguments = _resolveArguments(
      executable,
      arguments,
      useVendedFlutter: useVendedFlutter,
    );
    logger.detail(
      '''[Process.run] $resolvedExecutable ${resolvedArguments.join(' ')}${workingDirectory == null ? '' : ' (in $workingDirectory)'}''',
    );

    final result = await processWrapper.run(
      resolvedExecutable,
      resolvedArguments,
      workingDirectory: workingDirectory,
      environment: resolvedEnvironment,
      runInShell: runInShell,
    );

    _logResult(result);

    return result;
  }

  /// Runs the process synchronously and returns the result.
  QuickPatchProcessResult runSync(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
    bool useVendedFlutter = true,
  }) {
    final resolvedEnvironment = _resolveEnvironment(
      environment,
      executable: executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedExecutable = _resolveExecutable(
      executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedArguments = _resolveArguments(
      executable,
      arguments,
      useVendedFlutter: useVendedFlutter,
    );
    logger.detail(
      '''[Process.runSync] $resolvedExecutable ${resolvedArguments.join(' ')}${workingDirectory == null ? '' : ' (in $workingDirectory)'}''',
    );

    final result = processWrapper.runSync(
      resolvedExecutable,
      resolvedArguments,
      workingDirectory: workingDirectory,
      environment: resolvedEnvironment,
    );

    _logResult(result);

    return result;
  }

  /// Starts a new process running the executable with the specified arguments.
  Future<Process> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool useVendedFlutter = true,
    bool? runInShell,
    String? workingDirectory,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    final resolvedEnvironment = environment ?? {};
    if (useVendedFlutter) {
      // Note: this will overwrite existing environment values.
      resolvedEnvironment.addAll(_environmentOverrides(executable: executable));
    }
    final resolvedExecutable = _resolveExecutable(
      executable,
      useVendedFlutter: useVendedFlutter,
    );
    final resolvedArguments = _resolveArguments(
      executable,
      arguments,
      useVendedFlutter: useVendedFlutter,
    );
    logger.detail(
      '''[Process.start] $resolvedExecutable ${resolvedArguments.join(' ')}${workingDirectory == null ? '' : ' (in $workingDirectory)'}''',
    );

    return processWrapper.start(
      resolvedExecutable,
      resolvedArguments,
      environment: resolvedEnvironment,
      runInShell: runInShell,
      workingDirectory: workingDirectory,
      mode: mode,
    );
  }

  Map<String, String> _resolveEnvironment(
    Map<String, String>? baseEnvironment, {
    required String executable,
    required bool useVendedFlutter,
  }) {
    final resolvedEnvironment = baseEnvironment ?? {};
    if (useVendedFlutter) {
      // Note: this will overwrite existing environment values.
      resolvedEnvironment.addAll(_environmentOverrides(executable: executable));
    }

    return resolvedEnvironment;
  }

  String _resolveExecutable(
    String executable, {
    required bool useVendedFlutter,
  }) {
    if (useVendedFlutter && executable == 'flutter') {
      return _sanitizeExecutablePath(quickpatchEnv.flutterBinaryFile.path);
    }
    return _sanitizeExecutablePath(executable);
  }

  /// Sanitizes the executable path on Windows.
  /// https://github.com/dart-lang/sdk/issues/37751
  String _sanitizeExecutablePath(String executable) {
    if (executable.isEmpty) return executable;
    if (!platform.isWindows) return executable;
    if (executable.contains(' ') && !executable.contains('"')) {
      // Use quoted strings to indicate where the file name ends and the
      // arguments begin; otherwise, the file name is ambiguous.
      return '"$executable"';
    }
    return executable;
  }

  List<String> _resolveArguments(
    String executable,
    List<String> arguments, {
    required bool useVendedFlutter,
  }) {
    var resolvedArguments = arguments;
    if (executable == 'flutter') {
      if (logger.level == Level.verbose) {
        /// We explicitly add the `--verbose` flag to flutter commands when the
        /// quickpatch command was run with `--verbose`
        /// (e.g. `quickpatch release ios --verbose`).
        resolvedArguments = [...resolvedArguments, '--verbose'];
      }
      if (useVendedFlutter && engineConfig.localEngine != null) {
        resolvedArguments = [
          '--local-engine-src-path=${engineConfig.localEngineSrcPath}',
          '--local-engine=${engineConfig.localEngine}',
          '--local-engine-host=${engineConfig.localEngineHost}',
          ...resolvedArguments,
        ];
      }
    }

    return resolvedArguments;
  }

  void _logResult(QuickPatchProcessResult result) {
    logger.detail('Exited with code ${result.exitCode}');

    final stdout = result.stdout as String?;
    if (stdout != null && stdout.isNotEmpty) {
      logger.detail('''

stdout:
$stdout''');
    }

    final stderr = result.stderr as String?;
    if (stderr != null && stderr.isNotEmpty) {
      logger.detail('''

stderr:
$stderr''');
    }
  }

  Map<String, String> _environmentOverrides({required String executable}) {
    if (executable == 'flutter') {
      // If this ever changes we also need to update the `quickpatch` shell
      // wrapper which downloads runs Flutter to fetch artifacts the first time.
      //
      // QuickPatch: when QUICKPATCH_STORAGE_BASE_URL is set, route Flutter's
      // engine downloads through our R2 mirror (mirror serves the
      // download.quickpatch.dev bucket under that path).
      // Resolve storage base: explicit override → derive from hosted URL → GCS.
      final hostedUrl = platform.environment['QUICKPATCH_HOSTED_URL'];
      final mirror =
          platform.environment['QUICKPATCH_STORAGE_BASE_URL'] ??
          (hostedUrl != null ? '$hostedUrl/storage' : null);
      final flutterStorageBaseUrl = mirror != null
          ? '$mirror/download.quickpatch.dev'
          : 'https://download.quickpatch.dev';
      return {'FLUTTER_STORAGE_BASE_URL': flutterStorageBaseUrl};
    }

    return {};
  }
}

/// Result from running a process.
class QuickPatchProcessResult {
  /// Creates a new [QuickPatchProcessResult].
  const QuickPatchProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// The exit code of the process.
  final int exitCode;

  /// The standard output of the process.
  final dynamic stdout;

  /// The standard error of the process.
  final dynamic stderr;
}

/// A wrapper around [Process] that can be mocked for testing.
// coverage:ignore-start
@visibleForTesting
class ProcessWrapper {
  /// Runs the process and returns the result.
  Future<QuickPatchProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
    bool? runInShell,
  }) async {
    final result = await Process.run(
      executable,
      arguments,
      environment: environment,
      // TODO(felangel): refactor to never runInShell
      runInShell: runInShell ?? Platform.isWindows,
      workingDirectory: workingDirectory,
    );
    return QuickPatchProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  /// Runs the process synchronously and returns the result.
  QuickPatchProcessResult runSync(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    String? workingDirectory,
  }) {
    final result = Process.runSync(
      executable,
      arguments,
      environment: environment,
      runInShell: Platform.isWindows,
      workingDirectory: workingDirectory,
    );
    return QuickPatchProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }

  /// Starts a new process running the executable with the specified arguments.
  Future<Process> start(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
    bool? runInShell,
    String? workingDirectory,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) {
    return Process.start(
      executable,
      arguments,
      // TODO(felangel): refactor to never runInShell
      runInShell: runInShell ?? Platform.isWindows,
      environment: environment,
      workingDirectory: workingDirectory,
      mode: mode,
    );
  }
}

// coverage:ignore-end
