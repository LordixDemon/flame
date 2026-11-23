import 'dart:convert' show ascii;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/core/crc32.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  group('geometry_math helpers', () {
    test('determinant3x3, isMirrored3x3, and uniformScale3x3 handle rotation, '
        'scale, and reflection matrices', () {
      final rotY = Matrix4.rotationY(math.pi / 2);
      expect(determinant3x3(rotY.storage), closeTo(1.0, 1e-6));
      expect(isMirrored3x3(rotY.storage), isFalse);
      expect(uniformScale3x3(rotY.storage), closeTo(1.0, 1e-6));

      final scaled = Matrix4.diagonal3Values(2, 2, 2);
      expect(determinant3x3(scaled.storage), closeTo(8.0, 1e-6));
      expect(uniformScale3x3(scaled.storage), closeTo(2.0, 1e-6));
      expect(isMirrored3x3(scaled.storage), isFalse);

      final mirrored = Matrix4.diagonal3Values(-1, 2, 3);
      expect(determinant3x3(mirrored.storage), closeTo(-6.0, 1e-6));
      expect(isMirrored3x3(mirrored.storage), isTrue);
      expect(
        uniformScale3x3(mirrored.storage),
        closeTo(math.pow(6.0, 1.0 / 3.0).toDouble(), 1e-6),
      );
    });

    test('transformAabbArvo and expandAabbByTransformedInstances compute tight '
        'transformed bounds', () {
      final rotY = Matrix4.rotationY(math.pi / 2)..setTranslationRaw(5, 2, -3);
      final out = Aabb3();
      transformAabbArvo(rotY.storage, 0, 1, 0, 0, 1, 2, 3, out);
      expect(out.min.x, closeTo(5 - 3, 1e-5));
      expect(out.max.x, closeTo(5 + 3, 1e-5));
      expect(out.min.y, closeTo(2 - 2, 1e-5));
      expect(out.max.y, closeTo(2 + 2, 1e-5));
      expect(out.min.z, closeTo(-3 - 1 - 1, 1e-5));
      expect(out.max.z, closeTo(-3 - 1 + 1, 1e-5));

      final localBox = Aabb3.minMax(Vector3(-1, -1, -1), Vector3(1, 1, 1));
      final buf = Float32List(VertexLayout.instanceStrideInFloats * 2);
      final m0 = Matrix4.translationValues(10, 0, 0);
      final m1 = Matrix4.translationValues(-4, 6, 3);
      buf.setRange(0, 16, m0.storage);
      buf.setRange(
        VertexLayout.instanceStrideInFloats,
        VertexLayout.instanceStrideInFloats + 16,
        m1.storage,
      );
      final union = Aabb3();
      final changed = expandAabbByTransformedInstances(
        buf,
        2,
        VertexLayout.instanceStrideInFloats,
        localBox,
        union,
      );
      expect(changed, isTrue);
      expect(union.min.x, closeTo(-5, 1e-5));
      expect(union.max.x, closeTo(11, 1e-5));
      expect(union.min.y, closeTo(-1, 1e-5));
      expect(union.max.y, closeTo(7, 1e-5));
      expect(union.max.z, closeTo(4, 1e-5));
    });

    test('aabbOverlaps and rayHitsAabb match analytical expectations', () {
      final a = Aabb3.minMax(Vector3(0, 0, 0), Vector3(2, 2, 2));
      final b = Aabb3.minMax(Vector3(2, 1, 1), Vector3(4, 3, 3));
      final c = Aabb3.minMax(Vector3(2.1, 1, 1), Vector3(4, 3, 3));
      expect(aabbOverlaps(a, b), isTrue);
      expect(aabbOverlaps(a, c), isFalse);

      final hitRay = Ray.originDirection(Vector3(-3, 1, 1), Vector3(1, 0, 0));
      expect(rayHitsAabb(hitRay, a, 10), isTrue);
      expect(rayHitsAabb(hitRay, a, 2.5), isFalse);
      final missRay = Ray.originDirection(Vector3(-3, 5, 1), Vector3(1, 0, 0));
      expect(rayHitsAabb(missRay, a, 20), isFalse);
    });

    test('rotateVectorByQuat/unrotateVectorByQuat, bases, inverse, closest '
        'triangle point, and IEEE CRC-32', () {
      final q = Quaternion.axisAngle(
        Vector3(1, 2, -1)..normalize(),
        1.1,
      );
      final v = Vector3(3.5, -1.25, 4.0);
      final rotated = Vector3.zero();
      final unrotated = Vector3.zero();
      rotateVectorByQuat(q, v, rotated);
      unrotateVectorByQuat(q, rotated, unrotated);
      expect(unrotated.distanceTo(v), lessThan(1e-6));

      final n = Vector3(0.3, 0.8, -0.5)..normalize();
      final t1 = Vector3.zero();
      final t2 = Vector3.zero();
      buildOrthonormalBasis3D(n, t1, t2);
      expect(t1.length, closeTo(1.0, 1e-6));
      expect(t2.length, closeTo(1.0, 1e-6));
      expect(n.dot(t1).abs(), lessThan(1e-6));
      expect(n.dot(t2).abs(), lessThan(1e-6));
      expect(t1.dot(t2).abs(), lessThan(1e-6));

      final up = Vector3(0, 1, 0);
      final u = Vector3.zero();
      final w = Vector3.zero();
      buildUpTangentBasis3D(up, u, w);
      expect(u.length, closeTo(1.0, 1e-6));
      expect(w.length, closeTo(1.0, 1e-6));
      expect(up.dot(u).abs(), lessThan(1e-6));
      expect(up.dot(w).abs(), lessThan(1e-6));

      final sym = Matrix3(4, 1, 0, 1, 3, 1, 0, 1, 2);
      final inv = Matrix3.zero();
      expect(invertSymmetric3D(sym, inv), isTrue);
      final prod = sym.multiplied(inv);
      expect(prod.entry(0, 0), closeTo(1.0, 1e-6));
      expect(prod.entry(1, 1), closeTo(1.0, 1e-6));
      expect(prod.entry(2, 2), closeTo(1.0, 1e-6));
      expect(prod.entry(0, 1).abs(), lessThan(1e-6));

      final triClosest = Vector3.zero();
      closestPointOnTriangle3D(
        0.5,
        2.0,
        0.5,
        Vector3(0, 0, 0),
        Vector3(2, 0, 0),
        Vector3(0, 0, 2),
        triClosest,
      );
      expect(triClosest.x, closeTo(0.5, 1e-6));
      expect(triClosest.y, closeTo(0.0, 1e-6));
      expect(triClosest.z, closeTo(0.5, 1e-6));

      final checkBytes = Uint8List.fromList(ascii.encode('123456789'));
      expect(computeCrc32Bytes(checkBytes), equals(0xCBF43926));
    });
  });

  group('StaticMeshBatcher3D 90-degree Y-rotation invariants', () {
    setUp(FakeGpuBackend.new);

    test('preserves positive 3x3 determinant, outward winding, and rotated '
        'face normals', () {
      final rotY90 = Matrix4.rotationY(math.pi / 2);
      expect(determinant3x3(rotY90.storage), closeTo(1.0, 1e-6));
      expect(isMirrored3x3(rotY90.storage), isFalse);

      final material = UnlitMaterial()
        ..renderState = const RenderState(cullMode: CullMode.backFace);
      final cube = CuboidMesh(size: Vector3(2, 1, 4), material: material);
      final batcher = StaticMeshBatcher3D()
        ..addStaticInstance(mesh: cube, transform: rotY90);
      batcher.bakeDirtyChunks();

      // Local +Z extents ([-2, +2]) rotate onto +X ([-2, +2]); local +X
      // ([-1, +1]) rotates onto -Z ([-1, +1]).
      final hitPlusX = batcher.raycast(
        Ray.originDirection(Vector3(6, 0, 0), Vector3(-1, 0, 0)),
      );
      expect(hitPlusX, isNotNull);
      expect(hitPlusX!.worldPoint.x, closeTo(2.0, 1e-4));
      expect(hitPlusX.worldNormal.x, closeTo(1.0, 1e-4));
      expect(hitPlusX.worldNormal.y.abs(), lessThan(1e-4));
      expect(hitPlusX.worldNormal.z.abs(), lessThan(1e-4));

      final hitMinusZ = batcher.raycast(
        Ray.originDirection(Vector3(0, 0, -6), Vector3(0, 0, 1)),
      );
      expect(hitMinusZ, isNotNull);
      expect(hitMinusZ!.worldPoint.z, closeTo(-1.0, 1e-4));
      expect(hitMinusZ.worldNormal.z, closeTo(-1.0, 1e-4));
    });
  });

  group('SurfaceBvh.queryAabb parity and reentrancy', () {
    setUp(FakeGpuBackend.new);

    test('matches brute-force triangle bounds and supports nested/reentrant '
        'queries', () {
      final sphere = SphereMesh(radius: 1.5, material: UnlitMaterial());
      final surface = sphere.surfaces.single;
      final bvh = surface.bvh;
      final triCount = surface.indexCount ~/ 3;

      final posOffset = surface.layout.offsetOf(
        VertexLayout.positionAttribute,
      )!;
      final stride = surface.layout.strideInFloats;
      final verts = surface.vertexData;
      final indices = surface.indices;

      List<int> bruteForce(Aabb3 box) {
        final hits = <int>[];
        for (var t = 0; t < triCount; t++) {
          final b = t * 3;
          final i0 = indices[b] * stride + posOffset;
          final i1 = indices[b + 1] * stride + posOffset;
          final i2 = indices[b + 2] * stride + posOffset;
          final minX = math.min(verts[i0], math.min(verts[i1], verts[i2]));
          final minY = math.min(
            verts[i0 + 1],
            math.min(verts[i1 + 1], verts[i2 + 1]),
          );
          final minZ = math.min(
            verts[i0 + 2],
            math.min(verts[i1 + 2], verts[i2 + 2]),
          );
          final maxX = math.max(verts[i0], math.max(verts[i1], verts[i2]));
          final maxY = math.max(
            verts[i0 + 1],
            math.max(verts[i1 + 1], verts[i2 + 1]),
          );
          final maxZ = math.max(
            verts[i0 + 2],
            math.max(verts[i1 + 2], verts[i2 + 2]),
          );
          if (maxX >= box.min.x - 1e-5 &&
              minX <= box.max.x + 1e-5 &&
              maxY >= box.min.y - 1e-5 &&
              minY <= box.max.y + 1e-5 &&
              maxZ >= box.min.z - 1e-5 &&
              minZ <= box.max.z + 1e-5) {
            hits.add(t);
          }
        }
        return hits;
      }

      final boxA = Aabb3.minMax(Vector3(0.0, 0.0, 0.0), Vector3(1.6, 1.6, 1.6));
      final boxB = Aabb3.minMax(
        Vector3(-1.6, -1.6, -1.6),
        Vector3(-0.1, -0.1, -0.1),
      );

      final expectedA = bruteForce(boxA);
      final expectedB = bruteForce(boxB);

      final outer = <int>[];
      final countA = bvh.queryAabb(boxA, outer, filterTriangles: true);
      expect(countA, equals(expectedA.length));
      expect(outer.toSet(), equals(expectedA.toSet()));

      final extentsOut = <int>[];
      bvh.queryAabbExtents(
        boxB.min.x,
        boxB.min.y,
        boxB.min.z,
        boxB.max.x,
        boxB.max.y,
        boxB.max.z,
        extentsOut,
        filterTriangles: true,
      );
      expect(extentsOut.toSet(), equals(expectedB.toSet()));

      // Reentrant/nested and deep BVH queries using separate output buffers
      // must agree with the brute-force baseline.
      final deepBvh = SurfaceBvh.build(surface, maxLeafTriangles: 1);
      final deepA = <int>[];
      final deepB = <int>[];
      deepBvh.queryAabb(boxA, deepA, filterTriangles: true);
      expect(deepA.toSet(), equals(expectedA.toSet()));

      final outerNested = <int>[];
      bvh.queryAabb(boxA, outerNested, filterTriangles: true);
      final innerNested = <int>[];
      var nestedMismatch = 0;
      for (final _ in outerNested.take(3)) {
        innerNested.clear();
        deepB.clear();
        bvh.queryAabb(boxB, innerNested, filterTriangles: true);
        deepBvh.queryAabb(boxB, deepB, filterTriangles: true);
        if (innerNested.length != expectedB.length ||
            deepB.length != expectedB.length) {
          nestedMismatch++;
        }
      }
      expect(nestedMismatch, equals(0));
      expect(outerNested.toSet(), equals(expectedA.toSet()));
    });
  });
}
