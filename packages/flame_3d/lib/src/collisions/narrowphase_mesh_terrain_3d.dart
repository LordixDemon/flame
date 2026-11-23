part of 'collision_manifold_3d.dart';

final MutableManifoldBuffer3D _rawManifoldBuf = MutableManifoldBuffer3D();
bool _inRawManifoldBuf = false;

MutableManifoldBuffer3D _acquireRawManifoldBuf() {
  if (_inRawManifoldBuf) {
    return MutableManifoldBuffer3D();
  }
  _inRawManifoldBuf = true;
  _rawManifoldBuf.clear();
  return _rawManifoldBuf;
}

void _releaseRawManifoldBuf(MutableManifoldBuffer3D buf) {
  if (identical(buf, _rawManifoldBuf)) {
    _inRawManifoldBuf = false;
  }
}

final List<Matrix4> _cmpMatStack = [Matrix4.identity(), Matrix4.identity()];
final List<Aabb3> _cmpBoxStack = [Aabb3(), Aabb3()];
final List<Aabb3> _cmpOtherBoxStack = [Aabb3(), Aabb3()];

final Matrix4 _hfInvMat = Matrix4.identity();
final Aabb3 _hfWorldBox = Aabb3();
final Aabb3 _hfLocalBox = Aabb3();
final Vector3 _hfLv00 = Vector3.zero();
final Vector3 _hfLv01 = Vector3.zero();
final Vector3 _hfLv11 = Vector3.zero();
final Vector3 _hfLv10 = Vector3.zero();
final Vector3 _hfWv00 = Vector3.zero();
final Vector3 _hfWv01 = Vector3.zero();
final Vector3 _hfWv11 = Vector3.zero();
final Vector3 _hfWv10 = Vector3.zero();

int _mergeGroupCap = 64;
Int32List _mergeRepManifold = Int32List(64);
Int32List _mergeGroupHead = Int32List(64);
Int32List _mergeManifoldNext = Int32List(64);
Int32List _mergeManifoldGroup = Int32List(64);
Int32List _mergeGroupDeepest = Int32List(64);
Int32List _mergeContactIdx = Int32List(256);

Matrix4 _borrowCmpMat(int depth) {
  while (_cmpMatStack.length <= depth) {
    _cmpMatStack.add(Matrix4.identity());
  }
  return _cmpMatStack[depth];
}

Aabb3 _borrowCmpBox(int depth) {
  while (_cmpBoxStack.length <= depth) {
    _cmpBoxStack.add(Aabb3());
  }
  return _cmpBoxStack[depth];
}

Aabb3 _borrowCmpOtherBox(int depth) {
  while (_cmpOtherBoxStack.length <= depth) {
    _cmpOtherBoxStack.add(Aabb3());
  }
  return _cmpOtherBoxStack[depth];
}

void _ensureMergeGroupCap(int count) {
  if (_mergeGroupCap >= count) {
    return;
  }
  var cap = _mergeGroupCap;
  while (cap < count) {
    cap *= 2;
  }
  _mergeRepManifold = Int32List(cap);
  _mergeGroupHead = Int32List(cap);
  _mergeManifoldNext = Int32List(cap);
  _mergeManifoldGroup = Int32List(cap);
  _mergeGroupDeepest = Int32List(cap);
  _mergeGroupCap = cap;
}

void _ensureMergeContactCap(int count) {
  if (_mergeContactIdx.length >= count) {
    return;
  }
  var cap = _mergeContactIdx.length;
  while (cap < count) {
    cap *= 2;
  }
  _mergeContactIdx = Int32List(cap);
}

