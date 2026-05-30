import 'package:path/path.dart' as p;

/// {@template interpreter_build}
/// Pure construction of the toolchain invocations for QuickPatch's iOS
/// arbitrary-code-push (Dart interpreter / dynamic-modules) path.
///
/// The architecture, host-proven end-to-end against real `package:flutter`
/// (see the engine proofs 2-9 + the merge-loader):
///
///  * RELEASE base: the app's own `lib/` is compiled to a `dart2bytecode`
///    module (interpreted, patchable). The AOT image is compiled from a
///    generated BOOTSTRAPPER entrypoint that imports the framework (so the
///    framework stays AOT and is referenced — not bundled — by the module)
///    but NOT the app code (so the app libs are naturally excluded from AOT).
///    A generated `dynamic_interface.yaml` marks the framework surface
///    `callable`/`extendable`/`can-be-overridden` so it is retained in AOT and
///    kept open-dispatch (so AOT framework calls reach interpreted overrides).
///
///  * PATCH: the changed app `lib/` is compiled to a `dart2bytecode` module
///    UNPREFIXED (same library URIs as the base). The on-device same-URI
///    MERGE-LOADER resolves the patch's references to the base library (so
///    private selectors match live instances) and swaps the bytecode onto the
///    existing functions. Only the app's own functions are interpreted; the
///    framework stays native. Patches are tiny (~1-2 KB).
///
/// This class only BUILDS the argument vectors and source — running them is
/// the caller's job (mirroring how the CLI already shells out to gen_snapshot
/// / gen_kernel / aot_tools). Keeping it pure makes it unit-testable without
/// the engine toolchain or a device.
/// {@endtemplate}
abstract final class InterpreterBuild {
  /// The language experiment the current Flutter framework source requires
  /// (null-aware collection elements, used pervasively in package:flutter).
  static const experimentFlag = '--enable-experiment=null-aware-elements';

