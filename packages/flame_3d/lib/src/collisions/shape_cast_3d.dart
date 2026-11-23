import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/components.dart' show Component;
import 'package:flame_3d/camera.dart' show World3D;
import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart' show ModelComponent;
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';

part 'shape_cast_gjk_3d.dart';

/// Time-of-impact (`toi` in `[0..1]`) hit returned by [ShapeCast3D].
class ShapeCastHit3D({
  required final double toi,
  required final double distance,
  required final Vector3 point,
  required final Vector3 normal,
  final Component3D? component,
  final Collider3D? collider,
});

/// Continuous swept 3D shape-casting (`sphereCast`, `capsuleCast`, and
/// `convexCast`) against [CollisionSystem3D] colliders and static
/// [MeshComponent] / [TerrainMesh3D] / [ModelComponent] surfaces.
abstract final class ShapeCast3D._() {
  /// Sweeps a sphere of [radius] from [origin] along [delta], returning the
  /// earliest [ShapeCastHit3D] (`toi` in `[0..1]`) or `null` when clear.
  static ShapeCastHit3D? sphereCast({
    required Vector3 origin,
    required double radius,
    required Vector3 delta,
    CollisionSystem3D? collisionSystem,
    World3D? world,
    Iterable<Object3D>? staticGeometry,
    int collisionMask = 0xFFFFFFFF,
    bool includeTriggers = false,
    bool Function(Component3D candidate)? filter,
  }) {
    final shape = SphereShape3D(radius: radius);
    _startMat.setIdentity();
    _startMat.setTranslation(origin);
    return convexCast(
      shape: shape,
      startTransform: _startMat,
      delta: delta,
      collisionSystem: collisionSystem,
      world: world,
      staticGeometry: staticGeometry,
      collisionMask: collisionMask,
      includeTriggers: includeTriggers,
      filter: filter,
    );
  }

  /// Sweeps a capsule of [radius] and total [height] aligned to [axis] (with
  /// optional [rotation]) from [origin] along [delta], returning the earliest
  /// [ShapeCastHit3D] (`toi` in `[0..1]`) or `null` when clear.
  static ShapeCastHit3D? capsuleCast({
    required Vector3 origin,
    required double radius,
    required double height,
    required Vector3 delta,
    Axis3D axis = Axis3D.y,
    Quaternion? rotation,
    CollisionSystem3D? collisionSystem,
    World3D? world,
    Iterable<Object3D>? staticGeometry,
    int collisionMask = 0xFFFFFFFF,
    bool includeTriggers = false,
    bool Function(Component3D candidate)? filter,
  }) {
    final shape = CapsuleShape3D(radius: radius, height: height, axis: axis);
    _startMat.setFromTranslationRotationScale(
      origin,
      rotation ?? _identityQuat,
      _unitScale,
    );
    return convexCast(
      shape: shape,
      startTransform: _startMat,
      delta: delta,
      collisionSystem: collisionSystem,
      world: world,
      staticGeometry: staticGeometry,
      collisionMask: collisionMask,
      includeTriggers: includeTriggers,
      filter: filter,
    );
  }

