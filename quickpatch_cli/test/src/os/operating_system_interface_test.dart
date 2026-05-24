import 'package:mason_logger/mason_logger.dart';
import 'package:mocktail/mocktail.dart';
import 'package:platform/platform.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/os/os.dart';
import 'package:quickpatch_cli/src/platform.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';
import 'package:test/test.dart';

import '../mocks.dart';

void main() {
  group(OperatingSystemInterface, () {
    late Platform platform;
    late QuickPatchProcess process;
    late QuickPatchProcessResult processResult;
    late OperatingSystemInterface osInterface;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        () => body(),
        values: {
          platformRef.overrideWith(() => platform),
          processRef.overrideWith(() => process),
        },
      );
    }

    setUp(() {
      platform = MockPlatform();
      process = MockQuickPatchProcess();
      processResult = MockProcessResult();

      when(() => platform.isLinux).thenReturn(false);
      when(() => platform.isMacOS).thenReturn(false);
      when(() => platform.isWindows).thenReturn(false);

      when(() => process.runSync(any(), any())).thenReturn(processResult);
      when(() => processResult.exitCode).thenReturn(ExitCode.success.code);
    });

    group('init', () {
      test(
        'throws UnsupportedError when operating system is not supported',
        () {
          expect(
            () => runWithOverrides(OperatingSystemInterface.new),
            throwsUnsupportedError,
          );
        },
      );
    });

    group('on macOS/Linux', () {
      setUp(() {
        when(() => platform.isMacOS).thenReturn(true);

        osInterface = runWithOverrides(OperatingSystemInterface.new);
      });

      group('which()', () {
        group('when no executable is found on PATH', () {
          setUp(() {
            when(() => processResult.exitCode).thenReturn(1);
          });

          test('returns null', () {
            expect(
              runWithOverrides(() => osInterface.which('quickpatch')),
              isNull,
            );
          });
        });

        group('when executable is found on PATH', () {
          const quickpatchPath = '/path/to/quickpatch';
          setUp(() {
            when(() => processResult.stdout).thenReturn(quickpatchPath);
          });

          test('returns path to executable', () {
            expect(
              runWithOverrides(() => osInterface.which('quickpatch')),
              quickpatchPath,
            );
          });
        });

        group('when executable contains leading and trailing newlines', () {
          const quickpatchPath = '''


/path/to/quickpatch

''';
          setUp(() {
            when(() => processResult.stdout).thenReturn(quickpatchPath);
          });

          test('returns trimmed path to binary', () {
            expect(
              runWithOverrides(() => osInterface.which('quickpatch')),
              equals('/path/to/quickpatch'),
            );
          });
        });
      });
    });

    group('on Windows', () {
      setUp(() {
        when(() => platform.isWindows).thenReturn(true);
        osInterface = runWithOverrides(OperatingSystemInterface.new);
      });

      group('which()', () {
        group('when no executable is found on PATH', () {
          setUp(() {
            when(() => processResult.exitCode).thenReturn(1);
          });

          test('returns null', () {
            expect(
              runWithOverrides(() => osInterface.which('quickpatch')),
              isNull,
            );
          });
        });

        group('when executable is found on PATH', () {
          const quickpatchPath = r'C:\path\to\quickpatch';
          setUp(() {
            when(() => processResult.stdout).thenReturn(quickpatchPath);
          });

          test('returns path to executable', () {
            expect(
              runWithOverrides(() => osInterface.which('quickpatch')),
              quickpatchPath,
            );
          });
        });

        group('when multiple executables are found on PATH', () {
          const quickpatchPath = r'C:\path\to\quickpatch';
          const quickpatchPaths = [
            r'C:\path\to\quickpatch',
            r'C:\path\to\quickpatch1',
            r'C:\path\to\quickpatch2',
            r'C:\path\to\quickpatch3',
          ];

          setUp(() {
            when(
              () => processResult.stdout,
            ).thenReturn(quickpatchPaths.join('\r\n'));
          });

          test('returns first path to executable', () {
            expect(
              runWithOverrides(() => osInterface.which('quickpatch')),
              quickpatchPath,
            );
          });
        });
      });
    });
  });
}
