part of 'meshopt_decoder_3d.dart';

Uint8List _encodeVertexStream(
  Uint8List vertices, {
  required int count,
  required int byteStride,
}) {
  _checkVertexParams(count, byteStride);
  if (vertices.lengthInBytes < count * byteStride) {
    throw ArgumentError(
      'vertices buffer (${vertices.lengthInBytes}B) smaller than '
      'count * byteStride (${count * byteStride}B)',
    );
  }

  final out = BytesBuilder(copy: false)..addByte(_vertexHeader);
  final firstVertex = Uint8List(byteStride);
  if (count > 0) {
    firstVertex.setRange(0, byteStride, vertices);
  }
  final lastVertex = Uint8List.fromList(firstVertex);
  final blockSize = _vertexBlockSize(byteStride);
  final deltas = Uint8List(_vertexBlockMaxSize);
  final scratch = Uint8List(_vertexBlockMaxSize * 2 + 64);

  for (var offset = 0; offset < count; offset += blockSize) {
    final blockCount = math.min(blockSize, count - offset);
    final aligned = _align16(blockCount);
    for (var k = 0; k < byteStride; k++) {
      var p = lastVertex[k];
      for (var i = 0; i < blockCount; i++) {
        final v = vertices[(offset + i) * byteStride + k];
        deltas[i] = _zigzag8((v - p) & 0xFF);
        p = v;
      }
      deltas.fillRange(blockCount, aligned, 0);
      final written = _encodeBytes(deltas, aligned, _bitsV0, scratch);
      // `sublist` copies: the builder keeps the lists it is given.
      out.add(scratch.sublist(0, written));
    }
    lastVertex.setRange(
      0,
      byteStride,
      vertices,
      (offset + blockCount - 1) * byteStride,
    );
  }

  final tailPad = math.max(byteStride, _tailMinSizeV0);
  for (var i = byteStride; i < tailPad; i++) {
    out.addByte(0);
  }
  out.add(firstVertex);
  return out.toBytes();
}

/// Encodes [size] bytes of [buffer] (a multiple of 16) as byte groups with
/// the bit widths in [bits] into [out], returning the number of bytes written.
int _encodeBytes(
  Uint8List buffer,
  int size,
  List<int> bits,
  Uint8List out,
) {
  final headerSize = (size ~/ _byteGroupSize + 3) ~/ 4;
  out.fillRange(0, headerSize, 0);
  var data = headerSize;
  var lastBits = -1;
  for (var i = 0; i < size; i += _byteGroupSize) {
    var bestK = 3;
    var bestSize = _measureGroup(buffer, i, bits[bestK]);
    for (var k = 0; k < 3; k++) {
      final groupSize = _measureGroup(buffer, i, bits[k]);
      if (groupSize < bestSize ||
          (groupSize == bestSize && bits[k] == lastBits && bits[bestK] != 8)) {
        bestK = k;
        bestSize = groupSize;
      }
    }
    final group = i ~/ _byteGroupSize;
    out[group ~/ 4] |= bestK << ((group % 4) * 2);
    data = _encodeGroup(buffer, i, bits[bestK], out, data);
    lastBits = bits[bestK];
  }
  return data;
}

/// The encoded size of the 16-byte group at [offset] with [bits] bits per
/// value (a very large size when [bits] is 0 and the group is not zero).
int _measureGroup(Uint8List buffer, int offset, int bits) {
  if (bits == 0) {
    for (var i = 0; i < _byteGroupSize; i++) {
      if (buffer[offset + i] != 0) {
        return 1 << 30;
      }
    }
    return 0;
  }
  if (bits == 8) {
    return _byteGroupSize;
  }
  final sentinel = (1 << bits) - 1;
  var escapes = 0;
  for (var i = 0; i < _byteGroupSize; i++) {
    if (buffer[offset + i] >= sentinel) {
      escapes++;
    }
  }
  return _byteGroupSize ~/ 8 * bits + escapes;
}

