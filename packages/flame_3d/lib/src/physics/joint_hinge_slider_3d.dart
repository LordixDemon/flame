part of 'joints_3d.dart';

/// 1-DOF revolute hinge joint locking anchor positions and aligning
/// [localAxisA] with [localAxisB], with optional twist angle limits
/// `[minAngle..maxAngle]` (in radians).
class HingeJoint3D({
  required super.bodyA,
  required super.bodyB,
  Vector3? localAnchorA,
  Vector3? localAnchorB,
  Vector3? localAxisA,
  Vector3? localAxisB,
  var double? minAngle,
  var double? maxAngle,
  super.collideConnected,
}) extends Joint3D {
  this
    : assert(
        minAngle == null || maxAngle == null || minAngle <= maxAngle,
        'minAngle must be <= maxAngle',
      ) {
    buildOrthonormalBasis3D(this.localAxisA, _perp1A, _perp2A);
    if (localAxisB != null) {
      this.localAxisB
        ..setFrom(localAxisB)
        ..normalize();
    } else {
      // Express world axis of A in B's initial local frame so initial pose has
      // zero swing error.
      final worldAxis = Vector3.zero();
      rotateVectorByQuat(bodyA.bodyRotation, this.localAxisA, worldAxis);
      unrotateVectorByQuat(bodyB.bodyRotation, worldAxis, this.localAxisB);
      this.localAxisB.normalize();
    }
    // Express A's reference `_perp1A` in B's local frame so `jointAngle == 0`
    // in the initial configuration!
    final worldPerp1 = Vector3.zero();
    final candB = Vector3.zero();
    rotateVectorByQuat(bodyA.bodyRotation, _perp1A, worldPerp1);
    unrotateVectorByQuat(bodyB.bodyRotation, worldPerp1, candB);
    candB.addScaled(this.localAxisB, -candB.dot(this.localAxisB));
    if (candB.length2 > 1e-10) {
      _perp1B
        ..setFrom(candB)
        ..normalize();
    } else {
      final dummy = Vector3.zero();
      buildOrthonormalBasis3D(this.localAxisB, _perp1B, dummy);
    }
  }

  /// Anchor point in [bodyA]'s local space.
  final Vector3 localAnchorA = localAnchorA?.clone() ?? Vector3.zero();

  /// Anchor point in [bodyB]'s local space.
  final Vector3 localAnchorB = localAnchorB?.clone() ?? Vector3.zero();

  /// Unit hinge axis in [bodyA]'s local space.
  final Vector3 localAxisA = (localAxisA?.clone() ?? Vector3(0.0, 0.0, 1.0))
    ..normalize();

  /// Unit hinge axis in [bodyB]'s local space.
  final Vector3 localAxisB = Vector3.zero();

  final Vector3 _perp1A = Vector3.zero();
  final Vector3 _perp2A = Vector3.zero();
  final Vector3 _perp1B = Vector3.zero();

  final Vector3 _rA = Vector3.zero();
  final Vector3 _rB = Vector3.zero();
  final Vector3 _wA = Vector3.zero();
  final Vector3 _wB = Vector3.zero();
  final Matrix3 _linearMass = Matrix3.zero();
  final Vector3 _linearBias = Vector3.zero();

  final Vector3 _a1 = Vector3.zero();
  final Vector3 _a2 = Vector3.zero();
  final Vector3 _b2 = Vector3.zero();
  final Vector3 _c2 = Vector3.zero();
  final Vector3 _u1 = Vector3.zero();
  final Vector3 _v1 = Vector3.zero();
  final Vector3 _u2 = Vector3.zero();

  double _swingM00 = 0.0;
  double _swingM01 = 0.0;
  double _swingM11 = 0.0;
  double _swingBias0 = 0.0;
  double _swingBias1 = 0.0;

  int _limitState = 0; // -1 = lower, 0 = inactive, +1 = upper, 2 = locked
  double _twistMass = 0.0;
  double _limitBias = 0.0;
  double _limitAccum = 0.0;

  final Vector3 _rhs = Vector3.zero();
  final Vector3 _imp = Vector3.zero();
  final Vector3 _scratch = Vector3.zero();
  final Vector3 _scratch2 = Vector3.zero();

  /// Current signed twist angle (radians) of [bodyB] relative to [bodyA] around
  /// the hinge axis.
  double get jointAngle {
    rotateVectorByQuat(bodyA.bodyRotation, _perp1A, _u1);
    rotateVectorByQuat(bodyA.bodyRotation, _perp2A, _v1);
    rotateVectorByQuat(bodyB.bodyRotation, _perp1B, _u2);
    return math.atan2(_u2.dot(_v1), _u2.dot(_u1));
  }

  @override
  void prepare(double dt) {
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    _buildPointToPointInvK(bodyA, _rA, bodyB, _rB, _linearMass);

    final invDt = dt > 1e-9 ? 1.0 / dt : 0.0;
    const betaLin = 0.2;
    _linearBias.setValues(
      (_wB.x - _wA.x) * betaLin * invDt,
      (_wB.y - _wA.y) * betaLin * invDt,
      (_wB.z - _wA.z) * betaLin * invDt,
    );

    // Swing basis perpendicular to `a1`.
    rotateVectorByQuat(bodyA.bodyRotation, localAxisA, _a1);
    rotateVectorByQuat(bodyB.bodyRotation, localAxisB, _a2);
    buildOrthonormalBasis3D(_a1, _b2, _c2);

    // 2x2 angular effective mass on `(_b2, _c2)` using `I_A^-1 + I_B^-1`.
    _sumInvInertiaMul(bodyA, bodyB, _b2, _scratch);
    final k00 = _b2.dot(_scratch);
    final k01 = _c2.dot(_scratch);
    _sumInvInertiaMul(bodyA, bodyB, _c2, _scratch);
    final k11 = _c2.dot(_scratch);
    final det = k00 * k11 - k01 * k01;
    if (det.abs() > 1e-14) {
      final invDet = 1.0 / det;
      _swingM00 = k11 * invDet;
      _swingM01 = -k01 * invDet;
      _swingM11 = k00 * invDet;
    } else {
      _swingM00 = 0.0;
      _swingM01 = 0.0;
      _swingM11 = 0.0;
    }

    // Swing angular error `err = a1 x a2`; target `(wB - wA) = -(beta/dt)*err`.
    final errX = _a1.y * _a2.z - _a1.z * _a2.y;
    final errY = _a1.z * _a2.x - _a1.x * _a2.z;
    final errZ = _a1.x * _a2.y - _a1.y * _a2.x;
    const betaAng = 0.25;
    _swingBias0 =
        (errX * _b2.x + errY * _b2.y + errZ * _b2.z) * betaAng * invDt;
    _swingBias1 =
        (errX * _c2.x + errY * _c2.y + errZ * _c2.z) * betaAng * invDt;

    // Optional twist limits around `_a1`.
    _limitState = 0;
    _limitBias = 0.0;
    _limitAccum = 0.0;
    if (minAngle != null || maxAngle != null) {
      _sumInvInertiaMul(bodyA, bodyB, _a1, _scratch);
      final kTwist = _a1.dot(_scratch);
      _twistMass = kTwist > 1e-12 ? 1.0 / kTwist : 0.0;

      final angle = jointAngle;
      final lo = minAngle;
      final hi = maxAngle;
      if (lo != null && hi != null && (hi - lo).abs() < 1e-4) {
        _limitState = 2;
        _limitBias = (angle - lo) * betaAng * invDt;
      } else if (lo != null && angle <= lo) {
        _limitState = -1;
        _limitBias = (angle - lo) * betaAng * invDt;
      } else if (hi != null && angle >= hi) {
        _limitState = 1;
        _limitBias = (angle - hi) * betaAng * invDt;
      }
    }
  }

  @override
  void solveVelocity(double dt) {
    // 1. Point-to-point linear anchor impulse.
    _relVel3(bodyA, _rA, bodyB, _rB, _rhs);
    _rhs.add(_linearBias);
    _mulMat3Neg(_linearMass, _rhs, _imp);
    _applyLinearPairImpulse(
      bodyA,
      _rA,
      bodyB,
      _rB,
      _imp.x,
      _imp.y,
      _imp.z,
      _scratch,
    );

    // 2. 2-DOF swing angular alignment impulse.
    final dwx = bodyB.angularVelocity.x - bodyA.angularVelocity.x;
    final dwy = bodyB.angularVelocity.y - bodyA.angularVelocity.y;
    final dwz = bodyB.angularVelocity.z - bodyA.angularVelocity.z;
    final cDot0 = dwx * _b2.x + dwy * _b2.y + dwz * _b2.z + _swingBias0;
    final cDot1 = dwx * _c2.x + dwy * _c2.y + dwz * _c2.z + _swingBias1;
    final l0 = -(_swingM00 * cDot0 + _swingM01 * cDot1);
    final l1 = -(_swingM01 * cDot0 + _swingM11 * cDot1);
    _applyAngularPairImpulse(
      bodyA,
      bodyB,
      _b2.x * l0 + _c2.x * l1,
      _b2.y * l0 + _c2.y * l1,
      _b2.z * l0 + _c2.z * l1,
      _scratch,
    );

    // 3. Twist limit impulse around `_a1`.
    if (_limitState != 0 && _twistMass > 0.0) {
      final dwTwist =
          (bodyB.angularVelocity.x - bodyA.angularVelocity.x) * _a1.x +
          (bodyB.angularVelocity.y - bodyA.angularVelocity.y) * _a1.y +
          (bodyB.angularVelocity.z - bodyA.angularVelocity.z) * _a1.z;
      var dLambda = -_twistMass * (dwTwist + _limitBias);
      if (_limitState == -1) {
        final prev = _limitAccum;
        _limitAccum = math.max(0.0, prev + dLambda);
        dLambda = _limitAccum - prev;
      } else if (_limitState == 1) {
        final prev = _limitAccum;
        _limitAccum = math.min(0.0, prev + dLambda);
        dLambda = _limitAccum - prev;
      } else {
        _limitAccum += dLambda;
      }
      if (dLambda.abs() > 1e-12) {
        _applyAngularPairImpulse(
          bodyA,
          bodyB,
          _a1.x * dLambda,
          _a1.y * dLambda,
          _a1.z * dLambda,
          _scratch,
        );
      }
    }
  }

  @override
  void solvePosition() {
    // 1. Anchor position drift correction.
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    final ex = _wB.x - _wA.x;
    final ey = _wB.y - _wA.y;
    final ez = _wB.z - _wA.z;
    if (ex * ex + ey * ey + ez * ez > 1e-9) {
      _buildPointToPointInvK(bodyA, _rA, bodyB, _rB, _linearMass);
      _rhs.setValues(ex * 0.4, ey * 0.4, ez * 0.4);
      _mulMat3Neg(_linearMass, _rhs, _imp);
      _applyPositionPairImpulse(
        bodyA,
        _rA,
        bodyB,
        _rB,
        _imp.x,
        _imp.y,
        _imp.z,
        _scratch,
      );
    }

    // 2. Swing & twist limit angular drift correction.
    rotateVectorByQuat(bodyA.bodyRotation, localAxisA, _a1);
    rotateVectorByQuat(bodyB.bodyRotation, localAxisB, _a2);
    final errX = _a1.y * _a2.z - _a1.z * _a2.y;
    final errY = _a1.z * _a2.x - _a1.x * _a2.z;
    final errZ = _a1.x * _a2.y - _a1.y * _a2.x;
    if (errX * errX + errY * errY + errZ * errZ > 1e-8) {
      _scratch2.setValues(errX, errY, errZ);
      _sumInvInertiaMul(bodyA, bodyB, _scratch2, _scratch);
      final denom = _scratch2.dot(_scratch);
      if (denom > 1e-12) {
        final scale = -0.4 * _scratch2.length2 / denom;
        _applyAngularPositionPairImpulse(
          bodyA,
          bodyB,
          errX * scale,
          errY * scale,
          errZ * scale,
          _scratch,
        );
      }
    }

    if (minAngle != null || maxAngle != null) {
      rotateVectorByQuat(bodyA.bodyRotation, localAxisA, _a1);
      final angle = jointAngle;
      var angleErr = 0.0;
      if (minAngle != null && angle < minAngle!) {
        angleErr = angle - minAngle!;
      } else if (maxAngle != null && angle > maxAngle!) {
        angleErr = angle - maxAngle!;
      }
      if (angleErr.abs() > 1e-4) {
        _sumInvInertiaMul(bodyA, bodyB, _a1, _scratch);
        final k = _a1.dot(_scratch);
        if (k > 1e-12) {
          final tau = -(angleErr * 0.5) / k;
          _applyAngularPositionPairImpulse(
            bodyA,
            bodyB,
            _a1.x * tau,
            _a1.y * tau,
            _a1.z * tau,
            _scratch,
          );
        }
      }
    }
  }
}

