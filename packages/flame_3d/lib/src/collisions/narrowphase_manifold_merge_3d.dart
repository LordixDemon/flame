part of 'collision_manifold_3d.dart';

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
  Narrowphase3D._scratch.merge.ensureGroupCap(count);

  var groupCount = 0;
  for (var i = 0; i < count; i++) {
    final nx = src.normalX(i);
    final ny = src.normalY(i);
    final nz = src.normalZ(i);
    var placed = -1;
    for (var g = 0; g < groupCount; g++) {
      final rep = Narrowphase3D._scratch.merge.repManifold[g];
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
      Narrowphase3D._scratch.merge.repManifold[placed] = i;
      Narrowphase3D._scratch.merge.groupHead[placed] = i;
      Narrowphase3D._scratch.merge.groupDeepest[placed] = i;
      Narrowphase3D._scratch.merge.manifoldNext[i] = -1;
      Narrowphase3D._scratch.merge.manifoldGroup[i] = placed;
    } else {
      // Link into group (append order not critical; keep track of deepest).
      Narrowphase3D._scratch.merge.manifoldGroup[i] = placed;
      Narrowphase3D._scratch.merge.manifoldNext[i] =
          Narrowphase3D._scratch.merge.groupHead[placed];
      Narrowphase3D._scratch.merge.groupHead[placed] = i;
      if (src.depth(i) >
          src.depth(Narrowphase3D._scratch.merge.groupDeepest[placed])) {
        Narrowphase3D._scratch.merge.groupDeepest[placed] = i;
      }
    }
  }

  for (var g = 0; g < groupCount; g++) {
    final rep = Narrowphase3D._scratch.merge.repManifold[g];
    if (Narrowphase3D._scratch.merge.manifoldNext[rep] == -1 &&
        Narrowphase3D._scratch.merge.groupHead[g] == rep) {
      dst.copyManifoldFrom(src, rep);
      continue;
    }

    final deepest = Narrowphase3D._scratch.merge.groupDeepest[g];
    final dnx = src.normalX(deepest);
    final dny = src.normalY(deepest);
    final dnz = src.normalZ(deepest);
    var uniqueCount = 0;

    for (var i = 0; i < count; i++) {
      if (Narrowphase3D._scratch.merge.manifoldGroup[i] != g) {
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
          final ei = Narrowphase3D._scratch.merge.contactIdx[e];
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
          Narrowphase3D._scratch.merge.ensureContactCap(uniqueCount + 1);
          Narrowphase3D._scratch.merge.contactIdx[uniqueCount++] = ci;
        }
      }
    }

    final outM = dst.beginManifold(dnx, dny, dnz, src.depth(deepest));
    if (uniqueCount <= 4) {
      for (var u = 0; u < uniqueCount; u++) {
        final ci = Narrowphase3D._scratch.merge.contactIdx[u];
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
      if (src.pointDepth(Narrowphase3D._scratch.merge.contactIdx[i]) >
          src.pointDepth(Narrowphase3D._scratch.merge.contactIdx[i0])) {
        i0 = i;
      }
    }
    final c0 = Narrowphase3D._scratch.merge.contactIdx[i0];
    final p0x = src.pointAX(c0);
    final p0y = src.pointAY(c0);
    final p0z = src.pointAZ(c0);

    var i1 = 0;
    var bestD2 = -1.0;
    for (var i = 0; i < uniqueCount; i++) {
      final ci = Narrowphase3D._scratch.merge.contactIdx[i];
      final dx = src.pointAX(ci) - p0x;
      final dy = src.pointAY(ci) - p0y;
      final dz = src.pointAZ(ci) - p0z;
      final d2 = dx * dx + dy * dy + dz * dz;
      if (d2 > bestD2) {
        bestD2 = d2;
        i1 = i;
      }
    }
    final c1 = Narrowphase3D._scratch.merge.contactIdx[i1];
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
      final ci = Narrowphase3D._scratch.merge.contactIdx[i];
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
    final c2 = Narrowphase3D._scratch.merge.contactIdx[i2];
    final p2x = src.pointAX(c2);
    final p2y = src.pointAY(c2);
    final p2z = src.pointAZ(c2);

    var i3 = 0;
    var bestFourth = -1.0;
    for (var i = 0; i < uniqueCount; i++) {
      if (i == i0 || i == i1 || i == i2) {
        continue;
      }
      final ci = Narrowphase3D._scratch.merge.contactIdx[i];
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
      final c3 = Narrowphase3D._scratch.merge.contactIdx[i3];
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
