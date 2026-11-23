part of 'collision_manifold_3d.dart';

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

/// Intersects [shape] (under [shapeTransform]) against all triangles of
/// [surface] (under [meshTransform]) overlapping [shape]'s local AABB in
/// `surface.bvh`, returning the deepest [CollisionManifold3D] (oriented from
/// [shape] toward [surface]) or `null` when separated.
CollisionManifold3D? _npIntersectShapeWithSurfaceBvh(
  Shape3D shape,
  Matrix4 shapeTransform,
  Surface surface,
  Matrix4 meshTransform,
) {
  final all = Narrowphase3D.intersectShapeWithSurfaceBvhAll(
    shape,
    shapeTransform,
    surface,
    meshTransform,
  );
  if (all.isEmpty) {
    return null;
  }
  var best = all[0];
  for (var i = 1; i < all.length; i++) {
    if (all[i].penetrationDepth > best.penetrationDepth) {
      best = all[i];
    }
  }
  return best;
}

/// Returns every triangle [CollisionManifold3D] where [shape] (under
/// [shapeTransform]) overlaps [surface] (under [meshTransform]).
List<CollisionManifold3D> _npIntersectShapeWithSurfaceBvhAll(
  Shape3D shape,
  Matrix4 shapeTransform,
  Surface surface,
  Matrix4 meshTransform,
) {
  final results = <CollisionManifold3D>[];
  if (surface.indexCount < 3) {
    return results;
  }
  // Ensure `surface.bvh` is built and look up our companion AABB index keyed
  // on the live `SurfaceBvh` instance (automatically invalidated whenever
  // `surface.updateVertices` rebuilds `surface.bvh`).
  final bvhRef = surface.bvh;
  if (bvhRef.triangleCount == 0) {
    return results;
  }

  _invMesh.setFrom(meshTransform);
  if (_invMesh.invert().abs() < 1e-15) {
    return results;
  }

  shape.computeWorldAabb(shapeTransform, _worldShapeBox);
  _localShapeBox
    ..setFrom(_worldShapeBox)
    ..transform(_invMesh);

  if (!aabbOverlaps(_localShapeBox, surface.aabb)) {
    return results;
  }

  _candidateTris.clear();
  bvhRef.queryAabb(_localShapeBox, _candidateTris);
  if (_candidateTris.isEmpty) {
    return results;
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

    final manifold = Narrowphase3D.intersectShapeWithTriangle(
      shape,
      shapeTransform,
      _triV0,
      _triV1,
      _triV2,
    );
    if (manifold != null) {
      results.add(manifold);
    }
  }
  return results;
}

/// Intersects [shape] (under [shapeTransform]) against a
/// [HeightfieldShape3D] (under [heightfieldTransform]) using direct `O(1)`
/// grid-cell clamping, returning the merged deepest [CollisionManifold3D]
/// oriented from [shape] toward [heightfield], or `null` when separated.
CollisionManifold3D? _npHeightfieldShape(
  Shape3D shape,
  Matrix4 shapeTransform,
  HeightfieldShape3D heightfield,
  Matrix4 heightfieldTransform,
) {
  return _pickDeepestMerged(
    Narrowphase3D.heightfieldShapeAll(
      shape,
      shapeTransform,
      heightfield,
      heightfieldTransform,
    ),
  );
}

