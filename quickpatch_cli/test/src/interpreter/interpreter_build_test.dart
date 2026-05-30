import 'package:quickpatch_cli/src/interpreter/interpreter_build.dart';
import 'package:test/test.dart';

void main() {
  group(InterpreterBuild, () {
    group('generateBootstrapperMain', () {
      test('imports the framework + dynamic_modules and loads the module', () {
        final src = InterpreterBuild.generateBootstrapperMain(
          frameworkImports: ['package:flutter/material.dart'],
        );
        expect(src, contains("import 'package:flutter/material.dart';"));
        expect(src, contains("import 'package:dynamic_modules/dynamic_modules.dart';"));
        expect(src, contains('loadModuleFromBytes(await _qpAppModuleBytes(args))'));
        // Must NOT import the app's own code (kept out of the AOT image).
        expect(src, isNot(contains('package:app/')));
      });

      test('asset mode defers byte-loading to the engine hook', () {
        final src = InterpreterBuild.generateBootstrapperMain(
          assetKey: 'assets/app.qpmod',
        );
        expect(src, contains('assets/app.qpmod'));
        expect(src, contains('UnimplementedError'));
        expect(src, isNot(contains("import 'dart:io';")));
      });

      test('argv mode reads the module path from argv[0]', () {
        final src = InterpreterBuild.generateBootstrapperMain(mode: 'argv');
        expect(src, contains("import 'dart:io';"));
        expect(src, contains('File(args[0]).readAsBytesSync()'));
      });

      test('supports multiple framework imports', () {
        final src = InterpreterBuild.generateBootstrapperMain(
          frameworkImports: [
            'package:flutter/material.dart',
            'package:flutter/widgets.dart',
          ],
        );
        expect(src, contains("import 'package:flutter/material.dart';"));
        expect(src, contains("import 'package:flutter/widgets.dart';"));
      });

      test('applyPatch wires loadModuleAsPatch on the live app', () {
        final src = InterpreterBuild.generateBootstrapperMain();
        expect(src, contains('_qpPatchBytes(args)'));
        expect(src, contains("loadModuleAsPatch(patch, '')"));
        expect(src, contains('if (patch != null)'));
      });

      test('applyPatch:false emits no patch path', () {
        final src = InterpreterBuild.generateBootstrapperMain(applyPatch: false);
        expect(src, isNot(contains('loadModuleAsPatch')));
        expect(src, isNot(contains('_qpPatchBytes')));
      });

      test('argv mode reads patch from argv[1]', () {
        final src = InterpreterBuild.generateBootstrapperMain(mode: 'argv');
        expect(src, contains('args.length < 2'));
        expect(src, contains('File(args[1]).readAsBytesSync()'));
      });

      test('ota mode downloads + applies the patch over HTTPS', () {
        final src = InterpreterBuild.generateBootstrapperMain(
          mode: 'ota',
          otaPatchUrl: 'https://cdn.example/patches/app/ios/latest.bytecode',
          appModuleAssetKey: 'assets/app.qpmod',
        );
        expect(src, contains("const _otaPatchUrl = 'https://cdn.example/patches/app/ios/latest.bytecode';"));
        expect(src, contains('WidgetsFlutterBinding.ensureInitialized()'));
        expect(src, contains("rootBundle.load('assets/app.qpmod')"));
        expect(src, contains('HttpClient()'));
        expect(src, contains("loadModuleAsPatch(patch, '')"));
        expect(src, contains('reassembleApplication()'));
        // OTA fetches over the network — must not read a bundled patch asset.
        expect(src, isNot(contains('app.patch')));
      });

      test('server mode routes OTA through the QuickPatch patch-check API', () {
        final src = InterpreterBuild.generateBootstrapperMain(
          mode: 'server',
          serverBaseUrl: 'https://qp.example/',
          appId: 'app-123',
          releaseVersion: '1.0.4+5',
        );
        expect(src, contains("const _base = 'https://qp.example';")); // trailing / stripped
        expect(src, contains("const _appId = 'app-123';"));
        expect(src, contains("const _releaseVersion = '1.0.4+5';"));
        expect(src, contains('/api/v1/patches/check'));
        expect(src, contains("body['patch_available']"));
        expect(src, contains("['download_url']"));
        // Shorebird-style: apply the STAGED patch at boot before the first
        // frame, and NEVER hot-swap the running session.
        expect(src, contains("loadModuleAsPatch(staged.bytes, '')"));
        expect(src, contains('_qpWriteStaged('));
        expect(src, contains('applied at boot'));
        expect(src, isNot(contains('reassembleApplication()')));
      });
    });

    group('dart2bytecodeArgs (patch)', () {
      test('compiles the changed app UNPREFIXED against the base import-dill', () {
        final args = InterpreterBuild.dart2bytecodeArgs(
          dart2bytecodeSnapshot: '/t/dart2bytecode.snapshot',
          platformDill: '/t/platform_strong.dill',
          packageConfig: '/t/package_config.json',
          importDill: '/t/base.dill',
          entry: 'package:app/main.dart',
          output: '/t/patch.bytecode',
        );
        expect(args.first, '/t/dart2bytecode.snapshot');
        expect(args, containsAll(['--target', 'flutter']));
        expect(args, containsAll(['--import-dill', '/t/base.dill']));
        expect(args, contains(InterpreterBuild.experimentFlag));
        // The merge-loader requires the patch to be UNPREFIXED.
        expect(args, isNot(contains('--prefix-library-uris')));
        expect(args.last, 'package:app/main.dart');
      });
    });

    group('genKernelArgs', () {
      test('threads the dynamic interface into the AOT bootstrapper compile', () {
        final args = InterpreterBuild.genKernelArgs(
          genKernelSnapshot: '/t/gen_kernel.snapshot',
          platformDill: '/t/platform_strong.dill',
          packageConfig: '/t/package_config.json',
          entry: '/t/qp_bootstrap_main.dart',
          output: '/t/qp_bootstrap.dill',
          dynamicInterfacePath: '/t/interface.yaml',
        );
        expect(args, containsAll(['--dynamic-interface', '/t/interface.yaml']));
        expect(args, isNot(contains('--no-link-platform')));
      });

      test('import-dill variant elides the linked platform', () {
        final args = InterpreterBuild.genKernelArgs(
          genKernelSnapshot: '/t/gen_kernel.snapshot',
          platformDill: '/t/platform_strong.dill',
          packageConfig: '/t/package_config.json',
          entry: '/t/qp_bootstrap_main.dart',
          output: '/t/qp_bootstrap_import.dill',
          noLinkPlatform: true,
        );
        expect(args, contains('--no-link-platform'));
      });
    });

    group('genInterfaceArgs', () {
      test('excludes the app package(s) from the framework interface', () {
        final args = InterpreterBuild.genInterfaceArgs(
          generatorScript: '/t/gen_dynamic_interface.dart',
          inputDill: '/t/base.dill',
          outputYaml: '/t/interface.yaml',
          appPackages: ['myapp', 'myapp_shared'],
        );
        expect(args, contains('--app-package=myapp'));
        expect(args, contains('--app-package=myapp_shared'));
      });
    });
  });
}
