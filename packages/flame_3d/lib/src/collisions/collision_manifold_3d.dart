import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart' show VertexLayout;
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

/// A single contact point pair inside a [CollisionManifold3D].
///
/// [featureId] names the pair of features (face, edge or vertex of each shape)
/// that produced the point. It stays the same from one step to the next while
/// the same features touch, which lets a solver carry the point's impulse
/// over (warm starting). Single-point manifolds use `0`.
class ContactPoint3D({
  required final Vector3 pointA,
  required final Vector3 pointB,
  required final double penetrationDepth,
  final int featureId = 0,
});

/// World-space contact manifold describing an overlap between two 3D shapes
/// (`A` and `B`).
///
/// [normal] is a unit vector pointing **from `A` toward `B`**, so translating
/// `A` by `-normal * penetrationDepth` (or `B` by `+normal * penetrationDepth`)
/// separates the shapes.
class CollisionManifold3D({
  required Vector3 normal,
  required final double penetrationDepth,
  required Vector3 contactPointA,
  required Vector3 contactPointB,
  List<ContactPoint3D>? contacts,
}) {
  /// Unit contact normal pointing from shape `A` toward shape `B`.
  final Vector3 normal = normal.clone();

  /// Deepest witness point on shape `A` in world space.
  final Vector3 contactPointA = contactPointA.clone();

  /// Deepest witness point on shape `B` in world space.
  final Vector3 contactPointB = contactPointB.clone();

  /// Contact points in this manifold (1 for curved shapes and edge contacts,
  /// up to 4 for face contacts between boxes and convex hulls).
  final List<ContactPoint3D> contacts = List.unmodifiable(
    contacts ??
        [
          ContactPoint3D(
            pointA: contactPointA.clone(),
            pointB: contactPointB.clone(),
            penetrationDepth: penetrationDepth,
          ),
        ],
  );

  final Vector3 _contactPoint = Vector3(
    0.5 * (contactPointA.x + contactPointB.x),
    0.5 * (contactPointA.y + contactPointB.y),
    0.5 * (contactPointA.z + contactPointB.z),
  );

  /// Midpoint between [contactPointA] and [contactPointB] in world space.
  Vector3 get contactPoint => _contactPoint;

  /// Returns the symmetric manifold oriented from `B` toward `A`.
  CollisionManifold3D flipped() {
    return CollisionManifold3D(
      normal: -normal,
      penetrationDepth: penetrationDepth,
      contactPointA: contactPointB,
      contactPointB: contactPointA,
      contacts: [
        for (final c in contacts)
          ContactPoint3D(
            pointA: c.pointB.clone(),
            pointB: c.pointA.clone(),
            penetrationDepth: c.penetrationDepth,
            featureId: c.featureId,
          ),
      ],
    );
  }
}

/// Reusable flat typed buffer of manifolds and contact points populated by
/// [Narrowphase3D.testAllInto] so physics step contact generation executes with
/// zero heap allocations for analytical primitive pairs.
@internal
class MutableManifoldBuffer3D() {
  int _manifoldCount = 0;
  int _contactCount = 0;

  // Per-manifold [nx, ny, nz, penetrationDepth] (stride 4) and
  // [contactStart, contactLength] (stride 2).
  Float64List _manifoldData = Float64List(64 * 4);
  Int32List _manifoldRanges = Int32List(64 * 2);

  // Per-contact [pax, pay, paz, pbx, pby, pbz, depth] (stride 7) + featureId.
  Float64List _contactData = Float64List(256 * 7);
  Int32List _contactFeatures = Int32List(256);

  /// Number of stored manifolds in this buffer.
  int get manifoldCount => _manifoldCount;

  /// Whether zero manifolds are currently stored.
  bool get isEmpty => _manifoldCount == 0;

  /// Whether at least one manifold is stored.
  bool get isNotEmpty => _manifoldCount > 0;

  /// Clears stored manifolds while retaining underlying typed capacity.
  @pragma('vm:prefer-inline')
  void clear() {
    _manifoldCount = 0;
    _contactCount = 0;
  }

  /// Maximum `penetrationDepth` across all stored manifolds (`0.0` if empty).
  double get maxPenetrationDepth {
    var deepest = 0.0;
    for (var m = 0; m < _manifoldCount; m++) {
      final d = _manifoldData[m * 4 + 3];
      if (d > deepest) {
        deepest = d;
      }
    }
    return deepest;
  }

  double normalX(int manifoldIndex) => _manifoldData[manifoldIndex * 4];
  double normalY(int manifoldIndex) => _manifoldData[manifoldIndex * 4 + 1];
  double normalZ(int manifoldIndex) => _manifoldData[manifoldIndex * 4 + 2];
  double depth(int manifoldIndex) => _manifoldData[manifoldIndex * 4 + 3];
  int contactStart(int manifoldIndex) => _manifoldRanges[manifoldIndex * 2];
  int contactLength(int manifoldIndex) =>
      _manifoldRanges[manifoldIndex * 2 + 1];

  double pointAX(int contactIndex) => _contactData[contactIndex * 7];
  double pointAY(int contactIndex) => _contactData[contactIndex * 7 + 1];
  double pointAZ(int contactIndex) => _contactData[contactIndex * 7 + 2];
  double pointBX(int contactIndex) => _contactData[contactIndex * 7 + 3];
  double pointBY(int contactIndex) => _contactData[contactIndex * 7 + 4];
  double pointBZ(int contactIndex) => _contactData[contactIndex * 7 + 5];
  double pointDepth(int contactIndex) => _contactData[contactIndex * 7 + 6];
  int featureId(int contactIndex) => _contactFeatures[contactIndex];

  void _ensureManifoldCapacity(int count) {
    final needed = count * 4;
    if (_manifoldData.length >= needed) {
      return;
    }
    var cap = _manifoldData.length ~/ 4;
    while (cap < count) {
      cap *= 2;
    }
    _manifoldData = Float64List(cap * 4)
      ..setRange(0, _manifoldCount * 4, _manifoldData);
    _manifoldRanges = Int32List(cap * 2)
      ..setRange(0, _manifoldCount * 2, _manifoldRanges);
  }

  void _ensureContactCapacity(int count) {
    final needed = count * 7;
    if (_contactData.length >= needed) {
      return;
    }
    var cap = _contactFeatures.length;
    while (cap < count) {
      cap *= 2;
    }
    _contactData = Float64List(cap * 7)
      ..setRange(0, _contactCount * 7, _contactData);
    _contactFeatures = Int32List(cap)
      ..setRange(0, _contactCount, _contactFeatures);
  }

  /// Appends a new manifold header and returns its `manifoldIndex`.
  int beginManifold(double nx, double ny, double nz, double depth) {
    final idx = _manifoldCount;
    _ensureManifoldCapacity(idx + 1);
    _manifoldCount = idx + 1;
    final mo = idx * 4;
    _manifoldData
      ..[mo] = nx
      ..[mo + 1] = ny
      ..[mo + 2] = nz
      ..[mo + 3] = depth;
    final ro = idx * 2;
    _manifoldRanges
      ..[ro] = _contactCount
      ..[ro + 1] = 0;
    return idx;
  }

  /// Updates the penetration depth recorded for [manifoldIndex].
  void setDepth(int manifoldIndex, double depth) {
    _manifoldData[manifoldIndex * 4 + 3] = depth;
  }

  /// Appends a contact point to [manifoldIndex].
  void addContact(
    int manifoldIndex,
    double pax,
    double pay,
    double paz,
    double pbx,
    double pby,
    double pbz,
    double depth, [
    int featureId = 0,
  ]) {
    final idx = _contactCount;
    _ensureContactCapacity(idx + 1);
    _contactCount = idx + 1;
    final co = idx * 7;
    _contactData
      ..[co] = pax
      ..[co + 1] = pay
      ..[co + 2] = paz
      ..[co + 3] = pbx
      ..[co + 4] = pby
      ..[co + 5] = pbz
      ..[co + 6] = depth;
    _contactFeatures[idx] = featureId;
    _manifoldRanges[manifoldIndex * 2 + 1]++;
  }

  /// Convenience fast path adding a single-point manifold in one call.
  void pushSingle(
    double nx,
    double ny,
    double nz,
    double depth,
    double pax,
    double pay,
    double paz,
    double pbx,
    double pby,
    double pbz, [
    int featureId = 0,
  ]) {
    final mIdx = beginManifold(nx, ny, nz, depth);
    addContact(mIdx, pax, pay, paz, pbx, pby, pbz, depth, featureId);
  }

  /// Appends an already-constructed [CollisionManifold3D] fallback result.
  void appendManifold(CollisionManifold3D manifold) {
    final n = manifold.normal;
    final mIdx = beginManifold(n.x, n.y, n.z, manifold.penetrationDepth);
    final contacts = manifold.contacts;
    for (var i = 0; i < contacts.length; i++) {
      final cp = contacts[i];
      addContact(
        mIdx,
        cp.pointA.x,
        cp.pointA.y,
        cp.pointA.z,
        cp.pointB.x,
        cp.pointB.y,
        cp.pointB.z,
        cp.penetrationDepth,
        cp.featureId,
      );
    }
  }
}

/// Narrowphase 3D intersection solver supporting analytical primitives, 15-axis
/// OBB SAT with Sutherland-Hodgman face clipping, general GJK+EPA convex
/// hulls, and `O(log T)` [Surface] triangle BVH queries.
abstract final class Narrowphase3D._() {
  /// Computes the [CollisionManifold3D] between [shapeA] at [transformA] and
  /// [shapeB] at [transformB], or `null` when separated.
  static CollisionManifold3D? test(
    Shape3D shapeA,
    Matrix4 transformA,
    Shape3D shapeB,
    Matrix4 transformB,
  ) {
    return switch ((shapeA, shapeB)) {
      (final SphereShape3D a, final SphereShape3D b) => sphereSphere(
        a,
        transformA,
        b,
        transformB,
      ),
      (final SphereShape3D a, final CapsuleShape3D b) => sphereCapsule(
        a,
        transformA,
        b,
        transformB,
      ),
      (final CapsuleShape3D a, final SphereShape3D b) => sphereCapsule(
        b,
        transformB,
        a,
        transformA,
      )?.flipped(),
      (final CapsuleShape3D a, final CapsuleShape3D b) => capsuleCapsule(
        a,
        transformA,
        b,
        transformB,
      ),
      (final SphereShape3D a, final BoxShape3D b) => sphereBox(
        a,
        transformA,
        b,
        transformB,
      ),
      (final BoxShape3D a, final SphereShape3D b) => sphereBox(
        b,
        transformB,
        a,
        transformA,
      )?.flipped(),
      (final CapsuleShape3D a, final BoxShape3D b) => capsuleBox(
        a,
        transformA,
        b,
        transformB,
      ),
      (final BoxShape3D a, final CapsuleShape3D b) => capsuleBox(
        b,
        transformB,
        a,
        transformA,
      )?.flipped(),
      (final BoxShape3D a, final BoxShape3D b) => boxBox(
        a,
        transformA,
        b,
        transformB,
      ),
      (final CompoundShape3D a, _) => _pickDeepestMerged(
        _testCompoundVsShapeAll(a, transformA, shapeB, transformB),
      ),
      (_, final CompoundShape3D b) => _pickDeepestMerged(
        _testCompoundVsShapeAll(b, transformB, shapeA, transformA),
      )?.flipped(),
      (final HeightfieldShape3D a, _) => heightfieldShape(
        shapeB,
        transformB,
        a,
        transformA,
      )?.flipped(),
      (_, final HeightfieldShape3D b) => heightfieldShape(
        shapeA,
        transformA,
        b,
        transformB,
      ),
      _ => convexConvex(shapeA, transformA, shapeB, transformB),
    };
  }

  /// Returns all distinct contact manifolds between [shapeA] (at [transformA])
  /// and [shapeB] (at [transformB]), preserving multi-normal contacts for
  /// concave [CompoundShape3D] and [HeightfieldShape3D] shapes while merging
  /// co-directional contact points.
  static List<CollisionManifold3D> testAll(
    Shape3D shapeA,
    Matrix4 transformA,
    Shape3D shapeB,
    Matrix4 transformB,
  ) {
    if (shapeA is CompoundShape3D) {
      return _mergeCoDirectionalManifolds(
        _testCompoundVsShapeAll(shapeA, transformA, shapeB, transformB),
      );
    }
    if (shapeB is CompoundShape3D) {
      final flippedAll = _testCompoundVsShapeAll(
        shapeB,
        transformB,
        shapeA,
        transformA,
      );
      if (flippedAll.isEmpty) {
        return const [];
      }
      return _mergeCoDirectionalManifolds([
        for (final m in flippedAll) m.flipped(),
      ]);
    }
    if (shapeA is HeightfieldShape3D) {
      final raw = heightfieldShapeAll(shapeB, transformB, shapeA, transformA);
      if (raw.isEmpty) {
        return const [];
      }
      return _mergeCoDirectionalManifolds([for (final m in raw) m.flipped()]);
    }
    if (shapeB is HeightfieldShape3D) {
      return _mergeCoDirectionalManifolds(
        heightfieldShapeAll(shapeA, transformA, shapeB, transformB),
      );
    }
    final single = test(shapeA, transformA, shapeB, transformB);
    return single == null ? const [] : [single];
  }