/// Returns all triangle contact manifolds where [shape] (under
/// [shapeTransform]) overlaps [heightfield] (under [heightfieldTransform]).
List<CollisionManifold3D> _npHeightfieldShapeAll(
  Shape3D shape,
  Matrix4 shapeTransform,
  HeightfieldShape3D heightfield,
  Matrix4 heightfieldTransform,
) {
  if (shape is HeightfieldShape3D) {
    return const [];
  }
  if (shape is CompoundShape3D) {
    return _testCompoundVsShapeAll(
      shape,
      shapeTransform,
      heightfield,
      heightfieldTransform,
    );
  }

  final invHf = Matrix4.copy(heightfieldTransform);
  if (invHf.invert().abs() < 1e-15) {
    return const [];
  }

  final worldBox = Aabb3();
  shape.computeWorldAabb(shapeTransform, worldBox);
  final localBox = Aabb3()
    ..setFrom(worldBox)
    ..transform(invHf);

  if (localBox.max.y < heightfield.minHeight - 1e-4 ||
      localBox.min.y > heightfield.maxHeight + 1e-4) {
    return const [];
  }

  final range = heightfield.cellRangeForLocalBounds(
    localBox.min.x,
    localBox.max.x,
    localBox.min.z,
    localBox.max.z,
  );
  if (range == null) {
    return const [];
  }

  final (c0, c1, r0, r1) = range;
  final m = heightfieldTransform.storage;
  // Heightfield world +Y axis for one-sided ground orientation check.
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

  final lv00 = Vector3.zero();
  final lv01 = Vector3.zero();
  final lv11 = Vector3.zero();
  final lv10 = Vector3.zero();
  final wv00 = Vector3.zero();
  final wv01 = Vector3.zero();
  final wv11 = Vector3.zero();
  final wv10 = Vector3.zero();
  final results = <CollisionManifold3D>[];

  for (var r = r0; r <= r1; r++) {
    for (var c = c0; c <= c1; c++) {
      heightfield.writeCellVerticesLocal(c, r, lv00, lv01, lv11, lv10);
      final cellMinY = math.min(
        math.min(lv00.y, lv01.y),
        math.min(lv11.y, lv10.y),
      );
      final cellMaxY = math.max(
        math.max(lv00.y, lv01.y),
        math.max(lv11.y, lv10.y),
      );
      if (localBox.max.y < cellMinY - 1e-4 ||
          localBox.min.y > cellMaxY + 1e-4) {
        continue;
      }

      transformPoint3D(m, lv00.x, lv00.y, lv00.z, wv00);
      transformPoint3D(m, lv01.x, lv01.y, lv01.z, wv01);
      transformPoint3D(m, lv11.x, lv11.y, lv11.z, wv11);
      transformPoint3D(m, lv10.x, lv10.y, lv10.z, wv10);

      final m0 = Narrowphase3D.intersectShapeWithTriangle(
        shape,
        shapeTransform,
        wv00,
        wv01,
        wv11,
      );
      if (m0 != null) {
        results.add(
          _orientHeightfieldManifold(
            m0,
            wv00,
            wv01,
            wv11,
            hfUpX,
            hfUpY,
            hfUpZ,
          ),
        );
      }

      final m1 = Narrowphase3D.intersectShapeWithTriangle(
        shape,
        shapeTransform,
        wv00,
        wv11,
        wv10,
      );
      if (m1 != null) {
        results.add(
          _orientHeightfieldManifold(
            m1,
            wv00,
            wv11,
            wv10,
            hfUpX,
            hfUpY,
            hfUpZ,
          ),
        );
      }
    }
  }
  return results;
}

