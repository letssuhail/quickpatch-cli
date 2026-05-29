import 'package:scoped_deps/scoped_deps.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// A reference to a [PubspecEditor] instance.
final pubspecEditorRef = create(PubspecEditor.new);

/// The [PubspecEditor] instance available in the current zone.
PubspecEditor get pubspecEditor => read(pubspecEditorRef);

/// {@template pubspec_editor}
/// A class that exposes APIs to edit the current project's `pubspec.yaml`.
/// {@endtemplate}
class PubspecEditor {
  /// Adds quickpatch.yaml to the assets section of the pubspec.yaml file.
  /// Does nothing if the pubspec.yaml file already contains quickpatch.yaml
  /// (or the legacy shorebird.yaml).
  /// Does nothing if a flutter project root cannot be found.
  void addQuickPatchYamlToPubspecAssets() {
    if (quickpatchEnv.pubspecContainsQuickPatchYaml) return;

    final root = quickpatchEnv.getFlutterProjectRoot();
    // TODO(felangel): this should throw an exception instead of returning
    // to make it explicit that the edit operation failed.
    if (root == null) return;

    final pubspecFile = quickpatchEnv.getPubspecYamlFile(cwd: root);
    final pubspecContents = pubspecFile.readAsStringSync();
    final editor = YamlEditor(pubspecContents);
    final yaml = loadYaml(pubspecContents, sourceUrl: pubspecFile.uri) as Map;

    if (!yaml.containsKey('flutter') || yaml['flutter'] == null) {
      editor.update(
        ['flutter'],
        {
          'assets': ['quickpatch.yaml'],
        },
      );
    } else {
      final flutterMap = yaml['flutter'] as Map;
      final existing = flutterMap['assets'];
      if (existing == null) {
        // `assets:` may be absent, or present but empty (null value).
        editor.update(['flutter', 'assets'], ['quickpatch.yaml']);
      } else {
        final assets = existing as List;
        if (!assets.contains('quickpatch.yaml')) {
          editor.update(['flutter', 'assets'], [...assets, 'quickpatch.yaml']);
        }
      }
    }

    if (editor.edits.isEmpty) return;

    pubspecFile.writeAsStringSync(editor.toString());
  }
}
