import 'dart:isolate';

import 'package:cryptography/cryptography.dart';

class PasswordHasher {
  const PasswordHasher();
  static const iterations = 600000;
  static const algorithm = 'pbkdf2-sha256';

  Future<List<int>> derive(String password, List<int> salt) =>
      Isolate.run(() async {
        final key = await Pbkdf2.hmacSha256(
          iterations: iterations,
          bits: 256,
        ).deriveKeyFromPassword(password: password, nonce: salt);
        return key.extractBytes();
      });

  static bool equal(List<int> first, List<int> second) {
    if (first.length != second.length) {
      return false;
    }
    var difference = 0;
    for (var i = 0; i < first.length; i++) {
      difference |= first[i] ^ second[i];
    }
    return difference == 0;
  }
}
