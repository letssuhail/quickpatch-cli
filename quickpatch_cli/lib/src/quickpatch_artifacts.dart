// Allowing one member abstracts for consistency/namespace/ease of testing.
// ignore_for_file: one_member_abstracts

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/cache.dart';
import 'package:quickpatch_cli/src/engine_config.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';

/// All QuickPatch artifacts used explicitly by QuickPatch.
enum QuickPatchArtifact {
  /// The iOS analyze_snapshot executable.
  analyzeSnapshotIos,

  /// The macOS analyze_snapshot executable.
  analyzeSnapshotMacOS,

  /// The aot_tools executable or kernel file.
  aotTools,

  /// The gen_snapshot executable for iOS.
  genSnapshotIos,

  /// The gen_snapshot executable for macOS that creates arm64 snapshots.
  genSnapshotMacosArm64,

  /// The gen_snapshot executable for macOS that creates x64 snapshots.
  genSnapshotMacosX64,

  /// The dart2bytecode snapshot (interpreter code-push: compiles changed app
  /// Dart to a bytecode patch module). Shipped in the iOS engine bundle.
  dart2bytecodeIos,

  /// The gen_kernel_aot snapshot for the interpreter path (compiles the
  /// bootstrapper/app to kernel). Shipped in the iOS engine bundle.
  genKernelIos,

  /// The Flutter platform_strong.dill matching the engine revision (used by
  /// dart2bytecode/gen_kernel for the interpreter path).
  flutterPlatformDillIos,

  /// The dynamic_interface generator script (emits the framework interface for
  /// the interpreter base build). Shipped in the iOS engine bundle.
  genInterfaceScriptIos,

  /// The dartaotruntime that runs the interpreter snapshots (dart2bytecode /
  /// gen_kernel). Must match the engine revision. Shipped in the iOS bundle.
  dartAotRuntimeIos,

  /// The dynamic_interface generator compiled to an AOT snapshot (runs via
  /// dartAotRuntimeIos; bundles package:kernel). Emits the framework interface.
  genInterfaceAotIos,
}

/// A reference to a [QuickPatchArtifacts] instance.
final quickpatchArtifactsRef = create<QuickPatchArtifacts>(
  QuickPatchCachedArtifacts.new,
);

/// The [QuickPatchArtifacts] instance available in the current zone.
QuickPatchArtifacts get quickpatchArtifacts => read(quickpatchArtifactsRef);

/// {@template quickpatch_artifacts}
/// A class that provides access to QuickPatch artifacts.
/// {@endtemplate}
abstract class QuickPatchArtifacts {
  /// Returns the path to the given [artifact].
  String getArtifactPath({required QuickPatchArtifact artifact});
}

/// {@template quickpatch_cached_artifacts}
/// A class that provides access to cached QuickPatch artifacts.
/// {@endtemplate}
class QuickPatchCachedArtifacts implements QuickPatchArtifacts {
  /// {@macro quickpatch_cached_artifacts}
  const QuickPatchCachedArtifacts();

  @override
  String getArtifactPath({required QuickPatchArtifact artifact}) {
    switch (artifact) {
      case QuickPatchArtifact.analyzeSnapshotIos:
        return _analyzeSnapshotIosFile.path;
      case QuickPatchArtifact.analyzeSnapshotMacOS:
        return _analyzeSnapshotMacosFile.path;
      case QuickPatchArtifact.aotTools:
        return _aotToolsFile.path;
      case QuickPatchArtifact.genSnapshotIos:
        return _genSnapshotIosFile.path;
      case QuickPatchArtifact.genSnapshotMacosArm64:
        return _genSnapshotMacOsArm64File.path;
      case QuickPatchArtifact.genSnapshotMacosX64:
        return _genSnapshotMacOsX64File.path;
      case QuickPatchArtifact.dart2bytecodeIos:
        return _iosEngineFile('dart2bytecode.dart.snapshot').path;
      case QuickPatchArtifact.genKernelIos:
        return _iosEngineFile('gen_kernel_aot.dart.snapshot').path;
      case QuickPatchArtifact.flutterPlatformDillIos:
        return _iosEngineFile('platform_strong.dill').path;
      case QuickPatchArtifact.genInterfaceScriptIos:
        return _iosEngineFile('gen_dynamic_interface.dart').path;
      case QuickPatchArtifact.dartAotRuntimeIos:
        return _iosEngineFile('dartaotruntime').path;
      case QuickPatchArtifact.genInterfaceAotIos:
        return _iosEngineFile('gen_dynamic_interface.aot').path;
    }
  }

  /// A file installed into the iOS engine cache dir
  /// (bin/cache/artifacts/engine/ios-release) by [ensureQuickPatchIosEngine].
  File _iosEngineFile(String name) => File(
    p.join(
      quickpatchEnv.flutterDirectory.path,
      'bin',
      'cache',
      'artifacts',
      'engine',
      'ios-release',
      name,
    ),
  );

  File get _analyzeSnapshotIosFile {
    return File(
      p.join(
        quickpatchEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'ios-release',
        'analyze_snapshot_arm64',
      ),
    );
  }

