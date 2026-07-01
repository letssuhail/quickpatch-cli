// GENERATED CODE - DO NOT MODIFY BY HAND

// ignore_for_file: implicit_dynamic_parameter, require_trailing_commas, cast_nullable_to_non_nullable, lines_longer_than_80_chars, strict_raw_type, unnecessary_lambdas

part of 'quickpatch_yaml.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

QuickPatchYaml _$QuickPatchYamlFromJson(Map json) => $checkedCreate(
  'QuickPatchYaml',
  json,
  ($checkedConvert) {
    $checkKeys(
      json,
      allowedKeys: const [
        'app_id',
        'flavors',
        'base_url',
        'auto_update',
        'patch_verification',
        'patch_public_key',
        'patch_public_keys',
      ],
    );
    final val = QuickPatchYaml(
      appId: $checkedConvert('app_id', (v) => v as String),
      flavors: $checkedConvert(
        'flavors',
        (v) => (v as Map?)?.map((k, e) => MapEntry(k as String, e as String)),
      ),
      baseUrl: $checkedConvert('base_url', (v) => v as String?),
      autoUpdate: $checkedConvert('auto_update', (v) => v as bool?),
      patchVerification: $checkedConvert(
        'patch_verification',
        (v) => $enumDecodeNullable(_$PatchVerificationEnumMap, v),
      ),
      patchPublicKey: $checkedConvert('patch_public_key', (v) => v as String?),
      patchPublicKeys: $checkedConvert(
        'patch_public_keys',
        (v) => v as String?,
      ),
    );
    return val;
  },
  fieldKeyMap: const {
    'appId': 'app_id',
    'baseUrl': 'base_url',
    'autoUpdate': 'auto_update',
    'patchVerification': 'patch_verification',
    'patchPublicKey': 'patch_public_key',
    'patchPublicKeys': 'patch_public_keys',
  },
);

Map<String, dynamic> _$QuickPatchYamlToJson(
  QuickPatchYaml instance,
) => <String, dynamic>{
  'app_id': instance.appId,
  'flavors': instance.flavors,
  'base_url': instance.baseUrl,
  'auto_update': instance.autoUpdate,
  'patch_verification': _$PatchVerificationEnumMap[instance.patchVerification],
  'patch_public_key': instance.patchPublicKey,
  'patch_public_keys': instance.patchPublicKeys,
};

const _$PatchVerificationEnumMap = {
  PatchVerification.strict: 'strict',
  PatchVerification.installOnly: 'install_only',
};
