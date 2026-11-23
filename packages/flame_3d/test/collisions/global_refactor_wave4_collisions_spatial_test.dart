import 'dart:typed_data';

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart'
    show makePerspectiveMatrix, makeViewMatrix;

ConvexHullShape3D _boxHull(double hx, double hy, double hz) {
  return ConvexHullShape3D(
    vertices: [
      Vector3(-hx, -hy, -hz),
      Vector3(hx, -hy, -hz),
      Vector3(hx, hy, -hz),
      Vector3(-hx, hy, -hz),
      Vector3(-hx, -hy, hz),
      Vector3(hx, -hy, hz),
      Vector3(hx, hy, hz),
      Vector3(-hx, hy, hz),
    ],
  );
}

Surface _floorQuadSurface() {
  return Surface(
    vertices: [
      Vertex(
        position: Vector3(-5, 0, -5),
        texCoord: Vector2(0, 0),
        normal: Vector3(0, 1, 0),
      ),
      Vertex(
        position: Vector3(-5, 0, 5),
        texCoord: Vector2(0, 1),
        normal: Vector3(0, 1, 0),
      ),
      Vertex(
        position: Vector3(5, 0, 5),
        texCoord: Vector2(1, 1),
        normal: Vector3(0, 1, 0),
      ),
      Vertex(
        position: Vector3(5, 0, -5),
        texCoord: Vector2(1, 0),
        normal: Vector3(0, 1, 0),
      ),
    ],
    indices: [0, 1, 2, 0, 2, 3],
  );
}

