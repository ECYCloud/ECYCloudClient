import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

class CacheSeal {
  CacheSeal._();

  static const int _nonceBytes = 12;
  static const int _tagBits = 128;

  static String seal(Uint8List key, String plaintext, String context) {
    final Random random = Random.secure();
    final Uint8List nonce = Uint8List.fromList(
      List<int>.generate(_nonceBytes, (_) => random.nextInt(256)),
    );
    final Uint8List sealed = _cipher(
      true,
      key,
      nonce,
      context,
    ).process(Uint8List.fromList(utf8.encode(plaintext)));
    return base64Encode(<int>[...nonce, ...sealed]);
  }

  static String? open(Uint8List key, Object? value, String context) {
    if (value is! String) {
      return null;
    }
    try {
      final Uint8List data = base64Decode(value);
      if (data.length <= _nonceBytes + _tagBits ~/ 8) {
        return null;
      }
      return utf8.decode(
        _cipher(
          false,
          key,
          Uint8List.sublistView(data, 0, _nonceBytes),
          context,
        ).process(Uint8List.sublistView(data, _nonceBytes)),
      );
    } on Object {
      return null;
    }
  }

  static GCMBlockCipher _cipher(
    bool encrypt,
    Uint8List key,
    Uint8List nonce,
    String context,
  ) => GCMBlockCipher(AESEngine())
    ..init(
      encrypt,
      AEADParameters(
        KeyParameter(key),
        _tagBits,
        nonce,
        Uint8List.fromList(utf8.encode(context)),
      ),
    );
}
