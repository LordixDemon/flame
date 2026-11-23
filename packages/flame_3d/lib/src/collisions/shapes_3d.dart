import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/camera.dart' show Ray;
import 'package:flame_3d/core.dart';
import 'package:meta/meta.dart';

part 'shape_capsule_3d.dart';
part 'shape_compound_3d.dart';
part 'shape_convex_hull_3d.dart';
part 'shape_heightfield_3d.dart';
part 'shape_sphere_box_3d.dart';

/// Alias for [Shape3D] used across compound and general collision APIs.
typedef CollisionShape3D = Shape3D;

/// Combining rule for friction or restitution between two [PhysicsMaterial3D]
/// instances in contact.
enum PhysicsCombineMode3D() {
  /// Arithmetic average `0.5 * (a + b)` (lowest priority).
  average,

  /// Smaller coefficient `min(a, b)`.
  minimum,

  /// Product `a * b`.
  multiply,

  /// Larger coefficient `max(a, b)` (highest priority).
  maximum;

  /// Combines [a] and [b] using this mode.
  double combine(double a, double b) {
    return switch (this) {
      PhysicsCombineMode3D.average => 0.5 * (a + b),
      PhysicsCombineMode3D.minimum => math.min(a, b),
      PhysicsCombineMode3D.multiply => a * b,
      PhysicsCombineMode3D.maximum => math.max(a, b),
    };
  }
}

/// Surface material properties (friction, restitution, combine rules, and
/// semantic [surfaceTag]) attachable to a `Collider3D` or `RigidBody3D`.
@immutable
class const PhysicsMaterial3D({
  final double friction = 0.5,
  final double restitution = 0.2,
  final PhysicsCombineMode3D frictionCombine = PhysicsCombineMode3D.average,
  final PhysicsCombineMode3D restitutionCombine = PhysicsCombineMode3D.maximum,
  final String surfaceTag = 'default',
}) {
  /// Combines the friction coefficients of [a] and [b], honoring the higher
  /// priority [PhysicsCombineMode3D].
  static double combineFriction(PhysicsMaterial3D a, PhysicsMaterial3D b) {
    final mode = a.frictionCombine.index >= b.frictionCombine.index
        ? a.frictionCombine
        : b.frictionCombine;
    return math.max(0.0, mode.combine(a.friction, b.friction));
  }

  /// Combines the restitution coefficients of [a] and [b], honoring the higher
  /// priority [PhysicsCombineMode3D].
  static double combineRestitution(PhysicsMaterial3D a, PhysicsMaterial3D b) {
    final mode = a.restitutionCombine.index >= b.restitutionCombine.index
        ? a.restitutionCombine
        : b.restitutionCombine;
    return mode.combine(a.restitution, b.restitution).clamp(0.0, 1.0);
  }
}

/// Principal coordinate axis in 3D space.
enum Axis3D() {
  /// The `+X` axis `(1, 0, 0)`.
  x,

  /// The `+Y` axis `(0, 1, 0)`.
  y,

  /// The `+Z` axis `(0, 0, 1)`.
  z;

  /// Writes this axis's positive unit vector into [out] and returns [out].
  Vector3 writeUnitVector(Vector3 out) {
    switch (this) {
      case Axis3D.x:
        out.setValues(1.0, 0.0, 0.0);
      case Axis3D.y:
        out.setValues(0.0, 1.0, 0.0);
      case Axis3D.z:
        out.setValues(0.0, 0.0, 1.0);
    }
    return out;
  }

  /// Allocates and returns this axis's positive unit vector.
  Vector3 get unitVector => writeUnitVector(Vector3.zero());
}

/// Base class for 3D collision shapes (convex primitives, [CompoundShape3D],
/// and [HeightfieldShape3D]).
///
/// Shapes are lightweight geometric descriptors in local space; world-space
/// queries take an explicit `worldTransform` [Matrix4] so one shape instance
/// can be shared across many colliders or rigid bodies.
sealed class Shape3D() {
  /// Minimum inscribed sphere radius used by default for continuous collision
  /// detection (`RigidBody3D.ccdSweptSphereRadius`).
  double get inscribedSphereRadius;

  /// Geometric volume in local space used when distributing mass across
  /// [CompoundShape3D] children or estimating buoyancy displacement.
  double estimateLocalVolume();

  /// Local-space center of mass offset (`(0, 0, 0)` for centered primitives;
  /// volume-weighted composite center of mass for [CompoundShape3D]).
  Vector3 get localCenterOfMass => _zeroCenterOfMass;

  /// Writes the local-space axis-aligned bounding box of this shape into [out].
  Aabb3 computeLocalAabb({Aabb3? out});

  /// Writes the world-space axis-aligned bounding box under [worldTransform]
  /// into [out].
  void computeWorldAabb(Matrix4 worldTransform, Aabb3 out);

  /// Writes the furthest point on this shape along `worldDir` (in world space)
  /// under [worldTransform] into [out].
  void supportPoint(Vector3 worldDir, Matrix4 worldTransform, Vector3 out);