/// 0-DOF weld joint locking both the relative 3D anchor position and the
/// relative 3D orientation between [bodyA] and [bodyB].
class FixedJoint3D({
  required super.bodyA,
  required super.bodyB,
  Vector3? localAnchorA,
  Vector3? localAnchorB,
  Quaternion? referenceRotation,
  super.collideConnected,
}) extends Joint3D {
  this {
    if (localAnchorA == null && localAnchorB == null) {
      // Lock the two bodies at their current relative pose around the midpoint.
      final mid = (bodyA.bodyPosition + bodyB.bodyPosition)..scale(0.5);
      unrotateVectorByQuat(
        bodyA.bodyRotation,
        mid - bodyA.bodyPosition,
        _anchorA,
      );
      unrotateVectorByQuat(
        bodyB.bodyRotation,
        mid - bodyB.bodyPosition,
        _anchorB,
      );
    } else {
      if (localAnchorA != null) {
        _anchorA.setFrom(localAnchorA);
      }
      if (localAnchorB != null) {
        _anchorB.setFrom(localAnchorB);
      }
    }
    if (referenceRotation != null) {
      _qRef
        ..setFrom(referenceRotation)
        ..normalize();
    } else {
      _quatMulConjA(bodyA.bodyRotation, bodyB.bodyRotation, _qRef);
    }
  }

  final Vector3 _anchorA = Vector3.zero();
  final Vector3 _anchorB = Vector3.zero();
  final Quaternion _qRef = Quaternion.identity();

  /// Anchor point in [bodyA]'s local space.
  Vector3 get localAnchorA => _anchorA;

  /// Anchor point in [bodyB]'s local space.
  Vector3 get localAnchorB => _anchorB;

  /// Target relative orientation `qA^-1 * qB`.
  Quaternion get referenceRotation => _qRef;

  final Vector3 _wA = Vector3.zero();
  final Vector3 _wB = Vector3.zero();
  final Vector3 _rA = Vector3.zero();
  final Vector3 _rB = Vector3.zero();
  final Matrix3 _linearMass = Matrix3.zero();
  final Matrix3 _angularMass = Matrix3.zero();
  final Vector3 _linearBias = Vector3.zero();
  final Vector3 _angularBias = Vector3.zero();
  final Vector3 _rhs = Vector3.zero();
  final Vector3 _imp = Vector3.zero();
  final Vector3 _scratch = Vector3.zero();
  final Quaternion _qTarget = Quaternion.identity();
  final Quaternion _qErr = Quaternion.identity();

  @override
  void prepare(double dt) {
    _computeWorldAnchorAndLever(bodyA, _anchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, _anchorB, _wB, _rB);
    _buildPointToPointInvK(bodyA, _rA, bodyB, _rB, _linearMass);
    _buildAngularInvK(bodyA, bodyB, _angularMass);

    final invDt = dt > 1e-9 ? 1.0 / dt : 0.0;
    const betaLin = 0.22;
    _linearBias.setValues(
      (_wB.x - _wA.x) * betaLin * invDt,
      (_wB.y - _wA.y) * betaLin * invDt,
      (_wB.z - _wA.z) * betaLin * invDt,
    );

    _computeWorldRotationError(
      bodyA.bodyRotation,
      bodyB.bodyRotation,
      _qRef,
      _qTarget,
      _qErr,
      _angularBias,
    );
    _angularBias.scale(0.25 * invDt);
  }

  @override
  void solveVelocity(double dt) {
    // 1. 3-DOF linear lock.
    _relVel3(bodyA, _rA, bodyB, _rB, _rhs);
    _rhs.add(_linearBias);
    _mulMat3Neg(_linearMass, _rhs, _imp);
    _applyLinearPairImpulse(
      bodyA,
      _rA,
      bodyB,
      _rB,
      _imp.x,
      _imp.y,
      _imp.z,
      _scratch,
    );

    // 2. 3-DOF angular lock.
    _rhs.setValues(
      (bodyB.angularVelocity.x - bodyA.angularVelocity.x) + _angularBias.x,
      (bodyB.angularVelocity.y - bodyA.angularVelocity.y) + _angularBias.y,
      (bodyB.angularVelocity.z - bodyA.angularVelocity.z) + _angularBias.z,
    );
    _mulMat3Neg(_angularMass, _rhs, _imp);
    _applyAngularPairImpulse(
      bodyA,
      bodyB,
      _imp.x,
      _imp.y,
      _imp.z,
      _scratch,
    );
  }

  @override
  void solvePosition() {
    _computeWorldAnchorAndLever(bodyA, _anchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, _anchorB, _wB, _rB);
    final ex = _wB.x - _wA.x;
    final ey = _wB.y - _wA.y;
    final ez = _wB.z - _wA.z;
    if (ex * ex + ey * ey + ez * ez > 1e-9) {
      _buildPointToPointInvK(bodyA, _rA, bodyB, _rB, _linearMass);
      _rhs.setValues(ex * 0.45, ey * 0.45, ez * 0.45);
      _mulMat3Neg(_linearMass, _rhs, _imp);
      _applyPositionPairImpulse(
        bodyA,
        _rA,
        bodyB,
        _rB,
        _imp.x,
        _imp.y,
        _imp.z,
        _scratch,
      );
    }

    _computeWorldRotationError(
      bodyA.bodyRotation,
      bodyB.bodyRotation,
      _qRef,
      _qTarget,
      _qErr,
      _rhs,
    );
    if (_rhs.length2 > 1e-9) {
      _buildAngularInvK(bodyA, bodyB, _angularMass);
      _rhs.scale(0.45);
      _mulMat3Neg(_angularMass, _rhs, _imp);
      _applyAngularPositionPairImpulse(
        bodyA,
        bodyB,
        _imp.x,
        _imp.y,
        _imp.z,
        _scratch,
      );
    }
  }
}

