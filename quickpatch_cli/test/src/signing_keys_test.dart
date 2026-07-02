import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';
import 'package:quickpatch_cli/src/signing_keys.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group('signing keys', () {
    const appId = 'aaaa-bbbb';
    late Directory configDir;
    late QuickPatchEnv quickpatchEnv;
    late QuickPatchLogger logger;
    late QuickPatchProcess process;

    R runWithOverrides<R>(R Function() body) => runScoped(
      body,
      values: {
        quickpatchEnvRef.overrideWith(() => quickpatchEnv),
        loggerRef.overrideWith(() => logger),
        processRef.overrideWith(() => process),
      },
    );

    Directory keyDir() => Directory(p.join(configDir.path, 'keys', appId));
    File privateKey() => File(p.join(keyDir().path, 'private.pem'));
    File publicKey() => File(p.join(keyDir().path, 'public.pem'));

    setUp(() {
      SigningKeyDefaults.clear();
      configDir = Directory.systemTemp.createTempSync('qp_signing_keys_test');
      quickpatchEnv = MockQuickPatchEnv();
      logger = MockQuickPatchLogger();
      process = MockQuickPatchProcess();
      when(() => quickpatchEnv.configDirectory).thenReturn(configDir);
    });

    tearDown(() {
      SigningKeyDefaults.clear();
      if (configDir.existsSync()) configDir.deleteSync(recursive: true);
    });

    QuickPatchProcessResult ok() =>
        const QuickPatchProcessResult(exitCode: 0, stdout: '', stderr: '');

    void stubOpensslWritingKeys() {
      when(() => process.run(any(), any())).thenAnswer((invocation) async {
        final exe = invocation.positionalArguments[0] as String;
        final args =
            (invocation.positionalArguments[1] as List).cast<String>();
        if (exe == 'openssl' && args.first == 'genpkey') {
          File(args[args.indexOf('-out') + 1])
            ..createSync(recursive: true)
            ..writeAsStringSync('PRIVATE-PEM');
        }
        if (exe == 'openssl' && args.first == 'rsa') {
          File(args[args.indexOf('-out') + 1])
            ..createSync(recursive: true)
            ..writeAsStringSync('PUBLIC-PEM');
        }
        return ok();
      });
    }

    test('readAppSigningKeys returns null when no keys are stored', () {
      expect(runWithOverrides(() => readAppSigningKeys(appId)), isNull);
    });

    test('readAppSigningKeys returns null when the pair is incomplete', () {
      privateKey()
        ..createSync(recursive: true)
        ..writeAsStringSync('PRIVATE-PEM');
      expect(runWithOverrides(() => readAppSigningKeys(appId)), isNull);
    });

    test('readAppSigningKeys returns the stored pair', () {
      privateKey()
        ..createSync(recursive: true)
        ..writeAsStringSync('PRIVATE-PEM');
      publicKey().writeAsStringSync('PUBLIC-PEM');
      final keys = runWithOverrides(() => readAppSigningKeys(appId));
      expect(keys, isNotNull);
      expect(keys!.privateKey.readAsStringSync(), 'PRIVATE-PEM');
      expect(keys.publicKey.readAsStringSync(), 'PUBLIC-PEM');
    });

    test('ensureAppSigningKeys generates a pair via openssl when absent',
        () async {
      stubOpensslWritingKeys();
      final keys =
          await runWithOverrides(() => ensureAppSigningKeys(appId));
      expect(keys.privateKey.existsSync(), isTrue);
      expect(keys.publicKey.existsSync(), isTrue);
      verify(
        () => process.run(
          'openssl',
          any(that: contains('genpkey')),
        ),
      ).called(1);
      verify(
        () => process.run(
          'openssl',
          any(that: containsAll(['rsa', '-pubout'])),
        ),
      ).called(1);
    });

    test('ensureAppSigningKeys reuses an existing pair (no openssl call)',
        () async {
      privateKey()
        ..createSync(recursive: true)
        ..writeAsStringSync('PRIVATE-PEM');
      publicKey().writeAsStringSync('PUBLIC-PEM');
      final keys =
          await runWithOverrides(() => ensureAppSigningKeys(appId));
      expect(keys.privateKey.readAsStringSync(), 'PRIVATE-PEM');
      verifyNever(() => process.run(any(), any()));
    });

    test('ensureAppSigningKeys throws when openssl fails', () async {
      when(() => process.run(any(), any())).thenAnswer(
        (_) async => const QuickPatchProcessResult(
          exitCode: 1,
          stdout: '',
          stderr: 'boom',
        ),
      );
      await expectLater(
        runWithOverrides(() => ensureAppSigningKeys(appId)),
        throwsA(isA<ProcessException>()),
      );
    });
  });
}