void _collectRawPairInto(
  Shape3D shapeA,
  Matrix4 transformA,
  Shape3D shapeB,
  Matrix4 transformB,
  MutableManifoldBuffer3D out,
  int depth,
) {
  if (shapeA is CompoundShape3D) {
    _collectCompoundRawInto(
      shapeA,
      transformA,
      shapeB,
      transformB,
      out,
      depth,
    );
    return;
  }
  if (shapeB is CompoundShape3D) {
    final start = out.manifoldCount;
    _collectCompoundRawInto(
      shapeB,
      transformB,
      shapeA,
      transformA,
      out,
      depth,
    );
    out.flipManifoldsFrom(start);
    return;
  }
  if (shapeA is HeightfieldShape3D) {
    final start = out.manifoldCount;
    _heightfieldShapeRawInto(shapeB, transformB, shapeA, transformA, out);
    out.flipManifoldsFrom(start);
    return;
  }
  if (shapeB is HeightfieldShape3D) {
    _heightfieldShapeRawInto(shapeA, transformA, shapeB, transformB, out);
    return;
  }
  Narrowphase3D._primitiveOrConvexInto(
    shapeA,
    transformA,
    shapeB,
    transformB,
    out,
  );
}

void _collectCompoundRawInto(
  CompoundShape3D compoundA,
  Matrix4 transformA,
  Shape3D shapeB,
  Matrix4 transformB,
  MutableManifoldBuffer3D out,
  int depth,
) {
  final boxB = _borrowCmpOtherBox(depth);
  shapeB.computeWorldAabb(transformB, boxB);
  final childMat = _borrowCmpMat(depth);
  final childBox = _borrowCmpBox(depth);
  for (var i = 0; i < compoundA.children.length; i++) {
    final child = compoundA.children[i];
    childMat
      ..setFrom(transformA)
      ..multiply(child.localTransform);
    child.shape.computeWorldAabb(childMat, childBox);
    if (!aabbOverlaps(childBox, boxB)) {
      continue;
    }
    _collectRawPairInto(
      child.shape,
      childMat,
      shapeB,
      transformB,
      out,
      depth + 1,
    );
  }
}

void _heightfieldShapeRawInto(
  Shape3D shape,
  Matrix4 shapeTransform,
  HeightfieldShape3D heightfield,
  Matrix4 heightfieldTransform,
  MutableManifoldBuffer3D out,
) {
  if (shape is HeightfieldShape3D) {
    return;
  }
  if (shape is CompoundShape3D) {
    _collectCompoundRawInto(
      shape,
      shapeTransform,
      heightfield,
      heightfieldTransform,
      out,
      0,
    );
    return;
  }

  _hfInvMat.setFrom(heightfieldTransform);
  if (_hfInvMat.invert().abs() < 1e-15) {
    return;
  }

  shape.computeWorldAabb(shapeTransform, _hfWorldBox);
  _hfLocalBox
    ..setFrom(_hfWorldBox)
    ..transform(_hfInvMat);

  if (_hfLocalBox.max.y < heightfield.minHeight - 1e-4 ||
      _hfLocalBox.min.y > heightfield.maxHeight + 1e-4) {
    return;
  }

  final halfW = heightfield.width * 0.5;
  final halfD = heightfield.depth * 0.5;
  final minX = _hfLocalBox.min.x;
  final maxX = _hfLocalBox.max.x;
  final minZ = _hfLocalBox.min.z;
  final maxZ = _hfLocalBox.max.z;
  if (maxX < -halfW || minX > halfW || maxZ < -halfD || minZ > halfD) {
    return;
  }
  final maxCol = heightfield.columns - 2;
  final maxRow = heightfield.rows - 2;
  final invCw = (heightfield.columns - 1) / heightfield.width;
  final invCd = (heightfield.rows - 1) / heightfield.depth;
  final c0 = ((minX + halfW) * invCw).floor().clamp(0, maxCol);
  final c1 = ((maxX + halfW) * invCw).floor().clamp(0, maxCol);
  final r0 = ((minZ + halfD) * invCd).floor().clamp(0, maxRow);
  final r1 = ((maxZ + halfD) * invCd).floor().clamp(0, maxRow);

  final m = heightfieldTransform.storage;
  var hfUpX = m[4];
  var hfUpY = m[5];
  var hfUpZ = m[6];
  final upLen = math.sqrt(hfUpX * hfUpX + hfUpY * hfUpY + hfUpZ * hfUpZ);
  if (upLen > 1e-12) {
    hfUpX /= upLen;
    hfUpY /= upLen;
    hfUpZ /= upLen;
  } else {
    hfUpX = 0.0;
    hfUpY = 1.0;
    hfUpZ = 0.0;
  }

  for (var r = r0; r <= r1; r++) {
    for (var c = c0; c <= c1; c++) {
      heightfield.writeCellVerticesLocal(
        c,
        r,
        _hfLv00,
        _hfLv01,
        _hfLv11,
        _hfLv10,
      );
      final cellMinY = math.min(
        math.min(_hfLv00.y, _hfLv01.y),
        math.min(_hfLv11.y, _hfLv10.y),
      );
      final cellMaxY = math.max(
        math.max(_hfLv00.y, _hfLv01.y),
        math.max(_hfLv11.y, _hfLv10.y),
      );
      if (_hfLocalBox.max.y < cellMinY - 1e-4 ||
          _hfLocalBox.min.y > cellMaxY + 1e-4) {
        continue;
      }

      transformPoint3D(m, _hfLv00.x, _hfLv00.y, _hfLv00.z, _hfWv00);
      transformPoint3D(m, _hfLv01.x, _hfLv01.y, _hfLv01.z, _hfWv01);
      transformPoint3D(m, _hfLv11.x, _hfLv11.y, _hfLv11.z, _hfWv11);
      transformPoint3D(m, _hfLv10.x, _hfLv10.y, _hfLv10.z, _hfWv10);

      final before0 = out.manifoldCount;
      _intersectShapeWithTriangleInto(
        shape,
        shapeTransform,
        _hfWv00,
        _hfWv01,
        _hfWv11,
        out,
      );
      if (out.manifoldCount > before0) {
        _orientBufferManifold(
          out,
          before0,
          _hfWv00,
          _hfWv01,
          _hfWv11,
          hfUpX,
          hfUpY,
          hfUpZ,
        );
      }

      final before1 = out.manifoldCount;
      _intersectShapeWithTriangleInto(
        shape,
        shapeTransform,
        _hfWv00,
        _hfWv11,
        _hfWv10,
        out,
      );
      if (out.manifoldCount > before1) {
        _orientBufferManifold(
          out,
          before1,
          _hfWv00,
          _hfWv11,
          _hfWv10,
          hfUpX,
          hfUpY,
          hfUpZ,
        );
      }
    }
  }
}