  /// Intersects [worldRay] against this shape transformed by [worldTransform]
  /// within [maxDistance] world units, returning `(distance, worldNormal)` or
  /// `null` when missed.
  (double distance, Vector3 normal)? raycast(
    Ray worldRay,
    Matrix4 worldTransform, {
    double maxDistance = double.infinity,
  });

  /// Computes the local-space diagonal moment of inertia `(Ix, Iy, Iz)` for a
  /// uniform solid body of [mass].
  Vector3 computeLocalInertiaDiagonal(double mass, {Vector3? out});

  /// Computes the full `3x3` symmetric local-space inertia tensor for [mass].
  Matrix3 computeLocalInertiaTensor(double mass, {Matrix3? out}) {
    final m = out ?? Matrix3.zero();
    m.setZero();
    final d = computeLocalInertiaDiagonal(mass, out: _inertiaDiagScratch);
    m.storage[0] = d.x;
    m.storage[4] = d.y;
    m.storage[8] = d.z;
    return m;
  }

  static final Vector3 _zeroCenterOfMass = Vector3.zero();
  static final Vector3 _inertiaDiagScratch = Vector3.zero();
}

final Matrix4 _invTransform = Matrix4.identity();
final Vector3 _unitWorldDir = Vector3.zero();
final Vector3 _localOrigin = Vector3.zero();
final Vector3 _localDir = Vector3.zero();

bool _invertAffineMatrixFast(Matrix4 src, Matrix4 dst) {
  final s = src.storage;
  if (s[3] == 0.0 && s[7] == 0.0 && s[11] == 0.0 && s[15] == 1.0) {
    final c0x = s[0];
    final c0y = s[1];
    final c0z = s[2];
    final c1x = s[4];
    final c1y = s[5];
    final c1z = s[6];
    final c2x = s[8];
    final c2y = s[9];
    final c2z = s[10];
    final l0 = c0x * c0x + c0y * c0y + c0z * c0z;
    final l1 = c1x * c1x + c1y * c1y + c1z * c1z;
    final l2 = c2x * c2x + c2y * c2y + c2z * c2z;
    if ((l0 - 1.0).abs() <= 1e-5 &&
        (l1 - 1.0).abs() <= 1e-5 &&
        (l2 - 1.0).abs() <= 1e-5) {
      final d01 = c0x * c1x + c0y * c1y + c0z * c1z;
      final d02 = c0x * c2x + c0y * c2y + c0z * c2z;
      final d12 = c1x * c2x + c1y * c2y + c1z * c2z;
      if (d01.abs() <= 1e-5 && d02.abs() <= 1e-5 && d12.abs() <= 1e-5) {
        final tx = s[12];
        final ty = s[13];
        final tz = s[14];
        final o = dst.storage;
        o[0] = c0x;
        o[4] = c0y;
        o[8] = c0z;
        o[12] = -(c0x * tx + c0y * ty + c0z * tz);
        o[1] = c1x;
        o[5] = c1y;
        o[9] = c1z;
        o[13] = -(c1x * tx + c1y * ty + c1z * tz);
        o[2] = c2x;
        o[6] = c2y;
        o[10] = c2z;
        o[14] = -(c2x * tx + c2y * ty + c2z * tz);
        o[3] = 0.0;
        o[7] = 0.0;
        o[11] = 0.0;
        o[15] = 1.0;
        return true;
      }
    }
  }
  dst.setFrom(src);
  return dst.invert().abs() >= 1e-15;
}

bool _prepareLocalRay(
  Ray worldRay,
  Matrix4 worldTransform,
  double maxDistance,
) {
  if (!(maxDistance >= 0.0)) {
    return false;
  }
  final dirLen = worldRay.direction.length;
  if (dirLen <= 1e-12) {
    return false;
  }
  final invLen = 1.0 / dirLen;
  final wx = worldRay.direction.x * invLen;
  final wy = worldRay.direction.y * invLen;
  final wz = worldRay.direction.z * invLen;
  _unitWorldDir.setValues(wx, wy, wz);

  if (!_invertAffineMatrixFast(worldTransform, _invTransform)) {
    return false;
  }
  final m = _invTransform.storage;
  final ox = worldRay.origin.x;
  final oy = worldRay.origin.y;
  final oz = worldRay.origin.z;
  _localOrigin.setValues(
    m[0] * ox + m[4] * oy + m[8] * oz + m[12],
    m[1] * ox + m[5] * oy + m[9] * oz + m[13],
    m[2] * ox + m[6] * oy + m[10] * oz + m[14],
  );
  _localDir.setValues(
    m[0] * wx + m[4] * wy + m[8] * wz,
    m[1] * wx + m[5] * wy + m[9] * wz,
    m[2] * wx + m[6] * wy + m[10] * wz,
  );
  return true;
}

Vector3 _transformLocalNormalToWorld(double lnx, double lny, double lnz) {
  final m = _invTransform.storage;
  var wnx = m[0] * lnx + m[1] * lny + m[2] * lnz;
  var wny = m[4] * lnx + m[5] * lny + m[6] * lnz;
  var wnz = m[8] * lnx + m[9] * lny + m[10] * lnz;
  final len = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
  if (len > 1e-12) {
    wnx /= len;
    wny /= len;
    wnz /= len;
  }
  return Vector3(wnx, wny, wnz);
}
