import 'dart:typed_data';
import 'dart:ui' show Color, Rect;

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/navigation.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/collisions/collision_manifold_3d.dart';
import 'package:flame_3d/src/components/instance_buffer_3d.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:flame_3d/src/physics/physics_solver_math_3d.dart';
import 'package:flame_3d/src/spatial/static_bvh_3d.dart';
import 'package:flutter_test/flutter_test.dart';

Matrix4 _pose(double x, double y, double z, [Quaternion? rot]) =>
    Matrix4.compose(
      Vector3(x, y, z),
      rot ?? Quaternion.identity(),
      Vector3(1, 1, 1),
    );

void _expectManifoldClose(CollisionManifold3D a, CollisionManifold3D b) {
  expect(a.normal.distanceTo(b.normal), lessThan(1e-6));
  expect(a.penetrationDepth, closeTo(b.penetrationDepth, 1e-6));
  expect(a.contactPointA.distanceTo(b.contactPointA), lessThan(1e-6));
  expect(a.contactPointB.distanceTo(b.contactPointB), lessThan(1e-6));
  expect(a.contacts.length, b.contacts.length);
  for (var i = 0; i < a.contacts.length; i++) {
    expect(
      a.contacts[i].pointA.distanceTo(b.contacts[i].pointA),
      lessThan(1e-6),
    );
    expect(
      a.contacts[i].pointB.distanceTo(b.contacts[i].pointB),
      lessThan(1e-6),
    );
    expect(a.contacts[i].featureId, b.contacts[i].featureId);
  }
}