  /// Generates the AOT bootstrapper `main()` source.
  ///
  /// It imports [frameworkImports] (so the framework is pulled into the AOT
  /// image and retained/open-dispatched by the generated interface) plus
  /// `package:dynamic_modules`, and loads the app bytecode module — whose
  /// entry-point IS the app's real `main()` (which calls `runApp`).
  ///
  /// The host/device split is isolated in `_qpAppModuleBytes`:
  ///  * [mode] == `'argv'`  — read a file path from `argv[0]` (host proofs);
  ///  * [mode] == `'asset'` — supplied by the engine load hook on device;
  ///  * [mode] == `'ota'`   — the PRODUCTION device variant: loads the app
  ///    bytecode module from the bundled asset [appModuleAssetKey], then after
  ///    the first frame downloads the latest `.bytecode` patch over HTTPS from
  ///    [otaPatchUrl] and applies it live via [loadModuleAsPatch] +
  ///    `reassembleApplication()`. This is the over-the-air code-push variant
  ///    proven on a physical iPhone (2026-05-30).
  ///
  /// When [applyPatch] is true (argv/asset modes) the bootstrapper, after
  /// loading the base app module, applies a staged patch via [loadModuleAsPatch]
  /// — the same-URI merge-loader swaps the changed functions onto the live app.
  static String generateBootstrapperMain({
    List<String> frameworkImports = const ['package:flutter/material.dart'],
    String mode = 'asset',
    String assetKey = 'assets/app.qpmod',
    bool applyPatch = true,
    String? otaPatchUrl,
    String appModuleAssetKey = 'assets/app.qpmod',
    Duration otaDelay = const Duration(seconds: 2),
    String? serverBaseUrl,
    String? appId,
    String? releaseVersion,
    String channel = 'stable',
    String? publicKeyBase64,
  }) {
    if (mode == 'ota') {
      assert(otaPatchUrl != null, 'ota mode requires otaPatchUrl');
      return _otaBootstrapper(
        frameworkImports: frameworkImports,
        otaPatchUrl: otaPatchUrl!,
        appModuleAssetKey: appModuleAssetKey,
        otaDelaySeconds: otaDelay.inSeconds,
      );
    }
    if (mode == 'server') {
      assert(
        serverBaseUrl != null && appId != null && releaseVersion != null,
        'server mode requires serverBaseUrl, appId, releaseVersion',
      );
      return _serverBootstrapper(
        frameworkImports: frameworkImports,
        baseUrl: serverBaseUrl!,
        appId: appId!,
        releaseVersion: releaseVersion!,
        channel: channel,
        appModuleAssetKey: appModuleAssetKey,
        otaDelaySeconds: otaDelay.inSeconds,
        publicKeyBase64: publicKeyBase64 ?? '',
      );
    }
    assert(mode == 'argv' || mode == 'asset', 'mode must be argv|asset|ota');
    final b = StringBuffer()
      ..writeln('// AUTO-GENERATED QuickPatch bootstrapper — do not edit.')
      ..writeln("import 'dart:typed_data';");
    if (mode == 'argv') b.writeln("import 'dart:io';");
    for (final imp in frameworkImports) {
      b.writeln("import '$imp';");
    }
    b
      ..writeln("import 'package:dynamic_modules/dynamic_modules.dart';")
      ..writeln()
      ..writeln('Future<void> main(List<String> args) async {')
      ..writeln('  await loadModuleFromBytes(await _qpAppModuleBytes(args));');
    if (applyPatch) {
      b
        ..writeln('  final patch = await _qpPatchBytes(args);')
        ..writeln('  if (patch != null) {')
        ..writeln('    // Same-URI merge-loader: swaps changed functions onto')
        ..writeln('    // the live app. The second arg (prefix) is ignored.')
        ..writeln("    loadModuleAsPatch(patch, '');")
        ..writeln('  }');
    }
    b
      ..writeln('}')
      ..writeln()
      ..writeln('Future<Uint8List> _qpAppModuleBytes(List<String> args) async {');
    if (mode == 'argv') {
      b.writeln('  return Uint8List.fromList(File(args[0]).readAsBytesSync());');
    } else {
      b
        ..writeln('  // Device: module ships as asset "$assetKey"; the engine')
        ..writeln('  // load hook supplies the bytes.')
        ..writeln("  throw UnimplementedError('engine hook supplies bytes');");
    }
    b.writeln('}');
    if (applyPatch) {
      b
        ..writeln()
        ..writeln('Future<Uint8List?> _qpPatchBytes(List<String> args) async {');
      if (mode == 'argv') {
        b
          ..writeln('  if (args.length < 2) return null;')
          ..writeln('  return Uint8List.fromList(File(args[1]).readAsBytesSync());');
      } else {
        b
          ..writeln('  // Device: the patch download/cache infra stages the')
          ..writeln('  // .bytecode; the engine hook supplies it (null = none).')
          ..writeln('  return null;');
      }
      b.writeln('}');
    }
    return b.toString();
  }