void _orientBufferManifold(
  MutableManifoldBuffer3D buf,
  int mIdx,
  Vector3 v0,
  Vector3 v1,
  Vector3 v2,
  double hfUpX,
  double hfUpY,
  double hfUpZ,
) {
  final dotUp =
      buf.normalX(mIdx) * hfUpX +
      buf.normalY(mIdx) * hfUpY +
      buf.normalZ(mIdx) * hfUpZ;
  if (dotUp <= 1e-5) {
    return;
  }
  final e1x = v1.x - v0.x;
  final e1y = v1.y - v0.y;
  final e1z = v1.z - v0.z;
  final e2x = v2.x - v0.x;
  final e2y = v2.y - v0.y;
  final e2z = v2.z - v0.z;
  var nx = -(e1y * e2z - e1z * e2y);
  var ny = -(e1z * e2x - e1x * e2z);
  var nz = -(e1x * e2y - e1y * e2x);
  final len = math.sqrt(nx * nx + ny * ny + nz * nz);
  if (len > 1e-12) {
    nx /= len;
    ny /= len;
    nz /= len;
  } else {
    nx = -hfUpX;
    ny = -hfUpY;
    nz = -hfUpZ;
  }
  buf.setNormal(mIdx, nx, ny, nz);
}

void _intersectShapeWithTriangleInto(
  Shape3D shape,
  Matrix4 shapeTransform,
  Vector3 v0,
  Vector3 v1,
  Vector3 v2,
  MutableManifoldBuffer3D out, {
  int depth = 0,
}) {
  if (shape is CompoundShape3D) {
    final baseM = out.manifoldCount;
    final baseC = out.contactCount;
    final childMat = _borrowCmpMat(depth);
    var bestM = -1;
    var bestDepth = double.negativeInfinity;
    for (var i = 0; i < shape.children.length; i++) {
      final child = shape.children[i];
      childMat
        ..setFrom(shapeTransform)
        ..multiply(child.localTransform);
      final before = out.manifoldCount;
      _intersectShapeWithTriangleInto(
        child.shape,
        childMat,
        v0,
        v1,
        v2,
        out,
        depth: depth + 1,
      );
      for (var mIdx = before; mIdx < out.manifoldCount; mIdx++) {
        final d = out.depth(mIdx);
        if (d > bestDepth) {
          bestDepth = d;
          bestM = mIdx;
        }
      }
    }
    if (bestM >= 0) {
      out.retainOnlyManifold(baseM, baseC, bestM);
    }
    return;
  }
  if (shape is SphereShape3D) {
    final m = shapeTransform.storage;
    final cx = m[12];
    final cy = m[13];
    final cz = m[14];
    final r = shape.worldRadius(shapeTransform);
    closestPointOnTriangle3D(cx, cy, cz, v0, v1, v2, _ptB);
    _sphereTrianglePointsInto(cx, cy, cz, r, _ptB, v0, v1, v2, out);
    return;
  }
  if (shape is CapsuleShape3D) {
    final r = shape.worldSpine(shapeTransform, _segA0, _segA1);
    _closestPointsSegmentTriangle(_segA0, _segA1, v0, v1, v2, _ptA, _ptB);
    _sphereTrianglePointsInto(_ptA.x, _ptA.y, _ptA.z, r, _ptB, v0, v1, v2, out);
    return;
  }

  _triCentroid.setValues(
    (v0.x + v1.x + v2.x) * (1.0 / 3.0),
    (v0.y + v1.y + v2.y) * (1.0 / 3.0),
    (v0.z + v1.z + v2.z) * (1.0 / 3.0),
  );
  final cA = centerOfMatrix3D(shapeTransform, _cAScratch);
  if (!_gjkEpaRun(
    shapeA: shape,
    transformA: shapeTransform,
    triV0: v0,
    triV1: v1,
    triV2: v2,
    cAx: cA.x,
    cAy: cA.y,
    cAz: cA.z,
    cBx: _triCentroid.x,
    cBy: _triCentroid.y,
    cBz: _triCentroid.z,
  )) {
    return;
  }
  if (_writeSupportFace(
    shape,
    shapeTransform,
    _epaNx,
    _epaNy,
    _epaNz,
    _faceA,
  )) {
    final e1x = v1.x - v0.x;
    final e1y = v1.y - v0.y;
    final e1z = v1.z - v0.z;
    final e2x = v2.x - v0.x;
    final e2y = v2.y - v0.y;
    final e2z = v2.z - v0.z;
    var tnx = e1y * e2z - e1z * e2y;
    var tny = e1z * e2x - e1x * e2z;
    var tnz = e1x * e2y - e1y * e2x;
    final len = math.sqrt(tnx * tnx + tny * tny + tnz * tnz);
    if (len > 1e-20) {
      final flip = tnx * _epaNx + tny * _epaNy + tnz * _epaNz > 0.0
          ? -1.0
          : 1.0;
      tnx *= flip / len;
      tny *= flip / len;
      tnz *= flip / len;
      _faceB
        ..setTriangle(v0, v1, v2)
        ..nx = tnx
        ..ny = tny
        ..nz = tnz
        ..faceId = 0;
      if (_clipSupportFacesInto(
        _epaNx,
        _epaNy,
        _epaNz,
        _faceA,
        _faceB,
        out,
      )) {
        return;
      }
    }
  }
  out.pushSingle(
    _epaNx,
    _epaNy,
    _epaNz,
    _epaDepth,
    _epaAx,
    _epaAy,
    _epaAz,
    _epaBx,
    _epaBy,
    _epaBz,
  );
}

