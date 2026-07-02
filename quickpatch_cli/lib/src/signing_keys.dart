/// Zero-config patch signing.
///
/// Users shouldn't need to know openssl to get signed patches. On the first
/// `quickpatch release` for an app, an RSA-2048 key pair is generated into
/// the per-app key store and used automatically; every later `release` and
/// `patch` picks it up from the same place. Explicit `--public-key-path` /
/// `--private-key-path` / `--public-key-cmd` / `--sign-cmd` always win, so
/// CI setups and externally-managed keys keep working unchanged.
///
/// Store layout: `<configDirectory>/keys/<appId>/{private.pem,public.pem}`
/// (next to the CLI's credentials, independent of where the CLI binary
/// lives, and never inside the user's project so it cannot end up in git).
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:quickpatch_cli/src/logging/logging.dart';
import 'package:quickpatch_cli/src/quickpatch_env.dart';
import 'package:quickpatch_cli/src/quickpatch_process.dart';

/// Default signing keys for the current command invocation, populated from
/// the per-app key store when the user passed no key flags. The key
/// resolution in `arg_results.dart` and the patch signer consult these as a
/// fallback after the explicit flags.
class SigningKeyDefaults {
  SigningKeyDefaults._();

  /// The public key to embed in releases / verify patches against.
  static File? publicKey;

  /// The private key to sign patch artifacts with.
  static File? privateKey;

  /// Clears the defaults (tests).
  static void clear() {
    publicKey = null;
    privateKey = null;
  }
}

/// The key-store directory for [appId].
Directory signingKeyDirectory(String appId) =>
    Directory(p.join(quickpatchEnv.configDirectory.path, 'keys', appId));

/// The stored key pair for [appId], or null when absent/incomplete.
({File privateKey, File publicKey})? readAppSigningKeys(String appId) {
  final dir = signingKeyDirectory(appId);
  final privateKey = File(p.join(dir.path, 'private.pem'));
  final publicKey = File(p.join(dir.path, 'public.pem'));
  if (!privateKey.existsSync() || !publicKey.existsSync()) return null;
  return (privateKey: privateKey, publicKey: publicKey);
}

/// Returns the stored key pair for [appId], generating one (RSA-2048 via
/// openssl, matching the documented manual flow byte-for-byte) if absent.
///
/// Throws [ProcessException] when openssl is unavailable or fails.
Future<({File privateKey, File publicKey})> ensureAppSigningKeys(
  String appId,
) async {
  final existing = readAppSigningKeys(appId);
  if (existing != null) return existing;

  final dir = signingKeyDirectory(appId)..createSync(recursive: true);
  final privateKeyPath = p.join(dir.path, 'private.pem');
  final publicKeyPath = p.join(dir.path, 'public.pem');

  final genPrivate = await process.run('openssl', [
    'genpkey',
    '-algorithm', 'RSA',
    '-out', privateKeyPath,
    '-pkeyopt', 'rsa_keygen_bits:2048',
  ]);
  if (genPrivate.exitCode != 0) {
    throw ProcessException(
      'openssl',
      ['genpkey'],
      'Failed to generate a signing key: ${genPrivate.stderr}',
      genPrivate.exitCode,
    );
  }
  final genPublic = await process.run('openssl', [
    'rsa',
    '-in', privateKeyPath,
    '-pubout',
    '-out', publicKeyPath,
  ]);
  if (genPublic.exitCode != 0) {
    throw ProcessException(
      'openssl',
      ['rsa', '-pubout'],
      'Failed to derive the public key: ${genPublic.stderr}',
      genPublic.exitCode,
    );
  }
  // Private key is a secret: owner read/write only (best-effort on
  // platforms that support chmod).
  try {
    await process.run('chmod', ['600', privateKeyPath]);
  } on Object {
    // Windows / restricted environments — non-fatal.
  }

  logger
    ..info('')
    ..info('🔑 Generated a patch-signing key pair for this app:')
    ..info('   ${dir.path}')
    ..info(
      '   The public key is embedded in your releases; patches are signed '
      'automatically.',
    )
    ..warn(
      '   BACK UP private.pem — patches for releases built with this key '
      'can only ever be signed with it.',
    );

  return (
    privateKey: File(privateKeyPath),
    publicKey: File(publicKeyPath),
  );
}