void main() {
  group('Wave 2.2 narrowphase & MutableManifoldBuffer3D unification', () {
    test('test/testAll match testAllInto across shape pairs', () {
      final sphere = SphereShape3D(radius: 0.6);
      final capsule = CapsuleShape3D(radius: 0.4, height: 1.2);
      final box = BoxShape3D(halfExtents: Vector3(0.5, 0.5, 0.5));
      final hull = ConvexHullShape3D(
        vertices: [
          Vector3(-0.4, -0.4, -0.4),
          Vector3(0.4, -0.4, -0.4),
          Vector3(0.4, 0.4, -0.4),
          Vector3(-0.4, 0.4, -0.4),
          Vector3(-0.4, -0.4, 0.4),
          Vector3(0.4, -0.4, 0.4),
          Vector3(0.4, 0.4, 0.4),
          Vector3(-0.4, 0.4, 0.4),
        ],
      );
      final compound = CompoundShape3D([
        CompoundChildShape3D(
          shape: BoxShape3D(halfExtents: Vector3(0.5, 0.25, 0.5)),
          position: Vector3(0, -0.25, 0),
        ),
        CompoundChildShape3D(
          shape: SphereShape3D(radius: 0.35),
          position: Vector3(0, 0.3, 0),
        ),
      ]);
      final hf = HeightfieldShape3D(
        heights: Float32List(16),
        columns: 4,
        rows: 4,
        width: 8,
        depth: 8,
      );

      final pairs = <(Shape3D, Matrix4, Shape3D, Matrix4)>[
        (sphere, _pose(0, 0, 0), sphere, _pose(0.8, 0, 0)),
        (sphere, _pose(0, 0, 0), capsule, _pose(0.7, 0.2, 0)),
        (capsule, _pose(0, 0, 0), capsule, _pose(0.5, 0.1, 0)),
        (sphere, _pose(0, 0.8, 0), box, _pose(0, 0, 0)),
        (capsule, _pose(0.1, 0.9, 0), box, _pose(0, 0, 0)),
        (box, _pose(0, 0.9, 0), box, _pose(0, 0, 0)),
        (hull, _pose(0.1, 0.7, 0), hull, _pose(0, 0, 0)),
        (compound, _pose(0, 0.9, 0), box, _pose(0, 0, 0)),
        (compound, _pose(0, 0.4, 0), hf, _pose(0, 0, 0)),
      ];

      final buf = MutableManifoldBuffer3D();
      for (final (sA, tA, sB, tB) in pairs) {
        buf.clear();
        Narrowphase3D.testAllInto(sA, tA, sB, tB, buf);
        final all = Narrowphase3D.testAll(sA, tA, sB, tB);
        expect(all.length, buf.manifoldCount);
        for (var i = 0; i < all.length; i++) {
          _expectManifoldClose(all[i], buf.materializeAt(i));
        }
        final deepest = Narrowphase3D.test(sA, tA, sB, tB);
        expect(deepest, isNotNull);
        _expectManifoldClose(deepest!, buf.materializeDeepest()!);
      }
    });

    test('compound vs triangle retains single deepest manifold cleanly', () {
      final compound = CompoundShape3D([
        CompoundChildShape3D(
          shape: BoxShape3D(halfExtents: Vector3(0.5, 0.5, 0.5)),
          position: Vector3(0, 0.45, 0),
        ),
        CompoundChildShape3D(
          shape: SphereShape3D(radius: 0.4),
          position: Vector3(0, 0.55, 0),
        ),
      ]);
      final tri0 = Vector3(-2, 0, -2);
      final tri1 = Vector3(2, 0, -2);
      final tri2 = Vector3(0, 0, 2);

      final buf = MutableManifoldBuffer3D();
      final m = Narrowphase3D.intersectShapeWithTriangle(
        compound,
        _pose(0, 0, 0),
        tri0,
        tri1,
        tri2,
      );
      expect(m, isNotNull);
      expect(m!.contacts.length, greaterThanOrEqualTo(3));

      // Verify direct plane query via Mesh/Surface BVH returns results.
      final mesh = PlaneMesh(size: Vector2(4, 4));
      final surf = mesh.surfaces.single;
      final sHit = Narrowphase3D.intersectShapeWithSurfaceBvh(
        BoxShape3D(halfExtents: Vector3(0.4, 0.4, 0.4)),
        _pose(0, 0.35, 0),
        surf,
        Matrix4.identity(),
      );
      final sAll = Narrowphase3D.intersectShapeWithSurfaceBvhAll(
        BoxShape3D(halfExtents: Vector3(0.4, 0.4, 0.4)),
        _pose(0, 0.35, 0),
        surf,
        Matrix4.identity(),
      );
      expect(sHit, isNotNull);
      expect(sAll, isNotEmpty);
      expect(buf.isEmpty, isTrue);
    });
  });

  group('StaticBvh3D & NavMesh3D / SurfaceBvh queries', () {
    test('build, queryAabb, queryLine, stack growth and reentrancy', () {
      const count = 200;
      final bounds = Float32List(count * 6);
      final centroids = Float32List(count * 3);
      for (var i = 0; i < count; i++) {
        final x = i * 2.0;
        final b = i * 6;
        bounds
          ..[b] = x - 0.5
          ..[b + 1] = -0.5
          ..[b + 2] = -0.5
          ..[b + 3] = x + 0.5
          ..[b + 4] = 0.5
          ..[b + 5] = 0.5;
        final c = i * 3;
        centroids
          ..[c] = x
          ..[c + 1] = 0
          ..[c + 2] = 0;
      }

      final bvh = StaticBvh3D.build(
        primitiveCount: count,
        primitiveBounds: bounds,
        centroids: centroids,
        maxLeafPrimitives: 1,
      );
      expect(bvh.primitiveCount, count);
      expect(bvh.nodeCount, greaterThan(count));

      final aabbHits = <int>[];
      bvh.queryAabbExtents(9.0, -1, -1, 15.0, 1, 1, aabbHits);
      expect(aabbHits.toSet(), equals({5, 6, 7}));

      final lineHits = <int>[];
      bvh.queryLine(10.0, 5.0, 0.0, 0.0, -1.0, 0.0, lineHits);
      expect(lineHits, contains(5));

      expect(
        bvh.boxDistanceSquared(0, 0.0, 3.0, 4.0),
        closeTo(9.0 + 16.0 - 2 * 3.0 * 0.5 - 2 * 4.0 * 0.5 + 0.5, 1.0),
      );
      final d2 = bvh.boxDistanceSquared(0, -2.5, 0.0, 0.0);
      expect(d2, closeTo(4.0, 1e-5));

      expect(
        () => StaticBvh3D.fromPrepared(
          nodeCount: 2,
          primitiveCount: 2,
          bounds: Float32List(2),
          leftOrFirst: Int32List(2),
          rightChild: Int32List(2),
          counts: Int32List(2),
          primitives: Int32List(2),
        ),
        throwsArgumentError,
      );

      // Reentrancy-safe SurfaceBvh filtering & NavMesh nearest lookup.
      final surf = PlaneMesh(size: Vector2(4, 4)).surfaces.single;
      final outTris = <int>[];
      surf.bvh.queryAabb(
        Aabb3.minMax(Vector3(-1, -1, -1), Vector3(1, 1, 1)),
        outTris,
        filterTriangles: true,
      );
      expect(outTris, isNotEmpty);

      final nav = NavMesh3D.fromMesh(PlaneMesh(size: Vector2(6, 6)));
      final nearest = nav.findNearestPoly(Vector3(1.2, 2.0, -0.8));
      expect(nearest, isNotNull);
    });
  });

  group('geometry_math & physics_solver_math_3d', () {
    test('invertSymmetricValues3D, quatMul, closestPoints, and im guards', () {
      final inv = Matrix3.zero();
      expect(invertSymmetricValues3D(2, 0, 0, 4, 0, 5, inv), isTrue);
      expect(inv.entry(0, 0), closeTo(0.5, 1e-6));
      expect(inv.entry(1, 1), closeTo(0.25, 1e-6));
      expect(inv.entry(2, 2), closeTo(0.2, 1e-6));
      expect(invertSymmetricValues3D(1, 0, 0, 1, 0, 0, inv), isFalse);

      final qA = Quaternion.axisAngle(Vector3(0, 1, 0), 0.7);
      final qB = Quaternion.axisAngle(Vector3(1, 0, 0), 0.5);
      final qProd = Quaternion.identity();
      final qRecover = Quaternion.identity();
      quatMul(qA, qB, qProd);
      quatMulConjA(qA, qProd, qRecover);
      expect((qRecover.x - qB.x).abs(), lessThan(1e-6));
      expect((qRecover.y - qB.y).abs(), lessThan(1e-6));
      expect((qRecover.z - qB.z).abs(), lessThan(1e-6));
      expect((qRecover.w - qB.w).abs(), lessThan(1e-6));

      final c1 = Vector3.zero();
      final c2 = Vector3.zero();
      closestPointOnSegment3D(
        1,
        3,
        0,
        Vector3(0, 0, 0),
        Vector3(2, 0, 0),
        c1,
      );
      expect(c1.distanceTo(Vector3(1, 0, 0)), lessThan(1e-6));

      closestPointsSegmentSegment3D(
        Vector3(0, 0, -1),
        Vector3(0, 0, 1),
        Vector3(2, -1, 0),
        Vector3(2, 1, 0),
        c1,
        c2,
      );
      expect(c1.distanceTo(Vector3(0, 0, 0)), lessThan(1e-6));
      expect(c2.distanceTo(Vector3(2, 0, 0)), lessThan(1e-6));

      final bodyA = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.5)),
        position: Vector3(0, 0, 0),
        mass: 2.0,
      );
      final bodyB = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.5)),
        position: Vector3(0, 1, 0),
        mass: 4.0,
      );
      bodyA.updateWorldInertia();
      bodyB.updateWorldInertia();

      final scratch = Vector3.zero();
      final kMasked = computeLinearAxisKWithInvMass(
        bodyA,
        0.0,
        Vector3.zero(),
        bodyB,
        bodyB.inverseMass,
        Vector3.zero(),
        Vector3(0, 1, 0),
        scratch,
      );
      expect(kMasked, closeTo(bodyB.inverseMass, 1e-9));

      applyLinearPairImpulseWithInvMass(
        bodyA,
        0.0,
        Vector3(1, 0, 0),
        bodyB,
        bodyB.inverseMass,
        Vector3.zero(),
        0,
        2,
        0,
        scratch,
      );
      expect(bodyA.linearVelocity.length, 0.0);
      expect(bodyB.linearVelocity.y, closeTo(2 * bodyB.inverseMass, 1e-6));

      applyPositionPairImpulseWithInvMass(
        bodyA,
        0.0,
        Vector3(1, 0, 0),
        bodyB,
        bodyB.inverseMass,
        Vector3.zero(),
        0,
        4,
        0,
        scratch,
      );
      expect(bodyA.bodyPosition.length, 0.0);
      expect(
        bodyB.bodyPosition.y,
        closeTo(1.0 + 4 * bodyB.inverseMass, 1e-6),
      );

      final pointInvK = Matrix3.zero();
      final angInvK = Matrix3.zero();
      buildPointToPointInvK(
        bodyA,
        Vector3(0, 0.5, 0),
        bodyB,
        Vector3(0, -0.5, 0),
        pointInvK,
      );
      buildAngularInvK(bodyA, bodyB, angInvK);
      expect(pointInvK.entry(0, 0), greaterThan(0.0));
      expect(angInvK.entry(1, 1), greaterThan(0.0));
    });
  });

  group('InstanceBuffer3D & batch adoption', () {
    test('append, update, removeAtSwapLast, world cache & clear', () {
      expect(() => InstanceBuffer3D(initialCapacity: 0), throwsArgumentError);

      final buf = InstanceBuffer3D(initialCapacity: 2);
      buf
        ..append(
          Matrix4.translationValues(1, 2, 3),
          const Color(0xFFFF0000),
          1,
          2,
          3,
          4,
        )
        ..append(
          Matrix4.translationValues(4, 5, 6),
          const Color(0xFF00FF00),
          5,
          6,
          7,
          8,
        )
        ..append(
          Matrix4.translationValues(7, 8, 9),
          const Color(0xFF0000FF),
          9,
          10,
          11,
          12,
        );
      expect(buf.length, 3);
      expect(buf.capacity, greaterThanOrEqualTo(3));

      expect(
        identical(buf.resolveWorld(Matrix4.identity(), 0), buf.localData),
        isTrue,
      );

      final parent = Matrix4.translationValues(10, 0, 0);
      final worldBuf1 = buf.resolveWorld(parent, 1);
      final v1 = buf.versionOf(worldBuf1);
      expect(worldBuf1[12], closeTo(11, 1e-5));
      // Cached lookup on unchanged version returns same buffer & version.
      final worldBuf1Again = buf.resolveWorld(parent, 1);
      expect(identical(worldBuf1Again, worldBuf1), isTrue);
      expect(buf.versionOf(worldBuf1Again), v1);

      buf.removeAtSwapLast(0);
      expect(buf.length, 2);
      expect(buf.readTransform(0).storage[12], closeTo(7, 1e-5));
      expect(buf.readData(0).x, closeTo(9, 1e-5));

      expect(buf.clear(), isTrue);
      expect(buf.isEmpty, isTrue);
      expect(buf.clear(), isFalse);

      final group = InstancedGroup3D(mesh: PlaneMesh(size: Vector2.all(1)))
        ..addInstance(transform: Matrix4.identity());
      final decals = DecalBatch3D(sortByDepth: true)
        ..addFlatDecal(
          center: Vector3.zero(),
          uvRect: const Rect.fromLTWH(0, 0, 0.5, 0.5),
        );
      expect(group.length, 1);
      expect(decals.length, 1);
    });
  });
}
