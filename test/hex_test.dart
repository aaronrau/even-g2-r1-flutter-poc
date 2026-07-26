import 'package:even_g2_r1_poc/src/util/hex.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses spaced and prefixed-looking hexadecimal input', () {
    expect(parseHex('AA 21-00:FF'), <int>[0xaa, 0x21, 0x00, 0xff]);
  });

  test('rejects incomplete hexadecimal input', () {
    expect(() => parseHex('ABC'), throwsFormatException);
  });
}
