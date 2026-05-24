import 'dart:io';

import 'package:mocktail/mocktail.dart';
import 'package:path/path.dart' as p;
import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/pubspec_editor.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:test/test.dart';

import 'mocks.dart';

class _FakeDirectory extends Fake implements Directory {}

void main() {
  group(PubspecEditor, () {
    late QuickPatchEnv quickpatchEnv;
    late PubspecEditor pubspecEditor;

    R runWithOverrides<R>(R Function() body) {
      return runScoped(
        () => body(),
        values: {quickpatchEnvRef.overrideWith(() => quickpatchEnv)},
      );
    }

    setUpAll(() {
      registerFallbackValue(_FakeDirectory());
    });

    setUp(() {
      quickpatchEnv = MockQuickPatchEnv();
      pubspecEditor = PubspecEditor();
    });

    group('addQuickPatchYamlToPubspecAssets', () {
      group('when quickpatch.yaml is part of the pubspec.yaml assets', () {
        setUp(() {
          when(
            () => quickpatchEnv.pubspecContainsQuickPatchYaml,
          ).thenReturn(true);
        });

        test('does nothing', () {
          expect(
            () =>
                runWithOverrides(pubspecEditor.addQuickPatchYamlToPubspecAssets),
            returnsNormally,
          );
          verifyNever(() => quickpatchEnv.getFlutterProjectRoot());
        });
      });

      group('when quickpatch.yaml is not part of the pubspec.yaml assets', () {
        setUp(() {
          when(
            () => quickpatchEnv.pubspecContainsQuickPatchYaml,
          ).thenReturn(false);
        });

        group('when a flutter project root cannot be found', () {
          setUp(() {
            when(() => quickpatchEnv.getFlutterProjectRoot()).thenReturn(null);
          });

          test('does nothing', () {
            expect(
              () => runWithOverrides(
                pubspecEditor.addQuickPatchYamlToPubspecAssets,
              ),
              returnsNormally,
            );
            verify(() => quickpatchEnv.getFlutterProjectRoot()).called(1);
          });
        });

        group('when a flutter project root can be found', () {
          const basePubspecContents = '''
name: test
version: 1.0.0
environment:
 sdk: ">=2.19.0 <3.0.0"''';
          late Directory tempDir;
          late File pubspecFile;

          setUp(() {
            tempDir = Directory.systemTemp.createTempSync();
            pubspecFile = File(p.join(tempDir.path, 'pubspec.yaml'));
            when(
              () => quickpatchEnv.getFlutterProjectRoot(),
            ).thenReturn(tempDir);
            when(
              () => quickpatchEnv.getPubspecYamlFile(cwd: any(named: 'cwd')),
            ).thenReturn(pubspecFile);
          });

          test('creates flutter.assets and adds quickpatch.yaml', () {
            pubspecFile
              ..createSync()
              ..writeAsStringSync(basePubspecContents);
            IOOverrides.runZoned(
              () => runWithOverrides(
                pubspecEditor.addQuickPatchYamlToPubspecAssets,
              ),
              getCurrentDirectory: () => tempDir,
            );
            expect(
              pubspecFile.readAsStringSync(),
              equals('''
$basePubspecContents
flutter:
 assets:
   - quickpatch.yaml
'''),
            );
          });

          test('creates assets and adds quickpatch.yaml (empty flutter)', () {
            pubspecFile
              ..createSync()
              ..writeAsStringSync('''
$basePubspecContents
flutter:
''');
            IOOverrides.runZoned(
              () => runWithOverrides(
                pubspecEditor.addQuickPatchYamlToPubspecAssets,
              ),
              getCurrentDirectory: () => tempDir,
            );
            expect(
              pubspecFile.readAsStringSync(),
              equals('''
$basePubspecContents
flutter:
 assets:
   - quickpatch.yaml
'''),
            );
          });
          test(
            'creates assets and adds quickpatch.yaml (non-empty flutter)',
            () {
              pubspecFile
                ..createSync()
                ..writeAsStringSync('''
$basePubspecContents
flutter:
 uses-material-design: true
''');
              IOOverrides.runZoned(
                () => runWithOverrides(
                  pubspecEditor.addQuickPatchYamlToPubspecAssets,
                ),
                getCurrentDirectory: () => tempDir,
              );
              expect(
                pubspecFile.readAsStringSync(),
                equals('''
$basePubspecContents
flutter:
 assets:
  - quickpatch.yaml
 uses-material-design: true
'''),
              );
            },
          );
          test('adds quickpatch.yaml to assets (existing assets)', () {
            pubspecFile
              ..createSync()
              ..writeAsStringSync('''
$basePubspecContents
flutter:
 assets:
  - some/asset.txt
''');
            IOOverrides.runZoned(
              () => runWithOverrides(
                pubspecEditor.addQuickPatchYamlToPubspecAssets,
              ),
              getCurrentDirectory: () => tempDir,
            );
            expect(
              pubspecFile.readAsStringSync(),
              equals('''
$basePubspecContents
flutter:
 assets:
  - some/asset.txt
  - quickpatch.yaml
'''),
            );
          });
        });
      });
    });
  });
}
