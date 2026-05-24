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
    }
  }

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
    }
  }

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