  /// The production over-the-air bootstrapper (mode `'ota'`). Loads the bundled
  /// app bytecode module, then downloads + applies the latest patch over HTTPS.
  static String _otaBootstrapper({
    required List<String> frameworkImports,
    required String otaPatchUrl,
    required String appModuleAssetKey,
    required int otaDelaySeconds,
  }) {
    final b = StringBuffer()
      ..writeln('// AUTO-GENERATED QuickPatch OTA bootstrapper — do not edit.')
      ..writeln("import 'dart:io';")
      ..writeln("import 'dart:typed_data';");
    for (final imp in frameworkImports) {
      b.writeln("import '$imp';");
    }
    b
      ..writeln("import 'package:flutter/services.dart' show rootBundle;")
      ..writeln("import 'package:dynamic_modules/dynamic_modules.dart';")
      ..writeln()
      ..writeln("const _otaPatchUrl = '$otaPatchUrl';")
      ..writeln()
      ..writeln('Future<void> main() async {')
      ..writeln('  WidgetsFlutterBinding.ensureInitialized();')
      ..writeln("  final appBytes =")
      ..writeln("      (await rootBundle.load('$appModuleAssetKey')).buffer.asUint8List();")
      ..writeln('  await loadModuleFromBytes(appBytes); // app main() -> runApp')
      ..writeln('  WidgetsBinding.instance.addPostFrameCallback((_) async {')
      ..writeln('    await Future<void>.delayed(')
      ..writeln('        const Duration(seconds: $otaDelaySeconds));')
      ..writeln('    try {')
      ..writeln('      final patch = await _qpDownloadPatch();')
      ..writeln('      if (patch == null || patch.isEmpty) return;')
      ..writeln("      loadModuleAsPatch(patch, '');")
      ..writeln('      WidgetsBinding.instance.reassembleApplication();')
      ..writeln('    } on Object catch (e) {')
      ..writeln("      debugPrint('QUICKPATCH: OTA skipped (\$e)');")
      ..writeln('    }')
      ..writeln('  });')
      ..writeln('}')
      ..writeln()
      ..writeln('Future<Uint8List?> _qpDownloadPatch() async {')
      ..writeln('  final client = HttpClient();')
      ..writeln('  try {')
      ..writeln('    final res = await (await client.getUrl(Uri.parse(_otaPatchUrl))).close();')
      ..writeln('    if (res.statusCode != 200) return null;')
      ..writeln('    final bb = BytesBuilder(copy: false);')
      ..writeln('    await for (final c in res) {')
      ..writeln('      bb.add(c);')
      ..writeln('    }')
      ..writeln('    return bb.takeBytes();')
      ..writeln('  } finally {')
      ..writeln('    client.close(force: true);')
      ..writeln('  }')
      ..writeln('}');
    return b.toString();
  }

  /// The production server-routed OTA bootstrapper (mode `'server'`).
  ///
  /// **Download-now / apply-on-next-launch** semantics (NOT a live hot-swap):
  ///  * BOOT — after loading the bundled base module, it applies any previously
  ///    STAGED patch from disk (re-verified) via [loadModuleAsPatch] *before the
  ///    first frame*, so the very first paint is already patched (no flash of
  ///    the old UI, no `reassembleApplication()` morph).
  ///  * BACKGROUND — after the first frame it queries the patch-check API
  ///    ([baseUrl]/api/v1/patches/check) for the current release/channel; a
  ///    newer, signature-verified patch is downloaded and STAGED to disk
  ///    (atomic temp+rename). It is never applied to the running session — it
  ///    takes effect on the next launch. A server rollback of the running patch
  ///    clears the stage so the next launch reverts to the base.
  ///
  /// Routed through the real QuickPatch channel (release / track / rollback)
  /// rather than a hardcoded CDN URL.
  static String _serverBootstrapper({
    required List<String> frameworkImports,
    required String baseUrl,
    required String appId,
    required String releaseVersion,
    required String channel,
    required String appModuleAssetKey,
    required int otaDelaySeconds,
    required String publicKeyBase64,
  }) {
    final base = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final b = StringBuffer()
      ..writeln('// AUTO-GENERATED QuickPatch server-OTA bootstrapper.')
      ..writeln("import 'dart:convert';")
      ..writeln("import 'dart:io';")
      ..writeln("import 'dart:typed_data';");
    for (final imp in frameworkImports) {
      b.writeln("import '$imp';");
    }
    b
      ..writeln("import 'package:flutter/services.dart' show rootBundle;")
      ..writeln("import 'package:dynamic_modules/dynamic_modules.dart';")
      ..writeln("import 'package:asn1lib/asn1lib.dart' as asn1;")
      ..writeln("import 'package:crypto/crypto.dart' as crypto;")
      ..writeln("import 'package:pointycastle/pointycastle.dart' as pc;")
      ..writeln()
      ..writeln("const _base = '$base';")
      ..writeln("const _appId = '$appId';")
      ..writeln("const _releaseVersion = '$releaseVersion';")
      ..writeln("const _channel = '$channel';")
      ..writeln("const _publicKeyB64 = '$publicKeyBase64';")
      ..writeln("const _appModuleAssetKey = '$appModuleAssetKey';")
      ..writeln('const _otaDelaySeconds = $otaDelaySeconds;')
      ..writeln()
      // The static body uses only the consts above; emit it raw so the
      // generated code's own `$` interpolations stay literal.
      ..write(_serverBootstrapperBody);
    return b.toString();
  }

