import 'package:json_annotation/json_annotation.dart';

part 'quickpatch_yaml.g.dart';

/// The patch verification mode for the app.
@JsonEnum(fieldRename: FieldRename.snake)
enum PatchVerification {
  /// Verify the patch signature and hash before installing and loading.
  strict,

  /// Verify the patch signature and hash before installing, but not when
  /// loading from cache.
  installOnly,
}

/// {@template quickpatch_yaml}
/// A QuickPatch configuration file which contains metadata about the app.
/// {@endtemplate}
@JsonSerializable(anyMap: true, disallowUnrecognizedKeys: true)
class QuickPatchYaml {
  /// {@macro quickpatch_yaml}
  const QuickPatchYaml({
    required this.appId,
    this.flavors,
    this.baseUrl,
    this.autoUpdate,
    this.patchVerification,
    this.patchPublicKey,
    this.patchPublicKeys,
  });

  /// Creates a [QuickPatchYaml] from a JSON map.
  factory QuickPatchYaml.fromJson(Map<dynamic, dynamic> json) =>
      _$QuickPatchYamlFromJson(json);

  /// Converts this [QuickPatchYaml] to a JSON map.
  Map<String, dynamic> toJson() => _$QuickPatchYamlToJson(this);

  /// The base app id.
  ///
  /// Example:
  /// `"8d3155a8-a048-4820-acca-824d26c29b71"`
  final String appId;

  /// A map of flavor names to app ids.
  ///
  /// Will be `null` for apps with no flavors.
  ///
  /// Example:
  /// ```json
  /// {
  ///   "development": "8d3155a8-a048-4820-acca-824d26c29b71",
  ///   "production": "d458e87a-7362-4386-9eeb-629db2af413a"
  /// }
  /// ```
  final Map<String, String>? flavors;

  /// The base url used to check for updates.
  final String? baseUrl;

  /// Whether or not to automatically update the app.
  final bool? autoUpdate;

  /// The patch verification mode for the app.
  final PatchVerification? patchVerification;

  /// Base64-encoded public key the on-device updater uses to verify patch
  /// signatures. Embedded into the bundled config at build time (on vanilla
  /// Flutter, which lacks the fork's flutter_tools key-injection). Not secret.
  final String? patchPublicKey;

  /// Comma-separated additional trusted public keys for signing-key rotation:
  /// a patch verifies if its signature matches [patchPublicKey] or any of
  /// these. See the updater's `build_trusted_public_keys`.
  final String? patchPublicKeys;
}

/// Extension on [QuickPatchYaml] to get the app id for a specific flavor.
extension AppIdExtension on QuickPatchYaml {
  /// Returns the app id for the given flavor.
  String getAppId({String? flavor}) {
    if (flavor == null || flavors == null) return appId;
    return flavors![flavor] ?? appId;
  }
}
