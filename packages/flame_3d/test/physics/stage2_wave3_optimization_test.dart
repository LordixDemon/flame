import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/game.dart' show FlameGame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/navigation.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/collisions/collision_manifold_3d.dart'
    show MutableManifoldBuffer3D;
import 'package:flutter_test/flutter_test.dart';

class _TestCallbacksComponent({super.position})
    extends Component3D
    with CollisionCallbacks3D {
  int starts = 0;
  int stays = 0;
  int ends = 0;
  Collider3D? lastOther;

  @override
  void onCollisionStart3D(Collider3D other, CollisionManifold3D manifold) {
    starts++;
    lastOther = other;
  }

  @override
  void onCollision3D(Collider3D other, CollisionManifold3D manifold) {
    stays++;
    lastOther = other;
  }

  @override
  void onCollisionEnd3D(Collider3D other) {
    ends++;
    lastOther = other;
  }
}

Mesh _twoSurfaceBoxMesh() {
  final m = Mesh();
  final s0 = CuboidMesh(size: Vector3.all(1.0)).surfaces.first;
  final s1 = SphereMesh(radius: 0.5).surfaces.first;
  m.addSurface(s0);
  m.addSurface(s1);
  return m;
}

void main() {
  group('Stage 2 Wave 3 optimizations', () {
    test('Narrowphase3D.testAllInto matches testAll for ConvexHull, '
        'nested CompoundShape3D, and HeightfieldShape3D', () {
      final hullVerts = <Vector3>[
        for (final sx in const [-0.5, 0.5])
          for (final sy in const [-0.5, 0.5])
            for (final sz in const [-0.5, 0.5]) Vector3(sx, sy, sz),
      ];
      final hull = ConvexHullShape3D(vertices: hullVerts);
      final box = BoxShape3D(halfExtents: Vector3.all(0.5));
      final mA = Matrix4.identity()..setTranslationRaw(0.0, 0.0, 0.0);
      final mB = Matrix4.identity()
        ..setTranslationRaw(0.2, 0.75, 0.1)
        ..rotateY(0.4);

      final buf = MutableManifoldBuffer3D();
      Narrowphase3D.testAllInto(hull, mA, box, mB, buf);
      final ref = Narrowphase3D.testAll(hull, mA, box, mB);
      expect(buf.manifoldCount, ref.length);
      expect(buf.manifoldCount, 1);
      expect(buf.depth(0), closeTo(ref[0].penetrationDepth, 1e-6));
      expect(buf.contactLength(0), ref[0].contacts.length);
      expect(buf.normalY(0), closeTo(ref[0].normal.y, 1e-6));

      // Nested CompoundShape3D vs HeightfieldShape3D.
      final inner = CompoundShape3D([
        CompoundChildShape3D(
          shape: SphereShape3D(radius: 0.3),
          position: Vector3(-0.3, 0.0, 0.0),
        ),
        CompoundChildShape3D(
          shape: SphereShape3D(radius: 0.3),
          position: Vector3(0.3, 0.0, 0.0),
        ),
      ]);
      final outer = CompoundShape3D([
        CompoundChildShape3D(shape: inner, position: Vector3(0.0, 0.1, 0.0)),
      ]);
      final hf = HeightfieldShape3D(
        heights: Float32List(9),
        columns: 3,
        rows: 3,
        width: 10.0,
        depth: 10.0,
      );
      final cmpMat = Matrix4.identity()..setTranslationRaw(0.0, 0.1, 0.0);
      final hfMat = Matrix4.identity();
      buf.clear();
      Narrowphase3D.testAllInto(outer, cmpMat, hf, hfMat, buf);
      final hfRef = Narrowphase3D.testAll(outer, cmpMat, hf, hfMat);
      expect(buf.manifoldCount, hfRef.length);
      expect(buf.manifoldCount, greaterThanOrEqualTo(1));
      expect(buf.depth(0), closeTo(hfRef[0].penetrationDepth, 1e-6));
    });

    test('Collider3D pose/AABB cache invalidation and CollisionSystem3D '
        'mounted start/stay/end callbacks', () async {
      final colSys = CollisionSystem3D(autoStep: false);
      final hostA = _TestCallbacksComponent(position: Vector3(0.0, 0.0, 0.0));
      final colA = Collider3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.5)),
      );
      hostA.add(colA);

      final hostB = _TestCallbacksComponent(position: Vector3(0.5, 0.0, 0.0));
      final colB = Collider3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.5)),
        isStatic: true,
      );
      hostB.add(colB);

      final world = World3D()..addAll([colSys, hostA, hostB]);
      final game = FlameGame(world: world);
      await game.ready();
      game.onGameResize(Vector2(100, 100));

      // Verify cache tracks localOffset & shape mutations.
      final oldCenterX = colA.colliderWorldMatrix.storage[12];
      colA.localOffset.x = 0.25;
      expect(
        colA.colliderWorldMatrix.storage[12],
        closeTo(oldCenterX + 0.25, 1e-6),
      );
      colA.localOffset.x = 0.0;
      expect(colA.colliderWorldMatrix.storage[12], closeTo(oldCenterX, 1e-6));

      colSys.step();
      expect(hostA.starts, 1);
      expect(hostB.starts, 1);

      colSys.step();
      expect(hostA.stays, 1);
      expect(hostB.stays, 1);

      // Move dynamic collider away; end callbacks fire on both.
      hostA.position.x = 5.0;
      colSys.step();
      expect(hostA.ends, 1);
      expect(hostB.ends, 1);

      // Update shape invalidates AABB cache.
      colA.shape = SphereShape3D(radius: 2.0);
      final box = colA.colliderWorldAabb;
      expect(box.max.x - box.min.x, closeTo(4.0, 1e-5));
    });

    test('PhysicsWorld3D active-only broadphase wake propagation, '
        'inertia cache, and O(1) joint collision blocking', () {
      final world = PhysicsWorld3D(autoStep: false, sleepTimeThreshold: 0.05);
      final floor = RigidBody3D(
        bodyType: BodyType3D.static,
        shape: BoxShape3D(halfExtents: Vector3(10.0, 0.5, 10.0)),
        position: Vector3(0.0, -0.5, 0.0),
      );
      final a = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.25)),
        position: Vector3(0.0, 0.25, 0.0),
        isSleeping: true,
      );
      final b = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.25)),
        position: Vector3(0.0, 0.75, 0.0),
        isSleeping: true,
      );
      final striker = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.25)),
        position: Vector3(-0.6, 0.25, 0.0),
        linearVelocity: Vector3(4.0, 0.0, 0.0),
      );
      world
        ..addBody(floor)
        ..addBody(a)
        ..addBody(b)
        ..addBody(striker);

      // Striker wakes `a`, and in turn sleeping chain can wake `b`.
      for (var i = 0; i < 6; i++) {
        world.step(1 / 60);
      }
      expect(a.isSleeping, isFalse);

      // Joint non-colliding partner tracking.
      final jBodyA = RigidBody3D(
        shape: SphereShape3D(radius: 0.5),
        position: Vector3(4.0, 2.0, 0.0),
      );
      final jBodyB = RigidBody3D(
        shape: SphereShape3D(radius: 0.5),
        position: Vector3(4.3, 2.0, 0.0),
      );
      final joint = DistanceJoint3D(
        bodyA: jBodyA,
        bodyB: jBodyB,
      );
      world
        ..addBody(jBodyA)
        ..addBody(jBodyB)
        ..addJoint(joint);
      expect(jBodyA.nonCollidingJointPartners, contains(jBodyB));
      expect(jBodyB.nonCollidingJointPartners, contains(jBodyA));
      world.step(1 / 60);
      expect(jBodyA.position.distanceTo(jBodyB.position), lessThan(0.5));

      world.removeJoint(joint);
      expect(jBodyA.nonCollidingJointPartners, isEmpty);
      expect(jBodyB.nonCollidingJointPartners, isEmpty);
    });

    test('ShapeCast3D.convexCast BVH query and RayHit3D.intersectMesh '
        'multi-surface parity (rigid + scaled + mirrored)', () {
      final colSys = CollisionSystem3D(autoStep: false);
      final target = Collider3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.5)),
        position: Vector3(0.0, 0.0, 4.0),
      );
      colSys.register(target);

      final hit = ShapeCast3D.convexCast(
        shape: SphereShape3D(radius: 0.5),
        startTransform: Matrix4.identity(),
        delta: Vector3(0.0, 0.0, 10.0),
        collisionSystem: colSys,
      );
      expect(hit, isNotNull);
      expect(hit!.distance, closeTo(3.0, 1e-3));
      expect(hit.normal.z, closeTo(-1.0, 1e-3));

      final mesh = _twoSurfaceBoxMesh();
      final owner = MeshComponent(mesh: mesh);
      final ray = Ray()
        ..origin.setValues(0.0, 0.0, 5.0)
        ..direction.setValues(0.0, 0.0, -1.0);

      for (final mat in <Matrix4>[
        Matrix4.identity()..rotateY(0.35),
        Matrix4.identity()..scaleByVector3(Vector3(1.5, 2.0, 0.75)),
        Matrix4.identity()..scaleByVector3(Vector3(-1.0, 1.0, 1.0)),
      ]) {
        final mh = RayHit3D.intersectMesh(
          owner: owner,
          mesh: mesh,
          modelMatrix: mat,
          worldRay: ray,
          cullMode: CullMode.backFace,
        );
        expect(mh, isNotNull);
        RayHit3D? closest;
        var idx = 0;
        for (final s in mesh.surfaces) {
          final sh = RayHit3D.intersectSurface(
            owner: owner,
            surface: s,
            surfaceIndex: idx++,
            modelMatrix: mat,
            worldRay: ray,
            cullMode: CullMode.backFace,
          );
          if (sh != null &&
              (closest == null || sh.distance < closest.distance)) {
            closest = sh;
          }
        }
        expect(closest, isNotNull);
        expect(mh!.distance, closeTo(closest!.distance, 1e-5));
        expect(mh.worldNormal.distanceTo(closest.worldNormal), lessThan(1e-5));
      }
    });

    test('BuoyancyVolume3D skips dry calm bodies while waking submerged ones '
        'and RaycastVehicle3D matches BVH vs scan', () {
      final water = BuoyancyVolume3D();
      final drySleeping = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.5)),
        position: Vector3(0.0, 5.0, 0.0),
        isSleeping: true,
      );
      final wetBody = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3.all(0.5)),
        position: Vector3(0.0, -0.4, 0.0),
      );
      water.applyToBodies([drySleeping, wetBody], 1 / 60);
      expect(drySleeping.accumulatedForce.length2, 0.0);
      expect(drySleeping.isSleeping, isTrue);
      expect(wetBody.accumulatedForce.y, greaterThan(0.0));

      // Vehicle BVH raycast vs linear scan parity.
      RaycastVehicle3D makeVehicle(RigidBody3D chassis) =>
          RaycastVehicle3D.fourWheel(chassis: chassis)..throttle = 0.5;

      final worldA = PhysicsWorld3D(autoStep: false);
      final floorA = RigidBody3D(
        bodyType: BodyType3D.static,
        shape: BoxShape3D(halfExtents: Vector3(20.0, 0.5, 20.0)),
        position: Vector3(0.0, -0.5, 0.0),
      );
      final chA = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3(0.9, 0.35, 2.0)),
        mass: 600.0,
        position: Vector3(0.0, 0.7, 0.0),
      );
      final vA = makeVehicle(chA);
      worldA
        ..addBody(floorA)
        ..addBody(chA)
        ..addVehicle(vA);

      final floorB = RigidBody3D(
        bodyType: BodyType3D.static,
        shape: BoxShape3D(halfExtents: Vector3(20.0, 0.5, 20.0)),
        position: Vector3(0.0, -0.5, 0.0),
      );
      final chB = RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3(0.9, 0.35, 2.0)),
        mass: 600.0,
        position: Vector3(0.0, 0.7, 0.0),
      );
      final vB = makeVehicle(chB);

      for (var i = 0; i < 10; i++) {
        worldA.step(1 / 60);
        // Step vehicle without bodyBroadphase on worldB bodies, then compare.
        vB.stepVehicle(1 / 60, bodies: [floorB, chB]);
      }
      expect(vA.groundedWheelCount, 4);
      expect(vB.groundedWheelCount, 4);
      for (var w = 0; w < 4; w++) {
        expect(
          vA.wheelStates[w].suspensionLength,
          closeTo(vB.wheelStates[w].suspensionLength, 0.15),
        );
      }
    });

    test(
      'XpbdCloth3D and XpbdRope3D pre-transformed colliders & tube rings',
      () {
        final cloth = XpbdCloth3D(
          columns: 6,
          rows: 6,
          sphereColliders: [
            XpbdSphereCollider3D(center: Vector3(0.0, 0.0, 0.1), radius: 0.4),
          ],
        );
        for (var i = 0; i < 15; i++) {
          cloth.step(1 / 60);
        }
        for (var v = 0; v < cloth.vertexCount; v++) {
          final p = cloth.getVertexPosition(v);
          expect(
            p.distanceTo(Vector3(0.0, 0.0, 0.1)),
            greaterThanOrEqualTo(0.4 + cloth.particleThickness - 1e-2),
          );
        }

        final rope = XpbdRope3D(
          startPoint: Vector3(0.0, 1.0, 0.0),
          endPoint: Vector3(0.0, 0.0, 0.0),
          segmentCount: 8,
          sphereColliders: [
            XpbdSphereCollider3D(center: Vector3(0.0, 0.5, 0.0), radius: 0.2),
          ],
        );
        for (var i = 0; i < 15; i++) {
          rope.step(1 / 60);
        }
        for (var p = 0; p < rope.particleCount; p++) {
          expect(
            rope.getParticlePosition(p).distanceTo(Vector3(0.0, 0.5, 0.0)),
            greaterThanOrEqualTo(0.2 + rope.radius - 1e-2),
          );
        }
      },
    );

    test('NavMesh SAT obstacle query, NavMeshBuilder3D, and CrowdSteering3D '
        'RVO avoidance & timing', () {
      final mesh = NavMesh3D.fromIndexedTriangles(
        vertices: [
          Vector3(-5, 0, -5),
          Vector3(5, 0, -5),
          Vector3(5, 0, 5),
          Vector3(-5, 0, 5),
        ],
        triangles: [
          (0, 2, 1, Vector3(0, 1, 0)),
          (0, 3, 2, Vector3(0, 1, 0)),
        ],
      );
      // Center-piercing obstacle box (vertices all outside triangle, diagonal
      // edge crosses box interior -> checks edge-box SAT axes!).
      final count = mesh.setRegionCostInAabb(
        Aabb3.minMax(Vector3(-0.2, -0.5, -0.2), Vector3(0.2, 0.5, 0.2)),
        5.0,
      );
      expect(count, 2);

      // Dense crowd 64 agents moving toward opposite sides without overlap.
      final agents = <CrowdAgent3D>[];
      for (var i = 0; i < 64; i++) {
        final angle = (i / 64) * math.pi * 2.0;
        final a =
            CrowdAgent3D(
              position: Vector3(
                math.cos(angle) * 8.0,
                0.0,
                math.sin(angle) * 8.0,
              ),
              radius: 0.35,
            )..setPath([
              Vector3(-math.cos(angle) * 8.0, 0.0, -math.sin(angle) * 8.0),
            ]);
        agents.add(a);
      }
      final crowd = CrowdSteering3D(agents: agents);
      final sw = Stopwatch()..start();
      for (var step = 0; step < 30; step++) {
        crowd.update(1 / 60);
      }
      sw.stop();
      // ignore: avoid_print
      print(
        'Wave 3 microbench: 64-agent CrowdSteering x30 = '
        '${sw.elapsedMicroseconds} us',
      );
      for (var i = 0; i < agents.length; i++) {
        for (var j = i + 1; j < agents.length; j++) {
          expect(
            agents[i].position.distanceTo(agents[j].position),
            greaterThanOrEqualTo(0.68),
          );
        }
      }
    });
  });
}