int _encodeGroup(
  Uint8List buffer,
  int offset,
  int bits,
  Uint8List out,
  int data,
) {
  var cursor = data;
  if (bits == 0) {
    return cursor;
  }
  if (bits == 8) {
    out.setRange(cursor, cursor + _byteGroupSize, buffer, offset);
    return cursor + _byteGroupSize;
  }
  final perByte = 8 ~/ bits;
  final sentinel = (1 << bits) - 1;
  for (var i = 0; i < _byteGroupSize; i += perByte) {
    var byte = 0;
    for (var k = 0; k < perByte; k++) {
      final v = buffer[offset + i + k];
      byte = ((byte << bits) | (v >= sentinel ? sentinel : v)) & 0xFF;
    }
    if (bits == 1) {
      byte = _reverseBits8(byte);
    }
    out[cursor++] = byte;
  }
  for (var i = 0; i < _byteGroupSize; i++) {
    final v = buffer[offset + i];
    if (v >= sentinel) {
      out[cursor++] = v;
    }
  }
  return cursor;
}

Uint8List _decodeVertexStream(
  Uint8List encoded, {
  required int count,
  required int byteStride,
}) {
  _checkVertexParams(count, byteStride);
  if (encoded.isEmpty) {
    throw const FormatException('Empty meshopt vertex stream');
  }
  final header = encoded[0];
  if ((header & 0xF0) != _vertexHeader) {
    throw FormatException(
      'Not a meshopt vertex stream: header 0x${_hex(header)}',
    );
  }
  final version = header & 0x0F;
  if (version > _maxVertexVersion) {
    throw FormatException(
      'Unsupported meshopt vertex codec version $version (header '
      '0x${_hex(header)}); this decoder reads versions 0 and 1',
    );
  }

  final tailSize = byteStride + (version == 0 ? 0 : byteStride ~/ 4);
  final tailPad = math.max(
    tailSize,
    version == 0 ? _tailMinSizeV0 : _tailMinSizeV1,
  );
  if (encoded.length - 1 < tailPad) {
    throw const FormatException('Truncated meshopt vertex stream');
  }
  final tail = encoded.length - tailSize;
  final lastVertex = Uint8List(byteStride)
    ..setRange(0, byteStride, encoded, tail);
  final channels = version == 0 ? -1 : tail + byteStride;

  final out = Uint8List(count * byteStride);
  final blockSize = _vertexBlockSize(byteStride);
  final buffers = Uint8List(4 * _vertexBlockMaxSize);
  var data = 1;
  for (var offset = 0; offset < count; offset += blockSize) {
    final blockCount = math.min(blockSize, count - offset);
    data = _decodeVertexBlock(
      encoded,
      data,
      out,
      offset,
      blockCount,
      byteStride,
      lastVertex,
      channels,
      version,
      buffers,
    );
  }

  if (encoded.length - data != tailPad) {
    throw FormatException(
      'Malformed meshopt vertex stream: ${encoded.length - data - tailPad} '
      'bytes left between the data and the tail',
    );
  }
  return out;
}

