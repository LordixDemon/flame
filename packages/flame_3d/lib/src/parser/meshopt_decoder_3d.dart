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

  /// Shared/per-word 8-bit exponent + 24-bit signed mantissa float32 decoding.
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

/// Pure-Dart encoder & decoder for glTF 2.0 `EXT_meshopt_compression` streams
/// (`ATTRIBUTES`, `TRIANGLES`, `INDICES`, plus `OCTAHEDRAL`, `QUATERNION`, and
/// `EXPONENTIAL` filters) running identically on Dart VM, AOT, and Web.
abstract final class MeshoptDecoder3D._() {
  static const int _vertexHeaderV0 = 0xA0;
  static const int _triangleHeaderV1 = 0xE1;
  static const int _indexSeqHeaderV1 = 0xD1;

  static const List<int> _defaultCodeauxTable = <int>[
    0x00, 0x76, 0x87, 0x56, //
    0x67, 0x78, 0xA9, 0x86, //
    0x65, 0x89, 0x68, 0x98, //
    0x01, 0x69, 0x00, 0x00, //
  ];

  /// Decompresses a complete `EXT_meshopt_compression` buffer view slice and
  /// applies [filter] in place when `mode == MeshoptMode3D.attributes`.
  static Uint8List decodeBufferView(
    Uint8List compressed, {
    required int count,
    required int byteStride,
    required MeshoptMode3D mode,
    MeshoptFilter3D filter = MeshoptFilter3D.none,
  }) {
    final Uint8List out;
    switch (mode) {
      case MeshoptMode3D.attributes:
        out = decodeVertexStream(
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
      case MeshoptMode3D.triangles:
        out = decodeIndexStream(
          compressed,
          count: count,
          byteStride: byteStride,
          mode: MeshoptMode3D.triangles,
        );
      case MeshoptMode3D.indices:
        out = decodeIndexStream(
          compressed,
          count: count,
          byteStride: byteStride,
          mode: MeshoptMode3D.indices,
        );
    }
    return out;
  }

  // ===========================================================================
  // 1. Vertex Attribute Stream (`ATTRIBUTES`, Header `0xA0`)
  // ===========================================================================

  /// Compresses [vertices] (`count * byteStride` bytes, `byteStride` multiple
  /// of `4` in `4..256`) into a meshopt `ATTRIBUTES` (`0xA0`) bitstream.
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
    if (count == 0) {
      return Uint8List.fromList(const [_vertexHeaderV0]);
    }

    final out = BytesBuilder(copy: false)..addByte(_vertexHeaderV0);
    final blockCapacity = _vertexBlockSize(byteStride);
    final lastVertex = Uint8List.fromList(vertices.sublist(0, byteStride));
    final zzGroup = Uint8List(16);

    var vertexOffset = 0;
    while (vertexOffset < count) {
      final blockCount = math.min(blockCapacity, count - vertexOffset);
      final groups = (blockCount + 15) ~/ 16;
      final headerBytes = (groups + 3) ~/ 4;
      final headers = Uint8List(headerBytes);
      final channelPayload = BytesBuilder(copy: false);

      for (var k = 0; k < byteStride; k++) {
        headers.fillRange(0, headerBytes, 0);
        channelPayload.clear();
        var prev = lastVertex[k];

        for (var g = 0; g < groups; g++) {
          zzGroup.fillRange(0, 16, 0);
          var maxZz = 0;
          final baseVert = vertexOffset + g * 16;
          final limit = math.min(16, blockCount - g * 16);
          for (var i = 0; i < limit; i++) {
            final cur = vertices[(baseVert + i) * byteStride + k];
            final diff = (cur - prev) & 0xFF;
            final zz = _zigzag8(diff);
            zzGroup[i] = zz;
            if (zz > maxZz) {
              maxZz = zz;
            }
            prev = cur;
          }

          final int mode;
          if (maxZz == 0) {
            mode = 0;
          } else if (maxZz <= 3) {
            mode = 1;
            for (var b = 0; b < 4; b++) {
              final o = b * 4;
              channelPayload.addByte(
                (zzGroup[o] << 6) |
                    (zzGroup[o + 1] << 4) |
                    (zzGroup[o + 2] << 2) |
                    zzGroup[o + 3],
              );
            }
          } else if (maxZz <= 15) {
            mode = 2;
            for (var b = 0; b < 8; b++) {
              final o = b * 2;
              channelPayload.addByte((zzGroup[o] << 4) | zzGroup[o + 1]);
            }
          } else {
            mode = 3;
            channelPayload.add(Uint8List.fromList(zzGroup));
          }
          headers[g >> 2] |= mode << ((g & 3) * 2);
        }

        lastVertex[k] = prev;
        out
          ..add(Uint8List.fromList(headers))
          ..add(channelPayload.takeBytes());
      }

      vertexOffset += blockCount;
    }

    // Tail holds vertex 0's raw bytes as the initial delta reference.
    out.add(vertices.sublist(0, byteStride));
    return out.toBytes();
  }