void _sphereTrianglePointsInto(
  double cx,
  double cy,
  double cz,
  double r,
  Vector3 closestOnTri,
  Vector3 v0,
  Vector3 v1,
  Vector3 v2,
  MutableManifoldBuffer3D out,
) {
  final dx = closestOnTri.x - cx;
  final dy = closestOnTri.y - cy;
  final dz = closestOnTri.z - cz;
  final dist2 = dx * dx + dy * dy + dz * dz;
  if (dist2 > r * r) {
    return;
  }
  final dist = math.sqrt(dist2);
  double nx;
  double ny;
  double nz;
  if (dist > 1e-9) {
    final inv = 1.0 / dist;
    nx = dx * inv;
    ny = dy * inv;
    nz = dz * inv;
  } else {
    final e1x = v1.x - v0.x;
    final e1y = v1.y - v0.y;
    final e1z = v1.z - v0.z;
    final e2x = v2.x - v0.x;
    final e2y = v2.y - v0.y;
    final e2z = v2.z - v0.z;
    nx = -(e1y * e2z - e1z * e2y);
    ny = -(e1z * e2x - e1x * e2z);
    nz = -(e1x * e2y - e1y * e2x);
    final len = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (len > 1e-12) {
      nx /= len;
      ny /= len;
      nz /= len;
    } else {
      nx = 0.0;
      ny = -1.0;
      nz = 0.0;
    }
  }
  out.pushSingle(
    nx,
    ny,
    nz,
    r - dist,
    cx + nx * r,
    cy + ny * r,
    cz + nz * r,
    closestOnTri.x,
    closestOnTri.y,
    closestOnTri.z,
  );
}