void main() {
  group('Wave 4.1 collisions and spatial refactoring', () {
    test('Shape3D exposes isConvex and hasSupportFace capabilities', () {
      final sphere = SphereShape3D(radius: 1.0);
      final capsule = CapsuleShape3D(radius: 0.5, height: 2.0);
      final box = BoxShape3D(halfExtents: Vector3.all(1.0));
      final validHull = _boxHull(1.0, 1.0, 1.0);
      final degenerateHull = ConvexHullShape3D(
        vertices: [
          Vector3(0, 0, 0),
          Vector3(1, 0, 0),
          Vector3(0, 1, 0),
        ],
      );
      final compound = CompoundShape3D([
        CompoundChildShape3D(shape: box),
      ]);
      final heightfield = HeightfieldShape3D(
        heights: Float32List.fromList([0, 0, 0, 0]),
        columns: 2,
        rows: 2,
        width: 2.0,
        depth: 2.0,
      );

      expect(sphere.isConvex, isTrue);
      expect(sphere.hasSupportFace, isFalse);
      expect(capsule.isConvex, isTrue);
      expect(capsule.hasSupportFace, isFalse);
      expect(box.isConvex, isTrue);
      expect(box.hasSupportFace, isTrue);
      expect(validHull.isConvex, isTrue);
      expect(validHull.hasSupportFace, isTrue);
      expect(degenerateHull.isConvex, isTrue);
      expect(degenerateHull.hasSupportFace, isFalse);
      expect(compound.isConvex, isFalse);
      expect(compound.hasSupportFace, isFalse);
      expect(heightfield.isConvex, isFalse);
      expect(heightfield.hasSupportFace, isFalse);
    });

    test('ConvexHullShape3D Quickhull, raycast, and multi-point clipping', () {
      final hullA = _boxHull(1.0, 1.0, 1.0);
      final hullB = _boxHull(0.5, 0.5, 0.5);
      expect(hullA.faceCount, 6);

      final verticalHit = hullA.raycast(
        Ray.originDirection(Vector3(0, 5, 0), Vector3(0, -1, 0)),
        Matrix4.identity(),
      );
      expect(verticalHit, isNotNull);
      expect(verticalHit!.$1, closeTo(4.0, 1e-5));
      expect(verticalHit.$2.y, closeTo(1.0, 1e-5));

      final obliqueHit = hullA.raycast(
        Ray.originDirection(
          Vector3(3.0, 0.2, 0.1),
          Vector3(-1, -0.1, -0.05).normalized(),
        ),
        Matrix4.identity(),
      );
      expect(obliqueHit, isNotNull);
      expect(obliqueHit!.$1, greaterThan(1.5));
      expect(obliqueHit.$2.x, closeTo(1.0, 1e-4));

      expect(
        hullA.raycast(
          Ray.originDirection(Vector3(5, 5, 0), Vector3(0, -1, 0)),
          Matrix4.identity(),
        ),
        isNull,
      );

      final insideHit = hullA.raycast(
        Ray.originDirection(Vector3.zero(), Vector3(0, -1, 0)),
        Matrix4.identity(),
      );
      expect(insideHit, isNotNull);
      expect(insideHit!.$1, closeTo(0.0, 1e-6));

      final stacked = Narrowphase3D.test(
        hullA,
        Matrix4.identity(),
        hullB,
        Matrix4.translationValues(0, 1.4, 0),
      );
      expect(stacked, isNotNull);
      expect(stacked!.penetrationDepth, closeTo(0.1, 1e-4));
      expect(stacked.normal.y, closeTo(1.0, 1e-4));
      expect(stacked.contacts.length, 4);

      // Subsequent degenerate hull query does not leak stale clip state.
      final triHull = ConvexHullShape3D(
        vertices: [
          Vector3(-1, 0, -1),
          Vector3(1, 0, -1),
          Vector3(0, 0, 1),
        ],
      );
      final single = Narrowphase3D.test(
        triHull,
        Matrix4.identity(),
        SphereShape3D(radius: 0.5),
        Matrix4.translationValues(0, 0.25, 0),
      );
      expect(single, isNotNull);
      expect(single!.contacts.length, 1);
      expect(single.penetrationDepth, closeTo(0.25, 1e-4));
    });

    test('Narrowphase3D merges compound, heightfield, and SurfaceBvh', () {
      final compound = CompoundShape3D([
        CompoundChildShape3D(
          shape: BoxShape3D(halfExtents: Vector3(0.5, 0.5, 0.5)),
          position: Vector3(-0.4, 0, 0),
        ),
        CompoundChildShape3D(
          shape: BoxShape3D(halfExtents: Vector3(0.5, 0.5, 0.5)),
          position: Vector3(0.4, 0, 0),
        ),
      ]);
      final floorBox = BoxShape3D(halfExtents: Vector3(3.0, 0.5, 3.0));
      final compoundHits = Narrowphase3D.testAll(
        compound,
        Matrix4.translationValues(0, 0.9, 0),
        floorBox,
        Matrix4.identity(),
      );
      expect(compoundHits, hasLength(1));
      expect(compoundHits.single.penetrationDepth, closeTo(0.1, 1e-4));

      final heightfield = HeightfieldShape3D(
        heights: Float32List.fromList(List.filled(9, 0.0)),
        columns: 3,
        rows: 3,
        width: 6.0,
        depth: 6.0,
      );
      final hfHit = Narrowphase3D.heightfieldShape(
        SphereShape3D(radius: 1.0),
        Matrix4.translationValues(0, 0.7, 0),
        heightfield,
        Matrix4.identity(),
      );
      expect(hfHit, isNotNull);
      expect(hfHit!.penetrationDepth, closeTo(0.3, 1e-4));

      final surface = _floorQuadSurface();
      final bvhHits = Narrowphase3D.intersectShapeWithSurfaceBvhAll(
        BoxShape3D(halfExtents: Vector3(0.5, 0.5, 0.5)),
        Matrix4.translationValues(0, 0.4, 0),
        surface,
        Matrix4.identity(),
      );
      expect(bvhHits, isNotEmpty);
      expect(bvhHits.first.penetrationDepth, closeTo(0.1, 1e-4));
    });

    test('ShapeCast3D sweeps sphere, capsule, and convex hull cleanly', () {
      final targetCollider = Collider3D(
        shape: BoxShape3D(halfExtents: Vector3(1, 1, 1)),
        position: Vector3(5, 0, 0),
      );
      final heightfieldCollider = Collider3D(
        shape: HeightfieldShape3D(
          heights: Float32List.fromList([0, 0, 0, 0]),
          columns: 2,
          rows: 2,
          width: 4.0,
          depth: 4.0,
        ),
        position: Vector3(0, -3, 0),
      );
      final system = CollisionSystem3D()
        ..register(targetCollider)
        ..register(heightfieldCollider);

      final sphereSweep = ShapeCast3D.sphereCast(
        origin: Vector3.zero(),
        radius: 0.5,
        delta: Vector3(10, 0, 0),
        collisionSystem: system,
      );
      expect(sphereSweep, isNotNull);
      expect(sphereSweep!.distance, closeTo(3.5, 1e-3));
      expect(sphereSweep.collider, same(targetCollider));

      final capsuleSweep = ShapeCast3D.capsuleCast(
        origin: Vector3.zero(),
        radius: 0.5,
        height: 1.5,
        delta: Vector3(10, 0, 0),
        collisionSystem: system,
      );
      expect(capsuleSweep, isNotNull);
      expect(capsuleSweep!.distance, closeTo(3.5, 1e-3));

      final hullSweep = ShapeCast3D.convexCast(
        shape: _boxHull(0.5, 0.5, 0.5),
        startTransform: Matrix4.identity(),
        delta: Vector3(0, -5, 0),
        collisionSystem: system,
      );
      expect(hullSweep, isNotNull);
      expect(hullSweep!.distance, closeTo(2.5, 1e-2));
      expect(hullSweep.collider, same(heightfieldCollider));
    });

    test('CollisionSystem3D queries, raycasts, and trigger lifecycle work', () {
      var enters = 0;
      var stays = 0;
      var exits = 0;
      final mover = Collider3D(
        shape: SphereShape3D(radius: 1.0),
        position: Vector3(0, 0, 0),
      );
      final trigger = TriggerVolume3D(
        shape: BoxShape3D(halfExtents: Vector3(1, 1, 1)),
        position: Vector3(1.5, 0, 0),
        onEnter3D: (_, _) => enters++,
        onStay3D: (_, _) => stays++,
        onExit3D: (_) => exits++,
      );
      final system = CollisionSystem3D()
        ..register(mover)
        ..register(trigger);

      system.step();
      expect(enters, 1);
      expect(stays, 0);
      expect(exits, 0);

      system.step();
      expect(stays, 1);

      expect(system.overlapSphere(Vector3.zero(), 1.0), contains(mover));
      expect(
        system.overlapBox(Vector3(1.5, 0, 0), Vector3.all(0.5)),
        contains(trigger),
      );
      expect(
        system.overlapCapsule(Vector3(-1, 0, 0), Vector3(1, 0, 0), 0.25),
        contains(mover),
      );

      final frustumMat = makePerspectiveMatrix(1.0, 1.0, 0.1, 100.0)
        ..multiply(
          makeViewMatrix(
            Vector3(0, 0, 10),
            Vector3.zero(),
            Vector3(0, 1, 0),
          ),
        );
      final frustum = Frustum.matrix(frustumMat);
      expect(system.overlapFrustum(frustum), containsAll([mover, trigger]));

      final ray = Ray.originDirection(Vector3(-5, 0, 0), Vector3(1, 0, 0));
      final firstHit = system.raycastColliders(ray);
      expect(firstHit, isNotNull);
      expect(firstHit!.collider, same(mover));
      final allHits = system.raycastAllColliders(ray);
      expect(allHits.map((h) => h.collider), [mover, trigger]);

      mover.position.setValues(20, 0, 0);
      system.step();
      expect(exits, 1);
    });

    test('DynamicAabbTree3D queries, raycasts, and AVL invariants hold', () {
      final tree = DynamicAabbTree3D<String>(fatMargin: 0.2);
      final p0 = tree.insert(
        'near',
        Aabb3.minMax(Vector3(-1, -1, -1), Vector3(1, 1, 1)),
      );
      final p1 = tree.insert(
        'far',
        Aabb3.minMax(Vector3(4, -1, -1), Vector3(6, 1, 1)),
      );
      expect(tree.validateStructure(), isTrue);

      expect(
        tree.queryAabb(Aabb3.minMax(Vector3(-2, -2, -2), Vector3(2, 2, 2))),
        ['near'],
      );
      expect(tree.querySphere(Vector3(5, 0, 0), 0.5), ['far']);

      final frustumMat = makePerspectiveMatrix(1.0, 1.0, 0.1, 50.0)
        ..multiply(
          makeViewMatrix(
            Vector3(0, 0, 10),
            Vector3.zero(),
            Vector3(0, 1, 0),
          ),
        );
      final frustum = Frustum.matrix(frustumMat);
      expect(tree.queryFrustum(frustum), containsAll(['near', 'far']));

      final ray = Ray.originDirection(Vector3(-5, 0, 0), Vector3(1, 0, 0));
      final hit = tree.raycast(ray);
      expect(hit?.item, 'near');
      expect(tree.raycastAll(ray).map((h) => h.item), ['near', 'far']);

      expect(
        tree.update(
          p1,
          Aabb3.minMax(Vector3(4.05, -1, -1), Vector3(6.05, 1, 1)),
        ),
        isFalse,
      );
      tree.remove(p0);
      expect(tree.validateStructure(), isTrue);
      expect(tree.leafCount, 1);
    });
  });
}
