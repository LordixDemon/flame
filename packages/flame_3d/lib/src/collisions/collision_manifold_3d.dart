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

  /// Total number of stored contact points in this buffer.
  int get contactCount => _contactCount;

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

  /// Compacts `[baseManifold .. _manifoldCount)` down to only [keepManifold],
  /// discarding all sibling manifolds and their contacts added since
  /// `baseManifold` / `baseContact` without heap allocations.
  void retainOnlyManifold(int baseManifold, int baseContact, int keepManifold) {
    final keepStart = _manifoldRanges[keepManifold * 2];
    final keepLen = _manifoldRanges[keepManifold * 2 + 1];
    if (keepManifold != baseManifold) {
      final srcM = keepManifold * 4;
      final dstM = baseManifold * 4;
      _manifoldData
        ..[dstM] = _manifoldData[srcM]
        ..[dstM + 1] = _manifoldData[srcM + 1]
        ..[dstM + 2] = _manifoldData[srcM + 2]
        ..[dstM + 3] = _manifoldData[srcM + 3];
    }
    if (keepStart != baseContact) {
      for (var k = 0; k < keepLen; k++) {
        final srcC = (keepStart + k) * 7;
        final dstC = (baseContact + k) * 7;
        for (var j = 0; j < 7; j++) {
          _contactData[dstC + j] = _contactData[srcC + j];
        }
        _contactFeatures[baseContact + k] = _contactFeatures[keepStart + k];
      }
    }
    final ro = baseManifold * 2;
    _manifoldRanges
      ..[ro] = baseContact
      ..[ro + 1] = keepLen;
    _manifoldCount = baseManifold + 1;
    _contactCount = baseContact + keepLen;
  }

  /// Materializes manifold [manifoldIndex] as an immutable
  /// [CollisionManifold3D].
  CollisionManifold3D materializeAt(int manifoldIndex) {
    final mo = manifoldIndex * 4;
    final normal = Vector3(
      _manifoldData[mo],
      _manifoldData[mo + 1],
      _manifoldData[mo + 2],
    );
    final depth = _manifoldData[mo + 3];
    final start = contactStart(manifoldIndex);
    final len = contactLength(manifoldIndex);
    if (len <= 0) {
      return CollisionManifold3D(
        normal: normal,
        penetrationDepth: depth,
        contactPointA: Vector3.zero(),
        contactPointB: Vector3.zero(),
        contacts: const [],
      );
    }
    if (len == 1) {
      final co = start * 7;
      final pa = Vector3(
        _contactData[co],
        _contactData[co + 1],
        _contactData[co + 2],
      );
      final pb = Vector3(
        _contactData[co + 3],
        _contactData[co + 4],
        _contactData[co + 5],
      );
      return CollisionManifold3D(
        normal: normal,
        penetrationDepth: depth,
        contactPointA: pa,
        contactPointB: pb,
        contacts: [
          ContactPoint3D(
            pointA: pa,
            pointB: pb,
            penetrationDepth: _contactData[co + 6],
            featureId: _contactFeatures[start],
          ),
        ],
      );
    }
    var ax = 0.0;
    var ay = 0.0;
    var az = 0.0;
    var bx = 0.0;
    var by = 0.0;
    var bz = 0.0;
    final contacts = List<ContactPoint3D>.generate(len, (k) {
      final ci = start + k;
      final co = ci * 7;
      final pax = _contactData[co];
      final pay = _contactData[co + 1];
      final paz = _contactData[co + 2];
      final pbx = _contactData[co + 3];
      final pby = _contactData[co + 4];
      final pbz = _contactData[co + 5];
      ax += pax;
      ay += pay;
      az += paz;
      bx += pbx;
      by += pby;
      bz += pbz;
      return ContactPoint3D(
        pointA: Vector3(pax, pay, paz),
        pointB: Vector3(pbx, pby, pbz),
        penetrationDepth: _contactData[co + 6],
        featureId: _contactFeatures[ci],
      );
    }, growable: false);
    final inv = 1.0 / len;
    return CollisionManifold3D(
      normal: normal,
      penetrationDepth: depth,
      contactPointA: Vector3(ax * inv, ay * inv, az * inv),
      contactPointB: Vector3(bx * inv, by * inv, bz * inv),
      contacts: contacts,
    );
  }

  /// Materializes the first manifold, or `null` if the buffer is empty.
  CollisionManifold3D? materializeFirst() =>
      _manifoldCount == 0 ? null : materializeAt(0);

  /// Materializes the manifold with greatest depth, or `null` if empty.
  CollisionManifold3D? materializeDeepest() {
    if (_manifoldCount == 0) {
      return null;
    }
    var best = 0;
    var bestDepth = depth(0);
    for (var m = 1; m < _manifoldCount; m++) {
      final d = depth(m);
      if (d > bestDepth) {
        bestDepth = d;
        best = m;
      }
    }
    return materializeAt(best);
  }

  /// Materializes all manifolds in order as a growable list (`const []` if
  /// empty).
  List<CollisionManifold3D> materializeAll() {
    if (_manifoldCount == 0) {
      return const [];
    }
    return [for (var m = 0; m < _manifoldCount; m++) materializeAt(m)];
  }
}