void _mergeCoDirectionalInto(
  MutableManifoldBuffer3D src,
  MutableManifoldBuffer3D dst,
) {
  final count = src.manifoldCount;
  if (count == 0) {
    return;
  }
  if (count == 1) {
    dst.copyManifoldFrom(src, 0);
    return;
  }
  _ensureMergeGroupCap(count);

  var groupCount = 0;
  for (var i = 0; i < count; i++) {
    final nx = src.normalX(i);
    final ny = src.normalY(i);
    final nz = src.normalZ(i);
    var placed = -1;
    for (var g = 0; g < groupCount; g++) {
      final rep = _mergeRepManifold[g];
      if (src.normalX(rep) * nx +
              src.normalY(rep) * ny +
              src.normalZ(rep) * nz >=
          0.992) {
        placed = g;
        break;
      }
    }
    if (placed < 0) {
      placed = groupCount++;
      _mergeRepManifold[placed] = i;
      _mergeGroupHead[placed] = i;
      _mergeGroupDeepest[placed] = i;
      _mergeManifoldNext[i] = -1;
      _mergeManifoldGroup[i] = placed;
    } else {
      // Link into group (append order not critical; keep track of deepest).
      _mergeManifoldGroup[i] = placed;
      _mergeManifoldNext[i] = _mergeGroupHead[placed];
      _mergeGroupHead[placed] = i;
      if (src.depth(i) > src.depth(_mergeGroupDeepest[placed])) {
        _mergeGroupDeepest[placed] = i;
      }
    }
  }

  for (var g = 0; g < groupCount; g++) {
    final rep = _mergeRepManifold[g];
    if (_mergeManifoldNext[rep] == -1 && _mergeGroupHead[g] == rep) {
      dst.copyManifoldFrom(src, rep);
      continue;
    }

    final deepest = _mergeGroupDeepest[g];
    final dnx = src.normalX(deepest);
    final dny = src.normalY(deepest);
    final dnz = src.normalZ(deepest);
    var uniqueCount = 0;

    for (var i = 0; i < count; i++) {
      if (_mergeManifoldGroup[i] != g) {
        continue;
      }
      final start = src.contactStart(i);
      final len = src.contactLength(i);
      for (var k = 0; k < len; k++) {
        final ci = start + k;
        final ax = src.pointAX(ci);
        final ay = src.pointAY(ci);
        final az = src.pointAZ(ci);
        final bx = src.pointBX(ci);
        final by = src.pointBY(ci);
        final bz = src.pointBZ(ci);
        var dup = false;
        for (var e = 0; e < uniqueCount; e++) {
          final ei = _mergeContactIdx[e];
          final dax = src.pointAX(ei) - ax;
          final day = src.pointAY(ei) - ay;
          final daz = src.pointAZ(ei) - az;
          if (dax * dax + day * day + daz * daz < 1e-6) {
            final dbx = src.pointBX(ei) - bx;
            final dby = src.pointBY(ei) - by;
            final dbz = src.pointBZ(ei) - bz;
            if (dbx * dbx + dby * dby + dbz * dbz < 1e-6) {
              dup = true;
              break;
            }
          }
        }
        if (!dup) {
          _ensureMergeContactCap(uniqueCount + 1);
          _mergeContactIdx[uniqueCount++] = ci;
        }
      }
    }

    final outM = dst.beginManifold(dnx, dny, dnz, src.depth(deepest));
    if (uniqueCount <= 4) {
      for (var u = 0; u < uniqueCount; u++) {
        final ci = _mergeContactIdx[u];
        dst.addContact(
          outM,
          src.pointAX(ci),
          src.pointAY(ci),
          src.pointAZ(ci),
          src.pointBX(ci),
          src.pointBY(ci),
          src.pointBZ(ci),
          src.pointDepth(ci),
          src.featureId(ci),
        );
      }
      continue;
    }

    // Reduce to at most 4 well-spread points.
    var i0 = 0;
    for (var i = 1; i < uniqueCount; i++) {
      if (src.pointDepth(_mergeContactIdx[i]) >
          src.pointDepth(_mergeContactIdx[i0])) {
        i0 = i;
      }
    }
    final c0 = _mergeContactIdx[i0];
    final p0x = src.pointAX(c0);
    final p0y = src.pointAY(c0);
    final p0z = src.pointAZ(c0);

    var i1 = 0;
    var bestD2 = -1.0;
    for (var i = 0; i < uniqueCount; i++) {
      final ci = _mergeContactIdx[i];
      final dx = src.pointAX(ci) - p0x;
      final dy = src.pointAY(ci) - p0y;
      final dz = src.pointAZ(ci) - p0z;
      final d2 = dx * dx + dy * dy + dz * dz;
      if (d2 > bestD2) {
        bestD2 = d2;
        i1 = i;
      }
    }
    final c1 = _mergeContactIdx[i1];
    final p1x = src.pointAX(c1);
    final p1y = src.pointAY(c1);
    final p1z = src.pointAZ(c1);
    final e1x = p1x - p0x;
    final e1y = p1y - p0y;
    final e1z = p1z - p0z;

    var i2 = 0;
    var bestArea = -1.0;
    for (var i = 0; i < uniqueCount; i++) {
      if (i == i0 || i == i1) {
        continue;
      }
      final ci = _mergeContactIdx[i];
      final e2x = src.pointAX(ci) - p0x;
      final e2y = src.pointAY(ci) - p0y;
      final e2z = src.pointAZ(ci) - p0z;
      final cx = e1y * e2z - e1z * e2y;
      final cy = e1z * e2x - e1x * e2z;
      final cz = e1x * e2y - e1y * e2x;
      final area = (cx * dnx + cy * dny + cz * dnz).abs();
      if (area > bestArea) {
        bestArea = area;
        i2 = i;
      }
    }
    final c2 = _mergeContactIdx[i2];
    final p2x = src.pointAX(c2);
    final p2y = src.pointAY(c2);
    final p2z = src.pointAZ(c2);

    var i3 = 0;
    var bestFourth = -1.0;
    for (var i = 0; i < uniqueCount; i++) {
      if (i == i0 || i == i1 || i == i2) {
        continue;
      }
      final ci = _mergeContactIdx[i];
      final px = src.pointAX(ci);
      final py = src.pointAY(ci);
      final pz = src.pointAZ(ci);
      final d0 =
          (px - p0x) * (px - p0x) +
          (py - p0y) * (py - p0y) +
          (pz - p0z) * (pz - p0z);
      final d1 =
          (px - p1x) * (px - p1x) +
          (py - p1y) * (py - p1y) +
          (pz - p1z) * (pz - p1z);
      final d2 =
          (px - p2x) * (px - p2x) +
          (py - p2y) * (py - p2y) +
          (pz - p2z) * (pz - p2z);
      final dMin = math.min(d0, math.min(d1, d2));
      if (dMin > bestFourth) {
        bestFourth = dMin;
        i3 = i;
      }
    }

    dst.addContact(
      outM,
      p0x,
      p0y,
      p0z,
      src.pointBX(c0),
      src.pointBY(c0),
      src.pointBZ(c0),
      src.pointDepth(c0),
      src.featureId(c0),
    );
    if (i1 != i0) {
      dst.addContact(
        outM,
        p1x,
        p1y,
        p1z,
        src.pointBX(c1),
        src.pointBY(c1),
        src.pointBZ(c1),
        src.pointDepth(c1),
        src.featureId(c1),
      );
    }
    if (i2 != i0 && i2 != i1) {
      dst.addContact(
        outM,
        p2x,
        p2y,
        p2z,
        src.pointBX(c2),
        src.pointBY(c2),
        src.pointBZ(c2),
        src.pointDepth(c2),
        src.featureId(c2),
      );
    }
    if (i3 != i0 && i3 != i1 && i3 != i2) {
      final c3 = _mergeContactIdx[i3];
      dst.addContact(
        outM,
        src.pointAX(c3),
        src.pointAY(c3),
        src.pointAZ(c3),
        src.pointBX(c3),
        src.pointBY(c3),
        src.pointBZ(c3),
        src.pointDepth(c3),
        src.featureId(c3),
      );
    }
  }
}