  /// Sweeps a [shape] (convex or [CompoundShape3D]) from [startTransform]
  /// along [delta].
  static ShapeCastHit3D? convexCast({
    required Shape3D shape,
    required Matrix4 startTransform,
    required Vector3 delta,
    CollisionSystem3D? collisionSystem,
    World3D? world,
    Iterable<Object3D>? staticGeometry,
    int collisionMask = 0xFFFFFFFF,
    bool includeTriggers = false,
    bool Function(Component3D candidate)? filter,
  }) {
    if (shape is CompoundShape3D) {
      ShapeCastHit3D? bestCompound;
      final childStart = Matrix4.identity();
      for (var i = 0; i < shape.children.length; i++) {
        final child = shape.children[i];
        childStart
          ..setFrom(startTransform)
          ..multiply(child.localTransform);
        final hit = convexCast(
          shape: child.shape,
          startTransform: childStart,
          delta: delta,
          collisionSystem: collisionSystem,
          world: world,
          staticGeometry: staticGeometry,
          collisionMask: collisionMask,
          includeTriggers: includeTriggers,
          filter: filter,
        );
        if (hit != null &&
            (bestCompound == null || hit.toi < bestCompound.toi)) {
          bestCompound = hit;
        }
      }
      return bestCompound;
    }

    final sweepLen2 = delta.length2;
    if (sweepLen2 <= 1e-16) {
      return null;
    }
    final sweepLen = math.sqrt(sweepLen2);

    shape.computeWorldAabb(startTransform, _aabbStart);
    _endMat.setFrom(startTransform);
    _endMat.storage[12] += delta.x;
    _endMat.storage[13] += delta.y;
    _endMat.storage[14] += delta.z;
    shape.computeWorldAabb(_endMat, _aabbEnd);

    _sweptAabb
      ..min.setValues(
        math.min(_aabbStart.min.x, _aabbEnd.min.x),
        math.min(_aabbStart.min.y, _aabbEnd.min.y),
        math.min(_aabbStart.min.z, _aabbEnd.min.z),
      )
      ..max.setValues(
        math.max(_aabbStart.max.x, _aabbEnd.max.x),
        math.max(_aabbStart.max.y, _aabbEnd.max.y),
        math.max(_aabbStart.max.z, _aabbEnd.max.z),
      );

    ShapeCastHit3D? best;
    var maxToi = 1.0;

    // 1. Test against CollisionSystem3D colliders.
    if (collisionSystem != null) {
      final colliders = collisionSystem.collectColliders(_colliderScratch);
      for (var i = 0; i < colliders.length; i++) {
        final c = colliders[i];
        if (!includeTriggers && c.isTrigger) {
          continue;
        }
        if ((c.collisionLayer & collisionMask) == 0) {
          continue;
        }
        final host = c.hostComponent;
        if (filter != null && (!filter(c) || !filter(host))) {
          continue;
        }
        final box = c.colliderWorldAabb;
        if (!aabbOverlaps(_sweptAabb, box)) {
          continue;
        }
        final hit = _sweepShapeAgainstCollider(
          shape,
          startTransform,
          delta,
          sweepLen,
          c,
          maxToi,
        );
        if (hit != null && hit.toi <= maxToi) {
          maxToi = hit.toi;
          best = hit;
        }
      }
    }

    // 2. Test against static Object3D geometry (`staticGeometry` + `world`).
    void testObject(Object3D obj) {
      if (filter != null && !filter(obj)) {
        return;
      }
      if (!aabbOverlaps(_sweptAabb, obj.aabb)) {
        return;
      }
      if (obj is MeshComponent) {
        final hit = _sweepShapeAgainstMesh(
          shape,
          startTransform,
          delta,
          sweepLen,
          obj,
          obj.mesh,
          obj.worldTransformMatrix,
          maxToi,
        );
        if (hit != null && hit.toi <= maxToi) {
          maxToi = hit.toi;
          best = hit;
        }
      } else if (obj is ModelComponent) {
        final ws = obj.evaluatePose();
        for (final node in ws.orderedNodes) {
          final mesh = node.node.mesh;
          if (mesh == null) {
            continue;
          }
          _nodeMat
            ..setFrom(obj.worldTransformMatrix)
            ..multiply(node.combinedTransform);
          final hit = _sweepShapeAgainstMesh(
            shape,
            startTransform,
            delta,
            sweepLen,
            obj,
            mesh,
            _nodeMat,
            maxToi,
          );
          if (hit != null && hit.toi <= maxToi) {
            maxToi = hit.toi;
            best = hit;
          }
        }
      }
    }

    if (staticGeometry != null) {
      for (final obj in staticGeometry) {
        testObject(obj);
      }
    }

    if (world != null) {
      void visit(Component comp) {
        if (comp is Component3D) {
          if (!aabbOverlaps(_sweptAabb, comp.aabb)) {
            return;
          }
          if (comp is Object3D) {
            // Avoid double-testing if already passed in `staticGeometry`.
            var alreadyTested = false;
            if (staticGeometry != null) {
              for (final s in staticGeometry) {
                if (identical(s, comp)) {
                  alreadyTested = true;
                  break;
                }
              }
            }
            if (!alreadyTested) {
              testObject(comp);
            }
          }
        }
        for (final child in comp.children) {
          visit(child);
        }
      }

      for (final child in world.children) {
        visit(child);
      }
    }

    return best;
  }