  File get _analyzeSnapshotMacosFile {
    return File(
      p.join(
        quickpatchEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'darwin-x64-release',
        'analyze_snapshot',
      ),
    );
  }

  File get _aotToolsFile {
    const executableName = 'aot-tools';
    final kernelFile = File(
      p.join(
        cache.getArtifactDirectory(executableName).path,
        quickpatchEnv.quickpatchEngineRevision,
        '$executableName.dill',
      ),
    );
    if (kernelFile.existsSync()) {
      return kernelFile;
    }

    // We shipped aot-tools as an executable in the past, so we return that if
    // no kernel file is found.
    return File(
      p.join(
        cache.getArtifactDirectory(executableName).path,
        quickpatchEnv.quickpatchEngineRevision,
        executableName,
      ),
    );
  }

  File get _genSnapshotIosFile {
    return File(
      p.join(
        quickpatchEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'ios-release',
        'gen_snapshot_arm64',
      ),
    );
  }

  File get _genSnapshotMacOsArm64File {
    return File(
      p.join(
        quickpatchEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'darwin-x64-release',
        'gen_snapshot_arm64',
      ),
    );
  }

  File get _genSnapshotMacOsX64File {
    return File(
      p.join(
        quickpatchEnv.flutterDirectory.path,
        'bin',
        'cache',
        'artifacts',
        'engine',
        'darwin-x64-release',
        'gen_snapshot_x64',
      ),
    );
  }
}

/// {@template quickpatch_local_engine_artifacts}
/// A class that provides access to locally built QuickPatch artifacts.
/// {@endtemplate}
class QuickPatchLocalEngineArtifacts implements QuickPatchArtifacts {
  /// {@macro quickpatch_local_engine_artifacts}
  const QuickPatchLocalEngineArtifacts();

  @override
  String getArtifactPath({required QuickPatchArtifact artifact}) {
    switch (artifact) {
      case QuickPatchArtifact.analyzeSnapshotIos:
        return _analyzeSnapshotIosFile.path;
      case QuickPatchArtifact.analyzeSnapshotMacOS:
        return _analyzeSnapshotMacosFile.path;
      case QuickPatchArtifact.aotTools:
        return _aotToolsFile.path;
      case QuickPatchArtifact.genSnapshotIos:
        return _genSnapshotIosFile.path;
      case QuickPatchArtifact.genSnapshotMacosArm64:
        return _genSnapshotMacosArm64File.path;
      case QuickPatchArtifact.genSnapshotMacosX64:
        return _genSnapshotMacosX64File.path;
      case QuickPatchArtifact.dart2bytecodeIos:
        return _hostOutFile('dart-sdk/bin/snapshots/dart2bytecode.dart.snapshot')
            .path;
      case QuickPatchArtifact.genKernelIos:
        return _hostOutFile(
          'dart-sdk/bin/snapshots/gen_kernel_aot.dart.snapshot',
        ).path;
      case QuickPatchArtifact.flutterPlatformDillIos:
        return _hostOutFile('flutter_patched_sdk/platform_strong.dill').path;
      case QuickPatchArtifact.genInterfaceScriptIos:
        // Dev-only: the generator script is not part of the engine out; pass
        // it explicitly when driving the interpreter path with --local-engine.
        throw UnsupportedError(
          'genInterfaceScriptIos is not resolvable via --local-engine; '
          'use the cached engine bundle or pass the script path directly.',
        );
      case QuickPatchArtifact.dartAotRuntimeIos:
        return _hostOutFile('dart-sdk/bin/dartaotruntime').path;
      case QuickPatchArtifact.genInterfaceAotIos:
        return _hostOutFile('gen_dynamic_interface.aot').path;
    }
  }

  /// A file in the local HOST engine out (where the interpreter build tools
  /// dart2bytecode/gen_kernel/platform live), e.g. mac_debug_unopt_arm64.
  File _hostOutFile(String relativePath) => File(
    p.join(
      engineConfig.localEngineSrcPath!,
      'out',
      engineConfig.localEngineHost,
      relativePath,
    ),
  );

  File get _analyzeSnapshotIosFile {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'clang_x64',
        'analyze_snapshot_arm64',
      ),
    );
  }

  File get _analyzeSnapshotMacosFile {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'clang_x64',
        'analyze_snapshot',
      ),
    );
  }

  File get _aotToolsFile {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'flutter',
        'third_party',
        'dart',
        'pkg',
        'aot_tools',
        'bin',
        'aot_tools.dart',
      ),
    );
  }

  File get _genSnapshotIosFile {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'clang_x64',
        'gen_snapshot_arm64',
      ),
    );
  }

  File get _genSnapshotMacosArm64File {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'artifacts_arm64',
        'gen_snapshot',
      ),
    );
  }

  File get _genSnapshotMacosX64File {
    return File(
      p.join(
        engineConfig.localEngineSrcPath!,
        'out',
        engineConfig.localEngine,
        'artifacts_x64',
        'gen_snapshot',
      ),
    );
  }
}
