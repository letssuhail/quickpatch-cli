import 'dart:convert';
import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:quickpatch_cli/src/engine_bootstrap.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group('ensureQuickPatchFlutterToolsPatched', () {
    late Directory flutterDir;
    late QuickPatchEnv quickpatchEnv;
    late QuickPatchLogger logger;

    File assetsFile() => File(
      p.join(
        flutterDir.path,
        'packages', 'flutter_tools', 'lib', 'src', 'build_system', 'targets',
        'assets.dart',
      ),
    );

    R runWithOverrides<R>(R Function() body) => runScoped(
      body,
      values: {
        quickpatchEnvRef.overrideWith(() => quickpatchEnv),
        loggerRef.overrideWith(() => logger),
      },
    );

    setUp(() {
      flutterDir = Directory.systemTemp.createTempSync('qp_fluttertools_test');
      quickpatchEnv = MockQuickPatchEnv();
      logger = MockQuickPatchLogger();
      when(() => quickpatchEnv.flutterDirectory).thenReturn(flutterDir);
    });

    tearDown(() {
      if (flutterDir.existsSync()) flutterDir.deleteSync(recursive: true);
    });

    void writeAssets(String guard) {
      final f = assetsFile()..parent.createSync(recursive: true);
      f.writeAsStringSync('''
          if (doCopy) {
            $guard
              injectPatchPublicKey(file.path);
            }
          }
''');
    }

    File snapshot() =>
        File(p.join(flutterDir.path, 'bin', 'cache', 'flutter_tools.snapshot'));

    test('returns early (no throw) when the SDK is not installed', () {
      // flutterDir exists but has no flutter_tools/assets.dart.
      expect(() => runWithOverrides(ensureQuickPatchFlutterToolsPatched),
          returnsNormally);
    });

    test('repoints any upstream *.yaml config guard to quickpatch.yaml', () {
      // A generic legacy filename proves the guard is matched generically, not
      // by a hard-coded upstream name.
      writeAssets("if (file.basename == 'legacy.yaml') {");
      snapshot()
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('stale');

      runWithOverrides(ensureQuickPatchFlutterToolsPatched);

      final patched = assetsFile().readAsStringSync();
      // The guard now matches QuickPatch's config file, and the legacy name is
      // fully replaced.
      expect(patched, contains("file.basename == 'quickpatch.yaml'"));
      expect(patched, isNot(contains("'legacy.yaml'")));
      // The stale tool snapshot is invalidated so the patch recompiles.
      expect(snapshot().existsSync(), isFalse);
    });

    test('is idempotent — a second run leaves the file unchanged', () {
      writeAssets("if (file.basename == 'legacy.yaml') {");
      runWithOverrides(ensureQuickPatchFlutterToolsPatched);
      final once = assetsFile().readAsStringSync();
      // Re-create a snapshot to prove the idempotent path does NOT delete it.
      snapshot()
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('fresh');

      runWithOverrides(ensureQuickPatchFlutterToolsPatched);

      expect(assetsFile().readAsStringSync(), once);
      expect(snapshot().existsSync(), isTrue);
    });

    test('warns (does not silently pass) if no guard is found', () {
      writeAssets('if (somethingElse) {');

      runWithOverrides(ensureQuickPatchFlutterToolsPatched);

      verify(() => logger.warn(any(that: contains('patch-signing fix'))))
          .called(1);
      // Unchanged — nothing to patch.
      expect(assetsFile().readAsStringSync(), isNot(contains('quickpatch.yaml')));
    });

    test('warns and does NOT patch if the guard is ambiguous (>1 match)', () {
      // A future Flutter revision with two *.yaml guards must not be patched
      // blindly — we cannot tell which is the key-injection site.
      assetsFile()
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('''
          if (file.basename == 'legacy.yaml') {}
          if (file.basename == 'other.yaml') {}
''');

      runWithOverrides(ensureQuickPatchFlutterToolsPatched);

      verify(() => logger.warn(any(that: contains('found 2')))).called(1);
      expect(assetsFile().readAsStringSync(), isNot(contains('quickpatch.yaml')));
    });

    // --- signing-key rotation emit (patch_public_keys) ---

    // Located by content (scan for the single-key emit), not by path, so the
    // fixture filename is deliberately neutral.
    File yamlCompilerFile() => File(
      p.join(
        flutterDir.path,
        'packages', 'flutter_tools', 'lib', 'src', 'config', 'yaml_compiler.dart',
      ),
    );

    void writeYamlCompiler({String varName = 'publicKeyEnvVar'}) {
      yamlCompilerFile()
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('''
  copyIfSet('patch_verification');
  final String? $varName = environment['SHOREBIRD_PUBLIC_KEY'];
  if ($varName != null) {
    compiled['patch_public_key'] = $varName;
  }
  return compiled;
''');
    }

    test('injects patch_public_keys emit after the single-key emit', () {
      writeYamlCompiler();

      runWithOverrides(ensureQuickPatchFlutterToolsPatched);

      final patched = yamlCompilerFile().readAsStringSync();
      // Rotation keys are now emitted from SHOREBIRD_PUBLIC_KEYS...
      expect(patched, contains("compiled['patch_public_keys']"));
      expect(patched, contains("environment['SHOREBIRD_PUBLIC_KEYS']"));
      // ...and the original single-key emit is preserved (not replaced).
      expect(patched, contains("compiled['patch_public_key'] ="));
    });

    test('rotation emit works regardless of the upstream variable name', () {
      // The match is generic on the local variable name.
      writeYamlCompiler(varName: 'somethingDifferent');

      runWithOverrides(ensureQuickPatchFlutterToolsPatched);

      expect(yamlCompilerFile().readAsStringSync(),
          contains("compiled['patch_public_keys']"));
    });

    test('rotation emit is idempotent — a second run is a no-op', () {
      writeYamlCompiler();
      runWithOverrides(ensureQuickPatchFlutterToolsPatched);
      final once = yamlCompilerFile().readAsStringSync();

      runWithOverrides(ensureQuickPatchFlutterToolsPatched);

      expect(yamlCompilerFile().readAsStringSync(), once);
    });

    test('warns and does NOT inject if the emit site is absent', () {
      // A compiler file with no single-key emit → nothing to anchor on.
      yamlCompilerFile()
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(
          "final x = environment['SHOREBIRD_PUBLIC_KEY'];\n"
          "compiled['patch_public_key'] = x; // not inside a guarded block\n",
        );

      runWithOverrides(ensureQuickPatchFlutterToolsPatched);

      verify(() => logger.warn(any(that: contains('signing-key rotation'))))
          .called(1);
      expect(yamlCompilerFile().readAsStringSync(),
          isNot(contains("compiled['patch_public_keys']")));
    });

    test('both fixes together invalidate the tool snapshot', () {
      writeAssets("if (file.basename == 'legacy.yaml') {");
      writeYamlCompiler();
      snapshot()
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('stale');

      runWithOverrides(ensureQuickPatchFlutterToolsPatched);

      expect(assetsFile().readAsStringSync(),
          contains("file.basename == 'quickpatch.yaml'"));
      expect(yamlCompilerFile().readAsStringSync(),
          contains("compiled['patch_public_keys']"));
      expect(snapshot().existsSync(), isFalse);
    });
  });

  group('binaryEmbedsRevision', () {
    late Directory tmp;
    const rev = '76ba1f79062a25f3e339546db98d259d';

    setUp(() => tmp = Directory.systemTemp.createTempSync('qp_embed'));
    tearDown(() => tmp.deleteSync(recursive: true));

    File binaryWith(List<int> bytes) =>
        File(p.join(tmp.path, 'gen_snapshot_arm64'))..writeAsBytesSync(bytes);

    test(
        'true when the revision appears as an ASCII substring surrounded by '
        'non-text bytes', () {
      final file = binaryWith([
        0x00, 0xFF, 0x7F, 0x01, // non-text bytes
        ...utf8.encode('...version=$rev...'),
        0x00, 0xFE,
      ]);
      expect(binaryEmbedsRevision(file, rev), isTrue);
    });

    test('false when the on-disk binary is a stock engine (different hash)', () {
      final file = binaryWith(
        utf8.encode('...version=41be3daaabd524b8aa7423bc24584957...'),
      );
      expect(binaryEmbedsRevision(file, rev), isFalse);
    });

    test('false when the file does not exist (treated as needs re-install)', () {
      expect(
        binaryEmbedsRevision(File(p.join(tmp.path, 'missing')), rev),
        isFalse,
      );
    });
  });

  group('ensureQuickPatchAndroidEngine', () {
    late Directory flutterDir;
    late QuickPatchEnv quickpatchEnv;
    late QuickPatchLogger logger;

    File engineVersion() =>
        File(p.join(flutterDir.path, 'bin', 'internal', 'engine.version'));

    R runWithOverrides<R>(R Function() body) => runScoped(
          body,
          values: {
            quickpatchEnvRef.overrideWith(() => quickpatchEnv),
            loggerRef.overrideWith(() => logger),
          },
        );

    setUp(() {
      flutterDir = Directory.systemTemp.createTempSync('qp_androidengine');
      quickpatchEnv = MockQuickPatchEnv();
      logger = MockQuickPatchLogger();
      when(() => quickpatchEnv.flutterDirectory).thenReturn(flutterDir);
    });

    tearDown(() {
      if (flutterDir.existsSync()) flutterDir.deleteSync(recursive: true);
    });

    test('maps the vanilla stable engine to the QuickPatch engine, then '
        'restores', () {
      engineVersion()
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('4c525dac5ebe5971c5708ef73558ed8edcf4a362');
      final restore = runWithOverrides(ensureQuickPatchAndroidEngine);
      expect(
        engineVersion().readAsStringSync(),
        '6500c84eba818b598fb967bd0276e6e50cdd02c9',
      );
      restore();
      expect(
        engineVersion().readAsStringSync(),
        '4c525dac5ebe5971c5708ef73558ed8edcf4a362',
      );
    });

    test('is a no-op for an unmapped engine (restore is safe)', () {
      engineVersion()
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('deadbeefdeadbeefdeadbeefdeadbeefdeadbeef');
      final restore = runWithOverrides(ensureQuickPatchAndroidEngine);
      expect(
        engineVersion().readAsStringSync(),
        'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
      );
      restore();
      expect(
        engineVersion().readAsStringSync(),
        'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
      );
    });
  });

  group('embedPatchPublicKeysInProjectYaml', () {
    late Directory projectDir;
    late QuickPatchEnv quickpatchEnv;
    late QuickPatchLogger logger;

    File yaml() => File(p.join(projectDir.path, 'quickpatch.yaml'));

    R runWithOverrides<R>(R Function() body) => runScoped(
          body,
          values: {
            quickpatchEnvRef.overrideWith(() => quickpatchEnv),
            loggerRef.overrideWith(() => logger),
          },
        );

    setUp(() {
      projectDir = Directory.systemTemp.createTempSync('qp_yaml_test');
      quickpatchEnv = MockQuickPatchEnv();
      logger = MockQuickPatchLogger();
      when(() => quickpatchEnv.getQuickPatchProjectRoot())
          .thenReturn(projectDir);
    });

    tearDown(() {
      if (projectDir.existsSync()) projectDir.deleteSync(recursive: true);
    });

    test('embeds patch_public_key into the yaml, then restores the original',
        () {
      const original = 'app_id: abc\nbase_url: https://x\n';
      yaml().writeAsStringSync(original);
      final restore = runWithOverrides(
        () => embedPatchPublicKeysInProjectYaml(base64PublicKey: 'KEY123'),
      );
      expect(yaml().readAsStringSync(), contains('patch_public_key: KEY123'));
      restore();
      expect(yaml().readAsStringSync(), original);
      expect(yaml().readAsStringSync(), isNot(contains('patch_public_key')));
    });

    test('emits rotation keys as comma-separated patch_public_keys', () {
      yaml().writeAsStringSync('app_id: abc\n');
      runWithOverrides(
        () => embedPatchPublicKeysInProjectYaml(
          base64PublicKey: 'PRIMARY',
          rotationPublicKeys: ['ROT1', ' ROT2 ', ''],
        ),
      );
      final s = yaml().readAsStringSync();
      expect(s, contains('patch_public_key: PRIMARY'));
      expect(s, contains('patch_public_keys: ROT1,ROT2'));
    });

    test('replaces any pre-existing key line (no stale keys)', () {
      yaml().writeAsStringSync('app_id: abc\npatch_public_key: OLD\n');
      runWithOverrides(
        () => embedPatchPublicKeysInProjectYaml(base64PublicKey: 'NEW'),
      );
      final s = yaml().readAsStringSync();
      expect(s, contains('patch_public_key: NEW'));
      expect(s, isNot(contains('OLD')));
    });

    test('no key => no-op; restore is safe and leaves the file untouched', () {
      const original = 'app_id: abc\n';
      yaml().writeAsStringSync(original);
      final restore = runWithOverrides(
        () => embedPatchPublicKeysInProjectYaml(base64PublicKey: null),
      );
      expect(yaml().readAsStringSync(), original);
      restore();
      expect(yaml().readAsStringSync(), original);
    });
  });
}