  /// Sweeps [shapeA] (at [startTransformA]) along [delta] against [shapeB]
  /// (at [transformB]) up to [maxToi], returning a [ShapeCastHit3D] or `null`.
  static ShapeCastHit3D? castShapeAgainstShape({
    required Shape3D shapeA,
    required Matrix4 startTransformA,
    required Vector3 delta,
    required Shape3D shapeB,
    required Matrix4 transformB,
    double maxToi = 1.0,
    Component3D? component,
    Collider3D? collider,
  }) {
    final sweepLen2 = delta.length2;
    if (sweepLen2 <= 1e-16 || !(maxToi >= 0.0)) {
      return null;
    }
    final sweepLen = math.sqrt(sweepLen2);
    final res = _sweepArbitraryShapes(
      shapeA,
      startTransformA,
      delta,
      shapeB,
      transformB,
      maxToi,
    );
    if (res == null) {
      return null;
    }
    return ShapeCastHit3D(
      toi: res.toi,
      distance: res.toi * sweepLen,
      point: res.point,
      normal: res.normal,
      component: component,
      collider: collider,
    );
  }

  static ShapeCastHit3D? _sweepShapeAgainstCollider(
    Shape3D shapeA,
    Matrix4 startA,
    Vector3 delta,
    double sweepLen,
    Collider3D colliderB,
    double maxToi,
  ) {
    final matB = colliderB.colliderWorldMatrix;
    final shapeB = colliderB.shape;
    final res = _sweepArbitraryShapes(
      shapeA,
      startA,
      delta,
      shapeB,
      matB,
      maxToi,
    );
    if (res == null) {
      return null;
    }
    return ShapeCastHit3D(
      toi: res.toi,
      distance: res.toi * sweepLen,
      point: res.point,
      normal: res.normal,
      component: colliderB.hostComponent,
      collider: colliderB,
    );
  }

  static _SweepResult? _sweepArbitraryShapes(
    Shape3D shapeA,
    Matrix4 startA,
    Vector3 delta,
    Shape3D shapeB,
    Matrix4 matB,
    double initialMaxToi,
  ) {
    if (shapeA is CompoundShape3D) {
      _SweepResult? best;
      var limit = initialMaxToi;
      final childStart = Matrix4.identity();
      for (var i = 0; i < shapeA.children.length; i++) {
        final child = shapeA.children[i];
        childStart
          ..setFrom(startA)
          ..multiply(child.localTransform);
        final hit = _sweepArbitraryShapes(
          child.shape,
          childStart,
          delta,
          shapeB,
          matB,
          limit,
        );
        if (hit != null && hit.toi <= limit) {
          limit = hit.toi;
          best = hit;
        }
      }
      return best;
    }

    if (shapeB is CompoundShape3D) {
      _SweepResult? best;
      var limit = initialMaxToi;
      final sweptBox = Aabb3();
      final boxStart = Aabb3();
      final boxEnd = Aabb3();
      final endMat = Matrix4.copy(startA);
      endMat.storage[12] += delta.x * limit;
      endMat.storage[13] += delta.y * limit;
      endMat.storage[14] += delta.z * limit;
      shapeA.computeWorldAabb(startA, boxStart);
      shapeA.computeWorldAabb(endMat, boxEnd);
      sweptBox
        ..min.setValues(
          math.min(boxStart.min.x, boxEnd.min.x),
          math.min(boxStart.min.y, boxEnd.min.y),
          math.min(boxStart.min.z, boxEnd.min.z),
        )
        ..max.setValues(
          math.max(boxStart.max.x, boxEnd.max.x),
          math.max(boxStart.max.y, boxEnd.max.y),
          math.max(boxStart.max.z, boxEnd.max.z),
        );

      final childMat = Matrix4.identity();
      final childBox = Aabb3();
      for (var i = 0; i < shapeB.children.length; i++) {
        final child = shapeB.children[i];
        childMat
          ..setFrom(matB)
          ..multiply(child.localTransform);
        child.shape.computeWorldAabb(childMat, childBox);
        if (!aabbOverlaps(sweptBox, childBox)) {
          continue;
        }
        final hit = _sweepArbitraryShapes(
          shapeA,
          startA,
          delta,
          child.shape,
          childMat,
          limit,
        );
        if (hit != null && hit.toi <= limit) {
          limit = hit.toi;
          best = hit;
        }
      }
      return best;
    }

    if (shapeB is HeightfieldShape3D) {
      return _sweepConvexAgainstHeightfield(
        shapeA,
        startA,
        delta,
        shapeB,
        matB,
        initialMaxToi,
      );
    }

    if (shapeA is HeightfieldShape3D) {
      // Sweeping heightfield by `delta` equals sweeping `shapeB` by `-delta`.
      final negDelta = Vector3(-delta.x, -delta.y, -delta.z);
      final rev = _sweepConvexAgainstHeightfield(
        shapeB,
        matB,
        negDelta,
        shapeA,
        startA,
        initialMaxToi,
      );
      if (rev == null) {
        return null;
      }
      return _SweepResult(
        toi: rev.toi,
        point: rev.point + delta * rev.toi,
        normal: -rev.normal,
      );
    }

    return _gjkConvexSweep(
      (dir, out) => shapeA.supportPoint(dir, startA, out),
      (dir, out) => shapeB.supportPoint(dir, matB, out),
      () => Narrowphase3D.test(shapeA, startA, shapeB, matB),
      centerOfMatrix3D(startA, _cA),
      centerOfMatrix3D(matB, _cB),
      delta,
      initialMaxToi,
    );
  }

