import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/game.dart' show NotifyingQuaternion, NotifyingVector3;
import 'package:flame_3d/physics.dart' show PhysicsWorld3D;
import 'package:meta/meta.dart';

/// Deterministic 32-bit-safe SplitMix/Xoshiro128** PRNG used by
/// `RigidBody3D` and `PhysicsWorld3D`. Its integer sequence is the same on
/// every platform; the simulation that consumes it uses the platform's `sin`
/// and `cos`, so identical seeds reproduce a throw bit for bit only on the
/// same platform and build.
class SeededRng3D(int seed) {
  /// Initializes the generator state from `seed`.
  this {
    var z = seed & 0xFFFFFFFF;
    int nextWord() {
      z = (z + 0x9E3779B9) & 0xFFFFFFFF;
      var t = z ^ (z >>> 16);
      t = _imul32(t, 0x85EBCA6B);
      t = t ^ (t >>> 13);
      t = _imul32(t, 0xC2B2AE35);
      return (t ^ (t >>> 16)) & 0xFFFFFFFF;
    }

    _s0 = nextWord();
    _s1 = nextWord();
    _s2 = nextWord();
    _s3 = nextWord();
    if ((_s0 | _s1 | _s2 | _s3) == 0) {
      _s0 = 1;
    }
  }

  int _s0 = 1;
  int _s1 = 0;
  int _s2 = 0;
  int _s3 = 0;

  static int _imul32(int a, int b) {
    final ah = (a >>> 16) & 0xFFFF;
    final al = a & 0xFFFF;
    final bh = (b >>> 16) & 0xFFFF;
    final bl = b & 0xFFFF;
    return ((al * bl) + ((((ah * bl) + (al * bh)) & 0xFFFF) << 16)) &
        0xFFFFFFFF;
  }

  static int _rotl32(int x, int k) =>
      ((x << k) | ((x & 0xFFFFFFFF) >>> (32 - k))) & 0xFFFFFFFF;

  int _nextUint32() {
    final result = _imul32(_rotl32(_imul32(_s1, 5), 7), 9);
    final t = (_s1 << 9) & 0xFFFFFFFF;
    _s2 = (_s2 ^ _s0) & 0xFFFFFFFF;
    _s3 = (_s3 ^ _s1) & 0xFFFFFFFF;
    _s1 = (_s1 ^ _s2) & 0xFFFFFFFF;
    _s0 = (_s0 ^ _s3) & 0xFFFFFFFF;
    _s2 = (_s2 ^ t) & 0xFFFFFFFF;
    _s3 = _rotl32(_s3, 11);
    return result;
  }

  /// Captures the internal 128-bit state for deterministic rollback snapshots.
  (int, int, int, int) saveState() => (_s0, _s1, _s2, _s3);

  /// Restores the internal 128-bit state captured by [saveState].
  void restoreState((int, int, int, int) state) {
    _s0 = state.$1 & 0xFFFFFFFF;
    _s1 = state.$2 & 0xFFFFFFFF;
    _s2 = state.$3 & 0xFFFFFFFF;
    _s3 = state.$4 & 0xFFFFFFFF;
    if ((_s0 | _s1 | _s2 | _s3) == 0) {
      _s0 = 1;
    }
  }

  /// Returns a uniform double in `[0.0, 1.0)`.
  double nextDouble() => _nextUint32() / 4294967296.0;

  /// Returns a uniform double in `[min, max)`.
  double rangeDouble(double min, double max) =>
      min + (max - min) * nextDouble();
}

/// Simulation mobility mode of a [RigidBody3D].
enum BodyType3D() {
  /// Simulated under gravity, forces, impulses, contacts, and joints.
  dynamic,

  /// Driven kinematically by velocity/code; infinite mass in collisions.
  kinematic,

  /// Immovable world geometry; zero velocity and infinite mass.
  static,
}