  /// The static portion of the server-OTA bootstrapper (everything after the
  /// generated `const _…` header). Emitted raw so the generated code's own
  /// `$…` interpolations are preserved verbatim; it depends only on the
  /// `_base`/`_appId`/`_releaseVersion`/`_channel`/`_publicKeyB64`/
  /// `_appModuleAssetKey`/`_otaDelaySeconds` consts the header defines.
  static const _serverBootstrapperBody = r'''
// Staged OTA: a downloaded patch is NEVER applied to the running session. It is
// STAGED to disk and applied at the NEXT launch, before the first frame — so the
// first paint is already patched (no flash of the old UI, no live reassemble).
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1) BOOT-TIME APPLY: load the base, then swap a previously-staged,
  //    re-verified patch onto it. The first frame is HELD (deferFirstFrame)
  //    across both steps so the very first paint is already patched — no flash
  //    of the old UI even if module loading yields to the event loop, and no
  //    live reassemble.
  var applied = 0;
  WidgetsBinding.instance.deferFirstFrame();
  try {
    final appBytes =
        (await rootBundle.load(_appModuleAssetKey)).buffer.asUint8List();
    await loadModuleFromBytes(appBytes); // base app main() -> runApp
    final staged = _qpReadStaged();
    if (staged != null) {
      loadModuleAsPatch(staged.bytes, '');
      applied = staged.number;
      debugPrint('QUICKPATCH: staged patch #${staged.number} applied at boot');
    } else {
      debugPrint('QUICKPATCH: no staged patch; running base');
    }
  } on Object catch (e) {
    debugPrint('QUICKPATCH: boot-apply skipped ($e)');
  } finally {
    WidgetsBinding.instance.allowFirstFrame();
  }

  // 2) BACKGROUND DOWNLOAD (after first frame): fetch a newer patch and STAGE
  //    it for the next launch. Never applied live.
  WidgetsBinding.instance.addPostFrameCallback((_) async {
    await Future<void>.delayed(const Duration(seconds: _otaDelaySeconds));
    try {
      debugPrint(
          'QUICKPATCH: OTA check (release=$_releaseVersion, have=#$applied)');
      final res = await _qpCheckServer(applied);
      if (res == null) {
        debugPrint('QUICKPATCH: OTA check unavailable');
        return;
      }
      // A server rollback of the patch we are running -> drop the stage so the
      // next launch reverts to the base.
      if (res.rolledBack.contains(applied) && applied != 0) {
        _qpClearStaged();
        debugPrint('QUICKPATCH: patch #$applied rolled back; staged cleared');
        return;
      }
      final p = res.patch;
      if (p == null) {
        debugPrint('QUICKPATCH: no newer patch');
        return;
      }
      _qpWriteStaged(p);
      debugPrint('QUICKPATCH: patch #${p.number} STAGED for next launch');
    } on Object catch (e) {
      debugPrint('QUICKPATCH: OTA error ($e)');
    }
  });
}

class _QpStaged {
  _QpStaged(this.bytes, this.number, this.hash, this.sig);
  final Uint8List bytes;
  final int number;
  final String? hash;
  final String? sig;
}

class _QpCheck {
  _QpCheck(this.patch, this.rolledBack);
  final _QpStaged? patch;
  final List<int> rolledBack;
}

// iOS sandbox: systemTemp = <container>/tmp, so its parent is the app
// container; we stage under Application Support (app-private).
Directory _qpStageDir() {
  final container = Directory.systemTemp.parent.path;
  return Directory(
      '$container/Library/Application Support/quickpatch/qp_stage');
}

// Read + re-verify the staged patch for THIS release. Returns null when there
// is none, it targets a different release, or it fails re-verification.
_QpStaged? _qpReadStaged() {
  final dir = _qpStageDir();
  final meta = File('${dir.path}/patch.json');
  final blob = File('${dir.path}/patch.qpmod');
  if (!meta.existsSync() || !blob.existsSync()) return null;
  final m = jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
  if (m['release_version'] != _releaseVersion) {
    debugPrint(
        'QUICKPATCH: staged patch for ${m['release_version']} != $_releaseVersion; ignoring');
    return null;
  }
  final bytes = Uint8List.fromList(blob.readAsBytesSync());
  final hash = m['hash'] as String?;
  final sig = m['sig'] as String?;
  if (!_qpVerify(bytes, hash, sig)) {
    debugPrint('QUICKPATCH: staged patch failed re-verify; ignoring');
    return null;
  }
  return _QpStaged(bytes, (m['number'] as num?)?.toInt() ?? 0, hash, sig);
}

// Atomically stage a verified patch: write temp files then rename over the
// live names so a crash mid-write can never leave a half-written patch that
// boots.
void _qpWriteStaged(_QpStaged p) {
  final dir = _qpStageDir();
  if (!dir.existsSync()) dir.createSync(recursive: true);
  File('${dir.path}/patch.qpmod.tmp').writeAsBytesSync(p.bytes, flush: true);
  File('${dir.path}/patch.json.tmp').writeAsStringSync(
    jsonEncode({
      'number': p.number,
      'release_version': _releaseVersion,
      'hash': p.hash,
      'sig': p.sig,
    }),
    flush: true,
  );
  File('${dir.path}/patch.qpmod.tmp').renameSync('${dir.path}/patch.qpmod');
  File('${dir.path}/patch.json.tmp').renameSync('${dir.path}/patch.json');
}

void _qpClearStaged() {
  final dir = _qpStageDir();
  if (dir.existsSync()) dir.deleteSync(recursive: true);
}

// Query the patch-check API. Downloads + verifies a newer patch (returned in
// `patch`) and surfaces any `rolled_back_patch_numbers`. Returns null only on
// a transport/HTTP failure (so the caller leaves the current stage untouched).
Future<_QpCheck?> _qpCheckServer(int currentPatchNumber) async {
  final client = HttpClient();
  try {
    final checkReq =
        await client.postUrl(Uri.parse('$_base/api/v1/patches/check'));
    checkReq.headers.contentType = ContentType.json;
    checkReq.write(jsonEncode({
      'app_id': _appId,
      'channel': _channel,
      'release_version': _releaseVersion,
      'platform': 'ios',
      'arch': 'aarch64',
      'current_patch_number': currentPatchNumber,
    }));
    final checkRes = await checkReq.close();
    if (checkRes.statusCode != 200) return null;
    final body = jsonDecode(await checkRes.transform(utf8.decoder).join())
        as Map<String, dynamic>;
    final rolled = (body['rolled_back_patch_numbers'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        const <int>[];
    if (body['patch_available'] != true) {
      return _QpCheck(null, rolled);
    }
    final patch = body['patch'] as Map<String, dynamic>;
    final number = (patch['number'] as num?)?.toInt() ?? 0;
    final url = patch['download_url'] as String;
    final hash = patch['hash'] as String?;
    final sig = patch['hash_signature'] as String?;
    final dlRes = await (await client.getUrl(Uri.parse(url))).close();
    if (dlRes.statusCode != 200) return _QpCheck(null, rolled);
    final bb = BytesBuilder(copy: false);
    await for (final c in dlRes) {
      bb.add(c);
    }
    final bytes = bb.takeBytes();
    // SECURITY: only stage a patch whose signature verifies against the public
    // key embedded at release time.
    if (!_qpVerify(bytes, hash, sig)) {
      debugPrint('QUICKPATCH: downloaded patch verification FAILED — rejected');
      return _QpCheck(null, rolled);
    }
    return _QpCheck(_QpStaged(bytes, number, hash, sig), rolled);
  } finally {
    client.close(force: true);
  }
}

// Verify integrity (sha256) + authenticity (RSA-SHA256 over the hex hash)
// against the embedded public key. Empty key => unsigned release (no key was
// provided at release); signed patches require a valid signature.
bool _qpVerify(Uint8List bytes, String? hashHex, String? sigB64) {
  if (_publicKeyB64.isEmpty) return true; // unsigned release
  if (hashHex == null || sigB64 == null) return false;
  if (crypto.sha256.convert(bytes).toString() != hashHex) return false;
  try {
    final seq = asn1.ASN1Parser(base64.decode(_publicKeyB64))
        .nextObject() as asn1.ASN1Sequence;
    final mod = (seq.elements[0] as asn1.ASN1Integer).valueAsBigInteger;
    final exp = (seq.elements[1] as asn1.ASN1Integer).valueAsBigInteger;
    final v = pc.Signer('SHA-256/RSA')
      ..init(false,
          pc.PublicKeyParameter<pc.RSAPublicKey>(pc.RSAPublicKey(mod, exp)));
    return v.verifySignature(Uint8List.fromList(utf8.encode(hashHex)),
        pc.RSASignature(base64.decode(sigB64)));
  } on Object {
    return false;
  }
}
''';

