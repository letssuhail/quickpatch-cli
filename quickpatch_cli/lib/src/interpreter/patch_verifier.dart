import 'dart:convert';
import 'dart:typed_data';

import 'package:asn1lib/asn1lib.dart' as asn1;
import 'package:crypto/crypto.dart' as crypto;
import 'package:pointycastle/pointycastle.dart';

/// {@template patch_verifier}
/// Verifies an interpreter (bytecode) patch before it is applied on device.
///
/// This is the security gate for arbitrary-code-push: a downloaded patch must
/// be both INTEGRITY-checked (sha256 matches the server's `hash`) and
/// AUTHENTICITY-checked (the server's `hash_signature` is a valid RSA-SHA256
/// signature of the hash, against the public key embedded in the app at release
/// time). Matches the signing scheme in [CodeSigner] (`SHA-256/RSA` over the
/// hex-hash string; public key is base64 DER of `ASN1Sequence(modulus,
/// exponent)`). Without this, anyone able to serve bytes to the device could
/// run arbitrary code.
///
/// This logic is mirrored verbatim in the generated server-OTA bootstrapper
/// (`InterpreterBuild._serverBootstrapper`); kept here too so the crypto is
/// unit-tested independently of a device.
/// {@endtemplate}
abstract final class PatchVerifier {
  /// Returns true only if [bytes] hashes to [expectedHashHex] AND
  /// [signatureB64] is a valid signature of that hash under [publicKeyBase64].
  static bool verify({
    required Uint8List bytes,
    required String expectedHashHex,
    required String signatureB64,
    required String publicKeyBase64,
  }) =>
      verifyAny(
        bytes: bytes,
        expectedHashHex: expectedHashHex,
        signatureB64: signatureB64,
        publicKeysBase64: [publicKeyBase64],
      );

  /// Like [verify] but accepts ANY one of several trusted keys. This is what
  /// enables signing-key rotation: a release trusts the primary key plus any
  /// rotation keys, so a patch signed by a rotated key verifies alongside one
  /// signed by the prior key. A valid-but-wrong key is skipped, not accepted.
  /// An empty (or all-blank) list means no key is configured → returns false
  /// for a signed patch (callers treat an empty list as "unsigned release"
  /// before calling, mirroring the on-device bootstrapper).
  static bool verifyAny({
    required Uint8List bytes,
    required String expectedHashHex,
    required String signatureB64,
    required List<String> publicKeysBase64,
  }) {
    final hashHex = crypto.sha256.convert(bytes).toString();
    if (hashHex != expectedHashHex) return false;
    final message = Uint8List.fromList(utf8.encode(hashHex));
    final signature = RSASignature(base64.decode(signatureB64));
    for (final publicKeyBase64 in publicKeysBase64) {
      if (publicKeyBase64.isEmpty) continue;
      try {
        final seq =
            asn1.ASN1Parser(base64.decode(publicKeyBase64)).nextObject()
                as asn1.ASN1Sequence;
        final modulus =
            (seq.elements[0] as asn1.ASN1Integer).valueAsBigInteger;
        final exponent =
            (seq.elements[1] as asn1.ASN1Integer).valueAsBigInteger;
        final verifier = Signer('SHA-256/RSA')
          ..init(
            false,
            PublicKeyParameter<RSAPublicKey>(RSAPublicKey(modulus, exponent)),
          );
        if (verifier.verifySignature(message, signature)) return true;
      } on Object {
        // Undecodable/mismatched key — try the next trusted key.
      }
    }
    return false;
  }
}
