import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:meta/meta.dart';

part 'narrowphase_distance_3d.dart';
part 'narrowphase_gjk_epa_3d.dart';
part 'narrowphase_mesh_terrain_3d.dart';
part 'narrowphase_primitives_3d.dart';

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

  /// Updates the normal stored for [manifoldIndex].
  void setNormal(int manifoldIndex, double nx, double ny, double nz) {
    final mo = manifoldIndex * 4;
    _manifoldData[mo] = nx;
    _manifoldData[mo + 1] = ny;
    _manifoldData[mo + 2] = nz;
  }

  /// Flips normals and swaps witness points `A <-> B` for all manifolds from
  /// [startManifold] to the end of the buffer.
  void flipManifoldsFrom(int startManifold) {
    for (var m = startManifold; m < _manifoldCount; m++) {
      final mo = m * 4;
      _manifoldData[mo] = -_manifoldData[mo];
      _manifoldData[mo + 1] = -_manifoldData[mo + 1];
      _manifoldData[mo + 2] = -_manifoldData[mo + 2];
      final start = _manifoldRanges[m * 2];
      final len = _manifoldRanges[m * 2 + 1];
      for (var k = 0; k < len; k++) {
        final co = (start + k) * 7;
        final tx = _contactData[co];
        final ty = _contactData[co + 1];
        final tz = _contactData[co + 2];
        _contactData[co] = _contactData[co + 3];
        _contactData[co + 1] = _contactData[co + 4];
        _contactData[co + 2] = _contactData[co + 5];
        _contactData[co + 3] = tx;
        _contactData[co + 4] = ty;
        _contactData[co + 5] = tz;
      }
    }
  }

  /// Copies [srcManifoldIndex] (and all of its contacts) from [src] into
  /// `this` without heap allocations.
  void copyManifoldFrom(MutableManifoldBuffer3D src, int srcManifoldIndex) {
    final mIdx = beginManifold(
      src.normalX(srcManifoldIndex),
      src.normalY(srcManifoldIndex),
      src.normalZ(srcManifoldIndex),
      src.depth(srcManifoldIndex),
    );
    final start = src.contactStart(srcManifoldIndex);
    final len = src.contactLength(srcManifoldIndex);
    for (var k = 0; k < len; k++) {
      final ci = start + k;
      addContact(
        mIdx,
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
    if (shapeA is CompoundShape3D) {
      _rawManifoldBuf.clear();
      _collectCompoundRawInto(
        shapeA,
        transformA,
        shapeB,
        transformB,
        _rawManifoldBuf,
        0,
      );
      _mergeCoDirectionalInto(_rawManifoldBuf, out);
      return;
    }
    if (shapeB is CompoundShape3D) {
      _rawManifoldBuf.clear();
      _collectCompoundRawInto(
        shapeB,
        transformB,
        shapeA,
        transformA,
        _rawManifoldBuf,
        0,
      );
      _rawManifoldBuf.flipManifoldsFrom(0);
      _mergeCoDirectionalInto(_rawManifoldBuf, out);
      return;
    }
    if (shapeA is HeightfieldShape3D) {
      _rawManifoldBuf.clear();
      _heightfieldShapeRawInto(
        shapeB,
        transformB,
        shapeA,
        transformA,
        _rawManifoldBuf,
      );
      _rawManifoldBuf.flipManifoldsFrom(0);
      _mergeCoDirectionalInto(_rawManifoldBuf, out);
      return;
    }
    if (shapeB is HeightfieldShape3D) {
      _rawManifoldBuf.clear();
      _heightfieldShapeRawInto(
        shapeA,
        transformA,
        shapeB,
        transformB,
        _rawManifoldBuf,
      );
      _mergeCoDirectionalInto(_rawManifoldBuf, out);
      return;
    }
    _primitiveOrConvexInto(shapeA, transformA, shapeB, transformB, out);
  }

  static void _primitiveOrConvexInto(
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
        _convexConvexInto(shapeA, transformA, shapeB, transformB, out);
    }
  }

  /// Exact analytical Sphere-Sphere narrowphase.
  static CollisionManifold3D? sphereSphere(
    SphereShape3D a,
    Matrix4 transformA,
    SphereShape3D b,
    Matrix4 transformB,
  ) => _npSphereSphere(a, transformA, b, transformB);

  /// Exact Sphere-Capsule narrowphase (`a`: sphere, `b`: capsule).
  static CollisionManifold3D? sphereCapsule(
    SphereShape3D a,
    Matrix4 transformA,
    CapsuleShape3D b,
    Matrix4 transformB,
  ) => _npSphereCapsule(a, transformA, b, transformB);

  /// Exact Capsule-Capsule narrowphase via segment-segment closest points.
  static CollisionManifold3D? capsuleCapsule(
    CapsuleShape3D a,
    Matrix4 transformA,
    CapsuleShape3D b,
    Matrix4 transformB,
  ) => _npCapsuleCapsule(a, transformA, b, transformB);

  /// Exact Sphere-Box (OBB) narrowphase.
  static CollisionManifold3D? sphereBox(
    SphereShape3D a,
    Matrix4 transformA,
    BoxShape3D b,
    Matrix4 transformB,
  ) => _npSphereBox(a, transformA, b, transformB);

  /// Exact Capsule-Box (OBB) narrowphase via segment-to-OBB distance.
  static CollisionManifold3D? capsuleBox(
    CapsuleShape3D a,
    Matrix4 transformA,
    BoxShape3D b,
    Matrix4 transformB,
  ) => _npCapsuleBox(a, transformA, b, transformB);

  /// Exact SAT Box-Box narrowphase (face-face clipping + edge-edge contacts).
  static CollisionManifold3D? boxBox(
    BoxShape3D a,
    Matrix4 transformA,
    BoxShape3D b,
    Matrix4 transformB,
  ) => _npBoxBox(a, transformA, b, transformB);

  /// General Convex-Convex narrowphase using GJK + EPA.
  static CollisionManifold3D? convexConvex(
    Shape3D shapeA,
    Matrix4 transformA,
    Shape3D shapeB,
    Matrix4 transformB,
  ) => _npConvexConvex(shapeA, transformA, shapeB, transformB);

  /// Deepest contact manifold between [shape] and static triangles in
  /// [surface].
  static CollisionManifold3D? intersectShapeWithSurfaceBvh(
    Shape3D shape,
    Matrix4 shapeTransform,
    Surface surface,
    Matrix4 meshTransform,
  ) => _npIntersectShapeWithSurfaceBvh(
    shape,
    shapeTransform,
    surface,
    meshTransform,
  );

  /// All colliding manifolds between [shape] and triangles in [surface].
  static List<CollisionManifold3D> intersectShapeWithSurfaceBvhAll(
    Shape3D shape,
    Matrix4 shapeTransform,
    Surface surface,
    Matrix4 meshTransform,
  ) => _npIntersectShapeWithSurfaceBvhAll(
    shape,
    shapeTransform,
    surface,
    meshTransform,
  );

  /// Deepest contact manifold between [shape] and [heightfield].
  static CollisionManifold3D? heightfieldShape(
    Shape3D shape,
    Matrix4 shapeTransform,
    HeightfieldShape3D heightfield,
    Matrix4 heightfieldTransform,
  ) => _npHeightfieldShape(
    shape,
    shapeTransform,
    heightfield,
    heightfieldTransform,
  );

  /// All contact manifolds between [shape] and triangles of [heightfield].
  static List<CollisionManifold3D> heightfieldShapeAll(
    Shape3D shape,
    Matrix4 shapeTransform,
    HeightfieldShape3D heightfield,
    Matrix4 heightfieldTransform,
  ) => _npHeightfieldShapeAll(
    shape,
    shapeTransform,
    heightfield,
    heightfieldTransform,
  );

  /// Computes contact manifold between [shape] and world-space triangle
  /// `(v0, v1, v2)`.
  static CollisionManifold3D? intersectShapeWithTriangle(
    Shape3D shape,
    Matrix4 shapeTransform,
    Vector3 v0,
    Vector3 v1,
    Vector3 v2,
  ) => _npIntersectShapeWithTriangle(shape, shapeTransform, v0, v1, v2);

  // Supporting-face contact manifolds (box and hull faces).

  /// Largest separation (in world units) at which a clipped face point is
  /// still reported (with a penetration depth of `0`): points of a face that
  /// is about to touch stay in the manifold instead of flickering in and out.

  /// Minimum cosine (about 5.7 degrees) between the contact normal and the
  /// better aligned of the two supporting faces for a face contact. Below it
  /// the contact is edge against edge and keeps a single point.
}
