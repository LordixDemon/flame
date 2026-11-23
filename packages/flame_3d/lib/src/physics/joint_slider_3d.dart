part of 'joints_3d.dart';

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
      quatMulConjA(bodyA.bodyRotation, bodyB.bodyRotation, _qRef);
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
    computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    rotateVectorByQuat(bodyA.bodyRotation, _axisA, _n1);
    return (_wB.x - _wA.x) * _n1.x +
        (_wB.y - _wA.y) * _n1.y +
        (_wB.z - _wA.z) * _n1.z;
  }

  /// Current relative speed (`m/s`) along the world slider axis.
  double get currentSpeed {
    computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    rotateVectorByQuat(bodyA.bodyRotation, _axisA, _n1);
    _rAEff.setValues(
      _rA.x + (_wB.x - _wA.x),
      _rA.y + (_wB.y - _wA.y),
      _rA.z + (_wB.z - _wA.z),
    );
    return relativeVelocityAlongAxis(bodyA, _rAEff, bodyB, _rB, _n1);
  }

  @override
  void prepare(double dt) {
    computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    final dx = _wB.x - _wA.x;
    final dy = _wB.y - _wA.y;
    final dz = _wB.z - _wA.z;
    _rAEff.setValues(_rA.x + dx, _rA.y + dy, _rA.z + dz);

    rotateVectorByQuat(bodyA.bodyRotation, _axisA, _n1);
    buildOrthonormalBasis3D(_n1, _t1, _t2);

    // 1. 3-DOF angular orientation lock.
    buildAngularInvK(bodyA, bodyB, _angularMass);
    final invDt = dt > 1e-9 ? 1.0 / dt : 0.0;
    computeWorldRotationError(
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
    final k01 = computeLinearCoupledK(
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
    mulMat3Neg(_angularMass, _rhs, _imp);
    applyAngularPairImpulse(
      bodyA,
      bodyB,
      _imp.x,
      _imp.y,
      _imp.z,
      _scratch,
    );

    // 2. 2-DOF transverse linear lock.
    final vT1 =
        relativeVelocityAlongAxis(bodyA, _rAEff, bodyB, _rB, _t1) + _transBias0;
    final vT2 =
        relativeVelocityAlongAxis(bodyA, _rAEff, bodyB, _rB, _t2) + _transBias1;
    final l0 = -(_transM00 * vT1 + _transM01 * vT2);
    final l1 = -(_transM01 * vT1 + _transM11 * vT2);
    applyLinearPairImpulse(
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
      final vAxial = relativeVelocityAlongAxis(bodyA, _rAEff, bodyB, _rB, _n1);
      var dMotor = _axialMass * (motorSpeed - vAxial);
      final prev = _motorAccum;
      _motorAccum = (prev + dMotor).clamp(-_maxMotorImpulse, _maxMotorImpulse);
      dMotor = _motorAccum - prev;
      if (dMotor.abs() > 1e-12) {
        applyLinearPairImpulse(
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
      final vAxial = relativeVelocityAlongAxis(bodyA, _rAEff, bodyB, _rB, _n1);
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
        applyLinearPairImpulse(
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
    computeWorldRotationError(
      bodyA.bodyRotation,
      bodyB.bodyRotation,
      _qRef,
      _qTarget,
      _qErr,
      _rhs,
    );
    if (_rhs.length2 > 1e-9) {
      buildAngularInvK(bodyA, bodyB, _angularMass);
      _rhs.scale(0.45);
      mulMat3Neg(_angularMass, _rhs, _imp);
      applyAngularPositionPairImpulse(
        bodyA,
        bodyB,
        _imp.x,
        _imp.y,
        _imp.z,
        _scratch,
      );
    }

    // 2. Transverse & axial limit position drift correction.
    computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
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
      final k01 = computeLinearCoupledK(
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
        applyPositionPairImpulse(
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
      computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
      computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
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
          applyPositionPairImpulse(
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
