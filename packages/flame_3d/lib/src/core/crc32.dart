import 'dart:typed_data';

import 'package:meta/meta.dart';

final Uint32List _crc32Table = _buildCrc32Table();

Uint32List _buildCrc32Table() {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1);
    }
    table[i] = c & 0xFFFFFFFF;
  }
  return table;
}

/// Computes the standard IEEE 802.3 CRC32 checksum of `data[start..end)`,
/// optionally skipping bytes in `[skipRangeStart, skipRangeEnd)`.
@internal
int computeCrc32Bytes(
  Uint8List data, {
  int start = 0,
  int? end,
  int skipRangeStart = -1,
  int skipRangeEnd = -1,
}) {
  final table = _crc32Table;
  final stop = end ?? data.length;
  var crc = 0xFFFFFFFF;
  for (var i = start; i < stop; i++) {
    if (i >= skipRangeStart && i < skipRangeEnd) {
      continue;
    }
    crc = (crc >>> 8) ^ table[(crc ^ data[i]) & 0xFF];
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
