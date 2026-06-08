import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:quickpatch_cli/src/interpreter/interpreter_build.dart';

/// Generates the `dynamic_modules` wrapper package under [buildDir] and returns
/// its root directory.
///
/// The interpreter bootstrapper imports `package:dynamic_modules`, whose
/// functions wrap the `dart:_internal` dynamic-module natives baked into the
/// engine's `platform_strong.dill`. The wrapper package itself ships nowhere,
/// so the CLI generates it (source = [InterpreterBuild.dynamicModulesLibrarySource]).
/// A `pubspec.yaml` is written too so the package can be consumed either via a
/// hand-built `package_config.json` ([prepareDynamicModulesPackageConfig]) or as
/// a pub `path:` dependency ([addDynamicModulesPathDependency]).
String writeDynamicModulesPackage(String buildDir) {
  final pkgRoot = Directory(p.join(buildDir, 'qp_dynamic_modules'));
  final libDir = Directory(p.join(pkgRoot.path, 'lib'))
    ..createSync(recursive: true);
  File(p.join(libDir.path, 'dynamic_modules.dart'))
      .writeAsStringSync(InterpreterBuild.dynamicModulesLibrarySource);
  File(p.join(pkgRoot.path, 'pubspec.yaml')).writeAsStringSync(
    'name: dynamic_modules\n'
    'publish_to: none\n'
    'environment:\n'
    "  sdk: '>=3.0.0 <4.0.0'\n",
  );
  return pkgRoot.path;
}

/// Makes `package:dynamic_modules` resolvable to the standalone interpreter
/// toolchain steps (gen_kernel / dart2bytecode) without touching the project.
///
/// Generates the wrapper under [buildDir] and writes an augmented COPY of the
/// project's [packageConfigPath] that maps `dynamic_modules` at it. Returns the
/// path of the augmented package_config. The project's own
/// `.dart_tool/package_config.json` is left untouched.
///
/// Used by the PATCH path (which never invokes `flutter build`). The RELEASE
/// path instead uses [addDynamicModulesPathDependency] so the `flutter build
/// ipa` subprocess — which compiles the bootstrapper via the project's own
/// package_config — can resolve the import as well.
String prepareDynamicModulesPackageConfig({
  required String buildDir,
  required String packageConfigPath,
}) {
  final pkgRoot = writeDynamicModulesPackage(buildDir);

  final original = File(packageConfigPath);
  final config = jsonDecode(original.readAsStringSync()) as Map<String, dynamic>;
  // `rootUri` is relative to the ORIGINAL config's directory. The copy lives in
  // a different directory (the build dir), so rebase every relative rootUri to
  // absolute — otherwise the app's own `package:<app>/...` imports resolve
  // against the wrong base (e.g. `../` -> build/ instead of the project root).
  final originalDirUri = Directory(p.dirname(packageConfigPath)).uri;
  final packages = (config['packages'] as List).cast<Map<String, dynamic>>()
    ..removeWhere((e) => e['name'] == 'dynamic_modules');
  for (final pkg in packages) {
    final rootUri = pkg['rootUri'] as String?;
    if (rootUri != null) {
      pkg['rootUri'] = originalDirUri.resolve(rootUri).toString();
    }
  }
  packages.add(<String, dynamic>{
    'name': 'dynamic_modules',
    'rootUri': Directory(pkgRoot).uri.toString(),
    'packageUri': 'lib/',
    'languageVersion': '3.12',
  });
  config['packages'] = packages;

  final out = File(p.join(buildDir, 'qp_package_config.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(config));
  return out.path;
}

/// Generates the wrapper package and adds it to [pubspec]'s `dependencies:` as a
/// `path:` dependency (idempotent), so a subsequent `flutter pub get` — and the
/// implicit one inside `flutter build ipa` — resolves `package:dynamic_modules`
/// from the project's real `package_config.json`.
///
/// Used by the RELEASE path. Caller is responsible for restoring the pubspec
/// afterwards (the releaser already backs it up and restores).
void addDynamicModulesPathDependency({
  required File pubspec,
  required String buildDir,
}) {
  final pkgRoot = writeDynamicModulesPackage(buildDir);
  var text = pubspec.readAsStringSync();
  if (text.contains('\n  dynamic_modules:')) return;
  text = text.replaceFirstMapped(
    RegExp(r'(\ndependencies:[ \t]*\n)'),
    (m) => '${m[1]}  dynamic_modules:\n    path: $pkgRoot\n',
  );
  pubspec.writeAsStringSync(text);
}
