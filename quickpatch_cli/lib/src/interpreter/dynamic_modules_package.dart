import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:quickpatch_cli/src/interpreter/interpreter_build.dart';

/// Makes `package:dynamic_modules` resolvable to the interpreter toolchain.
///
/// The interpreter bootstrapper imports `package:dynamic_modules`, whose
/// functions wrap the `dart:_internal` dynamic-module natives baked into the
/// engine's `platform_strong.dill`. The wrapper package itself ships nowhere,
/// so the CLI generates it ([InterpreterBuild.dynamicModulesLibrarySource])
/// under [buildDir] and writes an augmented copy of the project's
/// [packageConfigPath] that maps `dynamic_modules` at it.
///
/// Returns the path of the augmented package_config to hand to gen_kernel /
/// dart2bytecode. The project's own `.dart_tool/package_config.json` is left
/// untouched, so this is safe to run before or after `flutter pub get`.
String prepareDynamicModulesPackageConfig({
  required String buildDir,
  required String packageConfigPath,
}) {
  // 1. Generate the wrapper package source under the build dir.
  final pkgRoot = Directory(p.join(buildDir, 'qp_dynamic_modules'));
  final libDir = Directory(p.join(pkgRoot.path, 'lib'))
    ..createSync(recursive: true);
  File(p.join(libDir.path, 'dynamic_modules.dart'))
      .writeAsStringSync(InterpreterBuild.dynamicModulesLibrarySource);

  // 2. Copy the project package_config, adding/replacing the dynamic_modules
  //    entry pointing at the generated package.
  final original = File(packageConfigPath);
  final config = jsonDecode(original.readAsStringSync()) as Map<String, dynamic>;
  final packages = (config['packages'] as List).cast<Map<String, dynamic>>()
    ..removeWhere((e) => e['name'] == 'dynamic_modules');
  packages.add(<String, dynamic>{
    'name': 'dynamic_modules',
    'rootUri': pkgRoot.uri.toString(),
    'packageUri': 'lib/',
    'languageVersion': '3.12',
  });
  config['packages'] = packages;

  final out = File(p.join(buildDir, 'qp_package_config.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(config));
  return out.path;
}
