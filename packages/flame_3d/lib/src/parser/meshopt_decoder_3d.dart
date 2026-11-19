import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';

/// Stream compression mode defined by glTF `EXT_meshopt_compression`.
enum MeshoptMode3D(final String gltfValue) {
  /// General fixed-stride vertex/accessor attribute stream (`0xA0`).
  attributes('ATTRIBUTES'),

  /// Connected triangle index buffer (`0xE1`, `count % 3 == 0`).
  triangles('TRIANGLES'),

  /// Arbitrary scalar index sequence (`0xD1`).
  indices('INDICES');

  /// Resolves a [MeshoptMode3D] from its glTF JSON string (`ATTRIBUTES`,
  /// `TRIANGLES`, or `INDICES`).
  static MeshoptMode3D valueOf(String value) {
    return values.firstWhere(
      (e) => e.gltfValue == value,
      orElse: () =>
          throw FormatException('Unknown EXT_meshopt_compression mode: $value'),
    );
  }
}

/// Post-decompression attribute filter defined by glTF
/// `EXT_meshopt_compression`.
enum MeshoptFilter3D(final String gltfValue) {
  /// No post-decompression filter.
  none('NONE'),

  /// Octahedral unit-vector decoding (`4 x int8` or `4 x int16`).
  octahedral('OCTAHEDRAL'),

  /// Smallest-three unit-quaternion decoding (`4 x int16`).
  quaternion('QUATERNION'),

  /// 8-bit exponent + 24-bit signed mantissa float32 decoding.
  exponential('EXPONENTIAL');

  /// Resolves a [MeshoptFilter3D] from its glTF JSON string (defaults to
  /// [none] when `null`).
  static MeshoptFilter3D valueOf(String? value) {
    if (value == null || value.isEmpty) {
      return none;
    }
    return values.firstWhere(
      (e) => e.gltfValue == value,
      orElse: () => throw FormatException(
        'Unknown EXT_meshopt_compression filter: $value',
      ),
    );
  }
}

/// How [MeshoptDecoder3D.encodeFilterExp] chooses the exponent of each value.
enum MeshoptExpMode3D() {
  /// Every component of every element gets its own exponent.
  separate,

  /// All components of one element share the largest exponent among them
  /// (the default; what gltfpack uses for positions).
  sharedVector,

  /// Each component index shares the largest exponent across all elements.
  sharedComponent,

  /// Like [separate], but exponents below zero are raised to zero, so values
  /// below 1 lose precision instead of using tiny exponents.
  clamped,
}

/// Pure-Dart codec for the bitstreams of glTF 2.0 `EXT_meshopt_compression`,
/// compatible with meshoptimizer (`meshopt_decodeVertexBuffer`,
/// `meshopt_decodeIndexBuffer`, `meshopt_decodeIndexSequence` and the
/// `meshopt_decodeFilter*` functions), running identically on the Dart VM,
/// AOT and the web.
///
/// Decoding reads:
/// - `ATTRIBUTES` streams of vertex codec versions 0 (`0xA0`, the only version
///   `EXT_meshopt_compression` allows) and 1 (`0xA1`, written by
///   meshoptimizer 0.23 and later when asked for it);
/// - `TRIANGLES` streams of index codec versions 0 and 1 (`0xE0`, `0xE1`);
/// - `INDICES` streams (`0xD1`);
/// - the `OCTAHEDRAL`, `QUATERNION` and `EXPONENTIAL` filters, computed in
///   32-bit floating point like the reference.
///
/// A malformed or truncated stream throws a [FormatException]; a stream of a
/// newer codec version throws a [FormatException] naming the version, rather
/// than producing wrong data.
///
/// The encoders write streams that meshoptimizer decodes: vertex codec
/// version 0, index codec version 1, and the filter encodings of
/// `meshopt_encodeFilterOct`, `meshopt_encodeFilterQuat` and
/// `meshopt_encodeFilterExp`. They are meant for tests and small procedural
/// assets, not as a replacement for gltfpack.
abstract final class MeshoptDecoder3D._() {
  static const int _vertexHeader = 0xA0;
  static const int _indexHeader = 0xE0;
  static const int _sequenceHeader = 0xD0;
  static const int _maxVertexVersion = 1;
  static const int _maxIndexVersion = 1;

  static const int _byteGroupSize = 16;
  static const int _byteGroupDecodeLimit = 24;
  static const int _vertexBlockMaxSize = 256;
  static const int _tailMinSizeV0 = 32;
  static const int _tailMinSizeV1 = 24;

  static const List<int> _bitsV0 = <int>[0, 2, 4, 8];
  static const List<int> _bitsV1 = <int>[0, 1, 2, 4, 8];

  static const List<int> _codeAuxTable = <int>[
    0x00, 0x76, 0x87, 0x56, //
    0x67, 0x78, 0xA9, 0x86, //
    0x65, 0x89, 0x68, 0x98, //
    0x01, 0x69, 0x00, 0x00, //
  ];

