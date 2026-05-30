import 'dart:io';

import 'package:quickpatch_cli/src/interpreter/interpreter_build.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';

/// {@template interpreter_patch_exception}
/// Thrown when building an interpreter (bytecode) patch fails.
/// {@endtemplate}
class InterpreterPatchException implements Exception {
  /// {@macro interpreter_patch_exception}
  InterpreterPatchException(this.message);

  /// A human-readable description of the failure.
  final String message;

  @override
  String toString() => 'InterpreterPatchException: $message';
}

/// {@template interpreter_patcher}
/// Builds an iOS arbitrary-code-push (bytecode) patch by compiling the changed
/// app Dart to an UNPREFIXED `dart2bytecode` module against the release's base
/// bootstrapper kernel. The on-device same-URI merge-loader then swaps the
/// changed functions onto the live app (proven host-side, proofs 2-9).
///
/// This is the code-change counterpart to the existing data-only AOT-diff path
/// in [`IosPatcher`]: instead of being blocked by the data-only gate, a code
/// change ships as a tiny (~1-2 KB) bytecode patch loaded via the interpreter.
///
/// The process runner is injected so the orchestration is unit-testable
/// without the toolchain. Toolchain paths come from the interpreter-capable
/// QuickPatch engine bundle (resolved by the caller via `quickpatchArtifacts`).
/// {@endtemplate}
class InterpreterPatcher {
  /// {@macro interpreter_patcher}
  InterpreterPatcher({
    required this.process,
    required this.aotRuntimePath,
    required this.dart2bytecodeSnapshotPath,
    required this.platformDillPath,
  });

  /// Runner for the `dartaotruntime` invocation (injectable for tests).
  final QuickPatchProcess process;

  /// `dartaotruntime` that executes the dart2bytecode snapshot.
  final String aotRuntimePath;

  /// The `dart2bytecode.dart.snapshot` (interpreter toolchain).
  final String dart2bytecodeSnapshotPath;

  /// The Flutter `platform_strong.dill` matching the engine revision.
  final String platformDillPath;

  /// Compiles [entry] (the changed app entry/library) to an UNPREFIXED
  /// bytecode patch at [outputPath], referencing the framework supplied by
  /// [importDillPath] (the release's base bootstrapper kernel). Returns the
  /// produced patch file.
  ///
  /// Throws [InterpreterPatchException] if dart2bytecode fails or no patch is
  /// produced.
  Future<File> buildBytecodePatch({
    required String packageConfigPath,
    required String importDillPath,
    required String entry,
    required String outputPath,
  }) async {
    final args = InterpreterBuild.dart2bytecodeArgs(
      dart2bytecodeSnapshot: dart2bytecodeSnapshotPath,
      platformDill: platformDillPath,
      packageConfig: packageConfigPath,
      importDill: importDillPath,
      entry: entry,
      output: outputPath,
      product: true,
    );

    final result = await process.run(aotRuntimePath, args);
    if (result.exitCode != 0) {
      throw InterpreterPatchException(
        'dart2bytecode failed (exit ${result.exitCode}): ${result.stderr}',
      );
    }

    final out = File(outputPath);
    if (!out.existsSync()) {
      throw InterpreterPatchException(
        'dart2bytecode reported success but no patch was produced at '
        '$outputPath',
      );
    }
    return out;
  }
}