/// A 3D rigid body component simulated by `PhysicsWorld3D`.
///
/// Can be added either as a child of an existing [Component3D] (such as a
/// [MeshComponent], automatically synchronizing its parent's `position` and
/// `rotation`) or standalone directly inside a `World3D`.
class RigidBody3D({
  required Shape3D shape,
  BodyType3D bodyType = BodyType3D.dynamic,
  double mass = 1.0,
  var double restitution = 0.0,
  var double friction = 0.5,
  var PhysicsMaterial3D? material,
  var double linearDamping = 0.01,
  var double angularDamping = 0.05,
  Vector3? linearVelocity,
  Vector3? angularVelocity,
  var bool canSleep = true,
  var bool isSleeping = false,
  var bool ccdEnabled = false,
  double? ccdSweptSphereRadius,
  var int collisionLayer = 1,
  var int collisionMask = 0xFFFFFFFF,
  var bool syncParent = true,
  super.position,
  super.scale,
  super.rotation,
  super.children,
}) extends Component3D {
  this : assert(mass >= 0, 'mass must be non-negative') {
    _customCcdRadius = ccdSweptSphereRadius;
    _recomputeMassProperties();
  }

  static int _nextDeterministicId = 1;

  /// Monotonic creation identifier used for deterministic broadphase ordering.
  final int deterministicId = _nextDeterministicId++;

  BodyType3D _bodyType = bodyType;

  /// Mobility classification (`dynamic`, `kinematic`, or `static`).
  BodyType3D get bodyType => _bodyType;
  set bodyType(BodyType3D value) {
    if (value == _bodyType) {
      return;
    }
    _bodyType = value;
    if (value != BodyType3D.dynamic) {
      isSleeping = false;
      sleepTimer = 0.0;
      if (value == BodyType3D.static) {
        linearVelocity.setZero();
        angularVelocity.setZero();
      }
    }
    _recomputeMassProperties();
  }

  Shape3D _shape = shape;

  /// Collision and inertia shape of this body.
  Shape3D get shape => _shape;
  set shape(Shape3D value) {
    if (identical(value, _shape)) {
      return;
    }
    _shape = value;
    _recomputeMassProperties();
    markAabbDirty();
  }

  double? _customCcdRadius;

  /// Swept sphere radius used when [ccdEnabled] is `true` (defaults to the
  /// minimum inscribed radius of [shape]).
  double get ccdSweptSphereRadius =>
      _customCcdRadius ?? math.max(1e-3, _shape.inscribedSphereRadius);
  set ccdSweptSphereRadius(double value) {
    assert(value > 0, 'ccdSweptSphereRadius must be positive');
    _customCcdRadius = value;
  }

  double _mass = mass;

  /// Mass in kilograms (used when [bodyType] is [BodyType3D.dynamic]).
  double get mass => _mass;
  set mass(double value) {
    assert(value >= 0, 'mass must be non-negative');
    if (value == _mass) {
      return;
    }
    _mass = value;
    _recomputeMassProperties();
  }

  /// World-space linear velocity (`m/s`).
  final Vector3 linearVelocity = linearVelocity?.clone() ?? Vector3.zero();

  /// World-space angular velocity (`rad/s`).
  final Vector3 angularVelocity = angularVelocity?.clone() ?? Vector3.zero();

  /// Accumulated sleep timer in seconds managed by `PhysicsWorld3D`.
  double sleepTimer = 0.0;

  /// Scratch index used by `PhysicsWorld3D` while grouping bodies into
  /// sleeping islands (`-1` outside of that pass).
  @internal
  int solverIndex = -1;

  double _inverseMass = 0.0;
  final Vector3 _localInvInertia = Vector3.zero();
  final Matrix3 _localInvInertiaTensor = Matrix3.zero();
  bool _hasOffDiagonalInertia = false;

  /// Local-space center-of-mass offset populated from [shape].
  final Vector3 localCenterOfMass = Vector3.zero();
  bool _hasComOffset = false;

  /// Inverse mass (`0` for `static` and `kinematic` bodies).
  double get inverseMass => _inverseMass;

  /// Local-space inverse inertia diagonal.
  Vector3 get localInverseInertia => _localInvInertia;

  /// World-space `3x3` inverse inertia tensor `R * I_local^-1 * R^T`.
  final Matrix3 worldInvInertia = Matrix3.zero();

  final Vector3 _forceAccum = Vector3.zero();
  final Vector3 _torqueAccum = Vector3.zero();
  final Matrix4 _bodyWorldMatrix = Matrix4.identity();
  final Aabb3 _worldAabb = Aabb3();
  final Aabb3 _localAabb = Aabb3();
  final Vector3 _scratchR = Vector3.zero();
  final Vector3 _scratchCross = Vector3.zero();
  final Vector3 _worldComScratch = Vector3.zero();

  /// Whether [localCenterOfMass] is non-zero.
  bool get hasCenterOfMassOffset => _hasComOffset;

  /// World-space center of mass (`bodyPosition + bodyRotation *
  /// localCenterOfMass`).
  Vector3 get worldCenterOfMass {
    final pos = bodyPosition;
    if (!_hasComOffset) {
      return pos;
    }
    _rotateQuat(bodyRotation, localCenterOfMass, _worldComScratch);
    _worldComScratch.add(pos);
    return _worldComScratch;
  }

  /// Accumulated world force for the upcoming physics step.
  Vector3 get accumulatedForce => _forceAccum;

  /// Accumulated world torque for the upcoming physics step.
  Vector3 get accumulatedTorque => _torqueAccum;

  /// Clears accumulated forces and torques at the end of force integration.
  void clearAccumulators() {
    _forceAccum.setZero();
    _torqueAccum.setZero();
  }

  /// The [Component3D] whose transform this rigid body drives: its parent
  /// [Component3D] when [syncParent] is `true` and attached as a child, or
  /// `this` when standalone.
  Component3D get hostComponent {
    if (syncParent) {
      final p = parent;
      if (p is Component3D) {
        return p;
      }
    }
    return this;
  }

  /// World/parent position of [hostComponent].
  NotifyingVector3 get bodyPosition => hostComponent.position;

  /// Orientation quaternion of [hostComponent].
  NotifyingQuaternion get bodyRotation => hostComponent.rotation;

  /// Current world transform matrix of this body's shape.
  Matrix4 get bodyWorldMatrix {
    final host = hostComponent;
    _bodyWorldMatrix.setFromTranslationRotationScale(
      host.position,
      host.rotation,
      host.scale,
    );
    return _bodyWorldMatrix;
  }

  /// Computes and returns the current world-space AABB of [shape].
  Aabb3 get bodyWorldAabb {
    _recordAabbPose();
    _shape.computeWorldAabb(bodyWorldMatrix, _worldAabb);
    return _worldAabb;
  }

  /// The AABB computed by the last [bodyWorldAabb] or
  /// [refreshCachedWorldAabb] call.
  @internal
  Aabb3 get cachedWorldAabb => _worldAabb;

  /// Recomputes the AABB only when the host's pose, scale or the shape changed
  /// since it was last computed; returns whether it was recomputed.
  @internal
  bool refreshCachedWorldAabb() {
    final host = hostComponent;
    final p = host.position;
    final q = host.rotation;
    final s = host.scale;
    final c = _aabbPose;
    if (identical(_aabbShape, _shape) &&
        c[0] == p.x &&
        c[1] == p.y &&
        c[2] == p.z &&
        c[3] == q.x &&
        c[4] == q.y &&
        c[5] == q.z &&
        c[6] == q.w &&
        c[7] == s.x &&
        c[8] == s.y &&
        c[9] == s.z) {
      return false;
    }
    bodyWorldAabb;
    return true;
  }

  void _recordAabbPose() {
    final host = hostComponent;
    final p = host.position;
    final q = host.rotation;
    final s = host.scale;
    _aabbPose
      ..[0] = p.x
      ..[1] = p.y
      ..[2] = p.z
      ..[3] = q.x
      ..[4] = q.y
      ..[5] = q.z
      ..[6] = q.w
      ..[7] = s.x
      ..[8] = s.y
      ..[9] = s.z;
    _aabbShape = _shape;
  }

  final Float64List _aabbPose = Float64List(10);
  Shape3D? _aabbShape;

  /// The physics worlds this body registered with when it mounted (those whose
  /// parent is one of its ancestors).
  @internal
  final List<PhysicsWorld3D> enclosingPhysicsWorlds = [];

  @override
  void onMount() {
    super.onMount();
    PhysicsWorld3D.attachToEnclosingWorlds(this);
  }

  @override
  void onRemove() {
    for (var i = 0; i < enclosingPhysicsWorlds.length; i++) {
      enclosingPhysicsWorlds[i].unregisterMountedComponent(this);
    }
    enclosingPhysicsWorlds.clear();
    super.onRemove();
  }

  /// Recomputes [worldInvInertia] (`R * I_local^-1 * R^T`) from the current
  /// [bodyRotation] with zero heap allocations.
  void updateWorldInertia() {
    if (_bodyType != BodyType3D.dynamic || _inverseMass <= 0.0) {
      worldInvInertia.setZero();
      return;
    }
    final q = bodyRotation;
    final x = q.x;
    final y = q.y;
    final z = q.z;
    final w = q.w;
    final x2 = x + x;
    final y2 = y + y;
    final z2 = z + z;
    final xx = x * x2;
    final xy = x * y2;
    final xz = x * z2;
    final yy = y * y2;
    final yz = y * z2;
    final zz = z * z2;
    final wx = w * x2;
    final wy = w * y2;
    final wz = w * z2;

    final r00 = 1.0 - (yy + zz);
    final r10 = xy + wz;
    final r20 = xz - wy;
    final r01 = xy - wz;
    final r11 = 1.0 - (xx + zz);
    final r21 = yz + wx;
    final r02 = xz + wy;
    final r12 = yz - wx;
    final r22 = 1.0 - (xx + yy);

    final out = worldInvInertia.storage;
    if (!_hasOffDiagonalInertia) {
      final ix = _localInvInertia.x;
      final iy = _localInvInertia.y;
      final iz = _localInvInertia.z;

      final m00 = r00 * r00 * ix + r01 * r01 * iy + r02 * r02 * iz;
      final m01 = r00 * r10 * ix + r01 * r11 * iy + r02 * r12 * iz;
      final m02 = r00 * r20 * ix + r01 * r21 * iy + r02 * r22 * iz;
      final m11 = r10 * r10 * ix + r11 * r11 * iy + r12 * r12 * iz;
      final m12 = r10 * r20 * ix + r11 * r21 * iy + r12 * r22 * iz;
      final m22 = r20 * r20 * ix + r21 * r21 * iy + r22 * r22 * iz;

      out[0] = m00;
      out[1] = m01;
      out[2] = m02;
      out[3] = m01;
      out[4] = m11;
      out[5] = m12;
      out[6] = m02;
      out[7] = m12;
      out[8] = m22;
      return;
    }

    // Full symmetric `R * I_local^-1 * R^T`.
    final li = _localInvInertiaTensor.storage;
    final i00 = li[0];
    final i01 = li[1];
    final i02 = li[2];
    final i11 = li[4];
    final i12 = li[5];
    final i22 = li[8];

    // `T = R * I_local^-1` (3x3).
    final t00 = r00 * i00 + r01 * i01 + r02 * i02;
    final t01 = r00 * i01 + r01 * i11 + r02 * i12;
    final t02 = r00 * i02 + r01 * i12 + r02 * i22;
    final t10 = r10 * i00 + r11 * i01 + r12 * i02;
    final t11 = r10 * i01 + r11 * i11 + r12 * i12;
    final t12 = r10 * i02 + r11 * i12 + r12 * i22;
    final t20 = r20 * i00 + r21 * i01 + r22 * i02;
    final t21 = r20 * i01 + r21 * i11 + r22 * i12;
    final t22 = r20 * i02 + r21 * i12 + r22 * i22;

    final m00 = t00 * r00 + t01 * r01 + t02 * r02;
    final m01 = t00 * r10 + t01 * r11 + t02 * r12;
    final m02 = t00 * r20 + t01 * r21 + t02 * r22;
    final m11 = t10 * r10 + t11 * r11 + t12 * r12;
    final m12 = t10 * r20 + t11 * r21 + t12 * r22;
    final m22 = t20 * r20 + t21 * r21 + t22 * r22;

    out[0] = m00;
    out[1] = m01;
    out[2] = m02;
    out[3] = m01;
    out[4] = m11;
    out[5] = m12;
    out[6] = m02;
    out[7] = m12;
    out[8] = m22;
  }

  /// Multiplies [worldInvInertia] by `(vx, vy, vz)` and writes into [out].
  void multiplyWorldInvInertia(
    double vx,
    double vy,
    double vz,
    Vector3 out,
  ) {
    final s = worldInvInertia.storage;
    out.setValues(
      s[0] * vx + s[3] * vy + s[6] * vz,
      s[1] * vx + s[4] * vy + s[7] * vz,
      s[2] * vx + s[5] * vy + s[8] * vz,
    );
  }

  /// Wakes this body from sleep.
  void wakeUp() {
    if (_bodyType == BodyType3D.dynamic) {
      isSleeping = false;
      sleepTimer = 0.0;
    }
  }

  /// Immediately puts this body to sleep and zeroes velocities and forces.
  void putToSleep() {
    if (_bodyType == BodyType3D.dynamic && canSleep) {
      isSleeping = true;
      linearVelocity.setZero();
      angularVelocity.setZero();
      _forceAccum.setZero();
      _torqueAccum.setZero();
    }
  }

  /// Applies an instantaneous linear [impulse] (`N*s`), optionally at
  /// [worldPoint] (generating torque `(worldPoint - worldCenterOfMass) x
  /// impulse`).
  void applyImpulse(Vector3 impulse, {Vector3? worldPoint}) {
    if (_bodyType != BodyType3D.dynamic || _inverseMass <= 0.0) {
      return;
    }
    wakeUp();
    linearVelocity.addScaled(impulse, _inverseMass);
    if (worldPoint != null) {
      final com = worldCenterOfMass;
      _scratchR.setValues(
        worldPoint.x - com.x,
        worldPoint.y - com.y,
        worldPoint.z - com.z,
      );
      _cross(_scratchR, impulse, _scratchCross);
      updateWorldInertia();
      multiplyWorldInvInertia(
        _scratchCross.x,
        _scratchCross.y,
        _scratchCross.z,
        _scratchR,
      );
      angularVelocity.add(_scratchR);
    }
  }

  /// Applies a continuous [force] (`N`) integrated on the next step, optionally
  /// at [worldPoint].
  void applyForce(Vector3 force, {Vector3? worldPoint}) {
    if (_bodyType != BodyType3D.dynamic || _inverseMass <= 0.0) {
      return;
    }
    wakeUp();
    _forceAccum.add(force);
    if (worldPoint != null) {
      final com = worldCenterOfMass;
      _scratchR.setValues(
        worldPoint.x - com.x,
        worldPoint.y - com.y,
        worldPoint.z - com.z,
      );
      _cross(_scratchR, force, _scratchCross);
      _torqueAccum.add(_scratchCross);
    }
  }

  /// Applies an instantaneous angular impulse [torque] (`N*m*s`).
  void applyTorqueImpulse(Vector3 torque) {
    if (_bodyType != BodyType3D.dynamic || _inverseMass <= 0.0) {
      return;
    }
    wakeUp();
    updateWorldInertia();
    multiplyWorldInvInertia(torque.x, torque.y, torque.z, _scratchR);
    angularVelocity.add(_scratchR);
  }

  /// Applies a continuous [torque] (`N*m`) integrated on the next step.
  void applyTorque(Vector3 torque) {
    if (_bodyType != BodyType3D.dynamic || _inverseMass <= 0.0) {
      return;
    }
    wakeUp();
    _torqueAccum.add(torque);
  }

  /// Applies a cross-platform deterministic launch velocity and angular spin
  /// derived from [seed] via [SeededRng3D].
  void applySeededSpinImpulse({
    required int seed,
    double linearSpeed = 5.0,
    Vector3? baseDirection,
    double directionSpreadRad = 0.2,
    double minSpinSpeed = 8.0,
    double maxSpinSpeed = 18.0,
  }) {
    if (_bodyType != BodyType3D.dynamic || _inverseMass <= 0.0) {
      return;
    }
    final rng = SeededRng3D(seed);
    wakeUp();

    final dir = baseDirection != null && baseDirection.length2 > 1e-12
        ? baseDirection.normalized()
        : Vector3(0.0, 0.35, -1.0).normalized();

    // Deterministic spherical perturbation within `directionSpreadRad`.
    final theta = rng.rangeDouble(0.0, math.pi * 2.0);
    final phi = rng.rangeDouble(0.0, directionSpreadRad);
    final perp1 = dir.x.abs() < 0.9
        ? Vector3(0.0, -dir.z, dir.y).normalized()
        : Vector3(-dir.z, 0.0, dir.x).normalized();
    final perp2 = dir.cross(perp1);

    final launchDir =
        (dir * math.cos(phi) +
                perp1 * (math.sin(phi) * math.cos(theta)) +
                perp2 * (math.sin(phi) * math.sin(theta)))
            .normalized();

    linearVelocity
      ..setFrom(launchDir)
      ..scale(linearSpeed);

    // Uniform random unit spin axis on S^2.
    final uz = rng.rangeDouble(-1.0, 1.0);
    final rHoriz = math.sqrt(math.max(0.0, 1.0 - uz * uz));
    final az = rng.rangeDouble(0.0, math.pi * 2.0);
    final spinMag = rng.rangeDouble(minSpinSpeed, maxSpinSpeed);
    angularVelocity.setValues(
      rHoriz * math.cos(az) * spinMag,
      rHoriz * math.sin(az) * spinMag,
      uz * spinMag,
    );
  }

  /// Returns whether 32-bit layer/mask filtering permits contact with [other].
  bool canCollideWith(RigidBody3D other) {
    if (identical(this, other) ||
        identical(hostComponent, other.hostComponent)) {
      return false;
    }
    if (_bodyType != BodyType3D.dynamic &&
        other._bodyType != BodyType3D.dynamic) {
      return false;
    }
    return (collisionLayer & other.collisionMask) != 0 &&
        (other.collisionLayer & collisionMask) != 0;
  }

  @override
  Aabb3? computeLocalAabb() => _shape.computeLocalAabb(out: _localAabb);

  void _recomputeMassProperties() {
    localCenterOfMass.setFrom(_shape.localCenterOfMass);
    _hasComOffset = localCenterOfMass.length2 > 1e-12;

    if (_bodyType != BodyType3D.dynamic || _mass <= 0.0) {
      _inverseMass = 0.0;
      _localInvInertia.setZero();
      _localInvInertiaTensor.setZero();
      _hasOffDiagonalInertia = false;
      worldInvInertia.setZero();
      return;
    }
    _inverseMass = 1.0 / _mass;

    // Shapes with products of inertia (compounds, asymmetric hulls) keep the
    // full tensor.
    final tensor = _shape.computeLocalInertiaTensor(_mass);
    final ts = tensor.storage;
    final offDiag2 = ts[1] * ts[1] + ts[2] * ts[2] + ts[5] * ts[5];
    final diag2 = ts[0] * ts[0] + ts[4] * ts[4] + ts[8] * ts[8];
    if (offDiag2 > 1e-12 * diag2 &&
        _invertSymmetric3(tensor, _localInvInertiaTensor)) {
      _hasOffDiagonalInertia = true;
      final inv = _localInvInertiaTensor.storage;
      _localInvInertia.setValues(inv[0], inv[4], inv[8]);
      updateWorldInertia();
      return;
    }

    _hasOffDiagonalInertia = false;
    final diag = _shape.computeLocalInertiaDiagonal(_mass);
    _localInvInertia.setValues(
      diag.x > 1e-12 ? 1.0 / diag.x : 0.0,
      diag.y > 1e-12 ? 1.0 / diag.y : 0.0,
      diag.z > 1e-12 ? 1.0 / diag.z : 0.0,
    );
    _localInvInertiaTensor.setZero();
    _localInvInertiaTensor.storage[0] = _localInvInertia.x;
    _localInvInertiaTensor.storage[4] = _localInvInertia.y;
    _localInvInertiaTensor.storage[8] = _localInvInertia.z;
    updateWorldInertia();
  }

  static bool _invertSymmetric3(Matrix3 sym, Matrix3 out) {
    final s = sym.storage;
    final a00 = s[0];
    final a01 = s[1];
    final a02 = s[2];
    final a11 = s[4];
    final a12 = s[5];
    final a22 = s[8];

    final c00 = a11 * a22 - a12 * a12;
    final c01 = -(a01 * a22 - a12 * a02);
    final c02 = a01 * a12 - a11 * a02;
    final c11 = a00 * a22 - a02 * a02;
    final c12 = -(a00 * a12 - a01 * a02);
    final c22 = a00 * a11 - a01 * a01;

    final det = a00 * c00 + a01 * c01 + a02 * c02;
    if (det.abs() <= 1e-14) {
      return false;
    }
    final invDet = 1.0 / det;
    final o = out.storage;
    o[0] = c00 * invDet;
    o[1] = c01 * invDet;
    o[2] = c02 * invDet;
    o[3] = c01 * invDet;
    o[4] = c11 * invDet;
    o[5] = c12 * invDet;
    o[6] = c02 * invDet;
    o[7] = c12 * invDet;
    o[8] = c22 * invDet;
    return true;
  }

  static void _rotateQuat(Quaternion q, Vector3 v, Vector3 out) {
    final qx = q.x;
    final qy = q.y;
    final qz = q.z;
    final qw = q.w;
    final tx = 2.0 * (qy * v.z - qz * v.y);
    final ty = 2.0 * (qz * v.x - qx * v.z);
    final tz = 2.0 * (qx * v.y - qy * v.x);
    out.setValues(
      v.x + qw * tx + (qy * tz - qz * ty),
      v.y + qw * ty + (qz * tx - qx * tz),
      v.z + qw * tz + (qx * ty - qy * tx),
    );
  }

  static void _cross(Vector3 a, Vector3 b, Vector3 out) {
    out.setValues(
      a.y * b.z - a.z * b.y,
      a.z * b.x - a.x * b.z,
      a.x * b.y - a.y * b.x,
    );
  }
}