final Matrix4 _invMesh = Matrix4.identity();
final Aabb3 _worldShapeBox = Aabb3();
final Aabb3 _localShapeBox = Aabb3();
final List<int> _candidateTris = [];
final Vector3 _triV0 = Vector3.zero();
final Vector3 _triV1 = Vector3.zero();
final Vector3 _triV2 = Vector3.zero();
final Vector3 _triCentroid = Vector3.zero();
final Vector3 _cAScratch = Vector3.zero();
final Vector3 _cBScratch = Vector3.zero();

/// Writes every triangle contact manifold where [shape] (under
/// [shapeTransform]) overlaps [surface] (under [meshTransform]) into [out].
void _intersectShapeWithSurfaceBvhRawInto(
  Shape3D shape,
  Matrix4 shapeTransform,
  Surface surface,
  Matrix4 meshTransform,
  MutableManifoldBuffer3D out,
) {
  if (surface.indexCount < 3) {
    return;
  }
  final bvhRef = surface.bvh;
  if (bvhRef.triangleCount == 0) {
    return;
  }

  _invMesh.setFrom(meshTransform);
  if (_invMesh.invert().abs() < 1e-15) {
    return;
  }

  shape.computeWorldAabb(shapeTransform, _worldShapeBox);
  _localShapeBox
    ..setFrom(_worldShapeBox)
    ..transform(_invMesh);

  if (!aabbOverlaps(_localShapeBox, surface.aabb)) {
    return;
  }

  _candidateTris.clear();
  bvhRef.queryAabb(_localShapeBox, _candidateTris);
  if (_candidateTris.isEmpty) {
    return;
  }

  final positions = surface.positions;
  final indices = surface.indices;
  final m = meshTransform.storage;

  for (var i = 0; i < _candidateTris.length; i++) {
    final tri = _candidateTris[i];
    final base = tri * 3;
    final i0 = indices[base] * 3;
    final i1 = indices[base + 1] * 3;
    final i2 = indices[base + 2] * 3;

    transformPoint3D(
      m,
      positions[i0],
      positions[i0 + 1],
      positions[i0 + 2],
      _triV0,
    );
    transformPoint3D(
      m,
      positions[i1],
      positions[i1 + 1],
      positions[i1 + 2],
      _triV1,
    );
    transformPoint3D(
      m,
      positions[i2],
      positions[i2 + 1],
      positions[i2 + 2],
      _triV2,
    );

    _intersectShapeWithTriangleInto(
      shape,
      shapeTransform,
      _triV0,
      _triV1,
      _triV2,
      out,
    );
  }
}