/// 1-DOF prismatic slider joint permitting translation only along a local or
/// world axis, with optional `[minDistance..maxDistance]` translational stops
/// and a force-limited linear motor (`motorSpeed`, `maxMotorForce`).
class SliderJoint3D({
  required super.bodyA,
  required super.bodyB,
  Vector3? localAnchorA,
  Vector3? localAnchorB,
  Vector3? localAxisA,
  Vector3? worldAxis,
  Quaternion? referenceRotation,
  var double? minDistance,
  var double? maxDistance,
  var double motorSpeed = 0.0,
  var double maxMotorForce = 0.0,
  super.collideConnected,
}) extends Joint3D {
  this
    : assert(
        minDistance == null ||
            maxDistance == null ||
            minDistance <= maxDistance,
        'minDistance must be <= maxDistance',
      ),
      assert(maxMotorForce >= 0, 'maxMotorForce must be non-negative') {
    if (worldAxis != null && worldAxis.length2 > 1e-12) {
      final unitW = worldAxis.normalized();
      unrotateVectorByQuat(bodyA.bodyRotation, unitW, _axisA);
      _axisA.normalize();
    } else if (localAxisA != null && localAxisA.length2 > 1e-12) {
      _axisA
        ..setFrom(localAxisA)
        ..normalize();
    } else {
      _axisA.setValues(1.0, 0.0, 0.0);
    }

    if (referenceRotation != null) {
      _qRef
        ..setFrom(referenceRotation)
        ..normalize();
    } else {
      _quatMulConjA(bodyA.bodyRotation, bodyB.bodyRotation, _qRef);
    }
  }

  /// Anchor point in [bodyA]'s local space.
  final Vector3 localAnchorA = localAnchorA?.clone() ?? Vector3.zero();

  /// Anchor point in [bodyB]'s local space.
  final Vector3 localAnchorB = localAnchorB?.clone() ?? Vector3.zero();

  final Vector3 _axisA = Vector3(1.0, 0.0, 0.0);
  final Quaternion _qRef = Quaternion.identity();

  /// Unit slider axis in [bodyA]'s local space.
  Vector3 get localAxisA => _axisA;

  final Vector3 _wA = Vector3.zero();
  final Vector3 _wB = Vector3.zero();
  final Vector3 _rA = Vector3.zero();
  final Vector3 _rAEff = Vector3.zero();
  final Vector3 _rB = Vector3.zero();
  final Vector3 _n1 = Vector3.zero();
  final Vector3 _t1 = Vector3.zero();
  final Vector3 _t2 = Vector3.zero();

  final Matrix3 _angularMass = Matrix3.zero();
  final Vector3 _angularBias = Vector3.zero();
  double _transM00 = 0.0;
  double _transM01 = 0.0;
  double _transM11 = 0.0;
  double _transBias0 = 0.0;
  double _transBias1 = 0.0;

  double _axialMass = 0.0;
  double _motorAccum = 0.0;
  double _maxMotorImpulse = 0.0;

  int _limitState = 0; // -1 = lower, 0 = free, +1 = upper, 2 = locked
  double _limitBias = 0.0;
  double _limitAccum = 0.0;

  final Vector3 _rhs = Vector3.zero();
  final Vector3 _imp = Vector3.zero();
  final Vector3 _scratch = Vector3.zero();
  final Quaternion _qTarget = Quaternion.identity();
  final Quaternion _qErr = Quaternion.identity();

  /// Current signed translation (meters) along the world slider axis.
  double get currentDistance {
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    rotateVectorByQuat(bodyA.bodyRotation, _axisA, _n1);
    return (_wB.x - _wA.x) * _n1.x +
        (_wB.y - _wA.y) * _n1.y +
        (_wB.z - _wA.z) * _n1.z;
  }

  /// Current relative speed (`m/s`) along the world slider axis.
  double get currentSpeed {
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    rotateVectorByQuat(bodyA.bodyRotation, _axisA, _n1);
    _rAEff.setValues(
      _rA.x + (_wB.x - _wA.x),
      _rA.y + (_wB.y - _wA.y),
      _rA.z + (_wB.z - _wA.z),
    );
    return _relVelAlongAxis(bodyA, _rAEff, bodyB, _rB, _n1);
  }

  @override
  void prepare(double dt) {
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    final dx = _wB.x - _wA.x;
    final dy = _wB.y - _wA.y;
    final dz = _wB.z - _wA.z;
    _rAEff.setValues(_rA.x + dx, _rA.y + dy, _rA.z + dz);

    rotateVectorByQuat(bodyA.bodyRotation, _axisA, _n1);
    buildOrthonormalBasis3D(_n1, _t1, _t2);

    // 1. 3-DOF angular orientation lock.
    _buildAngularInvK(bodyA, bodyB, _angularMass);
    final invDt = dt > 1e-9 ? 1.0 / dt : 0.0;
    _computeWorldRotationError(
      bodyA.bodyRotation,
      bodyB.bodyRotation,
      _qRef,
      _qTarget,
      _qErr,
      _angularBias,
    );
    _angularBias.scale(0.25 * invDt);

    // 2. 2-DOF transverse linear lock perpendicular to `_n1`.
    final k00 = computeLinearAxisK(bodyA, _rAEff, bodyB, _rB, _t1, _scratch);
    final k11 = computeLinearAxisK(bodyA, _rAEff, bodyB, _rB, _t2, _scratch);
    final k01 = _computeLinearCoupledK(
      bodyA,
      _rAEff,
      bodyB,
      _rB,
      _t1,
      _t2,
      _scratch,
    );
    final det = k00 * k11 - k01 * k01;
    if (det.abs() > 1e-14) {
      final invDet = 1.0 / det;
      _transM00 = k11 * invDet;
      _transM01 = -k01 * invDet;
      _transM11 = k00 * invDet;
    } else {
      _transM00 = 0.0;
      _transM01 = 0.0;
      _transM11 = 0.0;
    }
    const betaLin = 0.22;
    _transBias0 = (dx * _t1.x + dy * _t1.y + dz * _t1.z) * betaLin * invDt;
    _transBias1 = (dx * _t2.x + dy * _t2.y + dz * _t2.z) * betaLin * invDt;

    // 3. Axial motor & translational limits along `_n1`.
    final kAxial = computeLinearAxisK(
      bodyA,
      _rAEff,
      bodyB,
      _rB,
      _n1,
      _scratch,
    );
    _axialMass = kAxial > 1e-12 ? 1.0 / kAxial : 0.0;
    _motorAccum = 0.0;
    _maxMotorImpulse = maxMotorForce * math.max(0.0, dt);

    _limitState = 0;
    _limitBias = 0.0;
    _limitAccum = 0.0;
    if (minDistance != null || maxDistance != null) {
      final dist = dx * _n1.x + dy * _n1.y + dz * _n1.z;
      final lo = minDistance;
      final hi = maxDistance;
      if (lo != null && hi != null && (hi - lo).abs() < 1e-4) {
        _limitState = 2;
        _limitBias = (dist - lo) * betaLin * invDt;
      } else if (lo != null && dist <= lo) {
        _limitState = -1;
        _limitBias = (dist - lo) * betaLin * invDt;
      } else if (hi != null && dist >= hi) {
        _limitState = 1;
        _limitBias = (dist - hi) * betaLin * invDt;
      }
    }
  }

  @override
  void solveVelocity(double dt) {
    // 1. 3-DOF angular orientation lock.
    _rhs.setValues(
      (bodyB.angularVelocity.x - bodyA.angularVelocity.x) + _angularBias.x,
      (bodyB.angularVelocity.y - bodyA.angularVelocity.y) + _angularBias.y,
      (bodyB.angularVelocity.z - bodyA.angularVelocity.z) + _angularBias.z,
    );
    _mulMat3Neg(_angularMass, _rhs, _imp);
    _applyAngularPairImpulse(
      bodyA,
      bodyB,
      _imp.x,
      _imp.y,
      _imp.z,
      _scratch,
    );

    // 2. 2-DOF transverse linear lock.
    final vT1 = _relVelAlongAxis(bodyA, _rAEff, bodyB, _rB, _t1) + _transBias0;
    final vT2 = _relVelAlongAxis(bodyA, _rAEff, bodyB, _rB, _t2) + _transBias1;
    final l0 = -(_transM00 * vT1 + _transM01 * vT2);
    final l1 = -(_transM01 * vT1 + _transM11 * vT2);
    _applyLinearPairImpulse(
      bodyA,
      _rAEff,
      bodyB,
      _rB,
      _t1.x * l0 + _t2.x * l1,
      _t1.y * l0 + _t2.y * l1,
      _t1.z * l0 + _t2.z * l1,
      _scratch,
    );

    // 3. Axial motor impulse (`maxMotorForce`).
    if (_maxMotorImpulse > 0.0 && _axialMass > 0.0 && _limitState != 2) {
      final vAxial = _relVelAlongAxis(bodyA, _rAEff, bodyB, _rB, _n1);
      var dMotor = _axialMass * (motorSpeed - vAxial);
      final prev = _motorAccum;
      _motorAccum = (prev + dMotor).clamp(-_maxMotorImpulse, _maxMotorImpulse);
      dMotor = _motorAccum - prev;
      if (dMotor.abs() > 1e-12) {
        _applyLinearPairImpulse(
          bodyA,
          _rAEff,
          bodyB,
          _rB,
          _n1.x * dMotor,
          _n1.y * dMotor,
          _n1.z * dMotor,
          _scratch,
        );
      }
    }

    // 4. Axial translational limits.
    if (_limitState != 0 && _axialMass > 0.0) {
      final vAxial = _relVelAlongAxis(bodyA, _rAEff, bodyB, _rB, _n1);
      var dLambda = -_axialMass * (vAxial + _limitBias);
      if (_limitState == -1) {
        final prev = _limitAccum;
        _limitAccum = math.max(0.0, prev + dLambda);
        dLambda = _limitAccum - prev;
      } else if (_limitState == 1) {
        final prev = _limitAccum;
        _limitAccum = math.min(0.0, prev + dLambda);
        dLambda = _limitAccum - prev;
      } else {
        _limitAccum += dLambda;
      }
      if (dLambda.abs() > 1e-12) {
        _applyLinearPairImpulse(
          bodyA,
          _rAEff,
          bodyB,
          _rB,
          _n1.x * dLambda,
          _n1.y * dLambda,
          _n1.z * dLambda,
          _scratch,
        );
      }
    }
  }

  @override
  void solvePosition() {
    // 1. Orientation drift correction.
    _computeWorldRotationError(
      bodyA.bodyRotation,
      bodyB.bodyRotation,
      _qRef,
      _qTarget,
      _qErr,
      _rhs,
    );
    if (_rhs.length2 > 1e-9) {
      _buildAngularInvK(bodyA, bodyB, _angularMass);
      _rhs.scale(0.45);
      _mulMat3Neg(_angularMass, _rhs, _imp);
      _applyAngularPositionPairImpulse(
        bodyA,
        bodyB,
        _imp.x,
        _imp.y,
        _imp.z,
        _scratch,
      );
    }

    // 2. Transverse & axial limit position drift correction.
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    final dx = _wB.x - _wA.x;
    final dy = _wB.y - _wA.y;
    final dz = _wB.z - _wA.z;
    _rAEff.setValues(_rA.x + dx, _rA.y + dy, _rA.z + dz);
    rotateVectorByQuat(bodyA.bodyRotation, _axisA, _n1);
    buildOrthonormalBasis3D(_n1, _t1, _t2);

    final e0 = dx * _t1.x + dy * _t1.y + dz * _t1.z;
    final e1 = dx * _t2.x + dy * _t2.y + dz * _t2.z;
    if (e0 * e0 + e1 * e1 > 1e-9) {
      final k00 = computeLinearAxisK(bodyA, _rAEff, bodyB, _rB, _t1, _scratch);
      final k11 = computeLinearAxisK(bodyA, _rAEff, bodyB, _rB, _t2, _scratch);
      final k01 = _computeLinearCoupledK(
        bodyA,
        _rAEff,
        bodyB,
        _rB,
        _t1,
        _t2,
        _scratch,
      );
      final det = k00 * k11 - k01 * k01;
      if (det.abs() > 1e-14) {
        final invDet = 1.0 / det;
        final c0 = e0 * 0.45;
        final c1 = e1 * 0.45;
        final l0 = -(k11 * invDet * c0 - k01 * invDet * c1);
        final l1 = -(-k01 * invDet * c0 + k00 * invDet * c1);
        _applyPositionPairImpulse(
          bodyA,
          _rAEff,
          bodyB,
          _rB,
          _t1.x * l0 + _t2.x * l1,
          _t1.y * l0 + _t2.y * l1,
          _t1.z * l0 + _t2.z * l1,
          _scratch,
        );
      }
    }

    if (minDistance != null || maxDistance != null) {
      _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
      _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
      final ndx = _wB.x - _wA.x;
      final ndy = _wB.y - _wA.y;
      final ndz = _wB.z - _wA.z;
      _rAEff.setValues(_rA.x + ndx, _rA.y + ndy, _rA.z + ndz);
      rotateVectorByQuat(bodyA.bodyRotation, _axisA, _n1);
      final dist = ndx * _n1.x + ndy * _n1.y + ndz * _n1.z;
      var axialErr = 0.0;
      if (minDistance != null && dist < minDistance!) {
        axialErr = dist - minDistance!;
      } else if (maxDistance != null && dist > maxDistance!) {
        axialErr = dist - maxDistance!;
      }
      if (axialErr.abs() > 1e-4) {
        final k = computeLinearAxisK(bodyA, _rAEff, bodyB, _rB, _n1, _scratch);
        if (k > 1e-12) {
          final lambda = -(axialErr * 0.5) / k;
          _applyPositionPairImpulse(
            bodyA,
            _rAEff,
            bodyB,
            _rB,
            _n1.x * lambda,
            _n1.y * lambda,
            _n1.z * lambda,
            _scratch,
          );
        }
      }
    }
  }
}
