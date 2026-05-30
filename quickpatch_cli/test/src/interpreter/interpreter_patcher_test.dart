import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:quickpatch_cli/src/interpreter/interpreter_patcher.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';
import 'package:test/test.dart';

class _MockProcess extends Mock implements QuickPatchProcess {}

class _MockResult extends Mock implements QuickPatchProcessResult {}

void main() {
  group(InterpreterPatcher, () {
    late _MockProcess process;
    late InterpreterPatcher patcher;
    late Directory tmp;

    setUp(() {
      process = _MockProcess();
      tmp = Directory.systemTemp.createTempSync('qp_interp_patcher');
      patcher = InterpreterPatcher(
        process: process,
        aotRuntimePath: '/eng/dartaotruntime',
        dart2bytecodeSnapshotPath: '/eng/dart2bytecode.snapshot',
        platformDillPath: '/eng/platform_strong.dill',
      );
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    QuickPatchProcessResult result(int code, {String err = ''}) {
      final r = _MockResult();
      when(() => r.exitCode).thenReturn(code);
      when(() => r.stderr).thenReturn(err);
      return r;
    }

    test('invokes dart2bytecode with UNPREFIXED args and returns the patch',
        () async {
      final out = '${tmp.path}/patch.bytecode';
      when(() => process.run(any(), any())).thenAnswer((_) async {
        File(out).writeAsBytesSync([1, 2, 3]); // simulate dart2bytecode output
        return result(0);
      });

      final file = await patcher.buildBytecodePatch(
        packageConfigPath: '/app/.dart_tool/package_config.json',
        importDillPath: '/eng/base.dill',
        entry: 'package:app/main.dart',
        outputPath: out,
      );

      expect(file.path, out);
      final captured = verify(
        () => process.run('/eng/dartaotruntime', captureAny()),
      ).captured.single as List<String>;
      expect(captured.first, '/eng/dart2bytecode.snapshot');
      expect(captured, containsAll(['--import-dill', '/eng/base.dill']));
      expect(captured, isNot(contains('--prefix-library-uris')));
      expect(captured.last, 'package:app/main.dart');
    });

    test('throws when dart2bytecode exits non-zero', () async {
      when(() => process.run(any(), any()))
          .thenAnswer((_) async => result(70, err: 'boom'));

      expect(
        () => patcher.buildBytecodePatch(
          packageConfigPath: '/app/pc.json',
          importDillPath: '/eng/base.dill',
          entry: 'package:app/main.dart',
          outputPath: '${tmp.path}/none.bytecode',
        ),
        throwsA(
          isA<InterpreterPatchException>().having(
            (e) => e.message,
            'message',
            allOf(contains('exit 70'), contains('boom')),
          ),
        ),
      );
    });

    test('throws when no patch file is produced despite exit 0', () async {
      when(() => process.run(any(), any()))
          .thenAnswer((_) async => result(0));

      expect(
        () => patcher.buildBytecodePatch(
          packageConfigPath: '/app/pc.json',
          importDillPath: '/eng/base.dill',
          entry: 'package:app/main.dart',
          outputPath: '${tmp.path}/missing.bytecode',
        ),
        throwsA(isA<InterpreterPatchException>()),
      );
    });
  });
}
