part of 'collision_manifold_3d.dart';

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
  final boxB = Narrowphase3D._scratch.mesh.borrowCmpOtherBox(depth);
  shapeB.computeWorldAabb(transformB, boxB);
  final childMat = Narrowphase3D._scratch.mesh.borrowCmpMat(depth);
  final childBox = Narrowphase3D._scratch.mesh.borrowCmpBox(depth);
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

  Narrowphase3D._scratch.mesh.hfInvMat.setFrom(heightfieldTransform);
  if (Narrowphase3D._scratch.mesh.hfInvMat.invert().abs() < 1e-15) {
    return;
  }

  shape.computeWorldAabb(
    shapeTransform,
    Narrowphase3D._scratch.mesh.hfWorldBox,
  );
  Narrowphase3D._scratch.mesh.hfLocalBox
    ..setFrom(Narrowphase3D._scratch.mesh.hfWorldBox)
    ..transform(Narrowphase3D._scratch.mesh.hfInvMat);

  if (Narrowphase3D._scratch.mesh.hfLocalBox.max.y <
          heightfield.minHeight - 1e-4 ||
      Narrowphase3D._scratch.mesh.hfLocalBox.min.y >
          heightfield.maxHeight + 1e-4) {
    return;
  }

  final halfW = heightfield.width * 0.5;
  final halfD = heightfield.depth * 0.5;
  final minX = Narrowphase3D._scratch.mesh.hfLocalBox.min.x;
  final maxX = Narrowphase3D._scratch.mesh.hfLocalBox.max.x;
  final minZ = Narrowphase3D._scratch.mesh.hfLocalBox.min.z;
  final maxZ = Narrowphase3D._scratch.mesh.hfLocalBox.max.z;
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
        Narrowphase3D._scratch.mesh.hfLv00,
        Narrowphase3D._scratch.mesh.hfLv01,
        Narrowphase3D._scratch.mesh.hfLv11,
        Narrowphase3D._scratch.mesh.hfLv10,
      );
      final cellMinY = math.min(
        math.min(
          Narrowphase3D._scratch.mesh.hfLv00.y,
          Narrowphase3D._scratch.mesh.hfLv01.y,
        ),
        math.min(
          Narrowphase3D._scratch.mesh.hfLv11.y,
          Narrowphase3D._scratch.mesh.hfLv10.y,
        ),
      );
      final cellMaxY = math.max(
        math.max(
          Narrowphase3D._scratch.mesh.hfLv00.y,
          Narrowphase3D._scratch.mesh.hfLv01.y,
        ),
        math.max(
          Narrowphase3D._scratch.mesh.hfLv11.y,
          Narrowphase3D._scratch.mesh.hfLv10.y,
        ),
      );
      if (Narrowphase3D._scratch.mesh.hfLocalBox.max.y < cellMinY - 1e-4 ||
          Narrowphase3D._scratch.mesh.hfLocalBox.min.y > cellMaxY + 1e-4) {
        continue;
      }

      transformPoint3D(
        m,
        Narrowphase3D._scratch.mesh.hfLv00.x,
        Narrowphase3D._scratch.mesh.hfLv00.y,
        Narrowphase3D._scratch.mesh.hfLv00.z,
        Narrowphase3D._scratch.mesh.hfWv00,
      );
      transformPoint3D(
        m,
        Narrowphase3D._scratch.mesh.hfLv01.x,
        Narrowphase3D._scratch.mesh.hfLv01.y,
        Narrowphase3D._scratch.mesh.hfLv01.z,
        Narrowphase3D._scratch.mesh.hfWv01,
      );
      transformPoint3D(
        m,
        Narrowphase3D._scratch.mesh.hfLv11.x,
        Narrowphase3D._scratch.mesh.hfLv11.y,
        Narrowphase3D._scratch.mesh.hfLv11.z,
        Narrowphase3D._scratch.mesh.hfWv11,
      );
      transformPoint3D(
        m,
        Narrowphase3D._scratch.mesh.hfLv10.x,
        Narrowphase3D._scratch.mesh.hfLv10.y,
        Narrowphase3D._scratch.mesh.hfLv10.z,
        Narrowphase3D._scratch.mesh.hfWv10,
      );

      final before0 = out.manifoldCount;
      _intersectShapeWithTriangleInto(
        shape,
        shapeTransform,
        Narrowphase3D._scratch.mesh.hfWv00,
        Narrowphase3D._scratch.mesh.hfWv01,
        Narrowphase3D._scratch.mesh.hfWv11,
        out,
      );
      if (out.manifoldCount > before0) {
        _orientBufferManifold(
          out,
          before0,
          Narrowphase3D._scratch.mesh.hfWv00,
          Narrowphase3D._scratch.mesh.hfWv01,
          Narrowphase3D._scratch.mesh.hfWv11,
          hfUpX,
          hfUpY,
          hfUpZ,
        );
      }

      final before1 = out.manifoldCount;
      _intersectShapeWithTriangleInto(
        shape,
        shapeTransform,
        Narrowphase3D._scratch.mesh.hfWv00,
        Narrowphase3D._scratch.mesh.hfWv11,
        Narrowphase3D._scratch.mesh.hfWv10,
        out,
      );
      if (out.manifoldCount > before1) {
        _orientBufferManifold(
          out,
          before1,
          Narrowphase3D._scratch.mesh.hfWv00,
          Narrowphase3D._scratch.mesh.hfWv11,
          Narrowphase3D._scratch.mesh.hfWv10,
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
    final childMat = Narrowphase3D._scratch.mesh.borrowCmpMat(depth);
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
    closestPointOnTriangle3D(
      cx,
      cy,
      cz,
      v0,
      v1,
      v2,
      Narrowphase3D._scratch.dist.ptB,
    );
    _sphereTrianglePointsInto(
      cx,
      cy,
      cz,
      r,
      Narrowphase3D._scratch.dist.ptB,
      v0,
      v1,
      v2,
      out,
    );
    return;
  }
  if (shape is CapsuleShape3D) {
    final r = shape.worldSpine(
      shapeTransform,
      Narrowphase3D._scratch.dist.segA0,
      Narrowphase3D._scratch.dist.segA1,
    );
    _closestPointsSegmentTriangle(
      Narrowphase3D._scratch.dist.segA0,
      Narrowphase3D._scratch.dist.segA1,
      v0,
      v1,
      v2,
      Narrowphase3D._scratch.dist.ptA,
      Narrowphase3D._scratch.dist.ptB,
    );
    _sphereTrianglePointsInto(
      Narrowphase3D._scratch.dist.ptA.x,
      Narrowphase3D._scratch.dist.ptA.y,
      Narrowphase3D._scratch.dist.ptA.z,
      r,
      Narrowphase3D._scratch.dist.ptB,
      v0,
      v1,
      v2,
      out,
    );
    return;
  }

  Narrowphase3D._scratch.mesh.triCentroid.setValues(
    (v0.x + v1.x + v2.x) * (1.0 / 3.0),
    (v0.y + v1.y + v2.y) * (1.0 / 3.0),
    (v0.z + v1.z + v2.z) * (1.0 / 3.0),
  );
  final cA = centerOfMatrix3D(shapeTransform, Narrowphase3D._scratch.gjk.cA);
  if (!_gjkEpaRun(
    shapeA: shape,
    transformA: shapeTransform,
    triV0: v0,
    triV1: v1,
    triV2: v2,
    cAx: cA.x,
    cAy: cA.y,
    cAz: cA.z,
    cBx: Narrowphase3D._scratch.mesh.triCentroid.x,
    cBy: Narrowphase3D._scratch.mesh.triCentroid.y,
    cBz: Narrowphase3D._scratch.mesh.triCentroid.z,
  )) {
    return;
  }
  if (_writeSupportFace(
    shape,
    shapeTransform,
    Narrowphase3D._scratch.gjk.epaNx,
    Narrowphase3D._scratch.gjk.epaNy,
    Narrowphase3D._scratch.gjk.epaNz,
    Narrowphase3D._scratch.clip.faceA,
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
      final flip =
          tnx * Narrowphase3D._scratch.gjk.epaNx +
                  tny * Narrowphase3D._scratch.gjk.epaNy +
                  tnz * Narrowphase3D._scratch.gjk.epaNz >
              0.0
          ? -1.0
          : 1.0;
      tnx *= flip / len;
      tny *= flip / len;
      tnz *= flip / len;
      Narrowphase3D._scratch.clip.faceB
        ..setTriangle(v0, v1, v2)
        ..nx = tnx
        ..ny = tny
        ..nz = tnz
        ..faceId = 0;
      if (_clipSupportFacesInto(
        Narrowphase3D._scratch.gjk.epaNx,
        Narrowphase3D._scratch.gjk.epaNy,
        Narrowphase3D._scratch.gjk.epaNz,
        Narrowphase3D._scratch.clip.faceA,
        Narrowphase3D._scratch.clip.faceB,
        out,
      )) {
        return;
      }
    }
  }
  out.pushSingle(
    Narrowphase3D._scratch.gjk.epaNx,
    Narrowphase3D._scratch.gjk.epaNy,
    Narrowphase3D._scratch.gjk.epaNz,
    Narrowphase3D._scratch.gjk.epaDepth,
    Narrowphase3D._scratch.gjk.epaAx,
    Narrowphase3D._scratch.gjk.epaAy,
    Narrowphase3D._scratch.gjk.epaAz,
    Narrowphase3D._scratch.gjk.epaBx,
    Narrowphase3D._scratch.gjk.epaBy,
    Narrowphase3D._scratch.gjk.epaBz,
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

  Narrowphase3D._scratch.mesh.invMesh.setFrom(meshTransform);
  if (Narrowphase3D._scratch.mesh.invMesh.invert().abs() < 1e-15) {
    return;
  }

  shape.computeWorldAabb(
    shapeTransform,
    Narrowphase3D._scratch.mesh.worldShapeBox,
  );
  Narrowphase3D._scratch.mesh.localShapeBox
    ..setFrom(Narrowphase3D._scratch.mesh.worldShapeBox)
    ..transform(Narrowphase3D._scratch.mesh.invMesh);

  if (!aabbOverlaps(Narrowphase3D._scratch.mesh.localShapeBox, surface.aabb)) {
    return;
  }

  Narrowphase3D._scratch.mesh.candidateTris.clear();
  bvhRef.queryAabb(
    Narrowphase3D._scratch.mesh.localShapeBox,
    Narrowphase3D._scratch.mesh.candidateTris,
  );
  if (Narrowphase3D._scratch.mesh.candidateTris.isEmpty) {
    return;
  }

  final positions = surface.positions;
  final indices = surface.indices;
  final m = meshTransform.storage;

  for (var i = 0; i < Narrowphase3D._scratch.mesh.candidateTris.length; i++) {
    final tri = Narrowphase3D._scratch.mesh.candidateTris[i];
    final base = tri * 3;
    final i0 = indices[base] * 3;
    final i1 = indices[base + 1] * 3;
    final i2 = indices[base + 2] * 3;

    transformPoint3D(
      m,
      positions[i0],
      positions[i0 + 1],
      positions[i0 + 2],
      Narrowphase3D._scratch.mesh.triV0,
    );
    transformPoint3D(
      m,
      positions[i1],
      positions[i1 + 1],
      positions[i1 + 2],
      Narrowphase3D._scratch.mesh.triV1,
    );
    transformPoint3D(
      m,
      positions[i2],
      positions[i2 + 1],
      positions[i2 + 2],
      Narrowphase3D._scratch.mesh.triV2,
    );

    _intersectShapeWithTriangleInto(
      shape,
      shapeTransform,
      Narrowphase3D._scratch.mesh.triV0,
      Narrowphase3D._scratch.mesh.triV1,
      Narrowphase3D._scratch.mesh.triV2,
      out,
    );
  }
}