  /// Decompresses a complete `EXT_meshopt_compression` buffer view slice and
  /// applies [filter] in place when `mode == MeshoptMode3D.attributes`.
  ///
  /// Checks the constraints of the extension (strides per mode and filter,
  /// filters only on attributes) and throws a [FormatException] when one does
  /// not hold.
  static Uint8List decodeBufferView(
    Uint8List compressed, {
    required int count,
    required int byteStride,
    required MeshoptMode3D mode,
    MeshoptFilter3D filter = MeshoptFilter3D.none,
  }) {
    switch (mode) {
      case MeshoptMode3D.attributes:
        if (byteStride <= 0 || byteStride > 256 || byteStride % 4 != 0) {
          throw FormatException(
            'EXT_meshopt_compression ATTRIBUTES needs a byteStride divisible '
            'by 4 and at most 256, got $byteStride',
          );
        }
        _checkFilterStride(filter, byteStride);
        final out = decodeVertexStream(
          compressed,
          count: count,
          byteStride: byteStride,
        );
        applyFilterInPlace(
          out,
          count: count,
          byteStride: byteStride,
          filter: filter,
        );
        return out;
      case MeshoptMode3D.triangles:
      case MeshoptMode3D.indices:
        if (filter != MeshoptFilter3D.none) {
          throw FormatException(
            'EXT_meshopt_compression filter ${filter.gltfValue} is only '
            'allowed with ATTRIBUTES, not ${mode.gltfValue}',
          );
        }
        if (byteStride != 2 && byteStride != 4) {
          throw FormatException(
            'EXT_meshopt_compression ${mode.gltfValue} needs a byteStride of '
            '2 or 4, got $byteStride',
          );
        }
        return decodeIndexStream(
          compressed,
          count: count,
          byteStride: byteStride,
          mode: mode,
        );
    }
  }

  static void _checkFilterStride(MeshoptFilter3D filter, int byteStride) {
    final ok = switch (filter) {
      MeshoptFilter3D.none => true,
      MeshoptFilter3D.octahedral => byteStride == 4 || byteStride == 8,
      MeshoptFilter3D.quaternion => byteStride == 8,
      MeshoptFilter3D.exponential => byteStride % 4 == 0,
    };
    if (!ok) {
      throw FormatException(
        'EXT_meshopt_compression filter ${filter.gltfValue} does not allow '
        'a byteStride of $byteStride',
      );
    }
  }

  // ===========================================================================
  // 1. Vertex attribute codec (`ATTRIBUTES`)
  // ===========================================================================