  static _SweepResult? _sweepConvexAgainstHeightfield(
    Shape3D shapeA,
    Matrix4 startA,
    Vector3 delta,
    HeightfieldShape3D hf,
    Matrix4 hfMat,
    double initialMaxToi,
  ) {
    final invHf = Matrix4.copy(hfMat);
    if (invHf.invert().abs() < 1e-15) {
      return null;
    }

    final boxStart = Aabb3();
    final boxEnd = Aabb3();
    final endMat = Matrix4.copy(startA);
    endMat.storage[12] += delta.x * initialMaxToi;
    endMat.storage[13] += delta.y * initialMaxToi;
    endMat.storage[14] += delta.z * initialMaxToi;
    shapeA.computeWorldAabb(startA, boxStart);
    shapeA.computeWorldAabb(endMat, boxEnd);

    final localSwept = Aabb3.minMax(
      Vector3(
        math.min(boxStart.min.x, boxEnd.min.x),
        math.min(boxStart.min.y, boxEnd.min.y),
        math.min(boxStart.min.z, boxEnd.min.z),
      ),
      Vector3(
        math.max(boxStart.max.x, boxEnd.max.x),
        math.max(boxStart.max.y, boxEnd.max.y),
        math.max(boxStart.max.z, boxEnd.max.z),
      ),
    )..transform(invHf);

    if (localSwept.max.y < hf.minHeight - 1e-4 ||
        localSwept.min.y > hf.maxHeight + 1e-4) {
      return null;
    }
    final range = hf.cellRangeForLocalBounds(
      localSwept.min.x,
      localSwept.max.x,
      localSwept.min.z,
      localSwept.max.z,
    );
    if (range == null) {
      return null;
    }

    final (c0, c1, r0, r1) = range;
    final m = hfMat.storage;
    final lv00 = Vector3.zero();
    final lv01 = Vector3.zero();
    final lv11 = Vector3.zero();
    final lv10 = Vector3.zero();
    final wv00 = Vector3.zero();
    final wv01 = Vector3.zero();
    final wv11 = Vector3.zero();
    final wv10 = Vector3.zero();
    final triC = Vector3.zero();

    _SweepResult? best;
    var limit = initialMaxToi;

    for (var r = r0; r <= r1; r++) {
      for (var c = c0; c <= c1; c++) {
        hf.writeCellVerticesLocal(c, r, lv00, lv01, lv11, lv10);
        final cellMinY = math.min(
          math.min(lv00.y, lv01.y),
          math.min(lv11.y, lv10.y),
        );
        final cellMaxY = math.max(
          math.max(lv00.y, lv01.y),
          math.max(lv11.y, lv10.y),
        );
        if (localSwept.max.y < cellMinY - 1e-4 ||
            localSwept.min.y > cellMaxY + 1e-4) {
          continue;
        }

        transformPoint3D(m, lv00.x, lv00.y, lv00.z, wv00);
        transformPoint3D(m, lv01.x, lv01.y, lv01.z, wv01);
        transformPoint3D(m, lv11.x, lv11.y, lv11.z, wv11);
        transformPoint3D(m, lv10.x, lv10.y, lv10.z, wv10);

        triC.setValues(
          (wv00.x + wv01.x + wv11.x) * (1.0 / 3.0),
          (wv00.y + wv01.y + wv11.y) * (1.0 / 3.0),
          (wv00.z + wv01.z + wv11.z) * (1.0 / 3.0),
        );
        final hit0 = _gjkConvexSweep(
          (dir, out) => shapeA.supportPoint(dir, startA, out),
          (dir, out) => triangleSupport3D(wv00, wv01, wv11, dir, out),
          () => Narrowphase3D.intersectShapeWithTriangle(
            shapeA,
            startA,
            wv00,
            wv01,
            wv11,
          ),
          centerOfMatrix3D(startA, _cA),
          triC,
          delta,
          limit,
        );
        if (hit0 != null && hit0.toi <= limit) {
          limit = hit0.toi;
          best = hit0;
        }

        triC.setValues(
          (wv00.x + wv11.x + wv10.x) * (1.0 / 3.0),
          (wv00.y + wv11.y + wv10.y) * (1.0 / 3.0),
          (wv00.z + wv11.z + wv10.z) * (1.0 / 3.0),
        );
        final hit1 = _gjkConvexSweep(
          (dir, out) => shapeA.supportPoint(dir, startA, out),
          (dir, out) => triangleSupport3D(wv00, wv11, wv10, dir, out),
          () => Narrowphase3D.intersectShapeWithTriangle(
            shapeA,
            startA,
            wv00,
            wv11,
            wv10,
          ),
          centerOfMatrix3D(startA, _cA),
          triC,
          delta,
          limit,
        );
        if (hit1 != null && hit1.toi <= limit) {
          limit = hit1.toi;
          best = hit1;
        }
      }
    }
    return best;
  }