  /// Decompresses a meshopt `ATTRIBUTES` (`0xA0`) bitstream into
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
    if ((header & 0xF0) != _vertexHeaderV0 || (header & 0x0F) != 0) {
      final hex = header.toRadixString(16);
      throw FormatException(
        'Unsupported meshopt vertex stream header: 0x$hex',
      );
    }
    if (count == 0) {
      return Uint8List(0);
    }
    if (encoded.length < 1 + byteStride) {
      throw const FormatException('Truncated meshopt vertex stream');
    }

    final out = Uint8List(count * byteStride);
    final dataLimit = encoded.length - byteStride;
    final lastVertex = Uint8List.fromList(
      encoded.sublist(dataLimit, encoded.length),
    );
    final blockCapacity = _vertexBlockSize(byteStride);
    final zzGroup = Uint8List(16);

    var cursor = 1;
    var vertexOffset = 0;
    while (vertexOffset < count) {
      final blockCount = math.min(blockCapacity, count - vertexOffset);
      final groups = (blockCount + 15) ~/ 16;
      final headerBytes = (groups + 3) ~/ 4;

      for (var k = 0; k < byteStride; k++) {
        if (cursor + headerBytes > dataLimit) {
          throw const FormatException(
            'Truncated meshopt vertex channel header',
          );
        }
        final headerStart = cursor;
        cursor += headerBytes;
        var prev = lastVertex[k];

        for (var g = 0; g < groups; g++) {
          final mode =
              (encoded[headerStart + (g >> 2)] >> ((g & 3) * 2)) & 0x03;
          switch (mode) {
            case 0:
              zzGroup.fillRange(0, 16, 0);
            case 1:
              if (cursor + 4 > dataLimit) {
                throw const FormatException(
                  'Truncated 2-bit meshopt vertex group',
                );
              }
              for (var b = 0; b < 4; b++) {
                final byte = encoded[cursor++];
                final o = b * 4;
                zzGroup[o] = (byte >> 6) & 0x03;
                zzGroup[o + 1] = (byte >> 4) & 0x03;
                zzGroup[o + 2] = (byte >> 2) & 0x03;
                zzGroup[o + 3] = byte & 0x03;
              }
            case 2:
              if (cursor + 8 > dataLimit) {
                throw const FormatException(
                  'Truncated 4-bit meshopt vertex group',
                );
              }
              for (var b = 0; b < 8; b++) {
                final byte = encoded[cursor++];
                final o = b * 2;
                zzGroup[o] = (byte >> 4) & 0x0F;
                zzGroup[o + 1] = byte & 0x0F;
              }
            case 3:
              if (cursor + 16 > dataLimit) {
                throw const FormatException(
                  'Truncated 8-bit meshopt vertex group',
                );
              }
              for (var i = 0; i < 16; i++) {
                zzGroup[i] = encoded[cursor++];
              }
          }

          final baseVert = vertexOffset + g * 16;
          final limit = math.min(16, blockCount - g * 16);
          for (var i = 0; i < limit; i++) {
            prev = (prev + _unzigzag8(zzGroup[i])) & 0xFF;
            out[(baseVert + i) * byteStride + k] = prev;
          }
        }
        lastVertex[k] = prev;
      }

      vertexOffset += blockCount;
    }