  /// Zero-allocation narrowphase entry point writing all distinct contact
  /// manifolds between [shapeA] (at [transformA]) and [shapeB] (at
  /// [transformB]) into [out] without clearing prior contents of [out].
  @internal
  static void testAllInto(
    Shape3D shapeA,
    Matrix4 transformA,
    Shape3D shapeB,
    Matrix4 transformB,
    MutableManifoldBuffer3D out,
  ) {
    switch ((shapeA, shapeB)) {
      case (final SphereShape3D a, final SphereShape3D b):
        final mA = transformA.storage;
        final mB = transformB.storage;
        _pushSphereSphereInto(
          mA[12],
          mA[13],
          mA[14],
          a.worldRadius(transformA),
          mB[12],
          mB[13],
          mB[14],
          b.worldRadius(transformB),
          out,
          flip: false,
        );
      case (final SphereShape3D a, final CapsuleShape3D b):
        _sphereCapsuleInto(a, transformA, b, transformB, out, flip: false);
      case (final CapsuleShape3D a, final SphereShape3D b):
        _sphereCapsuleInto(b, transformB, a, transformA, out, flip: true);
      case (final CapsuleShape3D a, final CapsuleShape3D b):
        final rA = a.worldSpine(transformA, _segA0, _segA1);
        final rB = b.worldSpine(transformB, _segB0, _segB1);
        _closestPointsSegmentSegment(
          _segA0,
          _segA1,
          _segB0,
          _segB1,
          _ptA,
          _ptB,
        );
        _pushSphereSphereInto(
          _ptA.x,
          _ptA.y,
          _ptA.z,
          rA,
          _ptB.x,
          _ptB.y,
          _ptB.z,
          rB,
          out,
          flip: false,
        );
      case (final SphereShape3D a, final BoxShape3D b):
        _sphereBoxInto(a, transformA, b, transformB, out, flip: false);
      case (final BoxShape3D a, final SphereShape3D b):
        _sphereBoxInto(b, transformB, a, transformA, out, flip: true);
      case (final CapsuleShape3D a, final BoxShape3D b):
        _capsuleBoxInto(a, transformA, b, transformB, out, flip: false);
      case (final BoxShape3D a, final CapsuleShape3D b):
        _capsuleBoxInto(b, transformB, a, transformA, out, flip: true);
      case (final BoxShape3D a, final BoxShape3D b):
        _boxBoxInto(a, transformA, b, transformB, out);
      default:
        final list = testAll(shapeA, transformA, shapeB, transformB);
        for (var i = 0; i < list.length; i++) {
          out.appendManifold(list[i]);
        }
    }
  }

  static void _sphereCapsuleInto(
    SphereShape3D a,
    Matrix4 transformA,
    CapsuleShape3D b,
    Matrix4 transformB,
    MutableManifoldBuffer3D out, {
    required bool flip,
  }) {
    final mA = transformA.storage;
    final cAx = mA[12];
    final cAy = mA[13];
    final cAz = mA[14];
    final rA = a.worldRadius(transformA);
    final rB = b.worldSpine(transformB, _segB0, _segB1);
    _closestPointOnSegment(cAx, cAy, cAz, _segB0, _segB1, _ptB);
    _pushSphereSphereInto(
      cAx,
      cAy,
      cAz,
      rA,
      _ptB.x,
      _ptB.y,
      _ptB.z,
      rB,
      out,
      flip: flip,
    );
  }

  static void _sphereBoxInto(
    SphereShape3D a,
    Matrix4 transformA,
    BoxShape3D b,
    Matrix4 transformB,
    MutableManifoldBuffer3D out, {
    required bool flip,
  }) {
    final mA = transformA.storage;
    final rA = a.worldRadius(transformA);
    _obbB.extract(b, transformB);
    _pushSphereObbInto(mA[12], mA[13], mA[14], rA, _obbB, out, flip: flip);
  }

  static void _capsuleBoxInto(
    CapsuleShape3D a,
    Matrix4 transformA,
    BoxShape3D b,
    Matrix4 transformB,
    MutableManifoldBuffer3D out, {
    required bool flip,
  }) {
    final rA = a.worldSpine(transformA, _segA0, _segA1);
    _obbB.extract(b, transformB);

    final p0x = _obbB.toLocalX(_segA0.x, _segA0.y, _segA0.z);
    final p0y = _obbB.toLocalY(_segA0.x, _segA0.y, _segA0.z);
    final p0z = _obbB.toLocalZ(_segA0.x, _segA0.y, _segA0.z);
    final p1x = _obbB.toLocalX(_segA1.x, _segA1.y, _segA1.z);
    final p1y = _obbB.toLocalY(_segA1.x, _segA1.y, _segA1.z);
    final p1z = _obbB.toLocalZ(_segA1.x, _segA1.y, _segA1.z);

    final bestT = _closestSegmentParamToAabb(
      p0x,
      p0y,
      p0z,
      p1x - p0x,
      p1y - p0y,
      p1z - p0z,
      _obbB.ex,
      _obbB.ey,
      _obbB.ez,
    );

    final sx = _segA0.x + (_segA1.x - _segA0.x) * bestT;
    final sy = _segA0.y + (_segA1.y - _segA0.y) * bestT;
    final sz = _segA0.z + (_segA1.z - _segA0.z) * bestT;
    _pushSphereObbInto(sx, sy, sz, rA, _obbB, out, flip: flip);
  }

  static void _boxBoxInto(
    BoxShape3D a,
    Matrix4 transformA,
    BoxShape3D b,
    Matrix4 transformB,
    MutableManifoldBuffer3D out,
  ) {
    final sat = _solveBoxBoxSat(a, transformA, b, transformB);
    if (sat == null) {
      return;
    }
    final (bestAxisCode, minPen) = sat;
    final nx = _boxNormalScratch.x;
    final ny = _boxNormalScratch.y;
    final nz = _boxNormalScratch.z;

    if (bestAxisCode < 6) {
      _writeObbFace(_obbA, nx, ny, nz, _faceA);
      _writeObbFace(_obbB, -nx, -ny, -nz, _faceB);
      if (_clipSupportFacesInto(
        nx,
        ny,
        nz,
        _faceA,
        _faceB,
        out,
        forceReference: bestAxisCode < 3 ? 1 : 2,
        depthOverride: minPen,
      )) {
        return;
      }
    }

    if (bestAxisCode >= 6) {
      final edgePair = bestAxisCode - 6;
      final axisA = edgePair ~/ 3;
      final axisB = edgePair % 3;
      _obbA.supportEdge(axisA, nx, ny, nz, _segA0, _segA1);
      _obbB.supportEdge(axisB, -nx, -ny, -nz, _segB0, _segB1);
      _closestPointsSegmentSegment(_segA0, _segA1, _segB0, _segB1, _ptA, _ptB);
      out.pushSingle(
        nx,
        ny,
        nz,
        minPen,
        _ptA.x,
        _ptA.y,
        _ptA.z,
        _ptB.x,
        _ptB.y,
        _ptB.z,
      );
      return;
    }

    a.supportPoint(_boxNormalScratch, transformA, _ptA);
    _boxNormalNegScratch.setValues(-nx, -ny, -nz);
    b.supportPoint(_boxNormalNegScratch, transformB, _ptB);
    out.pushSingle(
      nx,
      ny,
      nz,
      minPen,
      _ptA.x,
      _ptA.y,
      _ptA.z,
      _ptB.x,
      _ptB.y,
      _ptB.z,
    );
  }

  static final Vector3 _boxNormalScratch = Vector3.zero();
  static final Vector3 _boxNormalNegScratch = Vector3.zero();

  static (int, double)? _solveBoxBoxSat(
    BoxShape3D a,
    Matrix4 transformA,
    BoxShape3D b,
    Matrix4 transformB,
  ) {
    _obbA.extract(a, transformA);
    _obbB.extract(b, transformB);

    final tx = _obbB.cx - _obbA.cx;
    final ty = _obbB.cy - _obbA.cy;
    final tz = _obbB.cz - _obbA.cz;

    var minPen = double.infinity;
    var bestAxisCode = -1;

    bool testAxis(
      double ax,
      double ay,
      double az,
      int code,
      double bias, [
      double slack = 0.0,
    ]) {
      final len2 = ax * ax + ay * ay + az * az;
      if (len2 < 1e-10) {
        return true;
      }
      final invLen = 1.0 / math.sqrt(len2);
      var ux = ax * invLen;
      var uy = ay * invLen;
      var uz = az * invLen;

      final projA = _obbA.projectRadius(ux, uy, uz);
      final projB = _obbB.projectRadius(ux, uy, uz);
      var dist = tx * ux + ty * uy + tz * uz;
      if (dist < 0.0) {
        dist = -dist;
        ux = -ux;
        uy = -uy;
        uz = -uz;
      }
      final overlap = projA + projB - dist;
      if (overlap < 0.0) {
        return false;
      }
      if (overlap * bias + slack < minPen) {
        minPen = overlap;
        bestAxisCode = code;
        _boxNormalScratch.setValues(ux, uy, uz);
      }
      return true;
    }

    if (!testAxis(_obbA.u0x, _obbA.u0y, _obbA.u0z, 0, 1.0) ||
        !testAxis(_obbA.u1x, _obbA.u1y, _obbA.u1z, 1, 1.0) ||
        !testAxis(_obbA.u2x, _obbA.u2y, _obbA.u2z, 2, 1.0) ||
        !testAxis(_obbB.u0x, _obbB.u0y, _obbB.u0z, 3, 1.05, 2e-4) ||
        !testAxis(_obbB.u1x, _obbB.u1y, _obbB.u1z, 4, 1.05, 2e-4) ||
        !testAxis(_obbB.u2x, _obbB.u2y, _obbB.u2z, 5, 1.05, 2e-4)) {
      return null;
    }

    for (var i = 0; i < 3; i++) {
      final aUx = _obbA.axisX(i);
      final aUy = _obbA.axisY(i);
      final aUz = _obbA.axisZ(i);
      for (var j = 0; j < 3; j++) {
        final bUx = _obbB.axisX(j);
        final bUy = _obbB.axisY(j);
        final bUz = _obbB.axisZ(j);
        final cx = aUy * bUz - aUz * bUy;
        final cy = aUz * bUx - aUx * bUz;
        final cz = aUx * bUy - aUy * bUx;
        if (!testAxis(cx, cy, cz, 6 + i * 3 + j, 1.05, 2e-4)) {
          return null;
        }
      }
    }

    if (bestAxisCode < 0 || !minPen.isFinite) {
      return null;
    }

    if (tx * _boxNormalScratch.x +
            ty * _boxNormalScratch.y +
            tz * _boxNormalScratch.z <
        0.0) {
      _boxNormalScratch.negate();
    }
    return (bestAxisCode, minPen);
  }

  /// Exact analytical Sphere-Sphere narrowphase.
  static CollisionManifold3D? sphereSphere(
    SphereShape3D a,
    Matrix4 transformA,
    SphereShape3D b,
    Matrix4 transformB,
  ) {
    final mA = transformA.storage;
    final mB = transformB.storage;
    final rA = a.worldRadius(transformA);
    final rB = b.worldRadius(transformB);
    return _sphereSpherePoints(
      mA[12],
      mA[13],
      mA[14],
      rA,
      mB[12],
      mB[13],
      mB[14],
      rB,
    );
  }

  /// Exact analytical Sphere-Capsule narrowphase.
  static CollisionManifold3D? sphereCapsule(
    SphereShape3D a,
    Matrix4 transformA,
    CapsuleShape3D b,
    Matrix4 transformB,
  ) {
    final mA = transformA.storage;
    final cAx = mA[12];
    final cAy = mA[13];
    final cAz = mA[14];
    final rA = a.worldRadius(transformA);
    final rB = b.worldSpine(transformB, _segB0, _segB1);
    _closestPointOnSegment(cAx, cAy, cAz, _segB0, _segB1, _ptB);
    return _sphereSpherePoints(
      cAx,
      cAy,
      cAz,
      rA,
      _ptB.x,
      _ptB.y,
      _ptB.z,
      rB,
    );
  }

  /// Exact analytical Capsule-Capsule narrowphase.
  static CollisionManifold3D? capsuleCapsule(
    CapsuleShape3D a,
    Matrix4 transformA,
    CapsuleShape3D b,
    Matrix4 transformB,
  ) {
    final rA = a.worldSpine(transformA, _segA0, _segA1);
    final rB = b.worldSpine(transformB, _segB0, _segB1);
    _closestPointsSegmentSegment(_segA0, _segA1, _segB0, _segB1, _ptA, _ptB);
    return _sphereSpherePoints(
      _ptA.x,
      _ptA.y,
      _ptA.z,
      rA,
      _ptB.x,
      _ptB.y,
      _ptB.z,
      rB,
    );
  }

  /// Exact analytical Sphere-OBB narrowphase.
  static CollisionManifold3D? sphereBox(
    SphereShape3D a,
    Matrix4 transformA,
    BoxShape3D b,
    Matrix4 transformB,
  ) {
    final mA = transformA.storage;
    final rA = a.worldRadius(transformA);
    _obbB.extract(b, transformB);
    return _sphereObbPoints(mA[12], mA[13], mA[14], rA, _obbB);
  }

  /// Exact analytical Capsule-OBB narrowphase.
  static CollisionManifold3D? capsuleBox(
    CapsuleShape3D a,
    Matrix4 transformA,
    BoxShape3D b,
    Matrix4 transformB,
  ) {
    final rA = a.worldSpine(transformA, _segA0, _segA1);
    _obbB.extract(b, transformB);

    // Transform capsule segment into OBB B's local orthonormal frame.
    final p0x = _obbB.toLocalX(_segA0.x, _segA0.y, _segA0.z);
    final p0y = _obbB.toLocalY(_segA0.x, _segA0.y, _segA0.z);
    final p0z = _obbB.toLocalZ(_segA0.x, _segA0.y, _segA0.z);
    final p1x = _obbB.toLocalX(_segA1.x, _segA1.y, _segA1.z);
    final p1y = _obbB.toLocalY(_segA1.x, _segA1.y, _segA1.z);
    final p1z = _obbB.toLocalZ(_segA1.x, _segA1.y, _segA1.z);

    final hx = _obbB.ex;
    final hy = _obbB.ey;
    final hz = _obbB.ez;

    final bestT = _closestSegmentParamToAabb(
      p0x,
      p0y,
      p0z,
      p1x - p0x,
      p1y - p0y,
      p1z - p0z,
      hx,
      hy,
      hz,
    );

    final sx = _segA0.x + (_segA1.x - _segA0.x) * bestT;
    final sy = _segA0.y + (_segA1.y - _segA0.y) * bestT;
    final sz = _segA0.z + (_segA1.z - _segA0.z) * bestT;
    return _sphereObbPoints(sx, sy, sz, rA, _obbB);
  }

