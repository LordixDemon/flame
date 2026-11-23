part of 'meshopt_decoder_3d.dart';

void _applyFilterInPlace(
  Uint8List buffer, {
  required int count,
  required int byteStride,
  required MeshoptFilter3D filter,
}) {
  switch (filter) {
    case MeshoptFilter3D.none:
      return;
    case MeshoptFilter3D.octahedral:
      _decodeFilterOct(buffer, count: count, byteStride: byteStride);
    case MeshoptFilter3D.quaternion:
      _decodeFilterQuat(buffer, count: count, byteStride: byteStride);
    case MeshoptFilter3D.exponential:
      _decodeFilterExp(buffer, count: count, byteStride: byteStride);
  }
}

Uint8List _encodeFilterOct(
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

void _decodeFilterOct(
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

Uint8List _encodeFilterQuat(
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

void _decodeFilterQuat(
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

Uint8List _encodeFilterExp(
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

void _decodeFilterExp(
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
