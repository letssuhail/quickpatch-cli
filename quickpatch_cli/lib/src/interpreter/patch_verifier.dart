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
  }) {
    final hashHex = crypto.sha256.convert(bytes).toString();
    if (hashHex != expectedHashHex) return false;
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
      return verifier.verifySignature(
        Uint8List.fromList(utf8.encode(hashHex)),
        RSASignature(base64.decode(signatureB64)),
      );
    } on Object {
      return false;
    }
  }
}
