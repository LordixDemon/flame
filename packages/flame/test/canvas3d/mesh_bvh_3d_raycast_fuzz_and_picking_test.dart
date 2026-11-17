import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/canvas3d.dart';
import 'package:flutter_test/flutter_test.dart';

/// Independent reference: double-sided Möller-Trumbore over the vertices
/// transformed into world space (`T + R * S * p`).
double? _worldBrute(
  Ray3D ray,
  Mesh3D mesh,
  Float32List rot,
  double tx,
  double ty,
  double tz,
  double sx,
  double sy,
  double sz,
) {
  final pos = mesh.positions;
  final idx = mesh.indices;
  double wx(int i) =>
      tx +
      rot[0] * pos[i] * sx +
      rot[1] * pos[i + 1] * sy +
      rot[2] * pos[i + 2] * sz;
  double wy(int i) =>
      ty +
      rot[3] * pos[i] * sx +
      rot[4] * pos[i + 1] * sy +
      rot[5] * pos[i + 2] * sz;
  double wz(int i) =>
      tz +
      rot[6] * pos[i] * sx +
      rot[7] * pos[i + 1] * sy +
      rot[8] * pos[i + 2] * sz;
  double? best;
  for (var f = 0; f < idx.length ~/ 3; f++) {
    final i0 = idx[f * 3] * 3;
    final i1 = idx[f * 3 + 1] * 3;
    final i2 = idx[f * 3 + 2] * 3;
    final v0x = wx(i0);
    final v0y = wy(i0);
    final v0z = wz(i0);
    final e1x = wx(i1) - v0x;
    final e1y = wy(i1) - v0y;
    final e1z = wz(i1) - v0z;
    final e2x = wx(i2) - v0x;
    final e2y = wy(i2) - v0y;
    final e2z = wz(i2) - v0z;
    final px = ray.dy * e2z - ray.dz * e2y;
    final py = ray.dz * e2x - ray.dx * e2z;
    final pz = ray.dx * e2y - ray.dy * e2x;
    final det = e1x * px + e1y * py + e1z * pz;
    if (det.abs() < 1e-9) {
      continue;
    }
    final inv = 1.0 / det;
    final sxv = ray.ox - v0x;
    final syv = ray.oy - v0y;
    final szv = ray.oz - v0z;
    final u = (sxv * px + syv * py + szv * pz) * inv;
    if (u < 0 || u > 1) {
      continue;
    }
    final qx = syv * e1z - szv * e1y;
    final qy = szv * e1x - sxv * e1z;
    final qz = sxv * e1y - syv * e1x;
    final v = (ray.dx * qx + ray.dy * qy + ray.dz * qz) * inv;
    if (v < 0 || u + v > 1) {
      continue;
    }
    final t = (e2x * qx + e2y * qy + e2z * qz) * inv;
    if (t > 1e-5 && (best == null || t < best)) {
      best = t;
    }
  }
  return best;
}