  /// 15-axis SAT OBB-OBB narrowphase with Sutherland-Hodgman face clipping for
  /// stable multi-point contact manifolds.
  static CollisionManifold3D? boxBox(
    BoxShape3D a,
    Matrix4 transformA,
    BoxShape3D b,
    Matrix4 transformB,
  ) {
    _obbA.extract(a, transformA);
    _obbB.extract(b, transformB);

    final tx = _obbB.cx - _obbA.cx;
    final ty = _obbB.cy - _obbA.cy;
    final tz = _obbB.cz - _obbA.cz;

    var minPen = double.infinity;
    var bestAxisCode = -1;
    final bestNormal = Vector3.zero();

    // `bias` and `slack` make an axis win only when clearly better than the
    // current best: B's faces and the edge axes must beat A's faces by 5 %
    // plus 0.2 mm, so nearly parallel resting boxes keep the same reference
    // face (and contact feature ids) from one step to the next.
    bool testAxis(
      double ax,
      double ay,
      double az,
      int code,
      double bias, [
      double slack = 0.0,
    ]) {
      final len2 = ax * ax + ay * ay + az * az;
      if (len2 < 1e-10) {
        return true;
      }
      final invLen = 1.0 / math.sqrt(len2);
      var ux = ax * invLen;
      var uy = ay * invLen;
      var uz = az * invLen;

      final projA = _obbA.projectRadius(ux, uy, uz);
      final projB = _obbB.projectRadius(ux, uy, uz);
      var dist = tx * ux + ty * uy + tz * uz;
      if (dist < 0.0) {
        dist = -dist;
        ux = -ux;
        uy = -uy;
        uz = -uz;
      }
      final overlap = projA + projB - dist;
      if (overlap < 0.0) {
        return false;
      }
      if (overlap * bias + slack < minPen) {
        minPen = overlap;
        bestAxisCode = code;
        bestNormal.setValues(ux, uy, uz);
      }
      return true;
    }

    // 3 face axes of A (codes 0..2) & 3 face axes of B (codes 3..5).
    if (!testAxis(_obbA.u0x, _obbA.u0y, _obbA.u0z, 0, 1.0) ||
        !testAxis(_obbA.u1x, _obbA.u1y, _obbA.u1z, 1, 1.0) ||
        !testAxis(_obbA.u2x, _obbA.u2y, _obbA.u2z, 2, 1.0) ||
        !testAxis(_obbB.u0x, _obbB.u0y, _obbB.u0z, 3, 1.05, 2e-4) ||
        !testAxis(_obbB.u1x, _obbB.u1y, _obbB.u1z, 4, 1.05, 2e-4) ||
        !testAxis(_obbB.u2x, _obbB.u2y, _obbB.u2z, 5, 1.05, 2e-4)) {
      return null;
    }

    // 9 edge-edge cross axes (codes 6..14).
    for (var i = 0; i < 3; i++) {
      final aUx = _obbA.axisX(i);
      final aUy = _obbA.axisY(i);
      final aUz = _obbA.axisZ(i);
      for (var j = 0; j < 3; j++) {
        final bUx = _obbB.axisX(j);
        final bUy = _obbB.axisY(j);
        final bUz = _obbB.axisZ(j);
        final cx = aUy * bUz - aUz * bUy;
        final cy = aUz * bUx - aUx * bUz;
        final cz = aUx * bUy - aUy * bUx;
        if (!testAxis(cx, cy, cz, 6 + i * 3 + j, 1.05, 2e-4)) {
          return null;
        }
      }
    }

    if (bestAxisCode < 0 || !minPen.isFinite) {
      return null;
    }

    // Ensure `bestNormal` points from A to B (`(cB - cA) . n >= 0`).
    if (tx * bestNormal.x + ty * bestNormal.y + tz * bestNormal.z < 0.0) {
      bestNormal.negate();
    }

    if (bestAxisCode < 6) {
      // Reference face: the separating face axis; incident face: the most
      // anti-parallel face of the other box.
      final nx = bestNormal.x;
      final ny = bestNormal.y;
      final nz = bestNormal.z;
      _writeObbFace(_obbA, nx, ny, nz, _faceA);
      _writeObbFace(_obbB, -nx, -ny, -nz, _faceB);
      final faced = _clipSupportFaces(
        nx,
        ny,
        nz,
        _faceA,
        _faceB,
        forceReference: bestAxisCode < 3 ? 1 : 2,
        depthOverride: minPen,
      );
      if (faced != null) {
        return faced;
      }
    }

    // Edge-edge contact: closest points between the two supporting edges.
    if (bestAxisCode >= 6) {
      final edgePair = bestAxisCode - 6;
      final axisA = edgePair ~/ 3;
      final axisB = edgePair % 3;
      _obbA.supportEdge(
        axisA,
        bestNormal.x,
        bestNormal.y,
        bestNormal.z,
        _segA0,
        _segA1,
      );
      _obbB.supportEdge(
        axisB,
        -bestNormal.x,
        -bestNormal.y,
        -bestNormal.z,
        _segB0,
        _segB1,
      );
      _closestPointsSegmentSegment(_segA0, _segA1, _segB0, _segB1, _ptA, _ptB);
      return CollisionManifold3D(
        normal: bestNormal,
        penetrationDepth: minPen,
        contactPointA: _ptA,
        contactPointB: _ptB,
      );
    }

    a.supportPoint(bestNormal, transformA, _ptA);
    b.supportPoint(-bestNormal, transformB, _ptB);
    return CollisionManifold3D(
      normal: bestNormal,
      penetrationDepth: minPen,
      contactPointA: _ptA,
      contactPointB: _ptB,
    );
  }

  /// General Convex-Convex narrowphase using GJK + Expanding Polytope Algorithm
  /// (with spherical direction fallback for degenerate simplices).
  ///
  /// When both shapes have faces (boxes and non-degenerate hulls) and the EPA
  /// normal is within about 5.7 degrees of one of their supporting faces, the
  /// incident face is clipped against the reference face, which gives up to
  /// four contact points with stable feature ids; otherwise (edge against
  /// edge, or a curved shape) the manifold has the single EPA point.
  static CollisionManifold3D? convexConvex(
    Shape3D shapeA,
    Matrix4 transformA,
    Shape3D shapeB,
    Matrix4 transformB,
  ) {
    final epa = _gjkEpa(
      (dir, out) => shapeA.supportPoint(dir, transformA, out),
      (dir, out) => shapeB.supportPoint(dir, transformB, out),
      _centerOf(transformA, _cAScratch),
      _centerOf(transformB, _cBScratch),
    );
    if (epa == null) {
      return null;
    }
    final n = epa.normal;
    if (_writeSupportFace(shapeA, transformA, n.x, n.y, n.z, _faceA) &&
        _writeSupportFace(shapeB, transformB, -n.x, -n.y, -n.z, _faceB)) {
      final faced = _clipSupportFaces(n.x, n.y, n.z, _faceA, _faceB);
      if (faced != null) {
        return faced;
      }
    }
    return epa;
  }