CollisionManifold3D _orientHeightfieldManifold(
  CollisionManifold3D m,
  Vector3 v0,
  Vector3 v1,
  Vector3 v2,
  double hfUpX,
  double hfUpY,
  double hfUpZ,
) {
  // `m.normal` points from `shape` (above) toward `heightfield` (below), so
  // `m.normal . hfUp` should be `<= 0`. If `shape`'s center slightly crossed
  // the triangle plane, flip along `-triOutwardNormal` so solid ground always
  // pushes shapes upward.
  final dotUp = m.normal.x * hfUpX + m.normal.y * hfUpY + m.normal.z * hfUpZ;
  if (dotUp <= 1e-5) {
    return m;
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
  return CollisionManifold3D(
    normal: Vector3(nx, ny, nz),
    penetrationDepth: m.penetrationDepth,
    contactPointA: m.contactPointA,
    contactPointB: m.contactPointB,
  );
}

List<CollisionManifold3D> _testCompoundVsShapeAll(
  CompoundShape3D compoundA,
  Matrix4 transformA,
  Shape3D shapeB,
  Matrix4 transformB,
) {
  final boxB = Aabb3();
  shapeB.computeWorldAabb(transformB, boxB);
  final childMat = Matrix4.identity();
  final childBox = Aabb3();
  final results = <CollisionManifold3D>[];

  for (var i = 0; i < compoundA.children.length; i++) {
    final child = compoundA.children[i];
    childMat
      ..setFrom(transformA)
      ..multiply(child.localTransform);
    child.shape.computeWorldAabb(childMat, childBox);
    if (!aabbOverlaps(childBox, boxB)) {
      continue;
    }
    final sub = Narrowphase3D.testAll(
      child.shape,
      childMat,
      shapeB,
      transformB,
    );
    if (sub.isNotEmpty) {
      results.addAll(sub);
    }
  }
  return results;
}

CollisionManifold3D? _pickDeepestMerged(
  List<CollisionManifold3D> manifolds,
) {
  if (manifolds.isEmpty) {
    return null;
  }
  if (manifolds.length == 1) {
    return manifolds.first;
  }
  final merged = _mergeCoDirectionalManifolds(manifolds);
  var best = merged[0];
  for (var i = 1; i < merged.length; i++) {
    if (merged[i].penetrationDepth > best.penetrationDepth) {
      best = merged[i];
    }
  }
  return best;
}

List<CollisionManifold3D> _mergeCoDirectionalManifolds(
  List<CollisionManifold3D> manifolds,
) {
  if (manifolds.length <= 1) {
    return manifolds;
  }
  final groups = <List<CollisionManifold3D>>[];
  for (var i = 0; i < manifolds.length; i++) {
    final m = manifolds[i];
    var placed = false;
    for (var g = 0; g < groups.length; g++) {
      if (groups[g].first.normal.dot(m.normal) >= 0.992) {
        groups[g].add(m);
        placed = true;
        break;
      }
    }
    if (!placed) {
      groups.add([m]);
    }
  }

  final out = <CollisionManifold3D>[];
  for (final group in groups) {
    if (group.length == 1) {
      out.add(group.first);
      continue;
    }
    var deepest = group[0];
    final allContacts = <ContactPoint3D>[];
    for (final m in group) {
      if (m.penetrationDepth > deepest.penetrationDepth) {
        deepest = m;
      }
      for (final cp in m.contacts) {
        var dup = false;
        for (final existing in allContacts) {
          if (existing.pointA.distanceToSquared(cp.pointA) < 1e-6 &&
              existing.pointB.distanceToSquared(cp.pointB) < 1e-6) {
            dup = true;
            break;
          }
        }
        if (!dup) {
          allContacts.add(cp);
        }
      }
    }
    final reduced = allContacts.length <= 4
        ? allContacts
        : _reduceContactsToFour(
            allContacts,
            deepest.normal.x,
            deepest.normal.y,
            deepest.normal.z,
          );
    out.add(
      CollisionManifold3D(
        normal: deepest.normal,
        penetrationDepth: deepest.penetrationDepth,
        contactPointA: deepest.contactPointA,
        contactPointB: deepest.contactPointB,
        contacts: reduced,
      ),
    );
  }
  return out;
}

/// Intersects [shape] (under [shapeTransform]) against a single world-space
/// triangle `(v0, v1, v2)`, returning a [CollisionManifold3D] oriented from
/// [shape] toward the triangle, or `null` when separated.
CollisionManifold3D? _npIntersectShapeWithTriangle(
  Shape3D shape,
  Matrix4 shapeTransform,
  Vector3 v0,
  Vector3 v1,
  Vector3 v2,
) {
  if (shape is CompoundShape3D) {
    final childMat = Matrix4.identity();
    CollisionManifold3D? best;
    for (var i = 0; i < shape.children.length; i++) {
      final child = shape.children[i];
      childMat
        ..setFrom(shapeTransform)
        ..multiply(child.localTransform);
      final hit = Narrowphase3D.intersectShapeWithTriangle(
        child.shape,
        childMat,
        v0,
        v1,
        v2,
      );
      if (hit != null &&
          (best == null || hit.penetrationDepth > best.penetrationDepth)) {
        best = hit;
      }
    }
    return best;
  }
  if (shape is SphereShape3D) {
    final m = shapeTransform.storage;
    final cx = m[12];
    final cy = m[13];
    final cz = m[14];
    final r = shape.worldRadius(shapeTransform);
    closestPointOnTriangle3D(cx, cy, cz, v0, v1, v2, _ptB);
    return _sphereTrianglePoints(cx, cy, cz, r, _ptB, v0, v1, v2);
  }
  if (shape is CapsuleShape3D) {
    final r = shape.worldSpine(shapeTransform, _segA0, _segA1);
    _closestPointsSegmentTriangle(_segA0, _segA1, v0, v1, v2, _ptA, _ptB);
    return _sphereTrianglePoints(
      _ptA.x,
      _ptA.y,
      _ptA.z,
      r,
      _ptB,
      v0,
      v1,
      v2,
    );
  }

  _triCentroid.setValues(
    (v0.x + v1.x + v2.x) * (1.0 / 3.0),
    (v0.y + v1.y + v2.y) * (1.0 / 3.0),
    (v0.z + v1.z + v2.z) * (1.0 / 3.0),
  );
  final epa = _gjkEpa(
    (dir, out) => shape.supportPoint(dir, shapeTransform, out),
    (dir, out) => triangleSupport3D(v0, v1, v2, dir, out),
    centerOfMatrix3D(shapeTransform, _cAScratch),
    _triCentroid,
  );
  if (epa == null) {
    return null;
  }
  // A box or hull face lying on the triangle touches it at several points.
  final n = epa.normal;
  if (_writeSupportFace(shape, shapeTransform, n.x, n.y, n.z, _faceA)) {
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
      // The triangle's face toward the shape (against the A-to-B normal).
      final flip = tnx * n.x + tny * n.y + tnz * n.z > 0.0 ? -1.0 : 1.0;
      tnx *= flip / len;
      tny *= flip / len;
      tnz *= flip / len;
      _faceB
        ..setTriangle(v0, v1, v2)
        ..nx = tnx
        ..ny = tny
        ..nz = tnz
        ..faceId = 0;
      final faced = _clipSupportFaces(n.x, n.y, n.z, _faceA, _faceB);
      if (faced != null) {
        return faced;
      }
    }
  }
  return epa;
}

CollisionManifold3D? _sphereTrianglePoints(
  double cx,
  double cy,
  double cz,
  double r,
  Vector3 closestOnTri,
  Vector3 v0,
  Vector3 v1,
  Vector3 v2,
) {
  final dx = closestOnTri.x - cx;
  final dy = closestOnTri.y - cy;
  final dz = closestOnTri.z - cz;
  final dist2 = dx * dx + dy * dy + dz * dz;
  if (dist2 > r * r) {
    return null;
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
    // Sphere center lies directly on the triangle: orient along -triNormal.
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
  return CollisionManifold3D(
    normal: Vector3(nx, ny, nz),
    penetrationDepth: r - dist,
    contactPointA: Vector3(cx + nx * r, cy + ny * r, cz + nz * r),
    contactPointB: closestOnTri,
  );
}