/// Narrowphase 3D intersection solver supporting analytical primitives, 15-axis
/// OBB SAT with Sutherland-Hodgman face clipping, general GJK+EPA convex
/// hulls, and `O(log T)` [Surface] triangle BVH queries.
abstract final class Narrowphase3D._() {
  static final MutableManifoldBuffer3D _publicOutBuf =
      MutableManifoldBuffer3D();
  static bool _inPublicQuery = false;

  static MutableManifoldBuffer3D _acquirePublicBuffer() {
    if (_inPublicQuery) {
      return MutableManifoldBuffer3D();
    }
    _inPublicQuery = true;
    _publicOutBuf.clear();
    return _publicOutBuf;
  }

  static void _releasePublicBuffer(MutableManifoldBuffer3D buf) {
    if (identical(buf, _publicOutBuf)) {
      _inPublicQuery = false;
    }
  }

  /// Computes the [CollisionManifold3D] between [shapeA] at [transformA] and
  /// [shapeB] at [transformB], or `null` when separated.
  static CollisionManifold3D? test(
    Shape3D shapeA,
    Matrix4 transformA,
    Shape3D shapeB,
    Matrix4 transformB,
  ) {
    final buf = _acquirePublicBuffer();
    try {
      testAllInto(shapeA, transformA, shapeB, transformB, buf);
      return buf.materializeDeepest();
    } finally {
      _releasePublicBuffer(buf);
    }
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
    final buf = _acquirePublicBuffer();
    try {
      testAllInto(shapeA, transformA, shapeB, transformB, buf);
      return buf.materializeAll();
    } finally {
      _releasePublicBuffer(buf);
    }
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
      final raw = _acquireRawManifoldBuf();
      try {
        _collectCompoundRawInto(shapeA, transformA, shapeB, transformB, raw, 0);
        _mergeCoDirectionalInto(raw, out);
      } finally {
        _releaseRawManifoldBuf(raw);
      }
      return;
    }
    if (shapeB is CompoundShape3D) {
      final raw = _acquireRawManifoldBuf();
      try {
        _collectCompoundRawInto(shapeB, transformB, shapeA, transformA, raw, 0);
        raw.flipManifoldsFrom(0);
        _mergeCoDirectionalInto(raw, out);
      } finally {
        _releaseRawManifoldBuf(raw);
      }
      return;
    }
    if (shapeA is HeightfieldShape3D) {
      final raw = _acquireRawManifoldBuf();
      try {
        _heightfieldShapeRawInto(shapeB, transformB, shapeA, transformA, raw);
        raw.flipManifoldsFrom(0);
        _mergeCoDirectionalInto(raw, out);
      } finally {
        _releaseRawManifoldBuf(raw);
      }
      return;
    }
    if (shapeB is HeightfieldShape3D) {
      final raw = _acquireRawManifoldBuf();
      try {
        _heightfieldShapeRawInto(shapeA, transformA, shapeB, transformB, raw);
        _mergeCoDirectionalInto(raw, out);
      } finally {
        _releaseRawManifoldBuf(raw);
      }
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
        _sphereSphereInto(a, transformA, b, transformB, out);
      case (final SphereShape3D a, final CapsuleShape3D b):
        _sphereCapsuleInto(a, transformA, b, transformB, out, flip: false);
      case (final CapsuleShape3D a, final SphereShape3D b):
        _sphereCapsuleInto(b, transformB, a, transformA, out, flip: true);
      case (final CapsuleShape3D a, final CapsuleShape3D b):
        _capsuleCapsuleInto(a, transformA, b, transformB, out);
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
  ) {
    final buf = _acquirePublicBuffer();
    try {
      _sphereSphereInto(a, transformA, b, transformB, buf);
      return buf.materializeFirst();
    } finally {
      _releasePublicBuffer(buf);
    }
  }

  /// Exact Sphere-Capsule narrowphase (`a`: sphere, `b`: capsule).
  static CollisionManifold3D? sphereCapsule(
    SphereShape3D a,
    Matrix4 transformA,
    CapsuleShape3D b,
    Matrix4 transformB,
  ) {
    final buf = _acquirePublicBuffer();
    try {
      _sphereCapsuleInto(a, transformA, b, transformB, buf, flip: false);
      return buf.materializeFirst();
    } finally {
      _releasePublicBuffer(buf);
    }
  }

  /// Exact Capsule-Capsule narrowphase via segment-segment closest points.
  static CollisionManifold3D? capsuleCapsule(
    CapsuleShape3D a,
    Matrix4 transformA,
    CapsuleShape3D b,
    Matrix4 transformB,
  ) {
    final buf = _acquirePublicBuffer();
    try {
      _capsuleCapsuleInto(a, transformA, b, transformB, buf);
      return buf.materializeFirst();
    } finally {
      _releasePublicBuffer(buf);
    }
  }

