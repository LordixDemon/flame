part of 'meshopt_decoder_3d.dart';

Uint8List _encodeIndexStream(
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

Uint8List _decodeIndexStream(
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

Uint8List _encodeTriangles(Uint32List indices) {
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

void _decodeTriangles(
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

Uint8List _encodeIndexSequence(Uint32List indices) {
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

void _decodeIndexSequence(Uint8List encoded, Uint32List out) {
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