  /// Compresses [vertices] (`count * byteStride` bytes, `byteStride` a
  /// multiple of `4` in `4..256`) into an `ATTRIBUTES` stream of vertex codec
  /// version 0 (`0xA0`), as `meshopt_encodeVertexBuffer` writes it with
  /// version 0.
  static Uint8List encodeVertexStream(
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
  /// the bit widths in [bits] into [out], returning the number of bytes
  /// written.
  static int _encodeBytes(
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
            (groupSize == bestSize &&
                bits[k] == lastBits &&
                bits[bestK] != 8)) {
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
  static int _measureGroup(Uint8List buffer, int offset, int bits) {
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

  static int _encodeGroup(
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

  /// Decompresses an `ATTRIBUTES` stream (vertex codec version 0 or 1) into
  /// `count * byteStride` bytes.
  static Uint8List decodeVertexStream(
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

  static int _decodeVertexBlock(
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

  static int _decodeBytes(
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

  static int _decodeGroup(
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

  // ===========================================================================
  // 2. Index codecs (`TRIANGLES` and `INDICES`)
  // ===========================================================================

  /// Compresses `count` `Uint16` (`byteStride == 2`) or `Uint32`
  /// (`byteStride == 4`) indices into a `TRIANGLES` stream of index codec
  /// version 1 (`0xE1`) or an `INDICES` stream (`0xD1`).
  ///
  /// The triangle codec may rotate the corners of a triangle (keeping its
  /// winding), as meshoptimizer does.
  static Uint8List encodeIndexStream(
    Uint8List indices, {
    required int count,
    required int byteStride,
    MeshoptMode3D mode = MeshoptMode3D.triangles,
  }) {
    if (byteStride != 2 && byteStride != 4) {
      throw ArgumentError.value(byteStride, 'byteStride', 'Must be 2 or 4');
    }
    if (indices.lengthInBytes < count * byteStride) {
      throw ArgumentError('indices buffer too small for count * byteStride');
    }
    final bd = ByteData.sublistView(indices);
    final values = Uint32List(count);
    for (var i = 0; i < count; i++) {
      values[i] = byteStride == 2
          ? bd.getUint16(i * 2, Endian.little)
          : bd.getUint32(i * 4, Endian.little);
    }
    switch (mode) {
      case MeshoptMode3D.indices:
        return _encodeIndexSequence(values);
      case MeshoptMode3D.triangles:
        if (count % 3 != 0) {
          throw ArgumentError.value(
            count,
            'count',
            'Triangle index count must be a multiple of 3',
          );
        }
        return _encodeTriangles(values);
      case MeshoptMode3D.attributes:
        throw ArgumentError.value(
          mode,
          'mode',
          'Expected triangles or indices',
        );
    }
  }

  /// Decompresses a `TRIANGLES` (`0xE0`/`0xE1`) or `INDICES` (`0xD1`) stream
  /// into `count * byteStride` little-endian index bytes.
  ///
  /// When [mode] is given, a stream of the other kind throws a
  /// [FormatException]; otherwise the header decides.
  static Uint8List decodeIndexStream(
    Uint8List encoded, {
    required int count,
    required int byteStride,
    MeshoptMode3D? mode,
  }) {
    if (byteStride != 2 && byteStride != 4) {
      throw ArgumentError.value(byteStride, 'byteStride', 'Must be 2 or 4');
    }
    if (encoded.isEmpty) {
      throw const FormatException('Empty meshopt index stream');
    }
    final header = encoded[0];
    final kind = header & 0xF0;
    final version = header & 0x0F;
    if (kind != _indexHeader && kind != _sequenceHeader) {
      throw FormatException(
        'Unsupported meshopt index header: 0x${_hex(header)}',
      );
    }
    if (version > _maxIndexVersion) {
      throw FormatException(
        'Unsupported meshopt index codec version $version (header '
        '0x${_hex(header)}); this decoder reads versions 0 and 1',
      );
    }
    final values = Uint32List(count);
    if (kind == _sequenceHeader) {
      if (mode == MeshoptMode3D.triangles) {
        throw const FormatException(
          'Expected a TRIANGLES stream (0xE1), got INDICES (0xD1)',
        );
      }
      _decodeIndexSequence(encoded, values);
    } else {
      if (mode == MeshoptMode3D.indices) {
        throw const FormatException(
          'Expected an INDICES stream (0xD1), got TRIANGLES (0xE1)',
        );
      }
      if (count % 3 != 0) {
        throw FormatException(
          'Triangle index count must be a multiple of 3, got $count',
        );
      }
      _decodeTriangles(encoded, values, version);
    }

    final out = Uint8List(count * byteStride);
    if (byteStride == 4) {
      final bd = ByteData.sublistView(out);
      for (var i = 0; i < count; i++) {
        bd.setUint32(i * 4, values[i], Endian.little);
      }
    } else {
      final bd = ByteData.sublistView(out);
      for (var i = 0; i < count; i++) {
        bd.setUint16(i * 2, values[i] & 0xFFFF, Endian.little);
      }
    }
    return out;
  }

  static Uint8List _encodeTriangles(Uint32List indices) {
    const version = 1;
    const fecMax = version >= 1 ? 13 : 15;
    const rotations = <int>[0, 1, 2, 0, 1];
    final triangleCount = indices.length ~/ 3;

    final codes = Uint8List(triangleCount);
    final data = BytesBuilder(copy: false);
    final edgeFifo = Uint32List(32)..fillRange(0, 32, 0xFFFFFFFF);
    final vertexFifo = Uint32List(16)..fillRange(0, 16, 0xFFFFFFFF);
    var edgeOffset = 0;
    var vertexOffset = 0;
    var next = 0;
    var last = 0;

    int getEdge(int a, int b, int c) {
      for (var i = 0; i < 16; i++) {
        final index = (edgeOffset - 1 - i) & 15;
        final e0 = edgeFifo[index * 2];
        final e1 = edgeFifo[index * 2 + 1];
        if (e0 == a && e1 == b) {
          return i << 2;
        }
        if (e0 == b && e1 == c) {
          return (i << 2) | 1;
        }
        if (e0 == c && e1 == a) {
          return (i << 2) | 2;
        }
      }
      return -1;
    }

    int getVertex(int v) {
      for (var i = 0; i < 16; i++) {
        if (vertexFifo[(vertexOffset - 1 - i) & 15] == v) {
          return i;
        }
      }
      return -1;
    }

    void pushEdge(int a, int b) {
      edgeFifo[edgeOffset * 2] = a;
      edgeFifo[edgeOffset * 2 + 1] = b;
      edgeOffset = (edgeOffset + 1) & 15;
    }

    void pushVertex(int v) {
      vertexFifo[vertexOffset] = v;
      vertexOffset = (vertexOffset + 1) & 15;
    }

    void encodeIndex(int index) {
      final d = (index - last) & 0xFFFFFFFF;
      final v = ((d << 1) ^ (d >= 0x80000000 ? 0xFFFFFFFF : 0)) & 0xFFFFFFFF;
      _writeVByte(v, data);
      last = index;
    }

    for (var t = 0; t < triangleCount; t++) {
      final i = t * 3;
      final fer = getEdge(indices[i], indices[i + 1], indices[i + 2]);
      if (fer >= 0 && (fer >> 2) < 15) {
        final order = fer & 3;
        final a = indices[i + rotations[order]];
        final b = indices[i + rotations[order + 1]];
        final c = indices[i + rotations[order + 2]];
        final fe = fer >> 2;
        final fc = getVertex(c);
        int fec;
        if (fc >= 1 && fc < fecMax) {
          fec = fc;
        } else if (c == next) {
          next++;
          fec = 0;
        } else {
          fec = 15;
        }
        if (fec == 15) {
          if (((c + 1) & 0xFFFFFFFF) == last) {
            fec = 13;
            last = c;
          }
          if (c == ((last + 1) & 0xFFFFFFFF)) {
            fec = 14;
            last = c;
          }
        }
        codes[t] = (fe << 4) | fec;
        if (fec == 15) {
          encodeIndex(c);
        }
        if (fec == 0 || fec >= fecMax) {
          pushVertex(c);
        }
        pushEdge(c, b);
        pushEdge(a, c);
      } else {
        final rotation = indices[i + 1] == next
            ? 1
            : (indices[i + 2] == next ? 2 : 0);
        final a = indices[i + rotations[rotation]];
        final b = indices[i + rotations[rotation + 1]];
        final c = indices[i + rotations[rotation + 2]];

        var reset = false;
        if (a == 0 && b == 1 && c == 2 && next > 0) {
          reset = true;
          next = 0;
          vertexFifo.fillRange(0, 16, 0xFFFFFFFF);
        }

        final fb = getVertex(b);
        final fc = getVertex(c);

        int fea;
        if (a == next) {
          next++;
          fea = 0;
        } else {
          fea = 15;
        }
        int feb;
        if (fb >= 0 && fb < 14) {
          feb = fb + 1;
        } else if (b == next) {
          next++;
          feb = 0;
        } else {
          feb = 15;
        }
        int fec;
        if (fc >= 0 && fc < 14) {
          fec = fc + 1;
        } else if (c == next) {
          next++;
          fec = 0;
        } else {
          fec = 15;
        }

        final codeAux = (feb << 4) | fec;
        final codeAuxIndex = _codeAuxTable.indexOf(codeAux);
        if (fea == 0 && codeAuxIndex >= 0 && codeAuxIndex < 14 && !reset) {
          codes[t] = 0xF0 | codeAuxIndex;
        } else {
          codes[t] = 0xF0 | 14 | fea;
          data.addByte(codeAux);
        }

        if (fea == 15) {
          encodeIndex(a);
        }
        if (feb == 15) {
          encodeIndex(b);
        }
        if (fec == 15) {
          encodeIndex(c);
        }

        if (fea == 0 || fea == 15) {
          pushVertex(a);
        }
        if (feb == 0 || feb == 15) {
          pushVertex(b);
        }
        if (fec == 0 || fec == 15) {
          pushVertex(c);
        }

        pushEdge(b, a);
        pushEdge(c, b);
        pushEdge(a, c);
      }
    }

    return (BytesBuilder(copy: false)
          ..addByte(_indexHeader | version)
          ..add(codes)
          ..add(data.takeBytes())
          ..add(_codeAuxTable))
        .toBytes();
  }

  static void _decodeTriangles(
    Uint8List encoded,
    Uint32List out,
    int version,
  ) {
    final triangleCount = out.length ~/ 3;
    if (encoded.length < 1 + triangleCount + 16) {
      throw const FormatException('Truncated meshopt TRIANGLES stream');
    }
    final fecMax = version >= 1 ? 13 : 15;
    final edgeFifo = Uint32List(32)..fillRange(0, 32, 0xFFFFFFFF);
    final vertexFifo = Uint32List(16)..fillRange(0, 16, 0xFFFFFFFF);
    var edgeOffset = 0;
    var vertexOffset = 0;
    var next = 0;
    var last = 0;

    var code = 1;
    var data = 1 + triangleCount;
    final dataSafeEnd = encoded.length - 16;
    final codeAux = dataSafeEnd;
    final cursor = _Cursor(encoded);

    void pushEdge(int a, int b) {
      edgeFifo[edgeOffset * 2] = a;
      edgeFifo[edgeOffset * 2 + 1] = b;
      edgeOffset = (edgeOffset + 1) & 15;
    }

    void pushVertex(int v, {bool advance = true}) {
      vertexFifo[vertexOffset] = v;
      if (advance) {
        vertexOffset = (vertexOffset + 1) & 15;
      }
    }

    int decodeIndex() {
      cursor.position = data;
      final v = cursor.readVByte();
      data = cursor.position;
      final d = (v >>> 1) ^ ((v & 1) != 0 ? 0xFFFFFFFF : 0);
      return (last + d) & 0xFFFFFFFF;
    }

    for (var t = 0; t < triangleCount; t++) {
      final codeTri = encoded[code++];
      int a;
      int b;
      int c;
      if (codeTri < 0xF0) {
        final fe = codeTri >> 4;
        final edge = (edgeOffset - 1 - fe) & 15;
        a = edgeFifo[edge * 2];
        b = edgeFifo[edge * 2 + 1];
        final fec = codeTri & 15;
        if (fec < fecMax) {
          final cf = vertexFifo[(vertexOffset - 1 - fec) & 15];
          c = fec == 0 ? next : cf;
          if (fec == 0) {
            next = (next + 1) & 0xFFFFFFFF;
          }
          pushVertex(c, advance: fec == 0);
        } else {
          if (data > dataSafeEnd) {
            throw const FormatException('Truncated meshopt TRIANGLES data');
          }
          c = fec != 15 ? (last + fec * 2 - 27) & 0xFFFFFFFF : decodeIndex();
          last = c;
          pushVertex(c);
        }
        pushEdge(c, b);
        pushEdge(a, c);
      } else if (codeTri < 0xFE) {
        final aux = encoded[codeAux + (codeTri & 15)];
        final feb = aux >> 4;
        final fec = aux & 15;
        a = next;
        next = (next + 1) & 0xFFFFFFFF;
        final bf = vertexFifo[(vertexOffset - feb) & 15];
        b = feb == 0 ? next : bf;
        if (feb == 0) {
          next = (next + 1) & 0xFFFFFFFF;
        }
        final cf = vertexFifo[(vertexOffset - fec) & 15];
        c = fec == 0 ? next : cf;
        if (fec == 0) {
          next = (next + 1) & 0xFFFFFFFF;
        }
        pushVertex(a);
        pushVertex(b, advance: feb == 0);
        pushVertex(c, advance: fec == 0);
        pushEdge(b, a);
        pushEdge(c, b);
        pushEdge(a, c);
      } else {
        if (data > dataSafeEnd) {
          throw const FormatException('Truncated meshopt TRIANGLES data');
        }
        final aux = encoded[data++];
        final fea = codeTri == 0xFE ? 0 : 15;
        final feb = aux >> 4;
        final fec = aux & 15;
        if (aux == 0) {
          next = 0;
        }
        if (fea == 0) {
          a = next;
          next = (next + 1) & 0xFFFFFFFF;
        } else {
          a = 0;
        }
        if (feb == 0) {
          b = next;
          next = (next + 1) & 0xFFFFFFFF;
        } else {
          b = vertexFifo[(vertexOffset - feb) & 15];
        }
        if (fec == 0) {
          c = next;
          next = (next + 1) & 0xFFFFFFFF;
        } else {
          c = vertexFifo[(vertexOffset - fec) & 15];
        }
        if (fea == 15) {
          a = decodeIndex();
          last = a;
        }
        if (feb == 15) {
          b = decodeIndex();
          last = b;
        }
        if (fec == 15) {
          c = decodeIndex();
          last = c;
        }
        pushVertex(a);
        pushVertex(b, advance: feb == 0 || feb == 15);
        pushVertex(c, advance: fec == 0 || fec == 15);
        pushEdge(b, a);
        pushEdge(c, b);
        pushEdge(a, c);
      }
      out[t * 3] = a;
      out[t * 3 + 1] = b;
      out[t * 3 + 2] = c;
    }

    if (data != dataSafeEnd) {
      throw FormatException(
        'Malformed meshopt TRIANGLES stream: ${dataSafeEnd - data} bytes '
        'left before the code table',
      );
    }
  }

  static Uint8List _encodeIndexSequence(Uint32List indices) {
    final out = BytesBuilder(copy: false)..addByte(_sequenceHeader | 1);
    final last = Uint32List(2);
    var current = 0;
    for (var i = 0; i < indices.length; i++) {
      final index = indices[i];
      final cd = (index - last[current]).toSigned(32);
      if (cd.abs() >= 30) {
        current ^= 1;
      }
      final d = (index - last[current]) & 0xFFFFFFFF;
      final v = ((d << 1) ^ (d >= 0x80000000 ? 0xFFFFFFFF : 0)) & 0xFFFFFFFF;
      _writeVByte(((v << 1) | current) & 0xFFFFFFFF, out);
      last[current] = index;
    }
    out.add(const [0, 0, 0, 0]);
    return out.toBytes();
  }

  static void _decodeIndexSequence(Uint8List encoded, Uint32List out) {
    if (encoded.length < 1 + out.length + 4) {
      throw const FormatException('Truncated meshopt INDICES stream');
    }
    final dataSafeEnd = encoded.length - 4;
    final cursor = _Cursor(encoded)..position = 1;
    final last = Uint32List(2);
    for (var i = 0; i < out.length; i++) {
      if (cursor.position >= dataSafeEnd) {
        throw const FormatException('Truncated meshopt INDICES stream');
      }
      var v = cursor.readVByte();
      final current = v & 1;
      v >>>= 1;
      final d = (v >>> 1) ^ ((v & 1) != 0 ? 0xFFFFFFFF : 0);
      final index = (last[current] + d) & 0xFFFFFFFF;
      last[current] = index;
      out[i] = index;
    }
    if (cursor.position != dataSafeEnd) {
      throw FormatException(
        'Malformed meshopt INDICES stream: '
        '${dataSafeEnd - cursor.position} bytes left before the tail',
      );
    }
  }

  // ===========================================================================
  // 3. Filters (`OCTAHEDRAL`, `QUATERNION`, `EXPONENTIAL`)
  // ===========================================================================

  /// Applies the decoding of [filter] in place across [count] elements of
  /// [byteStride] bytes in [buffer].
  static void applyFilterInPlace(
    Uint8List buffer, {
    required int count,
    required int byteStride,
    required MeshoptFilter3D filter,
  }) {
    switch (filter) {
      case MeshoptFilter3D.none:
        return;
      case MeshoptFilter3D.octahedral:
        decodeFilterOct(buffer, count: count, byteStride: byteStride);
      case MeshoptFilter3D.quaternion:
        decodeFilterQuat(buffer, count: count, byteStride: byteStride);
      case MeshoptFilter3D.exponential:
        decodeFilterExp(buffer, count: count, byteStride: byteStride);
    }
  }

  /// Encodes unit vectors `(x, y, z, w)` for the `OCTAHEDRAL` filter, like
  /// `meshopt_encodeFilterOct`: `byteStride == 4` stores `4 x int8` with
  /// [bits] in `2..8`, `byteStride == 8` stores `4 x int16` with [bits] in
  /// `2..16`. `w` (a tangent's handedness, for example) is stored as a
  /// normalized 8-bit or 16-bit value.
  static Uint8List encodeFilterOct(
    List<Vector4> vectors, {
    int byteStride = 4,
    int bits = 8,
  }) {
    if (byteStride != 4 && byteStride != 8) {
      throw ArgumentError.value(byteStride, 'byteStride', 'Must be 4 or 8');
    }
    final maxBits = byteStride == 4 ? 8 : 16;
    if (bits < 2 || bits > maxBits) {
      throw ArgumentError.value(bits, 'bits', 'Must be in 2..$maxBits');
    }
    final out = Uint8List(vectors.length * byteStride);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < vectors.length; i++) {
      final n = vectors[i];
      var nx = _f(n.x);
      var ny = _f(n.y);
      final nz = _f(n.z);
      final nl = _f(_f(nx.abs() + ny.abs()) + nz.abs());
      final ns = nl == 0.0 ? 0.0 : _f(1.0 / nl);
      nx = _f(nx * ns);
      ny = _f(ny * ns);
      final u = nz >= 0.0
          ? nx
          : _f(_f(1.0 - ny.abs()) * (nx >= 0.0 ? 1.0 : -1.0));
      final v = nz >= 0.0
          ? ny
          : _f(_f(1.0 - nx.abs()) * (ny >= 0.0 ? 1.0 : -1.0));
      final fu = _quantizeSnorm(u, bits);
      final fv = _quantizeSnorm(v, bits);
      final fo = _quantizeSnorm(1.0, bits);
      final fw = _quantizeSnorm(_f(n.w), byteStride * 2);
      final base = i * byteStride;
      if (byteStride == 4) {
        bd
          ..setInt8(base, fu)
          ..setInt8(base + 1, fv)
          ..setInt8(base + 2, fo)
          ..setInt8(base + 3, fw);
      } else {
        bd
          ..setInt16(base, fu, Endian.little)
          ..setInt16(base + 2, fv, Endian.little)
          ..setInt16(base + 4, fo, Endian.little)
          ..setInt16(base + 6, fw, Endian.little);
      }
    }
    return out;
  }

  /// Decodes `OCTAHEDRAL`-filtered vectors in place into normalized `int8`
  /// (`byteStride == 4`) or `int16` (`byteStride == 8`) components, like
  /// `meshopt_decodeFilterOct`. The fourth component passes through.
  static void decodeFilterOct(
    Uint8List buffer, {
    required int count,
    required int byteStride,
  }) {
    if (byteStride != 4 && byteStride != 8) {
      throw ArgumentError.value(byteStride, 'byteStride', 'Must be 4 or 8');
    }
    final bd = ByteData.sublistView(buffer);
    final max = byteStride == 4 ? 127.0 : 32767.0;
    for (var i = 0; i < count; i++) {
      final base = i * byteStride;
      double x;
      double y;
      double z;
      if (byteStride == 4) {
        x = bd.getInt8(base).toDouble();
        y = bd.getInt8(base + 1).toDouble();
        z = bd.getInt8(base + 2).toDouble();
      } else {
        x = bd.getInt16(base, Endian.little).toDouble();
        y = bd.getInt16(base + 2, Endian.little).toDouble();
        z = bd.getInt16(base + 4, Endian.little).toDouble();
      }
      z = _f(_f(z - x.abs()) - y.abs());
      final t = z >= 0.0 ? 0.0 : z;
      x = _f(x + (x >= 0.0 ? t : -t));
      y = _f(y + (y >= 0.0 ? t : -t));
      final l = _f(math.sqrt(_f(_f(_f(x * x) + _f(y * y)) + _f(z * z))));
      final s = _f(max / l);
      final xf = _trunc(_f(_f(x * s) + (x >= 0.0 ? 0.5 : -0.5)));
      final yf = _trunc(_f(_f(y * s) + (y >= 0.0 ? 0.5 : -0.5)));
      final zf = _trunc(_f(_f(z * s) + (z >= 0.0 ? 0.5 : -0.5)));
      if (byteStride == 4) {
        bd
          ..setInt8(base, xf.toSigned(8))
          ..setInt8(base + 1, yf.toSigned(8))
          ..setInt8(base + 2, zf.toSigned(8));
      } else {
        bd
          ..setInt16(base, xf.toSigned(16), Endian.little)
          ..setInt16(base + 2, yf.toSigned(16), Endian.little)
          ..setInt16(base + 4, zf.toSigned(16), Endian.little);
      }
    }
  }

  /// Encodes unit quaternions `(x, y, z, w)` as smallest-three `4 x int16`
  /// records (`byteStride == 8`) for the `QUATERNION` filter, like
  /// `meshopt_encodeFilterQuat`; [bits] is in `4..16`. The quaternions are
  /// expected to be unit length.
  static Uint8List encodeFilterQuat(
    List<Quaternion> rotations, {
    int bits = 12,
  }) {
    if (bits < 4 || bits > 16) {
      throw ArgumentError.value(bits, 'bits', 'Must be in 4..16');
    }
    final scaler = _f(math.sqrt(2.0));
    final out = Uint8List(rotations.length * 8);
    final bd = ByteData.sublistView(out);
    final q = Float64List(4);
    for (var i = 0; i < rotations.length; i++) {
      final r = rotations[i];
      q[0] = _f(r.x);
      q[1] = _f(r.y);
      q[2] = _f(r.z);
      q[3] = _f(r.w);
      var qc = 0;
      for (var c = 1; c < 4; c++) {
        if (q[c].abs() > q[qc].abs()) {
          qc = c;
        }
      }
      final sign = q[qc] < 0.0 ? -1.0 : 1.0;
      int component(int c) =>
          _quantizeSnorm(_f(_f(q[(qc + c) & 3] * scaler) * sign), bits);
      final base = i * 8;
      bd
        ..setInt16(base, component(1), Endian.little)
        ..setInt16(base + 2, component(2), Endian.little)
        ..setInt16(base + 4, component(3), Endian.little)
        ..setInt16(
          base + 6,
          (_quantizeSnorm(1.0, bits) & ~3) | qc,
          Endian.little,
        );
    }
    return out;
  }

  /// Decodes `QUATERNION`-filtered `4 x int16` records (`byteStride == 8`) in
  /// place into normalized `int16` quaternions, like
  /// `meshopt_decodeFilterQuat`.
  static void decodeFilterQuat(
    Uint8List buffer, {
    required int count,
    int byteStride = 8,
  }) {
    if (byteStride != 8) {
      throw ArgumentError.value(byteStride, 'byteStride', 'Must be 8');
    }
    final bd = ByteData.sublistView(buffer);
    final scale = _f(32767.0 / _f(math.sqrt(2.0)));
    for (var i = 0; i < count; i++) {
      final base = i * 8;
      final w3 = bd.getInt16(base + 6, Endian.little);
      final s = (w3 | 3).toDouble();
      final x = bd.getInt16(base, Endian.little).toDouble();
      final y = bd.getInt16(base + 2, Endian.little).toDouble();
      final z = bd.getInt16(base + 4, Endian.little).toDouble();
      final ws = _f(s * s);
      final ww = _f(
        _f(_f(_f(ws * 2.0) - _f(x * x)) - _f(y * y)) - _f(z * z),
      );
      final w = _f(math.sqrt(ww >= 0.0 ? ww : 0.0));
      final ss = _f(scale / s);
      final xf = _trunc(_f(_f(x * ss) + (x >= 0.0 ? 0.5 : -0.5)));
      final yf = _trunc(_f(_f(y * ss) + (y >= 0.0 ? 0.5 : -0.5)));
      final zf = _trunc(_f(_f(z * ss) + (z >= 0.0 ? 0.5 : -0.5)));
      final wf = _trunc(_f(_f(w * ss) + 0.5));
      final qc = w3 & 3;
      bd
        ..setInt16(base + ((qc + 1) & 3) * 2, xf.toSigned(16), Endian.little)
        ..setInt16(base + ((qc + 2) & 3) * 2, yf.toSigned(16), Endian.little)
        ..setInt16(base + ((qc + 3) & 3) * 2, zf.toSigned(16), Endian.little)
        ..setInt16(base + qc * 2, wf.toSigned(16), Endian.little);
    }
  }

  /// Encodes `count * (byteStride ~/ 4)` floats as `(8-bit exponent |
  /// 24-bit signed mantissa)` words for the `EXPONENTIAL` filter, like
  /// `meshopt_encodeFilterExp`; [bits] (`1..24`) is the mantissa precision
  /// and [mode] how exponents are shared.
  static Uint8List encodeFilterExp(
    Float32List floats, {
    required int count,
    required int byteStride,
    int bits = 16,
    MeshoptExpMode3D mode = MeshoptExpMode3D.sharedVector,
  }) {
    if (byteStride < 4 || byteStride > 256 || byteStride % 4 != 0) {
      throw ArgumentError.value(
        byteStride,
        'byteStride',
        'Must be a multiple of 4 in 4..256',
      );
    }
    if (bits < 1 || bits > 24) {
      throw ArgumentError.value(bits, 'bits', 'Must be in 1..24');
    }
    final components = byteStride ~/ 4;
    if (floats.length < count * components) {
      throw ArgumentError('floats length smaller than count * components');
    }
    const minExp = -100;
    final componentExp = Int32List(components)
      ..fillRange(
        0,
        components,
        mode == MeshoptExpMode3D.separate ? 0 : minExp,
      );
    if (mode == MeshoptExpMode3D.sharedComponent) {
      for (var i = 0; i < count; i++) {
        for (var j = 0; j < components; j++) {
          final e = _optLog2(floats[i * components + j]);
          if (componentExp[j] < e) {
            componentExp[j] = e;
          }
        }
      }
    }

    final out = Uint8List(count * byteStride);
    final bd = ByteData.sublistView(out);
    const mantissaMask = (1 << 24) - 1;
    const mantissaMax = mantissaMask >> 1;
    for (var i = 0; i < count; i++) {
      final base = i * components;
      var vectorExp = minExp;
      switch (mode) {
        case MeshoptExpMode3D.sharedVector:
          for (var j = 0; j < components; j++) {
            final e = _optLog2(floats[base + j]);
            if (vectorExp < e) {
              vectorExp = e;
            }
          }
        case MeshoptExpMode3D.separate:
          for (var j = 0; j < components; j++) {
            final v = floats[base + j];
            if (v != 0) {
              final e = _optLog2(v);
              componentExp[j] = minExp < e ? e : minExp;
            }
          }
        case MeshoptExpMode3D.clamped:
          for (var j = 0; j < components; j++) {
            final e = _optLog2(floats[base + j]);
            componentExp[j] = e > 0 ? e : 0;
          }
        case MeshoptExpMode3D.sharedComponent:
          break;
      }
      for (var j = 0; j < components; j++) {
        final v = floats[base + j];
        var exp = mode == MeshoptExpMode3D.sharedVector
            ? vectorExp
            : componentExp[j];
        exp -= bits - 1;
        var m = _f(_f(v * _optExp2(-exp)) + (v >= 0 ? 0.5 : -0.5)).toInt();
        if (m > mantissaMax) {
          m = mantissaMax;
        }
        bd.setUint32(
          (base + j) * 4,
          ((m & mantissaMask) | (exp << 24)) & 0xFFFFFFFF,
          Endian.little,
        );
      }
    }
    return out;
  }

  /// Decodes `EXPONENTIAL`-filtered words in place into IEEE-754 `float32`
  /// values (`2^e * m`), like `meshopt_decodeFilterExp`.
  static void decodeFilterExp(
    Uint8List buffer, {
    required int count,
    required int byteStride,
  }) {
    if (byteStride < 4 || byteStride % 4 != 0) {
      throw ArgumentError.value(
        byteStride,
        'byteStride',
        'Must be a positive multiple of 4',
      );
    }
    final bd = ByteData.sublistView(buffer);
    final words = count * (byteStride ~/ 4);
    for (var w = 0; w < words; w++) {
      final raw = bd.getUint32(w * 4, Endian.little);
      final m = (raw & 0xFFFFFF).toSigned(24);
      final e = raw.toSigned(32) >> 24;
      bd.setFloat32(w * 4, _f(_optExp2(e) * m), Endian.little);
    }
  }

  // ===========================================================================
  // Helpers
  // ===========================================================================

  static void _checkVertexParams(int count, int byteStride) {
    if (count < 0) {
      throw ArgumentError.value(count, 'count', 'Must be >= 0');
    }
    if (byteStride < 4 || byteStride > 256 || byteStride % 4 != 0) {
      throw ArgumentError.value(
        byteStride,
        'byteStride',
        'Must be a multiple of 4 in [4..256]',
      );
    }
  }

  /// Elements per attribute block; part of the format.
  static int _vertexBlockSize(int byteStride) =>
      math.min((8192 ~/ byteStride) & ~15, _vertexBlockMaxSize);

  static int _align16(int v) => (v + 15) & ~15;

  static int _zigzag8(int v) =>
      ((v << 1) ^ ((v & 0x80) != 0 ? 0xFF : 0)) & 0xFF;

  static int _unzigzag8(int v) => ((v >> 1) ^ ((v & 1) != 0 ? 0xFF : 0)) & 0xFF;

  static int _unzigzag16(int v) =>
      ((v >> 1) ^ ((v & 1) != 0 ? 0xFFFF : 0)) & 0xFFFF;

  static int _rotl32(int v, int r) =>
      ((v << r) | (v >>> ((32 - r) & 31))) & 0xFFFFFFFF;

  static int _reverseBits8(int v) {
    var r = 0;
    for (var i = 0; i < 8; i++) {
      r |= ((v >> i) & 1) << (7 - i);
    }
    return r;
  }

  static void _writeVByte(int value, BytesBuilder out) {
    var v = value;
    do {
      out.addByte((v & 127) | (v > 127 ? 128 : 0));
      v >>>= 7;
    } while (v != 0);
  }

  static String _hex(int byte) => byte.toRadixString(16).padLeft(2, '0');

  static final Float32List _f32 = Float32List(1);
  static final ByteData _bits = ByteData(4);

  /// Rounds [v] to the nearest 32-bit float, so results match the reference's
  /// `float` arithmetic.
  static double _f(double v) {
    _f32[0] = v;
    return _f32[0];
  }

  static int _quantizeSnorm(double value, int n) {
    if (value.isNaN) {
      return 0;
    }
    final scale = ((1 << (n - 1)) - 1).toDouble();
    final round = value >= 0 ? 0.5 : -0.5;
    final v = value < -1.0 ? -1.0 : (value > 1.0 ? 1.0 : value);
    return _f(_f(v * scale) + round).toInt();
  }

  /// Truncates [v] toward zero like a C `int` cast, with `0` for the
  /// undefined cases (NaN, infinities) of malformed input.
  static int _trunc(double v) => v.isFinite ? v.toInt() : 0;

  /// The exponent of [v] plus one, like the reference `optlog2`.
  static int _optLog2(double v) {
    _bits.setFloat32(0, v);
    return ((_bits.getUint32(0) >> 23) & 0xFF) - 127 + 1;
  }

  /// `2^e` as a float built from its bits, like the reference `optexp2`.
  static double _optExp2(int e) {
    _bits.setUint32(0, ((e + 127) << 23) & 0xFFFFFFFF);
    return _bits.getFloat32(0);
  }
}

/// A read cursor over a byte list for variable-length integers.
class _Cursor(final Uint8List bytes) {
  int position = 0;

  /// Reads a little-endian base-128 integer of at most 5 bytes, like the
  /// reference `decodeVByte`.
  int readVByte() {
    if (position >= bytes.length) {
      throw const FormatException('Truncated meshopt varint');
    }
    final lead = bytes[position++];
    if (lead < 128) {
      return lead;
    }
    var result = lead & 127;
    var shift = 7;
    for (var i = 0; i < 4; i++) {
      if (position >= bytes.length) {
        throw const FormatException('Truncated meshopt varint');
      }
      final group = bytes[position++];
      result |= (group & 127) << shift;
      shift += 7;
      if (group < 128) {
        break;
      }
    }
    return result & 0xFFFFFFFF;
  }
}
