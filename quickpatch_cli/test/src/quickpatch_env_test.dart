import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:platform/platform.dart';
import 'package:pubspec_parse/pubspec_parse.dart';
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/json_output.dart';
import 'package:quickpatch_cli/src/platform.dart';
import 'package:quickpatch_cli/src/quickpatch_cli_command_runner.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:test/test.dart';

import 'mocks.dart';

void main() {
  group(QuickPatchEnv, () {
    const flutterRevision = 'test-flutter-revision';
    late Platform platform;
    late Directory quickpatchRoot;
    late Uri platformScript;
    late QuickPatchEnv quickpatchEnv;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        () => body(),
        values: {
          platformRef.overrideWith(() => platform),
          isJsonModeRef.overrideWith(() => false),
        },
      );
    }

    setUp(() {
      quickpatchRoot = Directory.systemTemp.createTempSync();
      platformScript = Uri.file(
        p.join(quickpatchRoot.path, 'bin', 'cache', 'quickpatch.snapshot'),
      );
      File(p.join(quickpatchRoot.path, 'bin', 'internal', 'flutter.version'))
        ..createSync(recursive: true)
        ..writeAsStringSync(flutterRevision, flush: true);
      platform = MockPlatform();
      quickpatchEnv = runWithOverrides(QuickPatchEnv.new);

      when(() => platform.environment).thenReturn(const {});
      when(() => platform.script).thenReturn(platformScript);
    });

    group('copyWith', () {
      test('creates a new instance with the provided values', () {
        final newEnv = runWithOverrides(
          () => quickpatchEnv.copyWith(flutterRevisionOverride: 'test'),
        );
        expect(newEnv, isNot(same(quickpatchEnv)));
        expect(newEnv.flutterRevision, equals('test'));
      });

      test('uses existing values when not provided', () {
        final newEnv = runWithOverrides(() => quickpatchEnv.copyWith());
        expect(newEnv, isNot(same(quickpatchEnv)));
        expect(
          runWithOverrides(() => newEnv.flutterRevision),
          equals(flutterRevision),
        );
      });
    });

    group('configDirectory', () {
      test('returns correct directory', () {
        expect(
          runWithOverrides(() => quickpatchEnv.configDirectory.path),
          endsWith(executableName),
        );
      });
    });

    group('logsDirectory', () {
      test('returns correct directory', () {
        expect(
          runWithOverrides(() => quickpatchEnv.logsDirectory.path),
          endsWith(p.join(executableName, 'logs')),
        );
      });
    });

    group('getQuickPatchYamlFile', () {
      test('returns correct file', () {
        final tempDir = Directory.systemTemp.createTempSync();
        expect(
          runWithOverrides(
            () => quickpatchEnv.getQuickPatchYamlFile(cwd: tempDir).path,
          ),
          equals(p.join(tempDir.path, 'quickpatch.yaml')),
        );
      });
    });

    group('getFlutterProjectRoot', () {
      test('uses override when provided', () {
        final tempDir = Directory.systemTemp.createTempSync();
        final overridePubspec = File(
          p.join(tempDir.path, 'override', 'pubspec.yaml'),
        );
        final override = overridePubspec.parent.path;
        File(p.join(tempDir.path, 'pubspec.yaml')).createSync(recursive: true);
        expect(
          runWithOverrides(
            () => QuickPatchEnv(
              flutterProjectRootOverride: override,
            ).getFlutterProjectRoot(),
          ),
          isA<Directory>().having((d) => d.path, 'absolute', override),
        );
      });

      test('returns null when no Flutter project exists', () {
        final tempDir = Directory.systemTemp.createTempSync();
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.getFlutterProjectRoot()),
            getCurrentDirectory: () => tempDir,
          ),
          isNull,
        );
      });

      test('returns correct directory when Flutter project exists (root)', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(p.join(tempDir.path, 'pubspec.yaml')).createSync(recursive: true);
        final projectRoot = IOOverrides.runZoned(
          () => runWithOverrides(() => quickpatchEnv.getFlutterProjectRoot()),
          getCurrentDirectory: () => tempDir,
        );
        expect(projectRoot!.path, equals(tempDir.path));
      });

      test(
        'returns correct directory when Flutter project exists (nested)',
        () {
          final tempDir = Directory.systemTemp.createTempSync();
          final nestedDir = Directory(p.join(tempDir.path, 'nested'));
          File(
            p.join(tempDir.path, 'pubspec.yaml'),
          ).createSync(recursive: true);
          final projectRoot = IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.getFlutterProjectRoot()),
            getCurrentDirectory: () => nestedDir,
          );
          expect(projectRoot!.path, equals(tempDir.path));
        },
      );
    });

    group('getQuickPatchProjectRoot', () {
      test('returns null when no QuickPatch project exists', () {
        final tempDir = Directory.systemTemp.createTempSync();
        expect(
          IOOverrides.runZoned(
            () =>
                runWithOverrides(() => quickpatchEnv.getQuickPatchProjectRoot()),
            getCurrentDirectory: () => tempDir,
          ),
          isNull,
        );
      });

      test(
        'returns correct directory when QuickPatch project exists (root)',
        () {
          final tempDir = Directory.systemTemp.createTempSync();
          File(
            p.join(tempDir.path, 'quickpatch.yaml'),
          ).createSync(recursive: true);
          final projectRoot = IOOverrides.runZoned(
            () =>
                runWithOverrides(() => quickpatchEnv.getQuickPatchProjectRoot()),
            getCurrentDirectory: () => tempDir,
          );
          expect(projectRoot!.path, equals(tempDir.path));
        },
      );

      test(
        'returns correct directory when Flutter project exists (nested)',
        () {
          final tempDir = Directory.systemTemp.createTempSync();
          final nestedDir = Directory(p.join(tempDir.path, 'nested'));
          File(
            p.join(tempDir.path, 'quickpatch.yaml'),
          ).createSync(recursive: true);
          final projectRoot = IOOverrides.runZoned(
            () =>
                runWithOverrides(() => quickpatchEnv.getQuickPatchProjectRoot()),
            getCurrentDirectory: () => nestedDir,
          );
          expect(projectRoot!.path, equals(tempDir.path));
        },
      );
    });

    group('dartBinaryFile', () {
      test('returns correct path', () {
        when(() => platform.isWindows).thenReturn(false);
        expect(
          runWithOverrides(() => quickpatchEnv.dartBinaryFile.path),
          equals(
            p.join(
              quickpatchRoot.path,
              'bin',
              'cache',
              'flutter',
              flutterRevision,
              'bin',
              'dart',
            ),
          ),
        );
        when(() => platform.isWindows).thenReturn(true);
        expect(
          runWithOverrides(() => quickpatchEnv.dartBinaryFile.path),
          equals(
            p.join(
              quickpatchRoot.path,
              'bin',
              'cache',
              'flutter',
              flutterRevision,
              'bin',
              'dart.bat',
            ),
          ),
        );
      });
    });

    group('iosPodfileLockFile', () {
      test('returns correct path', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(p.join(tempDir.path, 'pubspec.yaml')).createSync(recursive: true);
        final podfileLockFile = IOOverrides.runZoned(
          () => runWithOverrides(() => quickpatchEnv.iosPodfileLockFile),
          getCurrentDirectory: () => tempDir,
        );
        expect(
          podfileLockFile.path,
          equals(p.join(tempDir.path, 'ios', 'Podfile.lock')),
        );
      });
    });

    group('iosPodfileLockHash', () {
      group('when file does not exist', () {
        test('returns null', () {
          expect(
            runWithOverrides(() => quickpatchEnv.iosPodfileLockHash),
            isNull,
          );
        });
      });

      group('when file exists', () {
        late Directory tempDir;
        late String podfileLockHash;

        setUp(() {
          tempDir = Directory.systemTemp.createTempSync();

          // Required to resolve the project root.
          File(
            p.join(tempDir.path, 'pubspec.yaml'),
          ).createSync(recursive: true);

          const podfileLockContents = 'lock file';
          podfileLockHash = sha256
              .convert(utf8.encode(podfileLockContents))
              .toString();
          File(p.join(tempDir.path, 'ios', 'Podfile.lock'))
            ..createSync(recursive: true)
            ..writeAsStringSync(podfileLockContents);
        });

        test('returns correct hash', () {
          final actualHash = IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.iosPodfileLockHash),
            getCurrentDirectory: () => tempDir,
          );
          expect(actualHash, equals(podfileLockHash));
        });
      });
    });

    group('buildDirectory', () {
      test('returns correct path', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(p.join(tempDir.path, 'pubspec.yaml')).createSync(recursive: true);
        Directory(p.join(tempDir.path, 'build')).createSync(recursive: true);
        final buildDirectory = IOOverrides.runZoned(
          () => runWithOverrides(() => quickpatchEnv.buildDirectory),
          getCurrentDirectory: () => tempDir,
        );
        expect(buildDirectory.path, equals(p.join(tempDir.path, 'build')));
      });
    });

    group('iosSupplementDirectory', () {
      test('returns correct path', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(p.join(tempDir.path, 'pubspec.yaml')).createSync(recursive: true);
        Directory(
          p.join(tempDir.path, 'build', 'ios', 'quickpatch'),
        ).createSync(recursive: true);
        final supplementDirectory = IOOverrides.runZoned(
          () => runWithOverrides(() => quickpatchEnv.iosSupplementDirectory),
          getCurrentDirectory: () => tempDir,
        );
        expect(
          supplementDirectory.path,
          equals(p.join(tempDir.path, 'build', 'ios', 'quickpatch')),
        );
      });
    });

    group('macosPodfileLockFile', () {
      test('returns correct path', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(p.join(tempDir.path, 'pubspec.yaml')).createSync(recursive: true);
        final podfileLockFile = IOOverrides.runZoned(
          () => runWithOverrides(() => quickpatchEnv.macosPodfileLockFile),
          getCurrentDirectory: () => tempDir,
        );
        expect(
          podfileLockFile.path,
          equals(p.join(tempDir.path, 'macos', 'Podfile.lock')),
        );
      });
    });

    group('macosPodfileLockHash', () {
      group('when file does not exist', () {
        test('returns null', () {
          expect(
            runWithOverrides(() => quickpatchEnv.macosPodfileLockHash),
            isNull,
          );
        });
      });

      group('when file exists', () {
        late Directory tempDir;
        late String podfileLockHash;

        setUp(() {
          tempDir = Directory.systemTemp.createTempSync();

          // Required to resolve the project root.
          File(
            p.join(tempDir.path, 'pubspec.yaml'),
          ).createSync(recursive: true);

          const podfileLockContents = 'lock file';
          podfileLockHash = sha256
              .convert(utf8.encode(podfileLockContents))
              .toString();
          File(p.join(tempDir.path, 'macos', 'Podfile.lock'))
            ..createSync(recursive: true)
            ..writeAsStringSync(podfileLockContents);
        });

        test('returns correct hash', () {
          final actualHash = IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.macosPodfileLockHash),
            getCurrentDirectory: () => tempDir,
          );
          expect(actualHash, equals(podfileLockHash));
        });
      });
    });

    group('flutterBinaryFile', () {
      test('returns correct path', () {
        when(() => platform.isWindows).thenReturn(false);
        expect(
          runWithOverrides(() => quickpatchEnv.flutterBinaryFile.path),
          equals(
            p.join(
              quickpatchRoot.path,
              'bin',
              'cache',
              'flutter',
              flutterRevision,
              'bin',
              'flutter',
            ),
          ),
        );
        when(() => platform.isWindows).thenReturn(true);
        expect(
          runWithOverrides(() => quickpatchEnv.flutterBinaryFile.path),
          equals(
            p.join(
              quickpatchRoot.path,
              'bin',
              'cache',
              'flutter',
              flutterRevision,
              'bin',
              'flutter.bat',
            ),
          ),
        );
      });
    });

    group('getPubspecYamlFile', () {
      test('returns correct file', () {
        final tempDir = Directory.systemTemp.createTempSync();
        expect(
          runWithOverrides(
            () => quickpatchEnv.getPubspecYamlFile(cwd: tempDir).path,
          ),
          equals(p.join(tempDir.path, 'pubspec.yaml')),
        );
      });
    });

    group('getPubspecYaml', () {
      test('returns null when pubspec.yaml does not exist', () {
        final tempDir = Directory.systemTemp.createTempSync();
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.getPubspecYaml()),
            getCurrentDirectory: () => tempDir,
          ),
          isNull,
        );
      });

      test('returns null when error occurs reading pubspec.yaml', () {
        final tempDir = Directory.systemTemp.createTempSync();
        // This is not valid utf8 so readAsString will throw.
        File(
          p.join(tempDir.path, 'pubspec.yaml'),
        ).writeAsBytesSync([999999999999]);
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.getPubspecYaml()),
            getCurrentDirectory: () => tempDir,
          ),
          isNull,
        );
      });

      test('returns value when pubspec.yaml exists', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(
          p.join(tempDir.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: test');
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.getPubspecYaml()),
            getCurrentDirectory: () => tempDir,
          ),
          isA<Pubspec>().having((p) => p.name, 'name', 'test'),
        );
      });

      test('returns value when pubspec.yaml exists '
          'and contains a malformed value', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: test
publish_to: yon30c
        ''');
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.getPubspecYaml()),
            getCurrentDirectory: () => tempDir,
          ),
          isA<Pubspec>()
              .having((p) => p.name, 'name', 'test')
              .having((p) => p.publishTo, 'publishTo', isNull),
        );
      });
    });

    group('hasPubspecYaml', () {
      test('returns false when pubspec.yaml does not exist', () {
        final tempDir = Directory.systemTemp.createTempSync();
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.hasPubspecYaml),
            getCurrentDirectory: () => tempDir,
          ),
          isFalse,
        );
      });

      test('returns true when pubspec.yaml does exist', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(
          p.join(tempDir.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: test');
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.hasPubspecYaml),
            getCurrentDirectory: () => tempDir,
          ),
          isTrue,
        );
      });

      test('returns true even if pubspec.yaml contains malformed values', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: test
publish_to: yon30c
        ''');
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.hasPubspecYaml),
            getCurrentDirectory: () => tempDir,
          ),
          isTrue,
        );
      });
    });

    group('hasQuickPatchYaml', () {
      test('returns false when quickpatch.yaml does not exist', () {
        final tempDir = Directory('temp');
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.hasQuickPatchYaml),
            getCurrentDirectory: () => tempDir,
          ),
          isFalse,
        );
      });

      test('returns true when quickpatch.yaml does exist', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(
          p.join(tempDir.path, 'quickpatch.yaml'),
        ).writeAsStringSync('app_id: test-app-id');
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.hasQuickPatchYaml),
            getCurrentDirectory: () => tempDir,
          ),
          isTrue,
        );
      });
    });

    group('pubspecContainsQuickPatchYaml', () {
      test('returns false when pubspec.yaml does not '
          'contain quickpatch.yaml in assets', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(
          p.join(tempDir.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: test');
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(
              () => quickpatchEnv.pubspecContainsQuickPatchYaml,
            ),
            getCurrentDirectory: () => tempDir,
          ),
          isFalse,
        );
      });

      test('returns false when pubspec.yaml contains empty flutter config', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: test
flutter:''');
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(
              () => quickpatchEnv.pubspecContainsQuickPatchYaml,
            ),
            getCurrentDirectory: () => tempDir,
          ),
          isFalse,
        );
      });

      test('returns true when pubspec.yaml does '
          'contain quickpatch.yaml in assets', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: test
flutter:
  assets:
    - quickpatch.yaml
''');
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(
              () => quickpatchEnv.pubspecContainsQuickPatchYaml,
            ),
            getCurrentDirectory: () => tempDir,
          ),
          isTrue,
        );
      });
    });

    group('androidPackageName', () {
      test(
        'returns null when pubspec.yaml does not contain android module',
        () {
          final tempDir = Directory.systemTemp.createTempSync();
          File(
            p.join(tempDir.path, 'pubspec.yaml'),
          ).writeAsStringSync('name: test');
          expect(
            IOOverrides.runZoned(
              () => runWithOverrides(() => quickpatchEnv.androidPackageName),
              getCurrentDirectory: () => tempDir,
            ),
            isNull,
          );
        },
      );

      test('returns correct package name when '
          'pubspec.yaml contains android module', () {
        final tempDir = Directory.systemTemp.createTempSync();
        File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: test
flutter:
  module:
    androidPackage: test-package
''');
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.androidPackageName),
            getCurrentDirectory: () => tempDir,
          ),
          equals('test-package'),
        );
      });
    });

    group('flutterRevision', () {
      test('returns correct revision', () {
        const revision = 'test-revision';
        File(p.join(quickpatchRoot.path, 'bin', 'internal', 'flutter.version'))
          ..createSync(recursive: true)
          ..writeAsStringSync(revision, flush: true);
        expect(
          runWithOverrides(() => quickpatchEnv.flutterRevision),
          equals(revision),
        );
      });

      test('trims revision file content', () {
        const revision = '''

test-revision

\r\n
''';
        File(p.join(quickpatchRoot.path, 'bin', 'internal', 'flutter.version'))
          ..createSync(recursive: true)
          ..writeAsStringSync(revision, flush: true);

        expect(
          runWithOverrides(() => quickpatchEnv.flutterRevision),
          'test-revision',
        );
      });

      test('uses override when provided', () {
        const revision = 'test-revision';
        const override = 'override-revision';
        File(p.join(quickpatchRoot.path, 'bin', 'internal', 'flutter.version'))
          ..createSync(recursive: true)
          ..writeAsStringSync(revision, flush: true);
        expect(
          runWithOverrides(
            () => const QuickPatchEnv(
              flutterRevisionOverride: override,
            ).flutterRevision,
          ),
          equals(override),
        );
      });
    });

    group('usesQuickPatchCodePushPackage', () {
      group('when pubspec.yaml does not contain quickpatch_code_push', () {
        setUp(() {
          final tempDir = Directory.systemTemp.createTempSync();
          File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: test

dependencies:
  clock: ^1.1.2
  collection: ^1.19.1
  crypto: ^3.0.6
  dart_frog: ^1.2.4
''');
          quickpatchEnv = runWithOverrides(
            () => QuickPatchEnv(flutterProjectRootOverride: tempDir.path),
          );
        });

        test('returns false', () {
          expect(
            runWithOverrides(() => quickpatchEnv.usesQuickPatchCodePushPackage),
            isFalse,
          );
        });
      });

      group('when pubspec.yaml contains quickpatch_code_push', () {
        setUp(() {
          final tempDir = Directory.systemTemp.createTempSync();
          File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: test

dependencies:
  clock: ^1.1.2
  collection: ^1.19.1
  crypto: ^3.0.6
  dart_frog: ^1.2.4
  quickpatch_code_push: ^1.0.0
''');
          quickpatchEnv = runWithOverrides(
            () => QuickPatchEnv(flutterProjectRootOverride: tempDir.path),
          );
        });

        test('returns true', () {
          expect(
            runWithOverrides(() => quickpatchEnv.usesQuickPatchCodePushPackage),
            isTrue,
          );
        });
      });
    });

    group('quickpatchEngineRevision', () {
      test('returns correct revision', () {
        const engineRevision = 'test-revision';
        File(
            p.join(
              quickpatchRoot.path,
              'bin',
              'cache',
              'flutter',
              flutterRevision,
              'bin',
              'internal',
              'engine.version',
            ),
          )
          ..createSync(recursive: true)
          ..writeAsStringSync(engineRevision, flush: true);
        expect(
          runWithOverrides(() => quickpatchEnv.quickpatchEngineRevision),
          equals(engineRevision),
        );
      });
    });

    group('hostedUrl', () {
      test('returns hosted url from env if available', () {
        when(
          () => platform.environment,
        ).thenReturn({'QUICKPATCH_HOSTED_URL': 'https://example.com'});
        expect(
          runWithOverrides(() => quickpatchEnv.hostedUri),
          equals(Uri.parse('https://example.com')),
        );
      });

      test('falls back to quickpatch.yaml', () {
        final directory = Directory.systemTemp.createTempSync();
        File(p.join(directory.path, 'quickpatch.yaml')).writeAsStringSync('''
app_id: test-id
base_url: https://example.com''');
        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.hostedUri),
            getCurrentDirectory: () => directory,
          ),
          equals(Uri.parse('https://example.com')),
        );
      });

      test('defaults to the hosted QuickPatch server when there is no env '
          'override or quickpatch.yaml', () {
        expect(
          runWithOverrides(() => quickpatchEnv.hostedUri),
          equals(
            Uri.parse('https://quickpatch-server-production.up.railway.app'),
          ),
        );
      });

      test('returns null when unable to read quickpatch.yaml', () {
        final directory = Directory.systemTemp.createTempSync();
        // This is not valid utf8 so readAsString will throw.
        File(
          p.join(directory.path, 'quickpatch.yaml'),
        ).writeAsBytesSync([999999999999]);

        expect(
          IOOverrides.runZoned(
            () => runWithOverrides(() => quickpatchEnv.hostedUri),
            getCurrentDirectory: () => directory,
          ),
          isNull,
        );
      });
    });

    group('canAcceptUserInput', () {
      late Stdin stdin;

      setUp(() {
        stdin = MockStdin();
      });

      group('when stdin has terminal', () {
        setUp(() {
          when(() => stdin.hasTerminal).thenReturn(true);
        });

        group('when not running on CI', () {
          setUp(() {
            when(() => platform.environment).thenReturn({});
          });

          test('returns true', () {
            expect(
              IOOverrides.runZoned(
                () => runWithOverrides(() => quickpatchEnv.canAcceptUserInput),
                stdin: () => stdin,
              ),
              isTrue,
            );
          });
        });

        group('when running on CI', () {
          setUp(() {
            when(() => platform.environment).thenReturn({'CI': ''});
          });

          test('returns false', () {
            expect(
              IOOverrides.runZoned(
                () => runWithOverrides(() => quickpatchEnv.canAcceptUserInput),
                stdin: () => stdin,
              ),
              isFalse,
            );
          });
        });
      });

      group('when stdin has terminal', () {
        setUp(() {
          when(() => stdin.hasTerminal).thenReturn(false);
        });

        test('returns true', () {
          expect(
            IOOverrides.runZoned(
              () => runWithOverrides(() => quickpatchEnv.canAcceptUserInput),
              stdin: () => stdin,
            ),
            isFalse,
          );
        });
      });
    });

    group('authServiceUri', () {
      test('returns default URI when env var is not set', () {
        when(() => platform.environment).thenReturn({});
        expect(
          runWithOverrides(() => quickpatchEnv.authServiceUri),
          equals(Uri.parse('https://auth.quickpatch.dev')),
        );
      });

      test('returns URI from env var when set', () {
        when(() => platform.environment).thenReturn({
          'AUTH_SERVICE_URL': 'https://custom-auth.example.com',
        });
        expect(
          runWithOverrides(() => quickpatchEnv.authServiceUri),
          equals(Uri.parse('https://custom-auth.example.com')),
        );
      });
    });

    group('jwtIssuer', () {
      test('returns default issuer when env var is not set', () {
        when(() => platform.environment).thenReturn({});
        expect(
          runWithOverrides(() => quickpatchEnv.jwtIssuer),
          equals('https://auth.quickpatch.dev'),
        );
      });

      test('returns issuer from env var when set', () {
        when(() => platform.environment).thenReturn({
          'QUICKPATCH_JWT_ISSUER': 'https://custom-issuer.example.com',
        });
        expect(
          runWithOverrides(() => quickpatchEnv.jwtIssuer),
          equals('https://custom-issuer.example.com'),
        );
      });
    });

    group('isRunningOnCI', () {
      test('returns true if BOT variable is "true"', () {
        when(() => platform.environment).thenReturn({'BOT': 'true'});
        expect(runWithOverrides(() => quickpatchEnv.isRunningOnCI), isTrue);
      });

      test('returns true if TRAVIS variable is "true"', () {
        when(() => platform.environment).thenReturn({'TRAVIS': 'true'});
        expect(runWithOverrides(() => quickpatchEnv.isRunningOnCI), isTrue);
      });

      test('returns true if CONTINUOUS_INTEGRATION variable is "true"', () {
        when(
          () => platform.environment,
        ).thenReturn({'CONTINUOUS_INTEGRATION': 'true'});
        expect(runWithOverrides(() => quickpatchEnv.isRunningOnCI), isTrue);
      });

      test('returns true if CI variable is set', () {
        when(() => platform.environment).thenReturn({'CI': ''});
        expect(runWithOverrides(() => quickpatchEnv.isRunningOnCI), isTrue);
      });

      test('returns true if APPVEYOR variable is set', () {
        when(() => platform.environment).thenReturn({'APPVEYOR': ''});
        expect(runWithOverrides(() => quickpatchEnv.isRunningOnCI), isTrue);
      });

      test('returns true if CIRRUS_CI variable is set', () {
        when(() => platform.environment).thenReturn({'CIRRUS_CI': ''});
        expect(runWithOverrides(() => quickpatchEnv.isRunningOnCI), isTrue);
      });

      test(
        '''returns true if AWS_REGION and CODEBUILD_INITIATOR variables are set''',
        () {
          when(
            () => platform.environment,
          ).thenReturn({'AWS_REGION': '', 'CODEBUILD_INITIATOR': ''});
          expect(runWithOverrides(() => quickpatchEnv.isRunningOnCI), isTrue);
        },
      );

      test('returns true if JENKINS_URL variable is set', () {
        when(() => platform.environment).thenReturn({'JENKINS_URL': ''});
        expect(runWithOverrides(() => quickpatchEnv.isRunningOnCI), isTrue);
      });

      test('returns true if GITHUB_ACTIONS variable is set', () {
        when(() => platform.environment).thenReturn({'GITHUB_ACTIONS': ''});
        expect(runWithOverrides(() => quickpatchEnv.isRunningOnCI), isTrue);
      });

      test('returns true if TF_BUILD is set', () {
        when(() => platform.environment).thenReturn({'TF_BUILD': 'True'});
        expect(runWithOverrides(() => quickpatchEnv.isRunningOnCI), isTrue);
      });

      test('returns false if no relevant environment variables are set', () {
        when(() => platform.environment).thenReturn({});
        expect(runWithOverrides(() => quickpatchEnv.isRunningOnCI), isFalse);
      });
    });
  });
}