  static ShapeCastHit3D? _sweepShapeAgainstMesh(
    Shape3D shapeA,
    Matrix4 startA,
    Vector3 delta,
    double sweepLen,
    Object3D owner,
    Mesh mesh,
    Matrix4 meshMatrix,
    double initialMaxToi,
  ) {
    _invMesh.setFrom(meshMatrix);
    if (_invMesh.invert().abs() < 1e-15) {
      return null;
    }

    _localSweptAabb
      ..setFrom(_sweptAabb)
      ..transform(_invMesh);

    ShapeCastHit3D? best;
    var maxToi = initialMaxToi;
    final m = meshMatrix.storage;

    for (final surface in mesh.surfaces) {
      if (surface.indexCount < 3 ||
          !aabbOverlaps(_localSweptAabb, surface.aabb)) {
        continue;
      }
      final bvhRef = surface.bvh;
      if (bvhRef.triangleCount == 0) {
        continue;
      }
      _triCandidates.clear();
      bvhRef.queryAabb(_localSweptAabb, _triCandidates);
      if (_triCandidates.isEmpty) {
        continue;
      }

      final positions = surface.positions;
      final indices = surface.indices;

      for (var i = 0; i < _triCandidates.length; i++) {
        final tri = _triCandidates[i];
        final base = tri * 3;
        final i0 = indices[base] * 3;
        final i1 = indices[base + 1] * 3;
        final i2 = indices[base + 2] * 3;

        transformPoint3D(
          m,
          positions[i0],
          positions[i0 + 1],
          positions[i0 + 2],
          _tv0,
        );
        transformPoint3D(
          m,
          positions[i1],
          positions[i1 + 1],
          positions[i1 + 2],
          _tv1,
        );
        transformPoint3D(
          m,
          positions[i2],
          positions[i2 + 1],
          positions[i2 + 2],
          _tv2,
        );

        _triCenter.setValues(
          (_tv0.x + _tv1.x + _tv2.x) * (1.0 / 3.0),
          (_tv0.y + _tv1.y + _tv2.y) * (1.0 / 3.0),
          (_tv0.z + _tv1.z + _tv2.z) * (1.0 / 3.0),
        );

        final res = _gjkConvexSweep(
          (dir, out) => shapeA.supportPoint(dir, startA, out),
          (dir, out) => triangleSupport3D(_tv0, _tv1, _tv2, dir, out),
          () => Narrowphase3D.intersectShapeWithTriangle(
            shapeA,
            startA,
            _tv0,
            _tv1,
            _tv2,
          ),
          centerOfMatrix3D(startA, _cA),
          _triCenter,
          delta,
          maxToi,
        );
        if (res != null && res.toi <= maxToi) {
          maxToi = res.toi;
          best = ShapeCastHit3D(
            toi: res.toi,
            distance: res.toi * sweepLen,
            point: res.point,
            normal: res.normal,
            component: owner,
          );
        }
      }
    }
    return best;
  }
}