  /// Exact Sphere-Box (OBB) narrowphase.
  static CollisionManifold3D? sphereBox(
    SphereShape3D a,
    Matrix4 transformA,
    BoxShape3D b,
    Matrix4 transformB,
  ) {
    final buf = _acquirePublicBuffer();
    try {
      _sphereBoxInto(a, transformA, b, transformB, buf, flip: false);
      return buf.materializeFirst();
    } finally {
      _releasePublicBuffer(buf);
    }
  }

  /// Exact Capsule-Box (OBB) narrowphase via segment-to-OBB distance.
  static CollisionManifold3D? capsuleBox(
    CapsuleShape3D a,
    Matrix4 transformA,
    BoxShape3D b,
    Matrix4 transformB,
  ) {
    final buf = _acquirePublicBuffer();
    try {
      _capsuleBoxInto(a, transformA, b, transformB, buf, flip: false);
      return buf.materializeFirst();
    } finally {
      _releasePublicBuffer(buf);
    }
  }

  /// Exact SAT Box-Box narrowphase (face-face clipping + edge-edge contacts).
  static CollisionManifold3D? boxBox(
    BoxShape3D a,
    Matrix4 transformA,
    BoxShape3D b,
    Matrix4 transformB,
  ) {
    final buf = _acquirePublicBuffer();
    try {
      _boxBoxInto(a, transformA, b, transformB, buf);
      return buf.materializeFirst();
    } finally {
      _releasePublicBuffer(buf);
    }
  }

  /// General Convex-Convex narrowphase using GJK + EPA.
  static CollisionManifold3D? convexConvex(
    Shape3D shapeA,
    Matrix4 transformA,
    Shape3D shapeB,
    Matrix4 transformB,
  ) {
    final buf = _acquirePublicBuffer();
    try {
      _convexConvexInto(shapeA, transformA, shapeB, transformB, buf);
      return buf.materializeFirst();
    } finally {
      _releasePublicBuffer(buf);
    }
  }

  /// Deepest contact manifold between [shape] and static triangles in
  /// [surface].
  static CollisionManifold3D? intersectShapeWithSurfaceBvh(
    Shape3D shape,
    Matrix4 shapeTransform,
    Surface surface,
    Matrix4 meshTransform,
  ) {
    final buf = _acquirePublicBuffer();
    try {
      _intersectShapeWithSurfaceBvhRawInto(
        shape,
        shapeTransform,
        surface,
        meshTransform,
        buf,
      );
      return buf.materializeDeepest();
    } finally {
      _releasePublicBuffer(buf);
    }
  }

  /// All colliding manifolds between [shape] and triangles in [surface].
  static List<CollisionManifold3D> intersectShapeWithSurfaceBvhAll(
    Shape3D shape,
    Matrix4 shapeTransform,
    Surface surface,
    Matrix4 meshTransform,
  ) {
    final buf = _acquirePublicBuffer();
    try {
      _intersectShapeWithSurfaceBvhRawInto(
        shape,
        shapeTransform,
        surface,
        meshTransform,
        buf,
      );
      return buf.materializeAll();
    } finally {
      _releasePublicBuffer(buf);
    }
  }

  /// Deepest contact manifold between [shape] and [heightfield].
  static CollisionManifold3D? heightfieldShape(
    Shape3D shape,
    Matrix4 shapeTransform,
    HeightfieldShape3D heightfield,
    Matrix4 heightfieldTransform,
  ) => test(shape, shapeTransform, heightfield, heightfieldTransform);

  /// All contact manifolds between [shape] and triangles of [heightfield].
  static List<CollisionManifold3D> heightfieldShapeAll(
    Shape3D shape,
    Matrix4 shapeTransform,
    HeightfieldShape3D heightfield,
    Matrix4 heightfieldTransform,
  ) {
    final buf = _acquirePublicBuffer();
    try {
      _heightfieldShapeRawInto(
        shape,
        shapeTransform,
        heightfield,
        heightfieldTransform,
        buf,
      );
      return buf.materializeAll();
    } finally {
      _releasePublicBuffer(buf);
    }
  }

  /// Computes contact manifold between [shape] and world-space triangle
  /// `(v0, v1, v2)`.
  static CollisionManifold3D? intersectShapeWithTriangle(
    Shape3D shape,
    Matrix4 shapeTransform,
    Vector3 v0,
    Vector3 v1,
    Vector3 v2,
  ) {
    final buf = _acquirePublicBuffer();
    try {
      _intersectShapeWithTriangleInto(
        shape,
        shapeTransform,
        v0,
        v1,
        v2,
        buf,
      );
      return buf.materializeFirst();
    } finally {
      _releasePublicBuffer(buf);
    }
  }
}
