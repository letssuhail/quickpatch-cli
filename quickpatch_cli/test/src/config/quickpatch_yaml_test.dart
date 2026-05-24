import 'package:checked_yaml/checked_yaml.dart';
import 'package:quickpatch_cli/src/config/config.dart';
import 'package:test/test.dart';

void main() {
  group('QuickPatchYaml', () {
    test('can be deserialized without flavors', () {
      const yaml = '''
app_id: test_app_id
base_url: https://example.com
''';
      final quickpatchYaml = checkedYamlDecode(
        yaml,
        (m) => QuickPatchYaml.fromJson(m!),
      );
      expect(quickpatchYaml.appId, 'test_app_id');
      expect(quickpatchYaml.flavors, isNull);
      expect(quickpatchYaml.baseUrl, 'https://example.com');
    });

    test('can be deserialized with flavors', () {
      const yaml = '''
app_id: test_app_id1
flavors:
  development: test_app_id1
  production: test_app_id2
base_url: https://example.com
''';
      final quickpatchYaml = checkedYamlDecode(
        yaml,
        (m) => QuickPatchYaml.fromJson(m!),
      );
      expect(quickpatchYaml.appId, equals('test_app_id1'));
      expect(quickpatchYaml.flavors, {
        'development': 'test_app_id1',
        'production': 'test_app_id2',
      });
      expect(quickpatchYaml.baseUrl, 'https://example.com');
    });

    test('can be deserialized without auto-update', () {
      const yaml = '''
app_id: test_app_id
''';
      final quickpatchYaml = checkedYamlDecode(
        yaml,
        (m) => QuickPatchYaml.fromJson(m!),
      );
      expect(quickpatchYaml.appId, 'test_app_id');
      expect(quickpatchYaml.flavors, isNull);
      expect(quickpatchYaml.baseUrl, isNull);
      expect(quickpatchYaml.autoUpdate, isNull);
    });

    test('can be deserialized with auto-update', () {
      const yaml = '''
app_id: test_app_id
auto_update: true
''';
      final quickpatchYaml = checkedYamlDecode(
        yaml,
        (m) => QuickPatchYaml.fromJson(m!),
      );
      expect(quickpatchYaml.appId, 'test_app_id');
      expect(quickpatchYaml.flavors, isNull);
      expect(quickpatchYaml.baseUrl, isNull);
      expect(quickpatchYaml.autoUpdate, isTrue);
    });

    test('can be deserialized without patch_verification', () {
      const yaml = '''
app_id: test_app_id
''';
      final quickpatchYaml = checkedYamlDecode(
        yaml,
        (m) => QuickPatchYaml.fromJson(m!),
      );
      expect(quickpatchYaml.appId, 'test_app_id');
      expect(quickpatchYaml.patchVerification, isNull);
    });

    test('can be deserialized with patch_verification: strict', () {
      const yaml = '''
app_id: test_app_id
patch_verification: strict
''';
      final quickpatchYaml = checkedYamlDecode(
        yaml,
        (m) => QuickPatchYaml.fromJson(m!),
      );
      expect(quickpatchYaml.appId, 'test_app_id');
      expect(quickpatchYaml.patchVerification, PatchVerification.strict);
    });

    test('can be deserialized with patch_verification: install_only', () {
      const yaml = '''
app_id: test_app_id
patch_verification: install_only
''';
      final quickpatchYaml = checkedYamlDecode(
        yaml,
        (m) => QuickPatchYaml.fromJson(m!),
      );
      expect(quickpatchYaml.appId, 'test_app_id');
      expect(quickpatchYaml.patchVerification, PatchVerification.installOnly);
    });

    test('throws when patch_verification has invalid value', () {
      const yaml = '''
app_id: test_app_id
patch_verification: invalid_value
''';
      expect(
        () => checkedYamlDecode(yaml, (m) => QuickPatchYaml.fromJson(m!)),
        throwsA(
          isA<ParsedYamlException>().having(
            (e) => e.message,
            'message',
            contains('patch_verification'),
          ),
        ),
      );
    });

    group('AppIdExtension', () {
      test('getAppId returns base app id when no flavor is provided', () {
        const quickpatchYaml = QuickPatchYaml(appId: 'test_app_id');
        expect(quickpatchYaml.getAppId(), 'test_app_id');
      });

      test('getAppId returns base app id when flavor is not found', () {
        const quickpatchYaml = QuickPatchYaml(
          appId: 'test_app_id',
          flavors: {
            'development': 'test_app_id1',
            'production': 'test_app_id2',
          },
        );
        expect(quickpatchYaml.getAppId(flavor: 'staging'), 'test_app_id');
      });

      test('getAppId returns app id for flavor', () {
        const quickpatchYaml = QuickPatchYaml(
          appId: 'test_app_id',
          flavors: {
            'development': 'test_app_id1',
            'production': 'test_app_id2',
          },
        );
        expect(quickpatchYaml.getAppId(flavor: 'development'), 'test_app_id1');
        expect(quickpatchYaml.getAppId(flavor: 'production'), 'test_app_id2');
      });
    });
  });
}