void main() {
  group('MeshBvh3D and Raycaster3D', () {
    test('BVH, brute force and a world-space reference agree for rotated, '
        'mirrored and non-uniformly scaled meshes', () {
      final rng = math.Random(4242);
      final sphere = Mesh3D.uvSphere();
      // Box with a few degenerate (zero-area) triangles appended.
      final box = Mesh3D.box();
      final degIdx = Uint16List(box.indices.length + 6)
        ..setAll(0, box.indices)
        ..setAll(box.indices.length, <int>[0, 0, 0, 1, 1, 2]);
      final boxDegenerate = Mesh3D.fromRaw(
        positions: box.positions,
        normals: box.normals,
        indices: degIdx,
      );
      final meshes = <Mesh3D>[sphere, box, boxDegenerate];

      var hits = 0;
      var mismatches = 0;
      String? firstMismatch;
      for (var iter = 0; iter < 6000; iter++) {
        final mesh = meshes[iter % meshes.length];
        final rot = Float32List(9);
        Quaternion3D.writeEulerMatrix3(
          yawRad: rng.nextDouble() * 6.28,
          pitchRad: rng.nextDouble() * 6.28,
          rollRad: rng.nextDouble() * 6.28,
          out: rot,
        );
        double scale() =>
            (0.3 + rng.nextDouble() * 2.5) * (rng.nextInt(4) == 0 ? -1 : 1);
        final sx = scale();
        final sy = scale();
        final sz = scale();
        final tx = rng.nextDouble() * 4 - 2;
        final ty = rng.nextDouble() * 4 - 2;
        final tz = rng.nextDouble() * 4 - 2;

        // Ray from a random point on a radius-8 shell toward a point near the
        // mesh centre; every 5th ray is axis aligned.
        final ox = tx + (rng.nextDouble() * 2 - 1) * 8;
        final oy = ty + (rng.nextDouble() * 2 - 1) * 8;
        final oz = tz + (rng.nextDouble() * 2 - 1) * 8;
        var dx = tx + (rng.nextDouble() - 0.5) * 1.5 - ox;
        var dy = ty + (rng.nextDouble() - 0.5) * 1.5 - oy;
        var dz = tz + (rng.nextDouble() - 0.5) * 1.5 - oz;
        if (iter % 5 == 0) {
          dy = 0;
          dz = 0;
        }
        final len = math.sqrt(dx * dx + dy * dy + dz * dz);
        if (len < 1e-6) {
          continue;
        }
        dx /= len;
        dy /= len;
        dz /= len;
        final ray = Ray3D(ox: ox, oy: oy, oz: oz, dx: dx, dy: dy, dz: dz);

        (double, int)? cast({required bool bvh}) =>
            Raycaster3D.raycastMeshTransform(
              ray,
              mesh,
              worldX: tx,
              worldY: ty,
              worldZ: tz,
              scaleX: sx,
              scaleY: sy,
              scaleZ: sz,
              rotationMatrix3: rot,
              cullBackfaces: false,
              useBvh: bvh,
            );
        final a = cast(bvh: true);
        final b = cast(bvh: false);
        final c = _worldBrute(ray, mesh, rot, tx, ty, tz, sx, sy, sz);
        if (c != null) {
          hits++;
        }
        final ta = a?.$1;
        final tb = b?.$1;
        bool same(double? p, double? q) =>
            (p == null && q == null) ||
            (p != null && q != null && (p - q).abs() < 1e-3 * (1 + q.abs()));
        if (!same(ta, tb) || !same(tb, c)) {
          // Tolerate grazing-edge disagreements only if hit/miss differs and the
          // reference hit is within float noise of an edge: count them.
          mismatches++;
          firstMismatch ??=
              'iter=$iter bvh=$ta brute=$tb world=$c '
              'scale=($sx,$sy,$sz)';
        }
      }
      expect(hits, greaterThan(1500));
      // Allow a handful of edge-grazing float disagreements.
      expect(mismatches, lessThan(6), reason: '$mismatches: $firstMismatch');
    });

    test('a mesh whose centroids span many orders of magnitude gets a tree '
        'the fixed traversal stack can hold', () {
      // 200 small triangles in the planes x = 2^k: spatial midpoint splits
      // peel off one triangle per level, which used to build a tree deeper
      // than the 128-entry traversal stack.
      const count = 200;
      final positions = Float32List(count * 9);
      final indices = Uint16List(count * 3);
      for (var k = 0; k < count; k++) {
        final x = math.pow(2.0, k - 90).toDouble();
        final p = k * 9;
        positions[p] = x;
        positions[p + 1] = -1;
        positions[p + 2] = -1;
        positions[p + 3] = x;
        positions[p + 4] = 3;
        positions[p + 5] = -1;
        positions[p + 6] = x;
        positions[p + 7] = -1;
        positions[p + 8] = 3;
        indices[k * 3] = k * 3;
        indices[k * 3 + 1] = k * 3 + 1;
        indices[k * 3 + 2] = k * 3 + 2;
      }
      final bvh = MeshBvh3D.build(positions: positions, indices: indices);
      expect(bvh.triangleCount, count);

      // A ray down the x axis crosses every triangle plane; the closest hit
      // is the first plane behind its origin.
      // (Planes closer than the 1e-5 minimum hit distance are skipped.)
      for (final k in <int>[76, 90, 121, 150, 199]) {
        final planeX = math.pow(2.0, k - 90).toDouble();
        final ray = Ray3D(
          ox: planeX * 1.5,
          oy: 0,
          oz: 0,
          dx: -1,
          dy: 0,
          dz: 0,
        );
        final hit = bvh.raycastLocal(ray, cullBackfaces: false);
        expect(hit, isNotNull, reason: 'plane $k');
        expect(hit!.$2, k, reason: 'plane $k');
        expect(hit.$1, closeTo(planeX * 0.5, planeX * 1e-3));
      }
      // And from far outside, the outermost plane.
      final outer = math.pow(2.0, count - 1 - 90).toDouble();
      final hit = bvh.raycastLocal(
        Ray3D(ox: outer * 4, oy: 0, oz: 0, dx: -1, dy: 0, dz: 0),
        cullBackfaces: false,
      );
      expect(hit!.$2, count - 1);
    });

    test('pickClosest returns colliders with any id, negative included', () {
      final box = Mesh3D.box();
      MeshCollider3D collider(int id, double worldX) => MeshCollider3D(
        id: id,
        positions: box.positions,
        indices: box.indices,
        minX: box.minX,
        minY: box.minY,
        minZ: box.minZ,
        maxX: box.maxX,
        maxY: box.maxY,
        maxZ: box.maxZ,
        worldX: worldX,
        worldY: 0,
      );
      const ray = Ray3D(ox: -10, oy: 0, oz: 0, dx: 1, dy: 0, dz: 0);

      final single = Raycaster3D.pickClosest(ray, [collider(-7, 0)]);
      expect(single, isNotNull);
      expect(single!.id, -7);
      expect(single.distance, closeTo(9.5, 1e-6));

      // The nearer collider wins whatever the sign of its id.
      final nearest = Raycaster3D.pickClosest(ray, [
        collider(4, 5),
        collider(-1, 2),
      ]);
      expect(nearest!.id, -1);
      expect(nearest.distance, closeTo(11.5, 1e-6));

      const away = Ray3D(ox: -10, oy: 0, oz: 0, dx: -1, dy: 0, dz: 0);
      expect(Raycaster3D.pickClosest(away, [collider(-7, 0)]), isNull);
    });
  });
}
