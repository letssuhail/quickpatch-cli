import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/executables/executables.dart';
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  group('QuickPatchTools', () {
    late File dartBinaryFile;
    late Directory flutterDirectory;
    late Directory tempDir;
    late QuickPatchLogger logger;
    late QuickPatchEnv quickpatchEnv;
    late QuickPatchProcess process;
    late QuickPatchProcessResult processResult;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        () => body(),
        values: {
          processRef.overrideWith(() => process),
          quickpatchEnvRef.overrideWith(() => quickpatchEnv),
          loggerRef.overrideWith(() => logger),
          quickpatchToolsRef,
        },
      );
    }

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync();
      flutterDirectory = Directory(p.join(tempDir.path, 'flutter'))
        ..createSync();
      dartBinaryFile = File(p.join(tempDir.path, 'dart'))..createSync();
      processResult = MockProcessResult();
      quickpatchEnv = MockQuickPatchEnv();
      process = MockQuickPatchProcess();
      logger = MockQuickPatchLogger();

      when(() => processResult.exitCode).thenReturn(0);
      when(() => processResult.stdout).thenReturn('');
      when(() => processResult.stderr).thenReturn('');

      when(() => quickpatchEnv.flutterDirectory).thenReturn(flutterDirectory);
      when(() => quickpatchEnv.dartBinaryFile).thenReturn(dartBinaryFile);

      when(
        () => process.run(
          any(),
          any(),
          workingDirectory: any(named: 'workingDirectory'),
        ),
      ).thenAnswer((_) async => processResult);
    });

    test('have access a reference to quickpatch tool', () {
      expect(
        runScoped(() => quickpatchTools, values: {quickpatchToolsRef}),
        isA<QuickPatchTools>(),
      );
    });

    test('makes the correct cli call', () async {
      await runWithOverrides(
        () => quickpatchTools.package(
          patchPath: 'patchPath',
          outputPath: 'outputPath',
        ),
      );

      verify(
        () => process.run(
          dartBinaryFile.path,
          any(
            that: containsAllInOrder([
              'run',
              'quickpatch_tools',
              'package',
              '-p',
              'patchPath',
              '-o',
              'outputPath',
            ]),
          ),
          workingDirectory: p.join(
            flutterDirectory.path,
            'packages',
            'quickpatch_tools',
          ),
        ),
      ).called(1);
    });

    group('when the command fails', () {
      setUp(() {
        when(() => processResult.exitCode).thenReturn(1);
        when(() => processResult.stdout).thenReturn('stdout');
        when(() => processResult.stderr).thenReturn('stderr');
      });

      test('throws a PackageFailedException', () {
        expect(
          () => runWithOverrides(
            () => quickpatchTools.package(
              patchPath: 'patchPath',
              outputPath: 'outputPath',
            ),
          ),
          throwsA(
            isA<PackageFailedException>().having(
              (e) => e.toString(),
              'message',
              '''
Failed to create package (exit code ${processResult.exitCode}).
  stdout: ${processResult.stdout}
  stderr: ${processResult.stderr}''',
            ),
          ),
        );
      });
    });

    group('when the quickpatch tools directory exists', () {
      test('isSupported returns true', () {
        Directory(
          p.join(flutterDirectory.path, 'packages', 'quickpatch_tools'),
        ).createSync(recursive: true);
        final isSupported = runWithOverrides(
          () => quickpatchTools.isSupported(),
        );
        expect(isSupported, isTrue);
      });
    });

    group('when the quickpatch tools directory does not exist', () {
      test('isSupported returns false', () {
        final isSupported = runWithOverrides(
          () => quickpatchTools.isSupported(),
        );
        expect(isSupported, isFalse);
      });
    });
  });
}