    return out;
  }

  // ===========================================================================
  // 2. Triangle (`TRIANGLES`, `0xE1`) & Sequence (`INDICES`, `0xD1`) Codecs
  // ===========================================================================

  /// Compresses `count` `Uint16` (`byteStride == 2`) or `Uint32`
  /// (`byteStride == 4`) indices into a meshopt `TRIANGLES` (`0xE1`) or
  /// `INDICES` (`0xD1`) bitstream.
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
    int readIndex(int i) => byteStride == 2
        ? bd.getUint16(i * 2, Endian.little)
        : bd.getUint32(i * 4, Endian.little);

    if (mode == MeshoptMode3D.indices) {
      return _encodeIndexSequence(readIndex, count);
    }
    if (mode != MeshoptMode3D.triangles) {
      throw ArgumentError.value(mode, 'mode', 'Expected triangles or indices');
    }
    if (count % 3 != 0) {
      throw ArgumentError.value(
        count,
        'count',
        'Triangle index count must be a multiple of 3',
      );
    }
    return _encodeTriangles(readIndex, count ~/ 3);
  }

  /// Decompresses a meshopt `TRIANGLES` (`0xE1`) or `INDICES` (`0xD1`)
  /// bitstream into `count * byteStride` little-endian index bytes.
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
    final out = Uint8List(count * byteStride);
    final bd = ByteData.sublistView(out);
    void writeIndex(int i, int value) {
      if (byteStride == 2) {
        bd.setUint16(i * 2, value & 0xFFFF, Endian.little);
      } else {
        bd.setUint32(i * 4, value & 0xFFFFFFFF, Endian.little);
      }
    }

    if ((header & 0xF0) == 0xD0) {
      if (mode == MeshoptMode3D.triangles) {
        throw const FormatException(
          'Expected TRIANGLES header (0xE1), got INDICES (0xD1)',
        );
      }
      _decodeIndexSequence(encoded, count, writeIndex);
      return out;
    }

    if ((header & 0xF0) == 0xE0) {
      if (mode == MeshoptMode3D.indices) {
        throw const FormatException(
          'Expected INDICES header (0xD1), got TRIANGLES (0xE1)',
        );
      }
      if (count % 3 != 0) {
        throw ArgumentError.value(
          count,
          'count',
          'Triangle index count must be a multiple of 3',
        );
      }
      _decodeTriangles(encoded, count ~/ 3, writeIndex);
      return out;
    }

    throw FormatException(
      'Unsupported meshopt index header: 0x${header.toRadixString(16)}',
    );
  }

  static Uint8List _encodeTriangles(
    int Function(int) readIndex,
    int triCount,
  ) {
    final codes = Uint8List(triCount);
    final data = BytesBuilder(copy: false);
    final tempVarints = BytesBuilder(copy: false);

    final edgeFifo = Int32List(32)..fillRange(0, 32, -1);
    final vertexFifo = Int32List(16)..fillRange(0, 16, -1);
    var edgeOffset = 0;
    var vertexOffset = 0;
    var next = 0;
    var last = 0;

    void pushEdge(int a, int b) {
      edgeFifo[edgeOffset * 2] = a;
      edgeFifo[edgeOffset * 2 + 1] = b;
      edgeOffset = (edgeOffset + 1) & 15;
    }

    void pushVertex(int v) {
      vertexFifo[vertexOffset] = v;
      vertexOffset = (vertexOffset + 1) & 15;
    }

    int findEdge(int a, int b) {
      for (var k = 0; k < 16; k++) {
        final idx = (edgeOffset - 1 - k) & 15;
        if (edgeFifo[idx * 2] == a && edgeFifo[idx * 2 + 1] == b) {
          return k;
        }
      }
      return -1;
    }

    int findVertex(int v) {
      for (var k = 1; k < 13; k++) {
        if (vertexFifo[(vertexOffset - k) & 15] == v) {
          return k;
        }
      }
      return -1;
    }

    int encodeVertRef(int v, BytesBuilder sink) {
      if (v == next) {
        next++;
        pushVertex(v);
        return 0;
      }
      final fv = findVertex(v);
      if (fv >= 1) {
        return fv;
      }
      if (v == last + 1) {
        last = v;
        pushVertex(v);
        return 13;
      }
      if (v == last - 1) {
        last = v;
        pushVertex(v);
        return 14;
      }
      _writeZigzagVarint(v - last, sink);
      last = v;
      pushVertex(v);
      return 15;
    }

    for (var t = 0; t < triCount; t++) {
      var a = readIndex(t * 3);
      var b = readIndex(t * 3 + 1);
      var c = readIndex(t * 3 + 2);

      // 1. Check EdgeFifo across cyclic rotations `(a,b,c)` / `(b,c,a)` /
      // `(c,a,b)`.
      var edgeSlot = findEdge(a, b);
      if (edgeSlot < 0) {
        final e1 = findEdge(b, c);
        if (e1 >= 0) {
          edgeSlot = e1;
          final tmp = a;
          a = b;
          b = c;
          c = tmp;
        } else {
          final e2 = findEdge(c, a);
          if (e2 >= 0) {
            edgeSlot = e2;
            final tmp = c;
            c = b;
            b = a;
            a = tmp;
          }
        }
      }

      if (edgeSlot >= 0) {
        final fec = encodeVertRef(c, data);
        codes[t] = (edgeSlot << 4) | fec;
        pushEdge(c, b);
        pushEdge(a, c);
        continue;
      }

      // 2. Rotate cyclically if `b == next` or `c == next` so `a == next`.
      if (a != next) {
        if (b == next) {
          final tmp = a;
          a = b;
          b = c;
          c = tmp;
        } else if (c == next) {
          final tmp = c;
          c = b;
          b = a;
          a = tmp;
        }
      }

      tempVarints.clear();
      if (a == next) {
        next++;
        pushVertex(a);
        final feb = encodeVertRef(b, tempVarints);
        final fec = encodeVertRef(c, tempVarints);
        final caux = (feb << 4) | fec;

        var tableMatch = -1;
        if (feb < 13 && fec < 13) {
          for (var m = 0; m < 14; m++) {
            if (_defaultCodeauxTable[m] == caux) {
              tableMatch = m;
              break;
            }
          }
        }

        if (tableMatch >= 0) {
          codes[t] = 0xF0 | tableMatch;
          data.add(tempVarints.takeBytes());
        } else {
          codes[t] = 0xFE;
          data
            ..addByte(caux)
            ..add(tempVarints.takeBytes());
        }
      } else {
        codes[t] = 0xFF;
        _writeZigzagVarint(a - last, tempVarints);
        last = a;
        pushVertex(a);
        final feb = encodeVertRef(b, tempVarints);
        final fec = encodeVertRef(c, tempVarints);
        data
          ..addByte((feb << 4) | fec)
          ..add(tempVarints.takeBytes());
      }

      pushEdge(b, a);
      pushEdge(c, b);
      pushEdge(a, c);
    }

    final out = BytesBuilder(copy: false)
      ..addByte(_triangleHeaderV1)
      ..add(codes)
      ..add(data.takeBytes())
      ..add(_defaultCodeauxTable);
    return out.toBytes();
  }

  static void _decodeTriangles(
    Uint8List encoded,
    int triCount,
    void Function(int, int) writeIndex,
  ) {
    if (triCount == 0) {
      return;
    }
    if (encoded.length < 1 + triCount + 16) {
      throw const FormatException('Truncated meshopt TRIANGLES stream');
    }
    final dataLimit = encoded.length - 16;
    final codeauxOffset = dataLimit;
    var dataCursor = 1 + triCount;

    final edgeFifo = Int32List(32)..fillRange(0, 32, -1);
    final vertexFifo = Int32List(16)..fillRange(0, 16, -1);
    var edgeOffset = 0;
    var vertexOffset = 0;
    var next = 0;
    var last = 0;

    void pushEdge(int a, int b) {
      edgeFifo[edgeOffset * 2] = a;
      edgeFifo[edgeOffset * 2 + 1] = b;
      edgeOffset = (edgeOffset + 1) & 15;
    }

    void pushVertex(int v) {
      vertexFifo[vertexOffset] = v;
      vertexOffset = (vertexOffset + 1) & 15;
    }

    int readZigzagDelta() {
      var v = 0;
      var shift = 0;
      while (true) {
        if (dataCursor >= dataLimit) {
          throw const FormatException('Truncated meshopt index varint');
        }
        final byte = encoded[dataCursor++];
        v |= (byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) {
          break;
        }
        shift += 7;
      }
      final delta = (v >>> 1) ^ -(v & 1);
      return last += delta;
    }

    int decodeVertRef(int fe) {
      if (fe == 0) {
        final v = next++;
        pushVertex(v);
        return v;
      }
      if (fe < 13) {
        return vertexFifo[(vertexOffset - fe) & 15];
      }
      if (fe == 13) {
        final v = ++last;
        pushVertex(v);
        return v;
      }
      if (fe == 14) {
        final v = --last;
        pushVertex(v);
        return v;
      }
      final v = readZigzagDelta();
      pushVertex(v);
      return v;
    }

    for (var t = 0; t < triCount; t++) {
      final code = encoded[1 + t];
      int a;
      int b;
      int c;

      if (code < 0xF0) {
        final edgeIdx = (edgeOffset - 1 - (code >> 4)) & 15;
        a = edgeFifo[edgeIdx * 2];
        b = edgeFifo[edgeIdx * 2 + 1];
        c = decodeVertRef(code & 0x0F);
        pushEdge(c, b);
        pushEdge(a, c);
      } else if (code < 0xFE) {
        final caux = encoded[codeauxOffset + (code & 0x0F)];
        a = next++;
        pushVertex(a);
        b = decodeVertRef(caux >> 4);
        c = decodeVertRef(caux & 0x0F);
        pushEdge(b, a);
        pushEdge(c, b);
        pushEdge(a, c);
      } else if (code == 0xFE) {
        if (dataCursor >= dataLimit) {
          throw const FormatException('Truncated meshopt 0xFE triangle');
        }
        final caux = encoded[dataCursor++];
        a = next++;
        pushVertex(a);
        b = decodeVertRef(caux >> 4);
        c = decodeVertRef(caux & 0x0F);
        pushEdge(b, a);
        pushEdge(c, b);
        pushEdge(a, c);
      } else {
        if (dataCursor >= dataLimit) {
          throw const FormatException('Truncated meshopt 0xFF triangle');
        }
        final caux = encoded[dataCursor++];
        a = readZigzagDelta();
        pushVertex(a);
        b = decodeVertRef(caux >> 4);
        c = decodeVertRef(caux & 0x0F);
        pushEdge(b, a);
        pushEdge(c, b);
        pushEdge(a, c);
      }

      writeIndex(t * 3, a);
      writeIndex(t * 3 + 1, b);
      writeIndex(t * 3 + 2, c);
    }
  }

  static Uint8List _encodeIndexSequence(
    int Function(int) readIndex,
    int count,
  ) {
    final out = BytesBuilder(copy: false)..addByte(_indexSeqHeaderV1);
    var last0 = 0;
    var last1 = 0;
    for (var i = 0; i < count; i++) {
      final idx = readIndex(i);
      final d0 = (idx - last0).abs();
      final d1 = (idx - last1).abs();
      final channel = d1 < d0 ? 1 : 0;
      final delta = idx - (channel == 0 ? last0 : last1);
      if (channel == 0) {
        last0 = idx;
      } else {
        last1 = idx;
      }
      final zz = delta >= 0 ? (delta << 1) : ((-delta << 1) - 1);
      _writeUnsignedVarint((zz << 1) | channel, out);
    }
    // 4-byte reserved trailer matching meshopt_encodeIndexSequence v1.
    out.add(const [0, 0, 0, 0]);
    return out.toBytes();
  }

  static void _decodeIndexSequence(
    Uint8List encoded,
    int count,
    void Function(int, int) writeIndex,
  ) {
    if (count == 0) {
      return;
    }
    if (encoded.length < 5) {
      throw const FormatException('Truncated meshopt INDICES stream');
    }
    final limit = encoded.length - 4;
    var cursor = 1;
    var last0 = 0;
    var last1 = 0;

    for (var i = 0; i < count; i++) {
      var v = 0;
      var shift = 0;
      while (true) {
        if (cursor >= limit) {
          throw const FormatException('Truncated meshopt INDICES varint');
        }
        final byte = encoded[cursor++];
        v |= (byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) {
          break;
        }
        shift += 7;
      }
      final channel = v & 1;
      final zz = v >>> 1;
      final delta = (zz >>> 1) ^ -(zz & 1);
      final idx = (channel == 0 ? last0 : last1) + delta;
      if (channel == 0) {
        last0 = idx;
      } else {
        last1 = idx;
      }
      writeIndex(i, idx);
    }
  }

  // ===========================================================================
  // 3. Post-Decompression Filters (`OCTAHEDRAL`, `QUATERNION`, `EXPONENTIAL`)
  // ===========================================================================

  /// Applies [filter] in place across [count] elements of [byteStride] bytes in
  /// [buffer].
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

  /// Encodes unit normals/tangents `(nx, ny, nz, signW)` for the `OCTAHEDRAL`
  /// meshopt filter (`byteStride == 4` for `4 x int8` or `byteStride == 8` for
  /// `4 x int16`) ready to feed [encodeVertexStream].
  static Uint8List encodeFilterOct(
    List<Vector4> vectors, {
    int byteStride = 4,
    int bits = 8,
  }) {
    if (byteStride != 4 && byteStride != 8) {
      throw ArgumentError.value(byteStride, 'byteStride', 'Must be 4 or 8');
    }
    final maxBits = byteStride == 4 ? 8 : 16;
    final clampedBits = bits.clamp(2, maxBits);
    final fu = (1 << (clampedBits - 1)) - 1;
    final maxInt = byteStride == 4 ? 127 : 32767;

    final out = Uint8List(vectors.length * byteStride);
    final bd = ByteData.sublistView(out);

    for (var i = 0; i < vectors.length; i++) {
      final v = vectors[i];
      var nx = v.x;
      var ny = v.y;
      var nz = v.z;
      final l1 = nx.abs() + ny.abs() + nz.abs();
      double ox;
      double oy;
      if (l1 > 1e-12) {
        nx /= l1;
        ny /= l1;
        nz /= l1;
        if (nz >= 0.0) {
          ox = nx;
          oy = ny;
        } else {
          ox = (1.0 - ny.abs()) * (nx >= 0.0 ? 1.0 : -1.0);
          oy = (1.0 - nx.abs()) * (ny >= 0.0 ? 1.0 : -1.0);
        }
      } else {
        ox = 0.0;
        oy = 0.0;
      }

      final qx = (ox * fu).round().clamp(-fu, fu);
      final qy = (oy * fu).round().clamp(-fu, fu);
      final qw = (v.w.clamp(-1.0, 1.0) * maxInt).round().clamp(-maxInt, maxInt);

      final base = i * byteStride;
      if (byteStride == 4) {
        bd
          ..setInt8(base, qx)
          ..setInt8(base + 1, qy)
          ..setInt8(base + 2, fu)
          ..setInt8(base + 3, qw);
      } else {
        bd
          ..setInt16(base, qx, Endian.little)
          ..setInt16(base + 2, qy, Endian.little)
          ..setInt16(base + 4, fu, Endian.little)
          ..setInt16(base + 6, qw, Endian.little);
      }
    }
    return out;
  }

  /// Decodes `OCTAHEDRAL`-filtered signed integer unit vectors in place.
  static void decodeFilterOct(
    Uint8List buffer, {
    required int count,
    required int byteStride,
  }) {
    if (byteStride != 4 && byteStride != 8) {
      throw ArgumentError.value(byteStride, 'byteStride', 'Must be 4 or 8');
    }
    final bd = ByteData.sublistView(buffer);
    final maxInt = byteStride == 4 ? 127.0 : 32767.0;
    final maxClamp = byteStride == 4 ? 127 : 32767;

    for (var i = 0; i < count; i++) {
      final base = i * byteStride;
      final int rx;
      final int ry;
      final int rz;
      final int rw;
      if (byteStride == 4) {
        rx = bd.getInt8(base);
        ry = bd.getInt8(base + 1);
        rz = bd.getInt8(base + 2);
        rw = bd.getInt8(base + 3);
      } else {
        rx = bd.getInt16(base, Endian.little);
        ry = bd.getInt16(base + 2, Endian.little);
        rz = bd.getInt16(base + 4, Endian.little);
        rw = bd.getInt16(base + 6, Endian.little);
      }

      final fu = rz == 0 ? 1.0 : rz.abs().toDouble();
      var xf = rx / fu;
      var yf = ry / fu;
      final zf = 1.0 - xf.abs() - yf.abs();
      final t = math.min(zf, 0.0);
      xf += xf >= 0.0 ? t : -t;
      yf += yf >= 0.0 ? t : -t;

      final len = math.sqrt(xf * xf + yf * yf + zf * zf);
      final invLen = len > 1e-12 ? maxInt / len : 0.0;
      final nx = (xf * invLen).round().clamp(-maxClamp, maxClamp);
      final ny = (yf * invLen).round().clamp(-maxClamp, maxClamp);
      final nz = (zf * invLen).round().clamp(-maxClamp, maxClamp);

      if (byteStride == 4) {
        bd
          ..setInt8(base, nx)
          ..setInt8(base + 1, ny)
          ..setInt8(base + 2, nz)
          ..setInt8(base + 3, rw);
      } else {
        bd
          ..setInt16(base, nx, Endian.little)
          ..setInt16(base + 2, ny, Endian.little)
          ..setInt16(base + 4, nz, Endian.little)
          ..setInt16(base + 6, rw, Endian.little);
      }
    }
  }

  /// Encodes unit [Quaternion]s into smallest-three `4 x int16` (`byteStride =
  /// 8`) records for the `QUATERNION` meshopt filter.
  static Uint8List encodeFilterQuat(
    List<Quaternion> rotations, {
    int bits = 12,
  }) {
    final clampedBits = bits.clamp(4, 16);
    final scaler = ((1 << (clampedBits - 1)) - 1) | 3;
    final scaleFactor = scaler / math.sqrt(0.5);

    final out = Uint8List(rotations.length * 8);
    final bd = ByteData.sublistView(out);
    final comps = Float64List(4);

    for (var i = 0; i < rotations.length; i++) {
      final q = rotations[i];
      final len = math.sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
      if (len > 1e-12) {
        final inv = 1.0 / len;
        comps[0] = q.x * inv;
        comps[1] = q.y * inv;
        comps[2] = q.z * inv;
        comps[3] = q.w * inv;
      } else {
        comps[0] = 0.0;
        comps[1] = 0.0;
        comps[2] = 0.0;
        comps[3] = 1.0;
      }

      var qc = 0;
      for (var c = 1; c < 4; c++) {
        if (comps[c].abs() > comps[qc].abs()) {
          qc = c;
        }
      }
      final sign = comps[qc] < 0.0 ? -1.0 : 1.0;

      final s0 = (comps[(qc + 1) & 3] * sign * scaleFactor).round().clamp(
        -scaler,
        scaler,
      );
      final s1 = (comps[(qc + 2) & 3] * sign * scaleFactor).round().clamp(
        -scaler,
        scaler,
      );
      final s2 = (comps[(qc + 3) & 3] * sign * scaleFactor).round().clamp(
        -scaler,
        scaler,
      );
      final s3 = (scaler & ~3) | qc;

      final base = i * 8;
      bd
        ..setInt16(base, s0, Endian.little)
        ..setInt16(base + 2, s1, Endian.little)
        ..setInt16(base + 4, s2, Endian.little)
        ..setInt16(base + 6, s3, Endian.little);
    }
    return out;
  }

  /// Decodes `QUATERNION`-filtered `4 x int16` (`byteStride == 8`) unit
  /// quaternions in place into normalized `SHORT` (`[-32767..32767]`) values.
  static void decodeFilterQuat(
    Uint8List buffer, {
    required int count,
    int byteStride = 8,
  }) {
    if (byteStride != 8) {
      throw ArgumentError.value(byteStride, 'byteStride', 'Must be 8');
    }
    final bd = ByteData.sublistView(buffer);
    final qOut = Float64List(4);

    for (var i = 0; i < count; i++) {
      final base = i * 8;
      final s0 = bd.getInt16(base, Endian.little);
      final s1 = bd.getInt16(base + 2, Endian.little);
      final s2 = bd.getInt16(base + 4, Endian.little);
      final s3 = bd.getInt16(base + 6, Endian.little);

      final qc = s3 & 3;
      final scale = (s3 | 3).abs().toDouble();
      final ss = math.sqrt(0.5) / scale;

      final a = s0 * ss;
      final b = s1 * ss;
      final c = s2 * ss;
      final w = math.sqrt(math.max(0.0, 1.0 - a * a - b * b - c * c));

      qOut[qc] = w;
      qOut[(qc + 1) & 3] = a;
      qOut[(qc + 2) & 3] = b;
      qOut[(qc + 3) & 3] = c;

      final len = math.sqrt(
        qOut[0] * qOut[0] +
            qOut[1] * qOut[1] +
            qOut[2] * qOut[2] +
            qOut[3] * qOut[3],
      );
      final k = len > 1e-12 ? 32767.0 / len : 32767.0;
      bd
        ..setInt16(
          base,
          (qOut[0] * k).round().clamp(-32767, 32767),
          Endian.little,
        )
        ..setInt16(
          base + 2,
          (qOut[1] * k).round().clamp(-32767, 32767),
          Endian.little,
        )
        ..setInt16(
          base + 4,
          (qOut[2] * k).round().clamp(-32767, 32767),
          Endian.little,
        )
        ..setInt16(
          base + 6,
          (qOut[3] * k).round().clamp(-32767, 32767),
          Endian.little,
        );
    }
  }

  /// Encodes `Float32List` attribute data (`count * (byteStride ~/ 4)` floats)
  /// into packed `(8-bit exponent | 24-bit signed mantissa)` words for the
  /// `EXPONENTIAL` meshopt filter.
  static Uint8List encodeFilterExp(
    Float32List floats, {
    required int count,
    required int byteStride,
    int bits = 16,
  }) {
    if (byteStride < 4 || byteStride % 4 != 0) {
      throw ArgumentError.value(
        byteStride,
        'byteStride',
        'Must be a positive multiple of 4',
      );
    }
    final compsPerVertex = byteStride ~/ 4;
    if (floats.length < count * compsPerVertex) {
      throw ArgumentError('floats length smaller than count * compsPerVertex');
    }
    final clampedBits = bits.clamp(1, 24);
    final maxMantissa = (1 << (clampedBits - 1)) - 1;

    final out = Uint8List(count * byteStride);
    final bd = ByteData.sublistView(out);

    for (var i = 0; i < count; i++) {
      final fBase = i * compsPerVertex;
      var maxAbs = 0.0;
      for (var c = 0; c < compsPerVertex; c++) {
        final v = floats[fBase + c].abs();
        if (v.isFinite && v > maxAbs) {
          maxAbs = v;
        }
      }

      var exp = -128;
      if (maxAbs > 0.0) {
        final rawExp = (math.log(maxAbs / maxMantissa) / math.ln2).ceil().clamp(
          -128,
          127,
        );
        exp = rawExp;
      }
      final invScale = math.pow(2.0, -exp).toDouble();
      final expBits = exp & 0xFF;

      for (var c = 0; c < compsPerVertex; c++) {
        final f = floats[fBase + c];
        final m = f.isFinite
            ? (f * invScale).round().clamp(-8388608, 8388607)
            : 0;
        final word = (expBits << 24) | (m & 0xFFFFFF);
        bd.setUint32((fBase + c) * 4, word, Endian.little);
      }
    }
    return out;
  }

  /// Decodes `EXPONENTIAL`-filtered 32-bit `(exp8 | mantissa24)` words in place
  /// into IEEE-754 `float32` values.
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
    final totalWords = count * (byteStride ~/ 4);
    for (var w = 0; w < totalWords; w++) {
      final byteOff = w * 4;
      final raw = bd.getUint32(byteOff, Endian.little);
      var mantissa = raw & 0xFFFFFF;
      if ((mantissa & 0x800000) != 0) {
        mantissa -= 0x1000000;
      }
      var exp = (raw >>> 24) & 0xFF;
      if ((exp & 0x80) != 0) {
        exp -= 0x100;
      }
      final value = mantissa * math.pow(2.0, exp).toDouble();
      bd.setFloat32(byteOff, value, Endian.little);
    }
  }

  // ===========================================================================
  // Internal Bit/Varint Helpers
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

  static int _vertexBlockSize(int byteStride) =>
      ((8192 ~/ byteStride) & ~15).clamp(32, 256);

  static int _zigzag8(int v) =>
      ((v & 0x80) != 0 ? ((~v) << 1) | 1 : (v << 1)) & 0xFF;

  static int _unzigzag8(int u) =>
      ((u & 1) != 0 ? ~(u >>> 1) : (u >>> 1)) & 0xFF;

  static void _writeZigzagVarint(int signedDelta, BytesBuilder out) {
    final zz = signedDelta >= 0
        ? (signedDelta << 1)
        : ((-signedDelta << 1) - 1);
    _writeUnsignedVarint(zz, out);
  }

  static void _writeUnsignedVarint(int value, BytesBuilder out) {
    var v = value;
    while (v >= 0x80) {
      out.addByte((v & 0x7F) | 0x80);
      v >>>= 7;
    }
    out.addByte(v & 0x7F);
  }
}
