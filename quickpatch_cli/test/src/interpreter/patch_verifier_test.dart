import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:quickpatch_cli/src/code_signer.dart';
import 'package:quickpatch_cli/src/interpreter/patch_verifier.dart';
import 'package:test/test.dart';

/// Validates the on-device verification crypto against the REAL QuickPatch
/// signing scheme (CodeSigner: SHA-256/RSA over the hex-hash string). Uses
/// openssl to generate a keypair (matches `quickpatch keys create`).
void main() {
  group(PatchVerifier, () {
    late Directory tmp;
    late String privateKeyPath;
    late String publicKeyBase64;
    final signer = CodeSigner();
    final patch = Uint8List.fromList(utf8.encode('hello bytecode patch'));
    late String hashHex;
    late String signatureB64;

    setUpAll(() {
      tmp = Directory.systemTemp.createTempSync('qp_verify');
      privateKeyPath = '${tmp.path}/private.pem';
      final pubPath = '${tmp.path}/public.pem';
      // openssl genpkey -algorithm RSA ... ; openssl rsa -pubout
      Process.runSync('openssl', [
        'genpkey', '-algorithm', 'RSA', '-out', privateKeyPath,
        '-pkeyopt', 'rsa_keygen_bits:2048',
      ]);
      Process.runSync('openssl', [
        'rsa', '-in', privateKeyPath, '-pubout', '-out', pubPath,
      ]);
      publicKeyBase64 = signer.base64PublicKey(File(pubPath));
      // The signed message is the patch's hex sha256 (as the server stores it).
      hashHex =
          (Process.runSync('shasum', ['-a', '256', _write(tmp, patch)]).stdout
                  as String)
              .split(' ')
              .first;
      signatureB64 =
          signer.sign(message: hashHex, privateKeyPemFile: File(privateKeyPath));
    });

    tearDownAll(() => tmp.deleteSync(recursive: true));

    test('accepts a correctly signed patch', () {
      expect(
        PatchVerifier.verify(
          bytes: patch,
          expectedHashHex: hashHex,
          signatureB64: signatureB64,
          publicKeyBase64: publicKeyBase64,
        ),
        isTrue,
      );
    });

    test('rejects tampered bytes (hash mismatch)', () {
      expect(
        PatchVerifier.verify(
          bytes: Uint8List.fromList([...patch, 0]),
          expectedHashHex: hashHex,
          signatureB64: signatureB64,
          publicKeyBase64: publicKeyBase64,
        ),
        isFalse,
      );
    });

    test('rejects a bad signature', () {
      expect(
        PatchVerifier.verify(
          bytes: patch,
          expectedHashHex: hashHex,
          signatureB64: base64.encode(List.filled(256, 0)),
          publicKeyBase64: publicKeyBase64,
        ),
        isFalse,
      );
    });

    test('rejects a signature from a different key', () {
      final other = '${tmp.path}/other.pem';
      Process.runSync('openssl', [
        'genpkey', '-algorithm', 'RSA', '-out', other,
        '-pkeyopt', 'rsa_keygen_bits:2048',
      ]);
      final otherSig = signer.sign(message: hashHex, privateKeyPemFile: File(other));
      expect(
        PatchVerifier.verify(
          bytes: patch,
          expectedHashHex: hashHex,
          signatureB64: otherSig,
          publicKeyBase64: publicKeyBase64,
        ),
        isFalse,
      );
    });
  });
}

String _write(Directory dir, Uint8List bytes) {
  final f = File('${dir.path}/patch.bin')..writeAsBytesSync(bytes);
  return f.path;
}
