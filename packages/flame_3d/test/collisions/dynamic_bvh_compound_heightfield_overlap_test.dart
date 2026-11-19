import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DynamicAabbTree3D incremental SAH BVH & fat-AABB hysteresis', () {
    test(
      'maintains AVL balance, zero churn on small jitter, and accurate '
      'AABB/sphere/frustum/raycast queries',
      () {
        final tree = DynamicAabbTree3D<int>();
        final proxies = <int>[];

        for (var i = 0; i < 128; i++) {
          final x = (i % 16) * 2.0;
          final z = (i ~/ 16) * 2.0;
          final box = Aabb3.minMax(
            Vector3(x - 0.4, -0.4, z - 0.4),
            Vector3(x + 0.4, 0.4, z + 0.4),
          );
          proxies.add(tree.insert(i, box));
        }

        expect(tree.leafCount, 128);
        expect(tree.validateStructure(), isTrue);
        expect(tree.height, lessThanOrEqualTo(12));

        // Small jitter (`0.05 < fatMargin = 0.12`) causes ZERO tree churn!
        tree.resetTelemetry();
        for (var i = 0; i < 128; i++) {
          final x = (i % 16) * 2.0 + 0.05;
          final z = (i ~/ 16) * 2.0 - 0.04;
          final moved = tree.update(
            proxies[i],
            Aabb3.minMax(
              Vector3(x - 0.4, -0.4, z - 0.4),
              Vector3(x + 0.4, 0.4, z + 0.4),
            ),
          );
          expect(moved, isFalse);
        }
        expect(tree.reinsertCount, 0);
        expect(tree.validateStructure(), isTrue);

        // Large teleport beyond fat AABB triggers reinsertion & keeps balance.
        final reinserted = tree.update(
          proxies[0],
          Aabb3.minMax(
            Vector3(100.0, -0.4, 100.0),
            Vector3(100.8, 0.4, 100.8),
          ),
          displacement: Vector3(1.0, 0.0, 1.0),
        );
        expect(reinserted, isTrue);
        expect(tree.reinsertCount, 1);
        expect(tree.validateStructure(), isTrue);

        final farQuery = tree.queryAabb(
          Aabb3.minMax(Vector3(99.5, -1, 99.5), Vector3(101.5, 1, 101.5)),
        );
        expect(farQuery, equals([0]));

        // Sphere query around `(4.0, 0.0, 4.0)` (`i = 2 + 2 * 16 = 34`).
        final sphereHits = tree.querySphere(Vector3(4.0, 0.0, 4.0), 0.6);
        expect(sphereHits, contains(34));
        expect(sphereHits, isNot(contains(0)));

        // Raycast & raycastAll along +X through row `z = 2.0` (`r = 1`).
        final ray = Ray.originDirection(
          Vector3(-5.0, 0.0, 2.0),
          Vector3(1.0, 0.0, 0.0),
        );
        final firstHit = tree.raycast(ray);
        expect(firstHit, isNotNull);
        expect(firstHit!.item, 16); // `(c = 0, r = 1)`

        final allHits = tree.raycastAll(ray, maxDistance: 7.0);
        expect(allHits.map((h) => h.item).toList(), equals([16, 17]));

        // Remove half the proxies and verify invariants hold.
        for (var i = 0; i < 64; i++) {
          tree.remove(proxies[i]);
        }
        expect(tree.leafCount, 64);
        expect(tree.validateStructure(), isTrue);
      },
    );
  });

  group('CollisionSystem3D narrowphase spatial overlap queries', () {
    test(
      'overlapSphere, overlapBox, overlapCapsule, and overlapFrustum '
      'confirm narrowphase geometry and honor layer masks',
      () {
        final system = CollisionSystem3D(autoStep: false);

        final sphereCol = Collider3D(
          shape: SphereShape3D(radius: 0.5),
          position: Vector3(0.0, 0.0, -5.0),
        );
        // Rotated thin rod whose world AABB overlaps `(1.2, 1.2, -5)` corner,
        // allowing us to verify true narrowphase confirmation vs AABB-only!
        final rotatedBoxCol = Collider3D(
          shape: BoxShape3D(halfExtents: Vector3(2.0, 0.15, 0.15)),
          position: Vector3(0.0, 2.0, -5.0),
          rotation: Quaternion.axisAngle(Vector3(0, 0, 1), math.pi / 4),
          collisionLayer: 0x02,
        );
        final farBehindCamera = Collider3D(
          shape: SphereShape3D(radius: 1.0),
          position: Vector3(0.0, 0.0, 15.0),
        );
        final maskedOutCol = Collider3D(
          shape: SphereShape3D(radius: 0.5),
          position: Vector3(0.0, 0.0, -5.0),
          collisionLayer: 0x08,
        );

        system
          ..register(sphereCol)
          ..register(rotatedBoxCol)
          ..register(farBehindCamera)
          ..register(maskedOutCol);

        // 1. overlapSphere: hits `sphereCol`, excludes `maskedOutCol` by mask,
        // and rejects AABB corner of `rotatedBoxCol` where actual rod misses!
        final sHits = system.overlapSphere(
          Vector3(0.0, 0.0, -5.0),
          0.6,
          mask: 0x01 | 0x02,
        );
        expect(sHits, equals([sphereCol]));

        final rodFalseCorner = system.overlapSphere(
          Vector3(-1.1, 3.1, -5.0), // Inside rotated AABB, far from 45-deg rod!
          0.2,
          mask: 0x02,
        );
        expect(rodFalseCorner, isEmpty);

        // 2. overlapBox with custom orientation hits the 45-deg rod at center.
        final bHits = system.overlapBox(
          Vector3(0.8, 2.8, -5.0),
          Vector3(0.25, 0.25, 0.25),
          rotation: Quaternion.axisAngle(Vector3(0, 0, 1), math.pi / 4),
          mask: 0x02,
        );
        expect(bHits, equals([rotatedBoxCol]));

        // 3. overlapCapsule along diagonal segment hitting both `sphereCol` and
        // `rotatedBoxCol`.
        final capHits = system.overlapCapsule(
          Vector3(0.0, -0.2, -5.0),
          Vector3(0.0, 2.2, -5.0),
          0.25,
          mask: 0x01 | 0x02,
        );
        expect(capHits, containsAll([sphereCol, rotatedBoxCol]));
        expect(capHits, isNot(contains(farBehindCamera)));

        // 4. overlapFrustum looking along `-Z` from origin.
        final proj = Matrix4.identity()..setAsPerspective(60.0, 1.0, 0.5, 25.0);
        final view = Matrix4.identity()
          ..setAsViewMatrix(
            Vector3.zero(),
            Vector3(0.0, 0.5, -5.0),
            Vector3(0.0, 1.0, 0.0),
          );
        final vp = proj.multiplied(view);
        final frustum = Frustum()..setFromViewProjection(vp);

        final fHits = system.overlapFrustum(frustum, mask: 0x01 | 0x02);
        expect(fHits, containsAll([sphereCol, rotatedBoxCol]));
        expect(fHits, isNot(contains(farBehindCamera)));
        expect(fHits, isNot(contains(maskedOutCol)));
      },
    );
  });

  group('CompoundShape3D, HeightfieldShape3D & PhysicsMaterial3D', () {
    test(
      'CompoundShape3D computes exact Huygens-Steiner inertia, center of mass, '
      'raycast, and concave narrowphase contacts',
      () {
        // Symmetric dumbbell: two `r = 0.5` spheres at `(-2, 0, 0)` and
        // `(+2, 0, 0)` with total mass `10 kg` (`5 kg` each).
        final sphere = SphereShape3D(radius: 0.5);
        final dumbbell = CompoundShape3D([
          CompoundChildShape3D(
            shape: sphere,
            position: Vector3(-2.0, 0.0, 0.0),
          ),
          CompoundChildShape3D(shape: sphere, position: Vector3(2.0, 0.0, 0.0)),
        ]);

        expect(dumbbell.centerOfMass.length, lessThan(1e-6));
        final aabb = dumbbell.computeLocalAabb();
        expect(aabb.min.x, closeTo(-2.5, 1e-5));
        expect(aabb.max.x, closeTo(2.5, 1e-5));

        final diag = dumbbell.computeLocalInertiaDiagonal(10.0);
        // Each sphere has `I_sphere = 0.4 * 5 * 0.25 = 0.5`.
        // About X: `0.5 + 0.5 = 1.0`.
        // About Y & Z (parallel axis `d = 2.0`): `2 * (0.5 + 5 * 4.0) = 41.0`!
        expect(diag.x, closeTo(1.0, 1e-4));
        expect(diag.y, closeTo(41.0, 1e-4));
        expect(diag.z, closeTo(41.0, 1e-4));

        // Asymmetric hammer with heavy head (`massWeight = 3.0`) at `(0, 2, 0)`
        // and light handle (`massWeight = 1.0`) at `(0, 0, 0)` (equal volumes).
        final cube = BoxShape3D(halfExtents: Vector3.all(0.5));
        final hammer = CompoundShape3D([
          CompoundChildShape3D(
            shape: cube,
            position: Vector3(0.0, 0.0, 0.0),
          ),
          CompoundChildShape3D(
            shape: cube,
            position: Vector3(0.0, 2.0, 0.0),
            massWeight: 3.0,
          ),
        ]);
        // Expected CoM: `(0 * 1 + 2 * 3) / 4 = 1.5` along +Y!
        expect(hammer.centerOfMass.y, closeTo(1.5, 1e-5));

        // Concave U-cup: floor + left wall + right wall tested against a sphere
        // touching BOTH floor and left wall simultaneously (`testAll`).
        final cup = CompoundShape3D([
          CompoundChildShape3D(
            shape: BoxShape3D(halfExtents: Vector3(1.0, 0.1, 1.0)),
            position: Vector3(0.0, 0.0, 0.0),
          ),
          CompoundChildShape3D(
            shape: BoxShape3D(halfExtents: Vector3(0.1, 1.0, 1.0)),
            position: Vector3(-1.0, 1.0, 0.0),
          ),
          CompoundChildShape3D(
            shape: BoxShape3D(halfExtents: Vector3(0.1, 1.0, 1.0)),
            position: Vector3(1.0, 1.0, 0.0),
          ),
        ]);

        final ball = SphereShape3D(radius: 0.4);
        final ballInCorner = Matrix4.translationValues(-0.6, 0.4, 0.0);
        final allManifolds = Narrowphase3D.testAll(
          cup,
          Matrix4.identity(),
          ball,
          ballInCorner,
        );
        expect(allManifolds.length, 2);

        // Raycast hits left wall first when fired from `-X`.
        final hit = cup.raycast(
          Ray.originDirection(Vector3(-5.0, 0.8, 0.0), Vector3(1.0, 0.0, 0.0)),
          Matrix4.identity(),
        );
        expect(hit, isNotNull);
        expect(hit!.$1, closeTo(3.9, 1e-4));
        expect(hit.$2.x, closeTo(-1.0, 1e-4));
      },
    );

    test(
      'HeightfieldShape3D O(1) cell narrowphase, DDA raycast, sampleHeight, '
      'and PhysicsMaterial3D combine priority',
      () {
        const cols = 17;
        const rows = 17;
        final heights = Float32List(cols * rows);
        for (var r = 0; r < rows; r++) {
          final z = -8.0 + r * 1.0;
          for (var c = 0; c < cols; c++) {
            final x = -8.0 + c * 1.0;
            heights[r * cols + c] = math.sin(x * 0.4) * math.cos(z * 0.4) + 0.5;
          }
        }
        final hf = HeightfieldShape3D(
          heights: heights,
          columns: cols,
          rows: rows,
          width: 16.0,
          depth: 16.0,
          heightScale: 1.5,
        );

        // Diagonal DDA raycast across multiple hills must agree with
        // `sampleHeight` at the exact world hit point!
        final rayOrigin = Vector3(-6.0, 5.0, -5.0);
        final rayDir = Vector3(1.2, -0.8, 0.9).normalized();
        final rayHit = hf.raycast(
          Ray.originDirection(rayOrigin, rayDir),
          Matrix4.identity(),
        );
        expect(rayHit, isNotNull);
        final hitPt = rayOrigin + rayDir * rayHit!.$1;
        expect(hitPt.y, closeTo(hf.sampleHeight(hitPt.x, hitPt.z), 1e-4));
        expect(rayHit.$2.y, greaterThan(0.3));

        // Direct O(1) cell narrowphase against Sphere, Box, Capsule, ConvexHull
        // & CompoundShape3D.
        final surfY = hf.sampleHeight(1.3, -2.2);
        final sph = SphereShape3D(radius: 0.5);
        final sphManifold = Narrowphase3D.test(
          sph,
          Matrix4.translationValues(1.3, surfY + 0.3, -2.2),
          hf,
          Matrix4.identity(),
        );
        expect(sphManifold, isNotNull);
        expect(sphManifold!.normal.y, lessThan(-0.5));
        expect(sphManifold.penetrationDepth, greaterThan(0.1));

        final hull = ConvexHullShape3D(
          vertices: [
            Vector3(-0.3, -0.3, -0.3),
            Vector3(0.3, -0.3, -0.3),
            Vector3(0.0, -0.3, 0.4),
            Vector3(0.0, 0.4, 0.0),
          ],
        );
        final hullManifold = Narrowphase3D.test(
          hull,
          Matrix4.translationValues(1.3, surfY + 0.15, -2.2),
          hf,
          Matrix4.identity(),
        );
        expect(hullManifold, isNotNull);

        // PhysicsMaterial3D combine priority (`maximum > multiply > minimum >
        // average`).
        const ice = PhysicsMaterial3D(
          friction: 0.04,
          restitution: 0.1,
          frictionCombine: PhysicsCombineMode3D.minimum,
          restitutionCombine: PhysicsCombineMode3D.average,
          surfaceTag: 'ice',
        );
        const rubber = PhysicsMaterial3D(
          friction: 0.9,
          restitution: 0.85,
          surfaceTag: 'rubber',
        );
        expect(
          PhysicsMaterial3D.combineFriction(ice, rubber),
          closeTo(0.04, 1e-6),
        );
        expect(
          PhysicsMaterial3D.combineRestitution(ice, rubber),
          closeTo(0.85, 1e-6),
        );
        expect(ice.surfaceTag, 'ice');
      },
    );
  });
}
