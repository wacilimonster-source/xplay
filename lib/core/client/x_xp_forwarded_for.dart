import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

import 'x_api_constants.dart';

/// Generates the `x-xp-forwarded-for` header X requires on endpoints like
/// SearchTimeline and Followers since 2026.
///
/// X derives an AES-256 key from SHA-256(base_key + guest_id) and returns
/// `hex(IV || ciphertext || authTag)` of a small JSON payload. The value is
/// only valid for 5 minutes.
class XpForwardedFor {
  XpForwardedFor._();

  /// Hardcoded in X's FwdForSdk WASM data section (not dynamic).
  static const String baseKey =
      '0e6be1f1e21ffc33590b888fd4dc81b19713e570e805d4e5df80a493c9571a05';

  /// Builds the header value for [guestId] (must be URL-encoded, e.g.
  /// `v1%3A...`). Returns null when generation fails.
  static String? generate({required String guestId, String? userAgent}) {
    if (guestId.isEmpty) return null;
    try {
      final rawKey = utf8.encode('$baseKey$guestId');
      final key = Uint8List.fromList(sha256.convert(rawKey).bytes);

      final plain = jsonEncode({
        'navigator_properties': {
          'hasBeenActive': 'true',
          'userAgent': userAgent ?? xMobileUserAgent,
          'webdriver': 'false',
        },
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });

      final iv = Uint8List(12);
      final rng = Random.secure();
      for (var i = 0; i < iv.length; i++) {
        iv[i] = rng.nextInt(256);
      }

      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          true,
          AEADParameters(
            KeyParameter(key),
            128,
            iv,
            Uint8List(0),
          ),
        );

      final plainBytes = utf8.encode(plain);
      final out = Uint8List(cipher.getOutputSize(plainBytes.length));
      final processed =
          cipher.processBytes(plainBytes, 0, plainBytes.length, out, 0);
      cipher.doFinal(out, processed);

      final combined = Uint8List(iv.length + out.length)
        ..setAll(0, iv)
        ..setAll(iv.length, out);
      return combined.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    } catch (e) {
      return null;
    }
  }
}