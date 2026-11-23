part of 'joints_3d.dart';

/// Articulated spherical ragdoll joint combining a 3-DOF ball-and-socket anchor
/// with a gimbal-lock-free swing cone half-angle limit ([swingLimitRad]) and
/// twist angle limits (`[minTwistRad..maxTwistRad]`).
class ConeTwistJoint3D({
  required super.bodyA,
  required super.bodyB,
  Vector3? localAnchorA,
  Vector3? localAnchorB,
  Vector3? localAxisA,
  Vector3? localAxisB,
  var double swingLimitRad = 0.7853981633974483,
  var double minTwistRad = -0.5235987755982988,
  var double maxTwistRad = 0.5235987755982988,
  super.collideConnected,
}) extends Joint3D {
  this
    : assert(swingLimitRad >= 0, 'swingLimitRad must be non-negative'),
      assert(minTwistRad <= maxTwistRad, 'minTwistRad must be <= maxTwistRad') {
    final axA = (localAxisA?.clone() ?? Vector3(1.0, 0.0, 0.0))..normalize();
    _quatFromXAxis(axA, _qFrameA);

    if (localAxisB == null) {
      // Align joint frame B with joint frame A in the initial world pose so
      // both `swingAngle == 0` and `twistAngle == 0` at rest.
      final qWorldA = bodyA.bodyRotation * _qFrameA;
      _quatMulConjA(bodyB.bodyRotation, qWorldA, _qFrameB);
    } else {
      final axB = localAxisB.normalized();
      // Build frame B around `axB`, choosing its Y/Z reference from frame A's
      // initial world Y-axis so initial twist error is minimal.
      final qWorldA = bodyA.bodyRotation * _qFrameA;
      final worldRefY = Vector3.zero();
      final localRefY = Vector3.zero();
      rotateVectorByQuat(qWorldA, Vector3(0.0, 1.0, 0.0), worldRefY);
      unrotateVectorByQuat(bodyB.bodyRotation, worldRefY, localRefY);
      _quatFromXAndRefY(axB, localRefY, _qFrameB);
    }
  }

  /// Anchor point in [bodyA]'s local space.
  final Vector3 localAnchorA = localAnchorA?.clone() ?? Vector3.zero();

  /// Anchor point in [bodyB]'s local space.
  final Vector3 localAnchorB = localAnchorB?.clone() ?? Vector3.zero();

  final Quaternion _qFrameA = Quaternion.identity();
  final Quaternion _qFrameB = Quaternion.identity();

  final Vector3 _wA = Vector3.zero();
  final Vector3 _wB = Vector3.zero();
  final Vector3 _rA = Vector3.zero();
  final Vector3 _rB = Vector3.zero();
  final Matrix3 _linearMass = Matrix3.zero();
  final Vector3 _linearBias = Vector3.zero();

  final Quaternion _qWorldA = Quaternion.identity();
  final Quaternion _qWorldB = Quaternion.identity();
  final Quaternion _qRel = Quaternion.identity();
  final Vector3 _swingAxisWorld = Vector3.zero();
  final Vector3 _twistAxisWorld = Vector3.zero();

  bool _swingActive = false;
  double _swingMass = 0.0;
  double _swingBias = 0.0;
  double _swingAccum = 0.0;

  int _twistState = 0; // -1 = lower, 0 = free, +1 = upper, 2 = locked
  double _twistMass = 0.0;
  double _twistBias = 0.0;
  double _twistAccum = 0.0;

  final Vector3 _rhs = Vector3.zero();
  final Vector3 _imp = Vector3.zero();
  final Vector3 _scratch = Vector3.zero();

  /// Current swing cone angle (in `[0..pi]` radians) between the two joint
  /// twist axes.
  double get swingAngle {
    final (swing, _) = _decomposeSwingTwist();
    return swing;
  }

  /// Current signed twist angle (in `[-pi..pi]` radians) around the cone axis.
  double get twistAngle {
    final (_, twist) = _decomposeSwingTwist();
    return twist;
  }

  (double swing, double twist) _decomposeSwingTwist() {
    _quatMul(bodyA.bodyRotation, _qFrameA, _qWorldA);
    _quatMul(bodyB.bodyRotation, _qFrameB, _qWorldB);
    _quatMulConjA(_qWorldA, _qWorldB, _qRel);
    if (_qRel.w < 0.0) {
      _qRel.setValues(-_qRel.x, -_qRel.y, -_qRel.z, -_qRel.w);
    }

    // Twist around local +X `(1, 0, 0)`: `qTwist = normalize(qx, 0, 0, qw)`.
    var tx = _qRel.x;
    var tw = _qRel.w;
    final tLen = math.sqrt(tx * tx + tw * tw);
    if (tLen > 1e-9) {
      tx /= tLen;
      tw /= tLen;
    } else {
      tx = 0.0;
      tw = 1.0;
    }
    final twist = 2.0 * math.atan2(tx, tw);

    // Pure swing `qSwing = qRel * conj(qTwist)` has zero X component:
    // `sy = qRel.y * tw + qRel.z * tx`, `sz = qRel.z * tw - qRel.y * tx`,
    // `sw = qRel.w * tw + qRel.x * tx`.
    final sy = _qRel.y * tw + _qRel.z * tx;
    final sz = _qRel.z * tw - _qRel.y * tx;
    final sw = (_qRel.w * tw + _qRel.x * tx).clamp(-1.0, 1.0);
    final sSin = math.sqrt(sy * sy + sz * sz);
    final swing = 2.0 * math.atan2(sSin, sw);

    if (sSin > 1e-8) {
      _scratch.setValues(0.0, sy / sSin, sz / sSin);
    } else {
      _scratch.setValues(0.0, 1.0, 0.0);
    }
    rotateVectorByQuat(_qWorldA, _scratch, _swingAxisWorld);

    _scratch.setValues(1.0, 0.0, 0.0);
    rotateVectorByQuat(_qWorldA, _scratch, _twistAxisWorld);
    return (swing, twist);
  }

  @override
  void prepare(double dt) {
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    _buildPointToPointInvK(bodyA, _rA, bodyB, _rB, _linearMass);

    final invDt = dt > 1e-9 ? 1.0 / dt : 0.0;
    const betaLin = 0.22;
    _linearBias.setValues(
      (_wB.x - _wA.x) * betaLin * invDt,
      (_wB.y - _wA.y) * betaLin * invDt,
      (_wB.z - _wA.z) * betaLin * invDt,
    );

    final (swing, twist) = _decomposeSwingTwist();
    const betaAng = 0.25;

    _swingActive = swing >= swingLimitRad;
    _swingAccum = 0.0;
    if (_swingActive) {
      _sumInvInertiaMul(bodyA, bodyB, _swingAxisWorld, _scratch);
      final kSwing = _swingAxisWorld.dot(_scratch);
      _swingMass = kSwing > 1e-12 ? 1.0 / kSwing : 0.0;
      _swingBias = math.max(0.0, swing - swingLimitRad) * betaAng * invDt;
    } else {
      _swingMass = 0.0;
      _swingBias = 0.0;
    }

    _twistState = 0;
    _twistAccum = 0.0;
    _twistBias = 0.0;
    _sumInvInertiaMul(bodyA, bodyB, _twistAxisWorld, _scratch);
    final kTwist = _twistAxisWorld.dot(_scratch);
    _twistMass = kTwist > 1e-12 ? 1.0 / kTwist : 0.0;
    if ((maxTwistRad - minTwistRad).abs() < 1e-4) {
      _twistState = 2;
      _twistBias = (twist - minTwistRad) * betaAng * invDt;
    } else if (twist <= minTwistRad) {
      _twistState = -1;
      _twistBias = (twist - minTwistRad) * betaAng * invDt;
    } else if (twist >= maxTwistRad) {
      _twistState = 1;
      _twistBias = (twist - maxTwistRad) * betaAng * invDt;
    }
  }

  @override
  void solveVelocity(double dt) {
    // 1. Ball-and-socket linear anchor lock.
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

    // 2. Swing cone half-angle limit (`swing <= swingLimitRad`).
    if (_swingActive && _swingMass > 0.0) {
      final dwSwing =
          (bodyB.angularVelocity.x - bodyA.angularVelocity.x) *
              _swingAxisWorld.x +
          (bodyB.angularVelocity.y - bodyA.angularVelocity.y) *
              _swingAxisWorld.y +
          (bodyB.angularVelocity.z - bodyA.angularVelocity.z) *
              _swingAxisWorld.z;
      var dLambda = -_swingMass * (dwSwing + _swingBias);
      final prev = _swingAccum;
      _swingAccum = math.min(0.0, prev + dLambda);
      dLambda = _swingAccum - prev;
      if (dLambda.abs() > 1e-12) {
        _applyAngularPairImpulse(
          bodyA,
          bodyB,
          _swingAxisWorld.x * dLambda,
          _swingAxisWorld.y * dLambda,
          _swingAxisWorld.z * dLambda,
          _scratch,
        );
      }
    }

    // 3. Twist min/max limits around cone axis.
    if (_twistState != 0 && _twistMass > 0.0) {
      final dwTwist =
          (bodyB.angularVelocity.x - bodyA.angularVelocity.x) *
              _twistAxisWorld.x +
          (bodyB.angularVelocity.y - bodyA.angularVelocity.y) *
              _twistAxisWorld.y +
          (bodyB.angularVelocity.z - bodyA.angularVelocity.z) *
              _twistAxisWorld.z;
      var dLambda = -_twistMass * (dwTwist + _twistBias);
      if (_twistState == -1) {
        final prev = _twistAccum;
        _twistAccum = math.max(0.0, prev + dLambda);
        dLambda = _twistAccum - prev;
      } else if (_twistState == 1) {
        final prev = _twistAccum;
        _twistAccum = math.min(0.0, prev + dLambda);
        dLambda = _twistAccum - prev;
      } else {
        _twistAccum += dLambda;
      }
      if (dLambda.abs() > 1e-12) {
        _applyAngularPairImpulse(
          bodyA,
          bodyB,
          _twistAxisWorld.x * dLambda,
          _twistAxisWorld.y * dLambda,
          _twistAxisWorld.z * dLambda,
          _scratch,
        );
      }
    }
  }

  @override
  void solvePosition() {
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
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

    final (swing, twist) = _decomposeSwingTwist();
    if (swing > swingLimitRad + 1e-4) {
      _sumInvInertiaMul(bodyA, bodyB, _swingAxisWorld, _scratch);
      final k = _swingAxisWorld.dot(_scratch);
      if (k > 1e-12) {
        final tau = -((swing - swingLimitRad) * 0.5) / k;
        _applyAngularPositionPairImpulse(
          bodyA,
          bodyB,
          _swingAxisWorld.x * tau,
          _swingAxisWorld.y * tau,
          _swingAxisWorld.z * tau,
          _scratch,
        );
      }
    }

    var twistErr = 0.0;
    if (twist < minTwistRad) {
      twistErr = twist - minTwistRad;
    } else if (twist > maxTwistRad) {
      twistErr = twist - maxTwistRad;
    }
    if (twistErr.abs() > 1e-4) {
      _sumInvInertiaMul(bodyA, bodyB, _twistAxisWorld, _scratch);
      final k = _twistAxisWorld.dot(_scratch);
      if (k > 1e-12) {
        final tau = -(twistErr * 0.5) / k;
        _applyAngularPositionPairImpulse(
          bodyA,
          bodyB,
          _twistAxisWorld.x * tau,
          _twistAxisWorld.y * tau,
          _twistAxisWorld.z * tau,
          _scratch,
        );
      }
    }
  }
}