  /// Arguments for compiling [entry] to the bootstrapper AOT kernel (or, with
  /// [noLinkPlatform], the `--import-dill` base used by [dart2bytecodeArgs]).
  ///
  /// [dynamicInterfacePath], when provided, flows the generated framework
  /// interface into the compile (keeps the framework surface retained +
  /// open-dispatch). The result is passed to the genKernel snapshot via
  /// `dartaotruntime`.
  static List<String> genKernelArgs({
    required String genKernelSnapshot,
    required String platformDill,
    required String packageConfig,
    required String entry,
    required String output,
    String? dynamicInterfacePath,
    bool noLinkPlatform = false,
    bool product = false,
    bool aot = false,
  }) {
    return [
      genKernelSnapshot,
      if (aot) '--aot',
      '--target', 'flutter',
      '--platform', platformDill,
      '--packages', packageConfig,
      '-Ddart.vm.product=$product',
      if (noLinkPlatform) '--no-link-platform',
      if (dynamicInterfacePath != null) ...[
        '--dynamic-interface',
        dynamicInterfacePath,
      ],
      experimentFlag,
      '--output', output,
      entry,
    ];
  }

  /// Arguments for compiling [entry] (the changed app for a patch, or the whole
  /// app `lib/` for the release base module) to a `dart2bytecode` module.
  ///
  /// [importDill] is the base bootstrapper kernel (supplies the framework so
  /// the module REFERENCES it). The patch is intentionally UNPREFIXED so the
  /// on-device merge-loader resolves references to the base library.
  static List<String> dart2bytecodeArgs({
    required String dart2bytecodeSnapshot,
    required String platformDill,
    required String packageConfig,
    required String importDill,
    required String entry,
    required String output,
    bool product = false,
  }) {
    return [
      dart2bytecodeSnapshot,
      '--target', 'flutter',
      '--platform', platformDill,
      '--packages', packageConfig,
      '-Ddart.vm.product=$product',
      '--import-dill', importDill,
      experimentFlag,
      '--output', output,
      entry,
    ];
  }

  /// Arguments for the framework dynamic-interface generator (run with a Dart
  /// that can resolve `package:kernel`). It walks [inputDill] and emits the
  /// framework/SDK surface, excluding [appPackages] (the app's own libs are
  /// bytecode-from-start and need no marking).
  static List<String> genInterfaceArgs({
    required String generatorScript,
    required String inputDill,
    required String outputYaml,
    required List<String> appPackages,
  }) {
    return [
      generatorScript,
      inputDill,
      outputYaml,
      for (final pkg in appPackages) '--app-package=$pkg',
    ];
  }

  /// Standard on-disk name of the app bytecode module bundled with a release.
  static String appModuleAssetName = 'app.qpmod';

  /// Path of the app bytecode module within [buildDir].
  static String appModulePath(String buildDir) =>
      p.join(buildDir, appModuleAssetName);
}
