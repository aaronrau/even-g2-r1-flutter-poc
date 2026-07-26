import 'dart:typed_data';

Uint8List parseHex(String input) {
  final compact = input.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (compact.isEmpty) {
    throw const FormatException('Enter at least one hexadecimal byte.');
  }
  if (compact.length.isOdd) {
    throw const FormatException('Hex data must contain complete byte pairs.');
  }
  return Uint8List.fromList(<int>[
    for (var index = 0; index < compact.length; index += 2)
      int.parse(compact.substring(index, index + 2), radix: 16),
  ]);
}

String hexOf(Iterable<int> value, {int maxBytes = 48}) {
  final bytes = value.take(maxBytes).toList(growable: false);
  final text = bytes
      .map((byte) => (byte & 0xff).toRadixString(16).padLeft(2, '0'))
      .join(' ')
      .toUpperCase();
  return value.length > maxBytes ? '$text …' : text;
}