  /// Intersects [shape] (under [shapeTransform]) against all triangles of
  /// [surface] (under [meshTransform]) overlapping [shape]'s local AABB in
  /// `surface.bvh`, returning the deepest [CollisionManifold3D] (oriented from
  /// [shape] toward [surface]) or `null` when separated.
  static CollisionManifold3D? intersectShapeWithSurfaceBvh(
    Shape3D shape,
    Matrix4 shapeTransform,
    Surface surface,
    Matrix4 meshTransform,
  ) {
    final all = intersectShapeWithSurfaceBvhAll(
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
  static List<CollisionManifold3D> intersectShapeWithSurfaceBvhAll(
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

    if (!_aabbOverlaps(_localShapeBox, surface.aabb)) {
      return results;
    }

    final index = _aabbTrees[bvhRef] ??= _SurfaceTriangleAabbTree.build(
      surface,
    );
    _candidateTris.clear();
    index.queryAabb(_localShapeBox, _candidateTris);
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

      _transformPoint(
        m,
        positions[i0],
        positions[i0 + 1],
        positions[i0 + 2],
        _triV0,
      );
      _transformPoint(
        m,
        positions[i1],
        positions[i1 + 1],
        positions[i1 + 2],
        _triV1,
      );
      _transformPoint(
        m,
        positions[i2],
        positions[i2 + 1],
        positions[i2 + 2],
        _triV2,
      );

      final manifold = intersectShapeWithTriangle(
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
  static CollisionManifold3D? heightfieldShape(
    Shape3D shape,
    Matrix4 shapeTransform,
    HeightfieldShape3D heightfield,
    Matrix4 heightfieldTransform,
  ) {
    return _pickDeepestMerged(
      heightfieldShapeAll(
        shape,
        shapeTransform,
        heightfield,
        heightfieldTransform,
      ),
    );
  }

  /// Returns all triangle contact manifolds where [shape] (under
  /// [shapeTransform]) overlaps [heightfield] (under [heightfieldTransform]).
  static List<CollisionManifold3D> heightfieldShapeAll(
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

        _transformPoint(m, lv00.x, lv00.y, lv00.z, wv00);
        _transformPoint(m, lv01.x, lv01.y, lv01.z, wv01);
        _transformPoint(m, lv11.x, lv11.y, lv11.z, wv11);
        _transformPoint(m, lv10.x, lv10.y, lv10.z, wv10);

        final m0 = intersectShapeWithTriangle(
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

        final m1 = intersectShapeWithTriangle(
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

  static CollisionManifold3D _orientHeightfieldManifold(
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

  static List<CollisionManifold3D> _testCompoundVsShapeAll(
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
      if (!_aabbOverlaps(childBox, boxB)) {
        continue;
      }
      final sub = testAll(child.shape, childMat, shapeB, transformB);
      if (sub.isNotEmpty) {
        results.addAll(sub);
      }
    }
    return results;
  }

  static CollisionManifold3D? _pickDeepestMerged(
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

  static List<CollisionManifold3D> _mergeCoDirectionalManifolds(
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
  static CollisionManifold3D? intersectShapeWithTriangle(
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
        final hit = intersectShapeWithTriangle(
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
      _closestPointOnTriangle(cx, cy, cz, v0, v1, v2, _ptB);
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
      (dir, out) => _triangleSupport(v0, v1, v2, dir, out),
      _centerOf(shapeTransform, _cAScratch),
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

  static final Expando<_SurfaceTriangleAabbTree> _aabbTrees = Expando();
  static final Matrix4 _invMesh = Matrix4.identity();
  static final Aabb3 _worldShapeBox = Aabb3();
  static final Aabb3 _localShapeBox = Aabb3();
  static final List<int> _candidateTris = [];

  static final Vector3 _segA0 = Vector3.zero();
  static final Vector3 _segA1 = Vector3.zero();
  static final Vector3 _segB0 = Vector3.zero();
  static final Vector3 _segB1 = Vector3.zero();
  static final Vector3 _ptA = Vector3.zero();
  static final Vector3 _ptB = Vector3.zero();
  static final Vector3 _triV0 = Vector3.zero();
  static final Vector3 _triV1 = Vector3.zero();
  static final Vector3 _triV2 = Vector3.zero();
  static final Vector3 _triCentroid = Vector3.zero();
  static final Vector3 _cAScratch = Vector3.zero();
  static final Vector3 _cBScratch = Vector3.zero();
  static final _ObbFrame _obbA = _ObbFrame();
  static final _ObbFrame _obbB = _ObbFrame();

  static Vector3 _centerOf(Matrix4 m, Vector3 out) {
    final s = m.storage;
    out.setValues(s[12], s[13], s[14]);
    return out;
  }

  static void _transformPoint(
    Float32List m,
    double x,
    double y,
    double z,
    Vector3 out,
  ) {
    out.setValues(
      m[0] * x + m[4] * y + m[8] * z + m[12],
      m[1] * x + m[5] * y + m[9] * z + m[13],
      m[2] * x + m[6] * y + m[10] * z + m[14],
    );
  }

  static bool _aabbOverlaps(Aabb3 a, Aabb3 b) {
    return a.min.x <= b.max.x &&
        a.max.x >= b.min.x &&
        a.min.y <= b.max.y &&
        a.max.y >= b.min.y &&
        a.min.z <= b.max.z &&
        a.max.z >= b.min.z;
  }

  static void _triangleSupport(
    Vector3 v0,
    Vector3 v1,
    Vector3 v2,
    Vector3 dir,
    Vector3 out,
  ) {
    final d0 = v0.dot(dir);
    final d1 = v1.dot(dir);
    final d2 = v2.dot(dir);
    if (d0 >= d1 && d0 >= d2) {
      out.setFrom(v0);
    } else if (d1 >= d2) {
      out.setFrom(v1);
    } else {
      out.setFrom(v2);
    }
  }

  static void _pushSphereSphereInto(
    double ax,
    double ay,
    double az,
    double rA,
    double bx,
    double by,
    double bz,
    double rB,
    MutableManifoldBuffer3D out, {
    required bool flip,
  }) {
    final dx = bx - ax;
    final dy = by - ay;
    final dz = bz - az;
    final dist2 = dx * dx + dy * dy + dz * dz;
    final rSum = rA + rB;
    if (dist2 > rSum * rSum) {
      return;
    }
    final dist = math.sqrt(dist2);
    final double nx;
    final double ny;
    final double nz;
    if (dist > 1e-9) {
      final inv = 1.0 / dist;
      nx = dx * inv;
      ny = dy * inv;
      nz = dz * inv;
    } else {
      nx = 0.0;
      ny = 1.0;
      nz = 0.0;
    }
    final pax = ax + nx * rA;
    final pay = ay + ny * rA;
    final paz = az + nz * rA;
    final pbx = bx - nx * rB;
    final pby = by - ny * rB;
    final pbz = bz - nz * rB;
    final depth = rSum - dist;
    if (flip) {
      out.pushSingle(-nx, -ny, -nz, depth, pbx, pby, pbz, pax, pay, paz);
    } else {
      out.pushSingle(nx, ny, nz, depth, pax, pay, paz, pbx, pby, pbz);
    }
  }

  static void _pushSphereObbInto(
    double sx,
    double sy,
    double sz,
    double rA,
    _ObbFrame obb,
    MutableManifoldBuffer3D out, {
    required bool flip,
  }) {
    final lx = obb.toLocalX(sx, sy, sz);
    final ly = obb.toLocalY(sx, sy, sz);
    final lz = obb.toLocalZ(sx, sy, sz);
    final hx = obb.ex;
    final hy = obb.ey;
    final hz = obb.ez;

    final cx = lx.clamp(-hx, hx);
    final cy = ly.clamp(-hy, hy);
    final cz = lz.clamp(-hz, hz);

    final dx = lx - cx;
    final dy = ly - cy;
    final dz = lz - cz;
    final dist2 = dx * dx + dy * dy + dz * dz;
    if (dist2 > rA * rA) {
      return;
    }

    if (dist2 > 1e-12) {
      final dist = math.sqrt(dist2);
      obb.toWorld(cx, cy, cz, _ptB);
      final inv = 1.0 / dist;
      final nx = (_ptB.x - sx) * inv;
      final ny = (_ptB.y - sy) * inv;
      final nz = (_ptB.z - sz) * inv;
      final pax = sx + nx * rA;
      final pay = sy + ny * rA;
      final paz = sz + nz * rA;
      final depth = rA - dist;
      if (flip) {
        out.pushSingle(
          -nx,
          -ny,
          -nz,
          depth,
          _ptB.x,
          _ptB.y,
          _ptB.z,
          pax,
          pay,
          paz,
        );
      } else {
        out.pushSingle(
          nx,
          ny,
          nz,
          depth,
          pax,
          pay,
          paz,
          _ptB.x,
          _ptB.y,
          _ptB.z,
        );
      }
      return;
    }

    final penX = hx - lx.abs();
    final penY = hy - ly.abs();
    final penZ = hz - lz.abs();

    var nLx = 0.0;
    var nLy = 0.0;
    var nLz = 0.0;
    var faceLx = lx;
    var faceLy = ly;
    var faceLz = lz;
    double faceDist;

    if (penX <= penY && penX <= penZ) {
      faceDist = penX;
      final sign = lx >= 0.0 ? 1.0 : -1.0;
      nLx = -sign;
      faceLx = sign * hx;
    } else if (penY <= penZ) {
      faceDist = penY;
      final sign = ly >= 0.0 ? 1.0 : -1.0;
      nLy = -sign;
      faceLy = sign * hy;
    } else {
      faceDist = penZ;
      final sign = lz >= 0.0 ? 1.0 : -1.0;
      nLz = -sign;
      faceLz = sign * hz;
    }

    obb.dirToWorld(nLx, nLy, nLz, _boxNormalScratch);
    obb.toWorld(faceLx, faceLy, faceLz, _ptB);
    final nx = _boxNormalScratch.x;
    final ny = _boxNormalScratch.y;
    final nz = _boxNormalScratch.z;
    final pax = sx + nx * rA;
    final pay = sy + ny * rA;
    final paz = sz + nz * rA;
    final depth = rA + faceDist;
    if (flip) {
      out.pushSingle(
        -nx,
        -ny,
        -nz,
        depth,
        _ptB.x,
        _ptB.y,
        _ptB.z,
        pax,
        pay,
        paz,
      );
    } else {
      out.pushSingle(
        nx,
        ny,
        nz,
        depth,
        pax,
        pay,
        paz,
        _ptB.x,
        _ptB.y,
        _ptB.z,
      );
    }
  }

  static CollisionManifold3D? _sphereSpherePoints(
    double ax,
    double ay,
    double az,
    double rA,
    double bx,
    double by,
    double bz,
    double rB,
  ) {
    final dx = bx - ax;
    final dy = by - ay;
    final dz = bz - az;
    final dist2 = dx * dx + dy * dy + dz * dz;
    final rSum = rA + rB;
    if (dist2 > rSum * rSum) {
      return null;
    }
    final dist = math.sqrt(dist2);
    final double nx;
    final double ny;
    final double nz;
    if (dist > 1e-9) {
      final inv = 1.0 / dist;
      nx = dx * inv;
      ny = dy * inv;
      nz = dz * inv;
    } else {
      nx = 0.0;
      ny = 1.0;
      nz = 0.0;
    }
    final normal = Vector3(nx, ny, nz);
    return CollisionManifold3D(
      normal: normal,
      penetrationDepth: rSum - dist,
      contactPointA: Vector3(ax + nx * rA, ay + ny * rA, az + nz * rA),
      contactPointB: Vector3(bx - nx * rB, by - ny * rB, bz - nz * rB),
    );
  }

  static CollisionManifold3D? _sphereTrianglePoints(
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

  static CollisionManifold3D? _sphereObbPoints(
    double sx,
    double sy,
    double sz,
    double rA,
    _ObbFrame obb,
  ) {
    final lx = obb.toLocalX(sx, sy, sz);
    final ly = obb.toLocalY(sx, sy, sz);
    final lz = obb.toLocalZ(sx, sy, sz);
    final hx = obb.ex;
    final hy = obb.ey;
    final hz = obb.ez;

    final cx = lx.clamp(-hx, hx);
    final cy = ly.clamp(-hy, hy);
    final cz = lz.clamp(-hz, hz);

    final dx = lx - cx;
    final dy = ly - cy;
    final dz = lz - cz;
    final dist2 = dx * dx + dy * dy + dz * dz;
    if (dist2 > rA * rA) {
      return null;
    }

    if (dist2 > 1e-12) {
      final dist = math.sqrt(dist2);
      final pB = Vector3.zero();
      obb.toWorld(cx, cy, cz, pB);
      final inv = 1.0 / dist;
      final nx = (pB.x - sx) * inv;
      final ny = (pB.y - sy) * inv;
      final nz = (pB.z - sz) * inv;
      return CollisionManifold3D(
        normal: Vector3(nx, ny, nz),
        penetrationDepth: rA - dist,
        contactPointA: Vector3(sx + nx * rA, sy + ny * rA, sz + nz * rA),
        contactPointB: pB,
      );
    }

    // Sphere center lies inside OBB: pick closest face.
    final penX = hx - lx.abs();
    final penY = hy - ly.abs();
    final penZ = hz - lz.abs();

    var nLx = 0.0;
    var nLy = 0.0;
    var nLz = 0.0;
    var faceLx = lx;
    var faceLy = ly;
    var faceLz = lz;
    double faceDist;

    if (penX <= penY && penX <= penZ) {
      faceDist = penX;
      final sign = lx >= 0.0 ? 1.0 : -1.0;
      nLx = -sign;
      faceLx = sign * hx;
    } else if (penY <= penZ) {
      faceDist = penY;
      final sign = ly >= 0.0 ? 1.0 : -1.0;
      nLy = -sign;
      faceLy = sign * hy;
    } else {
      faceDist = penZ;
      final sign = lz >= 0.0 ? 1.0 : -1.0;
      nLz = -sign;
      faceLz = sign * hz;
    }

    final normal = Vector3.zero();
    obb.dirToWorld(nLx, nLy, nLz, normal);
    final pB = Vector3.zero();
    obb.toWorld(faceLx, faceLy, faceLz, pB);
    return CollisionManifold3D(
      normal: normal,
      penetrationDepth: rA + faceDist,
      contactPointA: Vector3(
        sx + normal.x * rA,
        sy + normal.y * rA,
        sz + normal.z * rA,
      ),
      contactPointB: pB,
    );
  }

  static double _closestSegmentParamToAabb(
    double p0x,
    double p0y,
    double p0z,
    double dx,
    double dy,
    double dz,
    double hx,
    double hy,
    double hz,
  ) {
    final breaks = _segBreaks;
    var count = 2;
    breaks[0] = 0.0;
    breaks[1] = 1.0;

    void addCrossings(double o, double d, double h) {
      if (d.abs() > 1e-12) {
        final t1 = (-h - o) / d;
        if (t1 > 0.0 && t1 < 1.0) {
          breaks[count++] = t1;
        }
        final t2 = (h - o) / d;
        if (t2 > 0.0 && t2 < 1.0) {
          breaks[count++] = t2;
        }
      }
    }

    addCrossings(p0x, dx, hx);
    addCrossings(p0y, dy, hy);
    addCrossings(p0z, dz, hz);

    // Insertion sort `breaks[0..count-1]`.
    for (var i = 1; i < count; i++) {
      final key = breaks[i];
      var j = i - 1;
      while (j >= 0 && breaks[j] > key) {
        breaks[j + 1] = breaks[j];
        j--;
      }
      breaks[j + 1] = key;
    }

    double distSqAt(double t) {
      final x = p0x + dx * t;
      final y = p0y + dy * t;
      final z = p0z + dz * t;
      final ex = x < -hx ? x + hx : (x > hx ? x - hx : 0.0);
      final ey = y < -hy ? y + hy : (y > hy ? y - hy : 0.0);
      final ez = z < -hz ? z + hz : (z > hz ? z - hz : 0.0);
      return ex * ex + ey * ey + ez * ez;
    }

    var bestT = 0.0;
    var bestD2 = distSqAt(0.0);

    for (var i = 0; i < count - 1; i++) {
      final tA = breaks[i];
      final tB = breaks[i + 1];
      if (tB - tA <= 1e-12) {
        continue;
      }
      final tMid = 0.5 * (tA + tB);
      final mx = p0x + dx * tMid;
      final my = p0y + dy * tMid;
      final mz = p0z + dz * tMid;

      // On `[tA, tB]`, the set of active outside axes is constant!
      var qa = 0.0;
      var qb = 0.0;
      if (mx < -hx) {
        qa += dx * dx;
        qb += dx * (p0x + hx);
      } else if (mx > hx) {
        qa += dx * dx;
        qb += dx * (p0x - hx);
      }
      if (my < -hy) {
        qa += dy * dy;
        qb += dy * (p0y + hy);
      } else if (my > hy) {
        qa += dy * dy;
        qb += dy * (p0y - hy);
      }
      if (mz < -hz) {
        qa += dz * dz;
        qb += dz * (p0z + hz);
      } else if (mz > hz) {
        qa += dz * dz;
        qb += dz * (p0z - hz);
      }

      if (qa <= 1e-18) {
        // Entire sub-interval lies inside AABB (`distSq == 0`)!
        return tMid;
      }
      final tStar = (-qb / qa).clamp(tA, tB);
      final d2 = distSqAt(tStar);
      if (d2 < bestD2) {
        bestD2 = d2;
        bestT = tStar;
      }
    }

    final dEnd = distSqAt(1.0);
    if (dEnd < bestD2) {
      bestT = 1.0;
    }
    return bestT;
  }

  static final Float64List _segBreaks = Float64List(8);

  static void _closestPointOnSegment(
    double px,
    double py,
    double pz,
    Vector3 a,
    Vector3 b,
    Vector3 out,
  ) {
    final abx = b.x - a.x;
    final aby = b.y - a.y;
    final abz = b.z - a.z;
    final len2 = abx * abx + aby * aby + abz * abz;
    if (len2 <= 1e-16) {
      out.setFrom(a);
      return;
    }
    final t = (((px - a.x) * abx + (py - a.y) * aby + (pz - a.z) * abz) / len2)
        .clamp(0.0, 1.0);
    out.setValues(a.x + abx * t, a.y + aby * t, a.z + abz * t);
  }

  static void _closestPointsSegmentSegment(
    Vector3 p1,
    Vector3 q1,
    Vector3 p2,
    Vector3 q2,
    Vector3 out1,
    Vector3 out2,
  ) {
    final d1x = q1.x - p1.x;
    final d1y = q1.y - p1.y;
    final d1z = q1.z - p1.z;
    final d2x = q2.x - p2.x;
    final d2y = q2.y - p2.y;
    final d2z = q2.z - p2.z;
    final rx = p1.x - p2.x;
    final ry = p1.y - p2.y;
    final rz = p1.z - p2.z;

    final a = d1x * d1x + d1y * d1y + d1z * d1z;
    final e = d2x * d2x + d2y * d2y + d2z * d2z;
    final f = d2x * rx + d2y * ry + d2z * rz;

    double s;
    double t;
    if (a <= 1e-14 && e <= 1e-14) {
      s = 0.0;
      t = 0.0;
    } else if (a <= 1e-14) {
      s = 0.0;
      t = (f / e).clamp(0.0, 1.0);
    } else {
      final c = d1x * rx + d1y * ry + d1z * rz;
      if (e <= 1e-14) {
        t = 0.0;
        s = (-c / a).clamp(0.0, 1.0);
      } else {
        final b = d1x * d2x + d1y * d2y + d1z * d2z;
        final denom = a * e - b * b;
        s = denom > 1e-14 ? ((b * f - c * e) / denom).clamp(0.0, 1.0) : 0.0;
        t = (b * s + f) / e;
        if (t < 0.0) {
          t = 0.0;
          s = (-c / a).clamp(0.0, 1.0);
        } else if (t > 1.0) {
          t = 1.0;
          s = ((b - c) / a).clamp(0.0, 1.0);
        }
      }
    }

    out1.setValues(p1.x + d1x * s, p1.y + d1y * s, p1.z + d1z * s);
    out2.setValues(p2.x + d2x * t, p2.y + d2y * t, p2.z + d2z * t);
  }

  static void _closestPointOnTriangle(
    double px,
    double py,
    double pz,
    Vector3 a,
    Vector3 b,
    Vector3 c,
    Vector3 out,
  ) {
    final abx = b.x - a.x;
    final aby = b.y - a.y;
    final abz = b.z - a.z;
    final acx = c.x - a.x;
    final acy = c.y - a.y;
    final acz = c.z - a.z;
    final apx = px - a.x;
    final apy = py - a.y;
    final apz = pz - a.z;

    final d1 = abx * apx + aby * apy + abz * apz;
    final d2 = acx * apx + acy * apy + acz * apz;
    if (d1 <= 0.0 && d2 <= 0.0) {
      out.setFrom(a);
      return;
    }

    final bpx = px - b.x;
    final bpy = py - b.y;
    final bpz = pz - b.z;
    final d3 = abx * bpx + aby * bpy + abz * bpz;
    final d4 = acx * bpx + acy * bpy + acz * bpz;
    if (d3 >= 0.0 && d4 <= d3) {
      out.setFrom(b);
      return;
    }

    final vc = d1 * d4 - d3 * d2;
    if (vc <= 0.0 && d1 >= 0.0 && d3 <= 0.0) {
      final v = d1 / (d1 - d3);
      out.setValues(a.x + v * abx, a.y + v * aby, a.z + v * abz);
      return;
    }

    final cpx = px - c.x;
    final cpy = py - c.y;
    final cpz = pz - c.z;
    final d5 = abx * cpx + aby * cpy + abz * cpz;
    final d6 = acx * cpx + acy * cpy + acz * cpz;
    if (d6 >= 0.0 && d5 <= d6) {
      out.setFrom(c);
      return;
    }

    final vb = d5 * d2 - d1 * d6;
    if (vb <= 0.0 && d2 >= 0.0 && d6 <= 0.0) {
      final w = d2 / (d2 - d6);
      out.setValues(a.x + w * acx, a.y + w * acy, a.z + w * acz);
      return;
    }

    final va = d3 * d6 - d5 * d4;
    if (va <= 0.0 && (d4 - d3) >= 0.0 && (d5 - d6) >= 0.0) {
      final w = (d4 - d3) / ((d4 - d3) + (d5 - d6));
      out.setValues(
        b.x + w * (c.x - b.x),
        b.y + w * (c.y - b.y),
        b.z + w * (c.z - b.z),
      );
      return;
    }

    final denom = 1.0 / (va + vb + vc);
    final v = vb * denom;
    final w = vc * denom;
    out.setValues(
      a.x + abx * v + acx * w,
      a.y + aby * v + acy * w,
      a.z + abz * v + acz * w,
    );
  }

  static void _closestPointsSegmentTriangle(
    Vector3 p0,
    Vector3 p1,
    Vector3 v0,
    Vector3 v1,
    Vector3 v2,
    Vector3 outSeg,
    Vector3 outTri,
  ) {
    var bestD2 = double.infinity;

    void consider(Vector3 candSeg, Vector3 candTri) {
      final dx = candSeg.x - candTri.x;
      final dy = candSeg.y - candTri.y;
      final dz = candSeg.z - candTri.z;
      final d2 = dx * dx + dy * dy + dz * dz;
      if (d2 < bestD2) {
        bestD2 = d2;
        outSeg.setFrom(candSeg);
        outTri.setFrom(candTri);
      }
    }

    // 1. Segment endpoints against triangle.
    _closestPointOnTriangle(p0.x, p0.y, p0.z, v0, v1, v2, _candTri);
    consider(p0, _candTri);
    _closestPointOnTriangle(p1.x, p1.y, p1.z, v0, v1, v2, _candTri);
    consider(p1, _candTri);

    // 2. Segment against the 3 triangle edges.
    _closestPointsSegmentSegment(p0, p1, v0, v1, _candSeg, _candTri);
    consider(_candSeg, _candTri);
    _closestPointsSegmentSegment(p0, p1, v1, v2, _candSeg, _candTri);
    consider(_candSeg, _candTri);
    _closestPointsSegmentSegment(p0, p1, v2, v0, _candSeg, _candTri);
    consider(_candSeg, _candTri);

    // 3. Segment piercing the triangle plane.
    final e1x = v1.x - v0.x;
    final e1y = v1.y - v0.y;
    final e1z = v1.z - v0.z;
    final e2x = v2.x - v0.x;
    final e2y = v2.y - v0.y;
    final e2z = v2.z - v0.z;
    final nx = e1y * e2z - e1z * e2y;
    final ny = e1z * e2x - e1x * e2z;
    final nz = e1x * e2y - e1y * e2x;
    final dx = p1.x - p0.x;
    final dy = p1.y - p0.y;
    final dz = p1.z - p0.z;
    final denom = nx * dx + ny * dy + nz * dz;
    if (denom.abs() > 1e-12) {
      final t =
          -(nx * (p0.x - v0.x) + ny * (p0.y - v0.y) + nz * (p0.z - v0.z)) /
          denom;
      if (t > 0.0 && t < 1.0) {
        _candSeg.setValues(p0.x + dx * t, p0.y + dy * t, p0.z + dz * t);
        _closestPointOnTriangle(
          _candSeg.x,
          _candSeg.y,
          _candSeg.z,
          v0,
          v1,
          v2,
          _candTri,
        );
        consider(_candSeg, _candTri);
      }
    }
  }

  static final Vector3 _candSeg = Vector3.zero();
  static final Vector3 _candTri = Vector3.zero();

  static List<ContactPoint3D> _reduceContactsToFour(
    List<ContactPoint3D> contacts,
    double nx,
    double ny,
    double nz,
  ) {
    // Keep deepest point first, then farthest from it, then maximize triangle
    // area, then farthest from triangle edges.
    var i0 = 0;
    for (var i = 1; i < contacts.length; i++) {
      if (contacts[i].penetrationDepth > contacts[i0].penetrationDepth) {
        i0 = i;
      }
    }
    var i1 = 0;
    var bestD2 = -1.0;
    final p0 = contacts[i0].pointA;
    for (var i = 0; i < contacts.length; i++) {
      final d2 = contacts[i].pointA.distanceToSquared(p0);
      if (d2 > bestD2) {
        bestD2 = d2;
        i1 = i;
      }
    }
    var i2 = 0;
    var bestArea = -1.0;
    final p1 = contacts[i1].pointA;
    for (var i = 0; i < contacts.length; i++) {
      if (i == i0 || i == i1) {
        continue;
      }
      final p = contacts[i].pointA;
      final e1x = p1.x - p0.x;
      final e1y = p1.y - p0.y;
      final e1z = p1.z - p0.z;
      final e2x = p.x - p0.x;
      final e2y = p.y - p0.y;
      final e2z = p.z - p0.z;
      final cx = e1y * e2z - e1z * e2y;
      final cy = e1z * e2x - e1x * e2z;
      final cz = e1x * e2y - e1y * e2x;
      final area = (cx * nx + cy * ny + cz * nz).abs();
      if (area > bestArea) {
        bestArea = area;
        i2 = i;
      }
    }
    var i3 = 0;
    var bestFourth = -1.0;
    final p2 = contacts[i2].pointA;
    for (var i = 0; i < contacts.length; i++) {
      if (i == i0 || i == i1 || i == i2) {
        continue;
      }
      final p = contacts[i].pointA;
      final d = math.min(
        p.distanceToSquared(p0),
        math.min(p.distanceToSquared(p1), p.distanceToSquared(p2)),
      );
      if (d > bestFourth) {
        bestFourth = d;
        i3 = i;
      }
    }
    final chosen = <int>{i0, i1, i2, i3};
    return [for (final idx in chosen) contacts[idx]];
  }

  // Supporting-face contact manifolds (box and hull faces).

  /// Largest separation (in world units) at which a clipped face point is
  /// still reported (with a penetration depth of `0`): points of a face that
  /// is about to touch stay in the manifold instead of flickering in and out.
  static const double _faceContactTolerance = 0.002;

  /// Minimum cosine (about 5.7 degrees) between the contact normal and the
  /// better aligned of the two supporting faces for a face contact. Below it
  /// the contact is edge against edge and keeps a single point.
  static const double _faceAlignmentCos = 0.995;

  static final _SupportFace3D _faceA = _SupportFace3D();
  static final _SupportFace3D _faceB = _SupportFace3D();
  static final _ClipBuffer3D _clip = _ClipBuffer3D();
  static final _ObbFrame _obbFace = _ObbFrame();
  static final Int32List _chosen = Int32List(4);

  /// Mixes two small non-negative integers into a 30-bit feature id.
  static int _mixId(int a, int b) {
    var h = (a ^ 0x2545F491) & 0x3FFFFFFF;
    h = (h * 1031 + (b & 0x3FFFFFFF) * 7 + 0x9E37) & 0x3FFFFFFF;
    h ^= h >> 13;
    return (h * 997) & 0x3FFFFFFF;
  }

  /// Writes into [out] the face of [shape] (under [m]) whose outward normal is
  /// closest to the world direction `(dx, dy, dz)`, returning `false` for
  /// shapes without faces (spheres, capsules, degenerate hulls).
  static bool _writeSupportFace(
    Shape3D shape,
    Matrix4 m,
    double dx,
    double dy,
    double dz,
    _SupportFace3D out,
  ) {
    if (shape is BoxShape3D) {
      _obbFace.extract(shape, m);
      _writeObbFace(_obbFace, dx, dy, dz, out);
      return true;
    }
    if (shape is ConvexHullShape3D) {
      return _writeHullFace(shape, m, dx, dy, dz, out);
    }
    return false;
  }

  static void _writeObbFace(
    _ObbFrame obb,
    double dx,
    double dy,
    double dz,
    _SupportFace3D out,
  ) {
    var axis = 0;
    var best = -1.0;
    var sign = 1.0;
    for (var k = 0; k < 3; k++) {
      final d = obb.axisX(k) * dx + obb.axisY(k) * dy + obb.axisZ(k) * dz;
      if (d.abs() > best) {
        best = d.abs();
        axis = k;
        sign = d >= 0.0 ? 1.0 : -1.0;
      }
    }
    final a0 = (axis + 1) % 3;
    final a1 = (axis + 2) % 3;
    final nx = sign * obb.axisX(axis);
    final ny = sign * obb.axisY(axis);
    final nz = sign * obb.axisZ(axis);
    final e = obb.extent(axis);
    final fcx = obb.cx + nx * e;
    final fcy = obb.cy + ny * e;
    final fcz = obb.cz + nz * e;
    final ux = obb.axisX(a0) * obb.extent(a0);
    final uy = obb.axisY(a0) * obb.extent(a0);
    final uz = obb.axisZ(a0) * obb.extent(a0);
    final vx = obb.axisX(a1) * obb.extent(a1) * sign;
    final vy = obb.axisY(a1) * obb.extent(a1) * sign;
    final vz = obb.axisZ(a1) * obb.extent(a1) * sign;
    out
      ..reset(4)
      ..nx = nx
      ..ny = ny
      ..nz = nz
      ..faceId = axis * 2 + (sign > 0.0 ? 0 : 1)
      ..setVertex(0, fcx + ux + vx, fcy + uy + vy, fcz + uz + vz)
      ..setVertex(1, fcx - ux + vx, fcy - uy + vy, fcz - uz + vz)
      ..setVertex(2, fcx - ux - vx, fcy - uy - vy, fcz - uz - vz)
      ..setVertex(3, fcx + ux - vx, fcy + uy - vy, fcz + uz - vz);
  }

  static bool _writeHullFace(
    ConvexHullShape3D hull,
    Matrix4 transform,
    double dx,
    double dy,
    double dz,
    _SupportFace3D out,
  ) {
    final normals = hull.hullFaceNormals;
    final start = hull.hullFaceStart;
    final verts = hull.hullFaceVertices;
    if (normals == null || start == null || verts == null) {
      return false;
    }
    final m = transform.storage;
    final c0x = m[0];
    final c0y = m[1];
    final c0z = m[2];
    final c1x = m[4];
    final c1y = m[5];
    final c1z = m[6];
    final c2x = m[8];
    final c2y = m[9];
    final c2z = m[10];
    // Columns of the cofactor matrix: world normals are `cof * localNormal`.
    var k0x = c1y * c2z - c1z * c2y;
    var k0y = c1z * c2x - c1x * c2z;
    var k0z = c1x * c2y - c1y * c2x;
    var k1x = c2y * c0z - c2z * c0y;
    var k1y = c2z * c0x - c2x * c0z;
    var k1z = c2x * c0y - c2y * c0x;
    var k2x = c0y * c1z - c0z * c1y;
    var k2y = c0z * c1x - c0x * c1z;
    var k2z = c0x * c1y - c0y * c1x;
    if (c0x * k0x + c0y * k0y + c0z * k0z < 0.0) {
      k0x = -k0x;
      k0y = -k0y;
      k0z = -k0z;
      k1x = -k1x;
      k1y = -k1y;
      k1z = -k1z;
      k2x = -k2x;
      k2y = -k2y;
      k2z = -k2z;
    }
    final faceCount = start.length - 1;
    var bestFace = 0;
    var bestDot = double.negativeInfinity;
    var bnx = 0.0;
    var bny = 0.0;
    var bnz = 0.0;
    for (var f = 0; f < faceCount; f++) {
      final lx = normals[f * 3];
      final ly = normals[f * 3 + 1];
      final lz = normals[f * 3 + 2];
      final wx = k0x * lx + k1x * ly + k2x * lz;
      final wy = k0y * lx + k1y * ly + k2y * lz;
      final wz = k0z * lx + k1z * ly + k2z * lz;
      final len = math.sqrt(wx * wx + wy * wy + wz * wz);
      if (len <= 1e-30) {
        continue;
      }
      final d = (wx * dx + wy * dy + wz * dz) / len;
      if (d > bestDot) {
        bestDot = d;
        bestFace = f;
        bnx = wx / len;
        bny = wy / len;
        bnz = wz / len;
      }
    }
    if (bestDot == double.negativeInfinity) {
      return false;
    }
    final coords = hull.hullCoords;
    final s = start[bestFace];
    final count = start[bestFace + 1] - s;
    out
      ..reset(count)
      ..nx = bnx
      ..ny = bny
      ..nz = bnz
      ..faceId = bestFace;
    for (var k = 0; k < count; k++) {
      final o = verts[s + k] * 3;
      final lx = coords[o];
      final ly = coords[o + 1];
      final lz = coords[o + 2];
      out.setVertex(
        k,
        m[0] * lx + m[4] * ly + m[8] * lz + m[12],
        m[1] * lx + m[5] * ly + m[9] * lz + m[13],
        m[2] * lx + m[6] * ly + m[10] * lz + m[14],
      );
    }
    return true;
  }

  /// Builds a multi-point manifold by clipping the incident face against the
  /// side planes of the reference face (the supporting face better aligned
  /// with the A-to-B normal `(nx, ny, nz)`), or returns `null` when the faces
  /// are not aligned enough for a face contact or nothing survives clipping.
  ///
  /// [forceReference] picks the reference face (`1`: A, `2`: B) instead.
  /// Each contact point gets a feature id built from the two faces and the
  /// clipped features, stable while the same features stay in contact.
  static (bool, double, double, double, int, int, int)? _prepareClippedFaces(
    double nx,
    double ny,
    double nz,
    _SupportFace3D fA,
    _SupportFace3D fB, {
    int forceReference = 0,
  }) {
    final alignA = fA.nx * nx + fA.ny * ny + fA.nz * nz;
    final alignB = -(fB.nx * nx + fB.ny * ny + fB.nz * nz);
    final bool refIsA;
    if (forceReference == 0) {
      if (math.max(alignA, alignB) < _faceAlignmentCos) {
        return null;
      }
      refIsA = alignA >= alignB - 1e-4;
    } else {
      refIsA = forceReference == 1;
    }
    final ref = refIsA ? fA : fB;
    final inc = refIsA ? fB : fA;
    final rnx = ref.nx;
    final rny = ref.ny;
    final rnz = ref.nz;
    final rv = ref.xyz;
    final rCount = ref.count;

    var ccx = 0.0;
    var ccy = 0.0;
    var ccz = 0.0;
    for (var i = 0; i < rCount; i++) {
      ccx += rv[i * 3];
      ccy += rv[i * 3 + 1];
      ccz += rv[i * 3 + 2];
    }
    ccx /= rCount;
    ccy /= rCount;
    ccz /= rCount;

    final clip = _clip..load(inc);
    for (var i = 0; i < rCount; i++) {
      final j = i + 1 == rCount ? 0 : i + 1;
      final vix = rv[i * 3];
      final viy = rv[i * 3 + 1];
      final viz = rv[i * 3 + 2];
      final ex = rv[j * 3] - vix;
      final ey = rv[j * 3 + 1] - viy;
      final ez = rv[j * 3 + 2] - viz;
      var sx = ey * rnz - ez * rny;
      var sy = ez * rnx - ex * rnz;
      var sz = ex * rny - ey * rnx;
      final len = math.sqrt(sx * sx + sy * sy + sz * sz);
      if (len <= 1e-12) {
        continue;
      }
      sx /= len;
      sy /= len;
      sz /= len;
      if (sx * (ccx - vix) + sy * (ccy - viy) + sz * (ccz - viz) > 0.0) {
        sx = -sx;
        sy = -sy;
        sz = -sz;
      }
      final limit = sx * vix + sy * viy + sz * viz;
      if (!clip.clipHalfspace(sx, sy, sz, limit, i + 1)) {
        return null;
      }
    }

    final refD = rnx * rv[0] + rny * rv[1] + rnz * rv[2];
    final kept = clip.keepBelow(rnx, rny, rnz, refD, _faceContactTolerance);
    if (kept == 0) {
      return null;
    }
    final pick = kept <= 4 ? kept : clip.selectFour(rnx, rny, rnz, _chosen);
    final base = _mixId(
      _mixId(refIsA ? 1 : 2, ref.faceId),
      inc.faceId,
    );
    return (refIsA, rnx, rny, rnz, base, pick, kept);
  }

  static bool _clipSupportFacesInto(
    double nx,
    double ny,
    double nz,
    _SupportFace3D fA,
    _SupportFace3D fB,
    MutableManifoldBuffer3D out, {
    int forceReference = 0,
    double depthOverride = -1.0,
  }) {
    final prep = _prepareClippedFaces(
      nx,
      ny,
      nz,
      fA,
      fB,
      forceReference: forceReference,
    );
    if (prep == null) {
      return false;
    }
    final (refIsA, rnx, rny, rnz, base, pick, kept) = prep;
    final clip = _clip;
    final mIdx = out.beginManifold(
      refIsA ? rnx : -rnx,
      refIsA ? rny : -rny,
      refIsA ? rnz : -rnz,
      depthOverride >= 0.0 ? depthOverride : 0.0,
    );
    var maxDepth = 0.0;
    for (var k = 0; k < pick; k++) {
      final idx = kept <= 4 ? k : _chosen[k];
      final px = clip.keptX(idx);
      final py = clip.keptY(idx);
      final pz = clip.keptZ(idx);
      final sep = clip.keptSep(idx);
      final depth = sep < 0.0 ? -sep : 0.0;
      if (depth > maxDepth) {
        maxDepth = depth;
      }
      final refX = px - rnx * sep;
      final refY = py - rny * sep;
      final refZ = pz - rnz * sep;
      final feat = _mixId(base, clip.keptId(idx));
      if (refIsA) {
        out.addContact(mIdx, refX, refY, refZ, px, py, pz, depth, feat);
      } else {
        out.addContact(mIdx, px, py, pz, refX, refY, refZ, depth, feat);
      }
    }
    if (depthOverride < 0.0) {
      out.setDepth(mIdx, maxDepth);
    }
    return true;
  }

  static CollisionManifold3D? _clipSupportFaces(
    double nx,
    double ny,
    double nz,
    _SupportFace3D fA,
    _SupportFace3D fB, {
    int forceReference = 0,
    double depthOverride = -1.0,
  }) {
    final prep = _prepareClippedFaces(
      nx,
      ny,
      nz,
      fA,
      fB,
      forceReference: forceReference,
    );
    if (prep == null) {
      return null;
    }
    final (refIsA, rnx, rny, rnz, base, pick, kept) = prep;
    final clip = _clip;
    final contacts = <ContactPoint3D>[];
    var maxDepth = 0.0;
    var ax = 0.0;
    var ay = 0.0;
    var az = 0.0;
    var bx = 0.0;
    var by = 0.0;
    var bz = 0.0;
    for (var k = 0; k < pick; k++) {
      final idx = kept <= 4 ? k : _chosen[k];
      final px = clip.keptX(idx);
      final py = clip.keptY(idx);
      final pz = clip.keptZ(idx);
      final sep = clip.keptSep(idx);
      final depth = sep < 0.0 ? -sep : 0.0;
      if (depth > maxDepth) {
        maxDepth = depth;
      }
      final pInc = Vector3(px, py, pz);
      final pRef = Vector3(px - rnx * sep, py - rny * sep, pz - rnz * sep);
      final pa = refIsA ? pRef : pInc;
      final pb = refIsA ? pInc : pRef;
      ax += pa.x;
      ay += pa.y;
      az += pa.z;
      bx += pb.x;
      by += pb.y;
      bz += pb.z;
      contacts.add(
        ContactPoint3D(
          pointA: pa,
          pointB: pb,
          penetrationDepth: depth,
          featureId: _mixId(base, clip.keptId(idx)),
        ),
      );
    }
    final inv = 1.0 / pick;
    return CollisionManifold3D(
      normal: refIsA ? Vector3(rnx, rny, rnz) : Vector3(-rnx, -rny, -rnz),
      penetrationDepth: depthOverride >= 0.0 ? depthOverride : maxDepth,
      contactPointA: Vector3(ax * inv, ay * inv, az * inv),
      contactPointB: Vector3(bx * inv, by * inv, bz * inv),
      contacts: contacts,
    );
  }

  static CollisionManifold3D? _gjkEpa(
    void Function(Vector3 dir, Vector3 out) supportA,
    void Function(Vector3 dir, Vector3 out) supportB,
    Vector3 centerA,
    Vector3 centerB,
  ) {
    void supportMinkowski(Vector3 dir, _MinkowskiVert out) {
      supportA(dir, out.a);
      _negDir.setValues(-dir.x, -dir.y, -dir.z);
      supportB(_negDir, out.b);
      out.p
        ..setFrom(out.a)
        ..sub(out.b);
    }

    _gjkDir
      ..setFrom(centerB)
      ..sub(centerA);
    if (_gjkDir.length2 < 1e-12) {
      _gjkDir.setValues(1.0, 0.0, 0.0);
    }

    final simplex = <_MinkowskiVert>[];
    final v0 = _MinkowskiVert();
    supportMinkowski(_gjkDir, v0);
    simplex.add(v0);
    _gjkDir
      ..setFrom(v0.p)
      ..negate();

    var hit = false;
    for (var iter = 0; iter < 48; iter++) {
      if (_gjkDir.length2 < 1e-16) {
        hit = true;
        break;
      }
      final next = _MinkowskiVert();
      supportMinkowski(_gjkDir, next);
      if (next.p.dot(_gjkDir) < -1e-9) {
        return null;
      }
      simplex.add(next);
      if (_updateGjkSimplex(simplex, _gjkDir)) {
        hit = true;
        break;
      }
    }
    if (!hit) {
      return null;
    }

    return _epaSolve(simplex, supportMinkowski, centerA, centerB);
  }

  static final Vector3 _negDir = Vector3.zero();
  static final Vector3 _gjkDir = Vector3.zero();

  static bool _updateGjkSimplex(List<_MinkowskiVert> s, Vector3 dir) {
    if (s.length == 2) {
      final a = s[1].p;
      final b = s[0].p;
      final ab = b - a;
      final ao = -a;
      if (ab.dot(ao) > 0.0) {
        dir.setFrom(ab.cross(ao).cross(ab));
        if (dir.length2 < 1e-16) {
          _anyPerp(ab, dir);
        }
      } else {
        s.removeAt(0);
        dir.setFrom(ao);
      }
      return false;
    }
    if (s.length == 3) {
      final a = s[2].p;
      final b = s[1].p;
      final c = s[0].p;
      final ab = b - a;
      final ac = c - a;
      final abc = ab.cross(ac);
      final ao = -a;

      if (abc.cross(ac).dot(ao) > 0.0) {
        if (ac.dot(ao) > 0.0) {
          s.removeAt(1);
          dir.setFrom(ac.cross(ao).cross(ac));
        } else if (ab.dot(ao) > 0.0) {
          s.removeAt(0);
          dir.setFrom(ab.cross(ao).cross(ab));
        } else {
          s
            ..removeAt(1)
            ..removeAt(0);
          dir.setFrom(ao);
        }
      } else if (ab.cross(abc).dot(ao) > 0.0) {
        if (ab.dot(ao) > 0.0) {
          s.removeAt(0);
          dir.setFrom(ab.cross(ao).cross(ab));
        } else {
          s
            ..removeAt(1)
            ..removeAt(0);
          dir.setFrom(ao);
        }
      } else {
        if (abc.dot(ao) > 0.0) {
          dir.setFrom(abc);
        } else {
          final tmp = s[0];
          s[0] = s[1];
          s[1] = tmp;
          dir
            ..setFrom(abc)
            ..negate();
        }
      }
      return false;
    }

    // Tetrahedron `s = [d, c, b, a]` where `a = s[3]` was just added.
    final a = s[3].p;
    final b = s[2].p;
    final c = s[1].p;
    final d = s[0].p;
    final ao = -a;
    final ab = b - a;
    final ac = c - a;
    final ad = d - a;

    var abc = ab.cross(ac);
    if (abc.dot(ad) > 0.0) {
      abc = -abc;
    }
    var acd = ac.cross(ad);
    if (acd.dot(ab) > 0.0) {
      acd = -acd;
    }
    var adb = ad.cross(ab);
    if (adb.dot(ac) > 0.0) {
      adb = -adb;
    }

    if (abc.dot(ao) > 1e-12) {
      s.removeAt(0); // Drop d, keep [c, b, a].
      dir.setFrom(abc);
      return false;
    }
    if (acd.dot(ao) > 1e-12) {
      s.removeAt(2); // Drop b, keep [d, c, a].
      dir.setFrom(acd);
      return false;
    }
    if (adb.dot(ao) > 1e-12) {
      s.removeAt(1); // Drop c, keep [d, b, a].
      dir.setFrom(adb);
      return false;
    }
    return true;
  }

  static void _anyPerp(Vector3 v, Vector3 out) {
    if (v.x.abs() < 0.9) {
      out.setValues(0.0, -v.z, v.y);
    } else {
      out.setValues(-v.z, 0.0, v.x);
    }
    if (out.length2 < 1e-18) {
      out.setValues(0.0, 1.0, 0.0);
    }
  }

  static CollisionManifold3D _epaSolve(
    List<_MinkowskiVert> initialSimplex,
    void Function(Vector3 dir, _MinkowskiVert out) supportMinkowski,
    Vector3 centerA,
    Vector3 centerB,
  ) {
    final verts = List<_MinkowskiVert>.of(initialSimplex);

    // Pad simplex to 4 non-coplanar vertices if GJK terminated early on an
    // edge/triangle containing the origin.
    for (final probe in _epaSeedDirs) {
      if (verts.length >= 4 && _tetraVolumeAbs(verts) > 1e-9) {
        break;
      }
      final cand = _MinkowskiVert();
      supportMinkowski(probe, cand);
      var dup = false;
      for (final existing in verts) {
        if (existing.p.distanceToSquared(cand.p) < 1e-10) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        if (verts.length < 4) {
          verts.add(cand);
        } else {
          verts[3] = cand;
        }
      }
    }

    if (verts.length < 4 || _tetraVolumeAbs(verts) <= 1e-9) {
      return _sampledFallbackManifold(supportMinkowski, centerA, centerB);
    }

    // Orient initial tetrahedron faces outward from its interior centroid.
    final centroid = (verts[0].p + verts[1].p + verts[2].p + verts[3].p)
      ..scale(0.25);
    final faces = <_EpaFace>[];
    for (final (i0, i1, i2) in const [
      (0, 1, 2),
      (0, 2, 3),
      (0, 3, 1),
      (1, 3, 2),
    ]) {
      final f = _makeEpaFace(verts, i0, i1, i2, centroid);
      if (f != null) {
        faces.add(f);
      }
    }

    if (faces.isEmpty) {
      return _sampledFallbackManifold(supportMinkowski, centerA, centerB);
    }

    for (var iter = 0; iter < 48; iter++) {
      var bestIdx = 0;
      for (var i = 1; i < faces.length; i++) {
        if (faces[i].distance < faces[bestIdx].distance) {
          bestIdx = i;
        }
      }
      final best = faces[bestIdx];

      final sup = _MinkowskiVert();
      supportMinkowski(best.normal, sup);
      final supportDist = sup.p.dot(best.normal);

      if (supportDist - best.distance <= 1e-4 || verts.length >= 64) {
        return _manifoldFromEpaFace(best, verts);
      }

      final newIdx = verts.length;
      verts.add(sup);

      // Remove all faces visible from `sup.p` and collect horizon edges.
      final horizon = <(int, int)>[];
      for (var i = faces.length - 1; i >= 0; i--) {
        final f = faces[i];
        if (f.normal.dot(sup.p - verts[f.i0].p) > 1e-7) {
          faces.removeAt(i);
          _addHorizonEdge(horizon, f.i0, f.i1);
          _addHorizonEdge(horizon, f.i1, f.i2);
          _addHorizonEdge(horizon, f.i2, f.i0);
        }
      }

      if (horizon.isEmpty) {
        return _manifoldFromEpaFace(best, verts);
      }

      for (final (e0, e1) in horizon) {
        final nf = _makeEpaFace(verts, e0, e1, newIdx, centroid);
        if (nf != null) {
          faces.add(nf);
        }
      }

      if (faces.isEmpty) {
        return _manifoldFromEpaFace(best, verts);
      }
    }

    var best = faces[0];
    for (var i = 1; i < faces.length; i++) {
      if (faces[i].distance < best.distance) {
        best = faces[i];
      }
    }
    return _manifoldFromEpaFace(best, verts);
  }

  static void _addHorizonEdge(List<(int, int)> horizon, int a, int b) {
    for (var i = 0; i < horizon.length; i++) {
      final (ha, hb) = horizon[i];
      if (ha == b && hb == a) {
        horizon.removeAt(i);
        return;
      }
    }
    horizon.add((a, b));
  }

  static double _tetraVolumeAbs(List<_MinkowskiVert> v) {
    final ab = v[1].p - v[0].p;
    final ac = v[2].p - v[0].p;
    final ad = v[3].p - v[0].p;
    return ab.cross(ac).dot(ad).abs();
  }

  static _EpaFace? _makeEpaFace(
    List<_MinkowskiVert> verts,
    int i0,
    int i1,
    int i2,
    Vector3 interiorPoint,
  ) {
    final p0 = verts[i0].p;
    final p1 = verts[i1].p;
    final p2 = verts[i2].p;
    final n = (p1 - p0).cross(p2 - p0);
    final len = n.length;
    if (len <= 1e-12) {
      return null;
    }
    n.scale(1.0 / len);
    var b1 = i1;
    var b2 = i2;
    if (n.dot(p0 - interiorPoint) < 0.0) {
      n.negate();
      b1 = i2;
      b2 = i1;
    }
    final dist = math.max(0.0, n.dot(p0));
    return _EpaFace(i0, b1, b2, n, dist);
  }

  static CollisionManifold3D _manifoldFromEpaFace(
    _EpaFace face,
    List<_MinkowskiVert> verts,
  ) {
    final v0 = verts[face.i0];
    final v1 = verts[face.i1];
    final v2 = verts[face.i2];

    // Project origin onto triangle `(v0.p, v1.p, v2.p)` to interpolate exact
    // witness points on A and B via barycentric weights.
    final proj = face.normal * face.distance;
    final e0 = v1.p - v0.p;
    final e1 = v2.p - v0.p;
    final ep = proj - v0.p;
    final d00 = e0.dot(e0);
    final d01 = e0.dot(e1);
    final d11 = e1.dot(e1);
    final d20 = ep.dot(e0);
    final d21 = ep.dot(e1);
    final denom = d00 * d11 - d01 * d01;
    var u = 1.0 / 3.0;
    var v = 1.0 / 3.0;
    var w = 1.0 / 3.0;
    if (denom.abs() > 1e-14) {
      v = ((d11 * d20 - d01 * d21) / denom).clamp(0.0, 1.0);
      w = ((d00 * d21 - d01 * d20) / denom).clamp(0.0, 1.0 - v);
      u = 1.0 - v - w;
    }

    final ptA = Vector3(
      v0.a.x * u + v1.a.x * v + v2.a.x * w,
      v0.a.y * u + v1.a.y * v + v2.a.y * w,
      v0.a.z * u + v1.a.z * v + v2.a.z * w,
    );
    final ptB = Vector3(
      v0.b.x * u + v1.b.x * v + v2.b.x * w,
      v0.b.y * u + v1.b.y * v + v2.b.y * w,
      v0.b.z * u + v1.b.z * v + v2.b.z * w,
    );
    return CollisionManifold3D(
      normal: face.normal,
      penetrationDepth: face.distance,
      contactPointA: ptA,
      contactPointB: ptB,
    );
  }

  static CollisionManifold3D _sampledFallbackManifold(
    void Function(Vector3 dir, _MinkowskiVert out) supportMinkowski,
    Vector3 centerA,
    Vector3 centerB,
  ) {
    final cand = _MinkowskiVert();
    var bestDepth = double.infinity;
    final bestN = Vector3(0.0, 1.0, 0.0);
    final bestA = Vector3.copy(centerA);
    final bestB = Vector3.copy(centerB);

    for (final dir in _epaSeedDirs) {
      supportMinkowski(dir, cand);
      final d = cand.p.dot(dir);
      if (d >= 0.0 && d < bestDepth) {
        bestDepth = d;
        bestN.setFrom(dir);
        bestA.setFrom(cand.a);
        bestB.setFrom(cand.b);
      }
    }
    if (!bestDepth.isFinite) {
      bestDepth = 0.0;
    }
    return CollisionManifold3D(
      normal: bestN,
      penetrationDepth: bestDepth,
      contactPointA: bestA,
      contactPointB: bestB,
    );
  }

  static final List<Vector3> _epaSeedDirs = _buildSphereDirs();

  static List<Vector3> _buildSphereDirs() {
    final dirs = <Vector3>[
      Vector3(1, 0, 0),
      Vector3(-1, 0, 0),
      Vector3(0, 1, 0),
      Vector3(0, -1, 0),
      Vector3(0, 0, 1),
      Vector3(0, 0, -1),
    ];
    const s2 = 0.7071067811865475;
    const s3 = 0.5773502691896258;
    for (final sx in const [-1.0, 1.0]) {
      for (final sy in const [-1.0, 1.0]) {
        dirs
          ..add(Vector3(sx * s2, sy * s2, 0))
          ..add(Vector3(sx * s2, 0, sy * s2))
          ..add(Vector3(0, sx * s2, sy * s2));
        for (final sz in const [-1.0, 1.0]) {
          dirs.add(Vector3(sx * s3, sy * s3, sz * s3));
        }
      }
    }
    return List.unmodifiable(dirs);
  }
}

class _MinkowskiVert() {
  final Vector3 p = Vector3.zero();
  final Vector3 a = Vector3.zero();
  final Vector3 b = Vector3.zero();
}

class _EpaFace(this.i0, this.i1, this.i2, this.normal, this.distance) {
  final int i0;
  final int i1;
  final int i2;
  final Vector3 normal;
  final double distance;
}

class _ObbFrame() {
  double cx = 0.0;
  double cy = 0.0;
  double cz = 0.0;
  double u0x = 1.0;
  double u0y = 0.0;
  double u0z = 0.0;
  double u1x = 0.0;
  double u1y = 1.0;
  double u1z = 0.0;
  double u2x = 0.0;
  double u2y = 0.0;
  double u2z = 1.0;
  double ex = 0.5;
  double ey = 0.5;
  double ez = 0.5;

  void extract(BoxShape3D box, Matrix4 m4) {
    final m = m4.storage;
    cx = m[12];
    cy = m[13];
    cz = m[14];

    final s0 = math.sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]);
    final s1 = math.sqrt(m[4] * m[4] + m[5] * m[5] + m[6] * m[6]);
    final s2 = math.sqrt(m[8] * m[8] + m[9] * m[9] + m[10] * m[10]);

    if (s0 > 1e-12) {
      u0x = m[0] / s0;
      u0y = m[1] / s0;
      u0z = m[2] / s0;
    } else {
      u0x = 1.0;
      u0y = 0.0;
      u0z = 0.0;
    }
    if (s1 > 1e-12) {
      u1x = m[4] / s1;
      u1y = m[5] / s1;
      u1z = m[6] / s1;
    } else {
      u1x = 0.0;
      u1y = 1.0;
      u1z = 0.0;
    }
    if (s2 > 1e-12) {
      u2x = m[8] / s2;
      u2y = m[9] / s2;
      u2z = m[10] / s2;
    } else {
      u2x = 0.0;
      u2y = 0.0;
      u2z = 1.0;
    }

    ex = math.max(1e-6, box.halfExtents.x * s0);
    ey = math.max(1e-6, box.halfExtents.y * s1);
    ez = math.max(1e-6, box.halfExtents.z * s2);
  }

  double toLocalX(double wx, double wy, double wz) =>
      (wx - cx) * u0x + (wy - cy) * u0y + (wz - cz) * u0z;

  double toLocalY(double wx, double wy, double wz) =>
      (wx - cx) * u1x + (wy - cy) * u1y + (wz - cz) * u1z;

  double toLocalZ(double wx, double wy, double wz) =>
      (wx - cx) * u2x + (wy - cy) * u2y + (wz - cz) * u2z;

  void toWorld(double lx, double ly, double lz, Vector3 out) {
    out.setValues(
      cx + u0x * lx + u1x * ly + u2x * lz,
      cy + u0y * lx + u1y * ly + u2y * lz,
      cz + u0z * lx + u1z * ly + u2z * lz,
    );
  }

  void dirToWorld(double lx, double ly, double lz, Vector3 out) {
    out.setValues(
      u0x * lx + u1x * ly + u2x * lz,
      u0y * lx + u1y * ly + u2y * lz,
      u0z * lx + u1z * ly + u2z * lz,
    );
  }

  double projectRadius(double ax, double ay, double az) {
    return ex * (u0x * ax + u0y * ay + u0z * az).abs() +
        ey * (u1x * ax + u1y * ay + u1z * az).abs() +
        ez * (u2x * ax + u2y * ay + u2z * az).abs();
  }

  double axisX(int i) => i == 0 ? u0x : (i == 1 ? u1x : u2x);
  double axisY(int i) => i == 0 ? u0y : (i == 1 ? u1y : u2y);
  double axisZ(int i) => i == 0 ? u0z : (i == 1 ? u1z : u2z);
  double extent(int i) => i == 0 ? ex : (i == 1 ? ey : ez);

  void supportEdge(
    int edgeAxis,
    double dx,
    double dy,
    double dz,
    Vector3 out0,
    Vector3 out1,
  ) {
    final s = Float64List(3);
    for (var k = 0; k < 3; k++) {
      if (k == edgeAxis) {
        s[k] = 0.0;
      } else {
        final dot = axisX(k) * dx + axisY(k) * dy + axisZ(k) * dz;
        s[k] = (dot >= 0.0 ? 1.0 : -1.0) * extent(k);
      }
    }
    final e = extent(edgeAxis);
    s[edgeAxis] = -e;
    toWorld(s[0], s[1], s[2], out0);
    s[edgeAxis] = e;
    toWorld(s[0], s[1], s[2], out1);
  }
}

/// Flat median-split AABB BVH over a [Surface]'s triangles for `O(log T)` local
/// AABB overlap queries without heap allocations during traversal.
class _SurfaceTriangleAabbTree._({
  required final int nodeCount,
  required final Float32List bounds,
  required final Int32List leftOrFirst,
  required final Int32List rightChild,
  required final Int32List counts,
  required final Int32List triangles,
}) {
  factory _SurfaceTriangleAabbTree.build(Surface surface) {
    final posOffset = surface.layout.offsetOf(VertexLayout.positionAttribute);
    final indices = surface.indices;
    final triCount = indices.length ~/ 3;
    if (posOffset == null || triCount == 0) {
      return _SurfaceTriangleAabbTree._(
        nodeCount: 0,
        bounds: Float32List(0),
        leftOrFirst: Int32List(0),
        rightChild: Int32List(0),
        counts: Int32List(0),
        triangles: Int32List(0),
      );
    }

    final verts = surface.vertexData;
    final stride = surface.layout.strideInFloats;
    final triIndices = Int32List(triCount);
    final triBounds = Float32List(triCount * 6);
    final centroids = Float32List(triCount * 3);

    for (var t = 0; t < triCount; t++) {
      triIndices[t] = t;
      final b = t * 3;
      final i0 = indices[b] * stride + posOffset;
      final i1 = indices[b + 1] * stride + posOffset;
      final i2 = indices[b + 2] * stride + posOffset;

      final x0 = verts[i0];
      final y0 = verts[i0 + 1];
      final z0 = verts[i0 + 2];
      final x1 = verts[i1];
      final y1 = verts[i1 + 1];
      final z1 = verts[i1 + 2];
      final x2 = verts[i2];
      final y2 = verts[i2 + 1];
      final z2 = verts[i2 + 2];

      final tb = t * 6;
      triBounds
        ..[tb] = math.min(x0, math.min(x1, x2))
        ..[tb + 1] = math.min(y0, math.min(y1, y2))
        ..[tb + 2] = math.min(z0, math.min(z1, z2))
        ..[tb + 3] = math.max(x0, math.max(x1, x2))
        ..[tb + 4] = math.max(y0, math.max(y1, y2))
        ..[tb + 5] = math.max(z0, math.max(z1, z2));

      final cb = t * 3;
      centroids
        ..[cb] = (x0 + x1 + x2) * (1.0 / 3.0)
        ..[cb + 1] = (y0 + y1 + y2) * (1.0 / 3.0)
        ..[cb + 2] = (z0 + z1 + z2) * (1.0 / 3.0);
    }

    final maxNodes = math.max(1, triCount * 2);
    final bounds = Float32List(maxNodes * 6);
    final leftOrFirst = Int32List(maxNodes);
    final rightChild = Int32List(maxNodes);
    final counts = Int32List(maxNodes);
    var nodeCount = 0;

    int buildNode(int start, int count) {
      final node = nodeCount++;
      var minX = double.infinity;
      var minY = double.infinity;
      var minZ = double.infinity;
      var maxX = double.negativeInfinity;
      var maxY = double.negativeInfinity;
      var maxZ = double.negativeInfinity;
      var cMinX = double.infinity;
      var cMinY = double.infinity;
      var cMinZ = double.infinity;
      var cMaxX = double.negativeInfinity;
      var cMaxY = double.negativeInfinity;
      var cMaxZ = double.negativeInfinity;

      for (var i = start; i < start + count; i++) {
        final t = triIndices[i];
        final tb = t * 6;
        minX = math.min(minX, triBounds[tb]);
        minY = math.min(minY, triBounds[tb + 1]);
        minZ = math.min(minZ, triBounds[tb + 2]);
        maxX = math.max(maxX, triBounds[tb + 3]);
        maxY = math.max(maxY, triBounds[tb + 4]);
        maxZ = math.max(maxZ, triBounds[tb + 5]);

        final cb = t * 3;
        cMinX = math.min(cMinX, centroids[cb]);
        cMinY = math.min(cMinY, centroids[cb + 1]);
        cMinZ = math.min(cMinZ, centroids[cb + 2]);
        cMaxX = math.max(cMaxX, centroids[cb]);
        cMaxY = math.max(cMaxY, centroids[cb + 1]);
        cMaxZ = math.max(cMaxZ, centroids[cb + 2]);
      }

      final nb = node * 6;
      bounds
        ..[nb] = minX
        ..[nb + 1] = minY
        ..[nb + 2] = minZ
        ..[nb + 3] = maxX
        ..[nb + 4] = maxY
        ..[nb + 5] = maxZ;

      if (count <= 4) {
        leftOrFirst[node] = start;
        counts[node] = count;
        return node;
      }

      final extX = cMaxX - cMinX;
      final extY = cMaxY - cMinY;
      final extZ = cMaxZ - cMinZ;
      var axis = 0;
      var split = 0.5 * (cMinX + cMaxX);
      var extent = extX;
      if (extY > extent) {
        axis = 1;
        split = 0.5 * (cMinY + cMaxY);
        extent = extY;
      }
      if (extZ > extent) {
        axis = 2;
        split = 0.5 * (cMinZ + cMaxZ);
        extent = extZ;
      }

      int mid;
      if (extent <= 1e-12) {
        mid = start + (count >> 1);
      } else {
        var i = start;
        var j = start + count - 1;
        while (i <= j) {
          if (centroids[triIndices[i] * 3 + axis] < split) {
            i++;
          } else {
            final tmp = triIndices[i];
            triIndices[i] = triIndices[j];
            triIndices[j] = tmp;
            j--;
          }
        }
        mid = i;
        if (mid == start || mid == start + count) {
          mid = start + (count >> 1);
        }
      }

      counts[node] = 0;
      leftOrFirst[node] = buildNode(start, mid - start);
      rightChild[node] = buildNode(mid, start + count - mid);
      return node;
    }

    buildNode(0, triCount);
    return _SurfaceTriangleAabbTree._(
      nodeCount: nodeCount,
      bounds: Float32List.sublistView(bounds, 0, nodeCount * 6),
      leftOrFirst: Int32List.sublistView(leftOrFirst, 0, nodeCount),
      rightChild: Int32List.sublistView(rightChild, 0, nodeCount),
      counts: Int32List.sublistView(counts, 0, nodeCount),
      triangles: triIndices,
    );
  }

  final Int32List _stack = Int32List(128);

  void queryAabb(Aabb3 query, List<int> outTriangles) {
    if (nodeCount == 0) {
      return;
    }
    final qMinX = query.min.x - 1e-5;
    final qMinY = query.min.y - 1e-5;
    final qMinZ = query.min.z - 1e-5;
    final qMaxX = query.max.x + 1e-5;
    final qMaxY = query.max.y + 1e-5;
    final qMaxZ = query.max.z + 1e-5;

    var sp = 0;
    _stack[sp++] = 0;

    while (sp > 0) {
      final node = _stack[--sp];
      final nb = node * 6;
      if (bounds[nb] > qMaxX ||
          bounds[nb + 3] < qMinX ||
          bounds[nb + 1] > qMaxY ||
          bounds[nb + 4] < qMinY ||
          bounds[nb + 2] > qMaxZ ||
          bounds[nb + 5] < qMinZ) {
        continue;
      }
      final cnt = counts[node];
      if (cnt > 0) {
        final start = leftOrFirst[node];
        for (var i = start; i < start + cnt; i++) {
          outTriangles.add(triangles[i]);
        }
      } else {
        _stack[sp++] = rightChild[node];
        _stack[sp++] = leftOrFirst[node];
      }
    }
  }
}

/// A shape's supporting face in world space: a convex polygon and its outward
/// unit normal (reused between narrowphase calls).
class _SupportFace3D() {
  Float64List xyz = Float64List(48);
  int count = 0;
  double nx = 0.0;
  double ny = 0.0;
  double nz = 0.0;
  int faceId = 0;

  void reset(int vertexCount) {
    if (xyz.length < vertexCount * 3) {
      xyz = Float64List(vertexCount * 3);
    }
    count = vertexCount;
  }

  void setVertex(int i, double x, double y, double z) {
    xyz[i * 3] = x;
    xyz[i * 3 + 1] = y;
    xyz[i * 3 + 2] = z;
  }

  void setTriangle(Vector3 v0, Vector3 v1, Vector3 v2) {
    reset(3);
    setVertex(0, v0.x, v0.y, v0.z);
    setVertex(1, v1.x, v1.y, v1.z);
    setVertex(2, v2.x, v2.y, v2.z);
  }
}

/// Ping-pong polygon buffers for Sutherland-Hodgman clipping with feature ids
/// per vertex, growing only when a larger polygon is seen.
class _ClipBuffer3D() {
  Float64List _a = Float64List(96);
  Float64List _b = Float64List(96);
  Int32List _aId = Int32List(32);
  Int32List _bId = Int32List(32);
  int _count = 0;
  Float64List _kept = Float64List(128);
  Int32List _keptId = Int32List(32);

  void _ensure(int vertices) {
    if (_aId.length < vertices) {
      final cap = vertices * 2;
      _a = Float64List(cap * 3)..setRange(0, _count * 3, _a);
      _aId = Int32List(cap)..setRange(0, _count, _aId);
      _b = Float64List(cap * 3);
      _bId = Int32List(cap);
      _kept = Float64List(cap * 4);
      _keptId = Int32List(cap);
    }
  }

  void load(_SupportFace3D face) {
    _count = 0;
    _ensure(face.count + 8);
    for (var i = 0; i < face.count; i++) {
      _a[i * 3] = face.xyz[i * 3];
      _a[i * 3 + 1] = face.xyz[i * 3 + 1];
      _a[i * 3 + 2] = face.xyz[i * 3 + 2];
      _aId[i] = i;
    }
    _count = face.count;
  }

  /// Keeps the part of the polygon with `n . x <= limit`; returns `false`
  /// when nothing is left.
  bool clipHalfspace(double nx, double ny, double nz, double limit, int plane) {
    _ensure(_count * 2 + 2);
    var outCount = 0;
    final n = _count;
    if (n == 0) {
      return false;
    }
    var prev = n - 1;
    var prevDist =
        _a[prev * 3] * nx +
        _a[prev * 3 + 1] * ny +
        _a[prev * 3 + 2] * nz -
        limit;
    for (var i = 0; i < n; i++) {
      final currDist =
          _a[i * 3] * nx + _a[i * 3 + 1] * ny + _a[i * 3 + 2] * nz - limit;
      // A vertex within 10 micrometres of the plane stays in (with its own
      // feature id): equal faces stacked edge on edge otherwise flip between
      // kept and clipped vertices with float noise.
      final prevIn = prevDist <= 1e-5;
      final currIn = currDist <= 1e-5;
      if (prevIn != currIn) {
        final t = prevDist / (prevDist - currDist);
        _b[outCount * 3] = _a[prev * 3] + (_a[i * 3] - _a[prev * 3]) * t;
        _b[outCount * 3 + 1] =
            _a[prev * 3 + 1] + (_a[i * 3 + 1] - _a[prev * 3 + 1]) * t;
        _b[outCount * 3 + 2] =
            _a[prev * 3 + 2] + (_a[i * 3 + 2] - _a[prev * 3 + 2]) * t;
        _bId[outCount] = Narrowphase3D._mixId(
          Narrowphase3D._mixId(_aId[prev] + 64, _aId[i] + 64),
          plane,
        );
        outCount++;
      }
      if (currIn) {
        _b[outCount * 3] = _a[i * 3];
        _b[outCount * 3 + 1] = _a[i * 3 + 1];
        _b[outCount * 3 + 2] = _a[i * 3 + 2];
        _bId[outCount] = _aId[i];
        outCount++;
      }
      prev = i;
      prevDist = currDist;
    }
    final t = _a;
    _a = _b;
    _b = t;
    final tId = _aId;
    _aId = _bId;
    _bId = tId;
    _count = outCount;
    return outCount > 0;
  }

  /// Keeps the vertices at most [tolerance] above the plane `n . x = d`,
  /// storing their signed separation; returns how many were kept.
  int keepBelow(double nx, double ny, double nz, double d, double tolerance) {
    var kept = 0;
    for (var i = 0; i < _count; i++) {
      final x = _a[i * 3];
      final y = _a[i * 3 + 1];
      final z = _a[i * 3 + 2];
      final sep = nx * x + ny * y + nz * z - d;
      if (sep <= tolerance) {
        _kept[kept * 4] = x;
        _kept[kept * 4 + 1] = y;
        _kept[kept * 4 + 2] = z;
        _kept[kept * 4 + 3] = sep;
        _keptId[kept] = _aId[i];
        kept++;
      }
    }
    _keptCount = kept;
    return kept;
  }

  int _keptCount = 0;

  double keptX(int i) => _kept[i * 4];
  double keptY(int i) => _kept[i * 4 + 1];
  double keptZ(int i) => _kept[i * 4 + 2];
  double keptSep(int i) => _kept[i * 4 + 3];
  int keptId(int i) => _keptId[i];

  double _dist2(int i, int j) {
    final dx = keptX(i) - keptX(j);
    final dy = keptY(i) - keptY(j);
    final dz = keptZ(i) - keptZ(j);
    return dx * dx + dy * dy + dz * dz;
  }

  /// Picks four well-spread kept points (the deepest, the farthest from it,
  /// the one spanning the largest triangle with both, then the farthest from
  /// those three) into [out]; returns `4`.
  int selectFour(double nx, double ny, double nz, Int32List out) {
    final n = _keptCount;
    var i0 = 0;
    for (var i = 1; i < n; i++) {
      if (keptSep(i) < keptSep(i0)) {
        i0 = i;
      }
    }
    var i1 = i0 == 0 ? 1 : 0;
    var best = -1.0;
    for (var i = 0; i < n; i++) {
      if (i == i0) {
        continue;
      }
      final dx = keptX(i) - keptX(i0);
      final dy = keptY(i) - keptY(i0);
      final dz = keptZ(i) - keptZ(i0);
      final d2 = dx * dx + dy * dy + dz * dz;
      if (d2 > best) {
        best = d2;
        i1 = i;
      }
    }
    var i2 = -1;
    best = -1.0;
    final e1x = keptX(i1) - keptX(i0);
    final e1y = keptY(i1) - keptY(i0);
    final e1z = keptZ(i1) - keptZ(i0);
    for (var i = 0; i < n; i++) {
      if (i == i0 || i == i1) {
        continue;
      }
      final e2x = keptX(i) - keptX(i0);
      final e2y = keptY(i) - keptY(i0);
      final e2z = keptZ(i) - keptZ(i0);
      final cx = e1y * e2z - e1z * e2y;
      final cy = e1z * e2x - e1x * e2z;
      final cz = e1x * e2y - e1y * e2x;
      final area = (cx * nx + cy * ny + cz * nz).abs();
      if (area > best) {
        best = area;
        i2 = i;
      }
    }
    var i3 = -1;
    best = -1.0;
    for (var i = 0; i < n; i++) {
      if (i == i0 || i == i1 || i == i2) {
        continue;
      }
      final dMin = math.min(
        _dist2(i, i0),
        math.min(_dist2(i, i1), i2 < 0 ? double.infinity : _dist2(i, i2)),
      );
      if (dMin > best) {
        best = dMin;
        i3 = i;
      }
    }
    out[0] = i0;
    out[1] = i1;
    out[2] = i2;
    out[3] = i3;
    return 4;
  }
}