int _decodeVertexBlock(
  Uint8List encoded,
  int start,
  Uint8List out,
  int vertexOffset,
  int count,
  int byteStride,
  Uint8List lastVertex,
  int channels,
  int version,
  Uint8List buffers,
) {
  final end = encoded.length;
  final aligned = _align16(count);
  final controlSize = version == 0 ? 0 : byteStride ~/ 4;
  if (end - start < controlSize) {
    throw const FormatException('Truncated meshopt vertex block');
  }
  final control = start;
  var data = start + controlSize;

  for (var k = 0; k < byteStride; k += 4) {
    final controlByte = version == 0 ? 0 : encoded[control + k ~/ 4];
    for (var j = 0; j < 4; j++) {
      final ctrl = (controlByte >> (j * 2)) & 3;
      final base = j * _vertexBlockMaxSize;
      if (ctrl == 3) {
        if (end - data < count) {
          throw const FormatException('Truncated meshopt literal block');
        }
        buffers.setRange(base, base + count, encoded, data);
        data += count;
      } else if (ctrl == 2) {
        buffers.fillRange(base, base + count, 0);
      } else {
        data = _decodeBytes(
          encoded,
          data,
          buffers,
          base,
          aligned,
          version == 0 ? _bitsV0 : _bitsV1,
          version == 0 ? 0 : ctrl,
        );
      }
    }

    final channel = version == 0 ? 0 : encoded[channels + k ~/ 4];
    switch (channel & 3) {
      case 0:
        for (var j = 0; j < 4; j++) {
          final base = j * _vertexBlockMaxSize;
          var p = lastVertex[k + j];
          var o = vertexOffset * byteStride + k + j;
          for (var i = 0; i < count; i++) {
            p = (_unzigzag8(buffers[base + i]) + p) & 0xFF;
            out[o] = p;
            o += byteStride;
          }
        }
      case 1:
        for (var j = 0; j < 4; j += 2) {
          final lo = j * _vertexBlockMaxSize;
          final hi = lo + _vertexBlockMaxSize;
          var p = lastVertex[k + j] | (lastVertex[k + j + 1] << 8);
          var o = vertexOffset * byteStride + k + j;
          for (var i = 0; i < count; i++) {
            final d = buffers[lo + i] | (buffers[hi + i] << 8);
            p = (_unzigzag16(d) + p) & 0xFFFF;
            out[o] = p & 0xFF;
            out[o + 1] = p >> 8;
            o += byteStride;
          }
        }
      case 2:
        final rot = (32 - (channel >> 4)) & 31;
        var p =
            lastVertex[k] |
            (lastVertex[k + 1] << 8) |
            (lastVertex[k + 2] << 16) |
            (lastVertex[k + 3] << 24);
        var o = vertexOffset * byteStride + k;
        for (var i = 0; i < count; i++) {
          final d =
              buffers[i] |
              (buffers[_vertexBlockMaxSize + i] << 8) |
              (buffers[2 * _vertexBlockMaxSize + i] << 16) |
              (buffers[3 * _vertexBlockMaxSize + i] << 24);
          p = _rotl32(d, rot) ^ p;
          out[o] = p & 0xFF;
          out[o + 1] = (p >> 8) & 0xFF;
          out[o + 2] = (p >> 16) & 0xFF;
          out[o + 3] = (p >>> 24) & 0xFF;
          o += byteStride;
        }
      default:
        throw FormatException(
          'Malformed meshopt vertex stream: invalid channel mode '
          '${channel & 3}',
        );
    }
  }

  lastVertex.setRange(
    0,
    byteStride,
    out,
    (vertexOffset + count - 1) * byteStride,
  );
  return data;
}

int _decodeBytes(
  Uint8List encoded,
  int start,
  Uint8List buffer,
  int base,
  int size,
  List<int> bits,
  int bitsOffset,
) {
  final end = encoded.length;
  final headerSize = (size ~/ _byteGroupSize + 3) ~/ 4;
  if (end - start < headerSize) {
    throw const FormatException('Truncated meshopt byte group header');
  }
  final header = start;
  var data = start + headerSize;
  for (var i = 0; i < size; i += _byteGroupSize) {
    if (end - data < _byteGroupDecodeLimit) {
      throw const FormatException('Truncated meshopt byte group');
    }
    final group = i ~/ _byteGroupSize;
    final k = (encoded[header + group ~/ 4] >> ((group % 4) * 2)) & 3;
    data = _decodeGroup(
      encoded,
      data,
      buffer,
      base + i,
      bits[bitsOffset + k],
    );
  }
  return data;
}

int _decodeGroup(
  Uint8List encoded,
  int data,
  Uint8List buffer,
  int offset,
  int bits,
) {
  switch (bits) {
    case 0:
      buffer.fillRange(offset, offset + _byteGroupSize, 0);
      return data;
    case 8:
      buffer.setRange(offset, offset + _byteGroupSize, encoded, data);
      return data + _byteGroupSize;
    case 1:
      var escapes = data + 2;
      for (var b = 0; b < 2; b++) {
        final byte = encoded[data + b];
        for (var k = 0; k < 8; k++) {
          final enc = (byte >> k) & 1;
          buffer[offset + b * 8 + k] = enc == 1 ? encoded[escapes++] : 0;
        }
      }
      return escapes;
    default:
      final perByte = 8 ~/ bits;
      final sentinel = (1 << bits) - 1;
      final groupBytes = _byteGroupSize ~/ perByte;
      var escapes = data + groupBytes;
      var o = offset;
      for (var b = 0; b < groupBytes; b++) {
        final byte = encoded[data + b];
        for (var k = perByte - 1; k >= 0; k--) {
          final enc = (byte >> (k * bits)) & sentinel;
          buffer[o++] = enc == sentinel ? encoded[escapes++] : enc;
        }
      }
      return escapes;
  }
}
