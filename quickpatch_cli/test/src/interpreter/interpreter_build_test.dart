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
        // frame (full-module load), and NEVER hot-swap the running session.
        expect(src, contains('loadModuleFromBytes(staged.bytes)'));
        expect(src, contains('_qpWriteStaged('));
        expect(src, contains('loaded at boot'));
        expect(src, isNot(contains('reassembleApplication()')));
        // The interpreter flow reports its own download/install telemetry
        // (the native binary-diff updater never sees these module patches).
        expect(src, contains('/api/v1/patches/events'));
        expect(src, contains("_qpReportEvent('__patch_download__'"));
        expect(src, contains("_qpReportEvent('__patch_install__'"));
        expect(src, contains("'client_id': _qpClientId()"));
        // The patch-check request must carry the same per-install client id —
        // the server buckets staged rollouts per device from it; without it
        // every iOS device lands in one bucket and percent rollouts are
        // all-or-nothing. Assert it appears in the CHECK body specifically.
        final checkBody = src.substring(
          src.indexOf('/api/v1/patches/check'),
          src.indexOf('current_patch_number'),
        );
        expect(checkBody, contains("'client_id': _qpClientId()"));
      });

      test(
          'REGRESSION (1.6.132): server bootstrapper import set is FROZEN — '
          'a new import changes the base library graph and breaks patch '
          'loading unless the patcher extraImports mirror is updated in '
          'lockstep + device-verified', () {
        final src = InterpreterBuild.generateBootstrapperMain(
          mode: 'server',
          serverBaseUrl: 'https://qp.example',
          appId: 'app-123',
          releaseVersion: '1.0.0+1',
          appUsesCodePush: true,
          publicKeyBase64: 'PRIMARYKEY',
        );
        final imports = src
            .split('\n')
            .where((l) => l.startsWith('import '))
            .toList();
        expect(imports, [
          "import 'dart:convert';",
          "import 'dart:io';",
          "import 'dart:typed_data';",
          "import 'package:flutter/material.dart';",
          "import 'package:flutter/services.dart' show rootBundle;",
          "import 'package:dynamic_modules/dynamic_modules.dart';",
          "import 'package:asn1lib/asn1lib.dart' as asn1;",
          "import 'package:crypto/crypto.dart' as crypto;",
          "import 'package:pointycastle/pointycastle.dart' as pc;",
          "import 'package:quickpatch_code_push/quickpatch_code_push.dart' as qpcp;",
        ]);
      });

      test('server mode with appUsesCodePush imports + retains '
          'quickpatch_code_push (so its FFI/isolate surface stays in the base)',
          () {
        final src = InterpreterBuild.generateBootstrapperMain(
          mode: 'server',
          serverBaseUrl: 'https://qp.example',
          appId: 'app-123',
          releaseVersion: '1.0.0+1',
          appUsesCodePush: true,
        );
        expect(
          src,
          contains(
              "import 'package:quickpatch_code_push/quickpatch_code_push.dart' as qpcp;"),
        );
        expect(src, contains("@pragma('vm:entry-point')"));
        expect(src, contains('qpcp.QuickPatchUpdater()'));
      });

      test('server mode WITHOUT appUsesCodePush does not import '
          'quickpatch_code_push (default)', () {
        final src = InterpreterBuild.generateBootstrapperMain(
          mode: 'server',
          serverBaseUrl: 'https://qp.example',
          appId: 'app-123',
          releaseVersion: '1.0.0+1',
        );
        expect(src, isNot(contains('quickpatch_code_push')));
      });

      test('server mode bakes the primary key into the trusted-key list', () {
        final src = InterpreterBuild.generateBootstrapperMain(
          mode: 'server',
          serverBaseUrl: 'https://qp.example',
          appId: 'app-123',
          releaseVersion: '1.0.0+1',
          publicKeyBase64: 'PRIMARYKEY',
        );
        expect(src, contains("const _publicKeysB64 = <String>['PRIMARYKEY'];"));
      });

      test('server mode bakes rotation keys (primary first) for rotation', () {
        final src = InterpreterBuild.generateBootstrapperMain(
          mode: 'server',
          serverBaseUrl: 'https://qp.example',
          appId: 'app-123',
          releaseVersion: '1.0.0+1',
          publicKeyBase64: 'PRIMARYKEY',
          rotationPublicKeysBase64: ['ROTKEY1', 'ROTKEY2'],
        );
        expect(
          src,
          contains(
            "const _publicKeysB64 = <String>['PRIMARYKEY', 'ROTKEY1', 'ROTKEY2'];",
          ),
        );
        // The verify helper iterates the list (any-match), not a single key.
        expect(src, contains('for (final key in keys)'));
        expect(src, isNot(contains('_publicKeyB64')));
      });

      test('server mode with no key emits an empty trusted-key list (unsigned)',
          () {
        final src = InterpreterBuild.generateBootstrapperMain(
          mode: 'server',
          serverBaseUrl: 'https://qp.example',
          appId: 'app-123',
          releaseVersion: '1.0.0+1',
        );
        expect(src, contains('const _publicKeysB64 = <String>[];'));
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
