part of 'joints_3d.dart';

/// Configurable 6-degree-of-freedom constraint with independent 3 linear and 3
/// angular lower/upper limits (`lower == upper` locks, `lower < upper` bounds,
/// `lower > upper` frees) plus unconditionally-stable implicit linear and
/// angular spring stiffness and damping.
class Generic6DofJoint3D({
  required super.bodyA,
  required super.bodyB,
  Vector3? localAnchorA,
  Vector3? localAnchorB,
  Quaternion? localFrameA,
  Quaternion? localFrameB,
  Vector3? linearLowerLimit,
  Vector3? linearUpperLimit,
  Vector3? angularLowerLimit,
  Vector3? angularUpperLimit,
  Vector3? linearSpringStiffness,
  Vector3? linearSpringDamping,
  Vector3? angularSpringStiffness,
  Vector3? angularSpringDamping,
  Vector3? linearEquilibrium,
  Vector3? angularEquilibrium,
  super.collideConnected,
}) extends Joint3D {
  this {
    if (localFrameA != null) {
      _frameA
        ..setFrom(localFrameA)
        ..normalize();
    }
    if (localFrameB != null) {
      _frameB
        ..setFrom(localFrameB)
        ..normalize();
    } else {
      final qWorldA = bodyA.bodyRotation * _frameA;
      _quatMulConjA(bodyB.bodyRotation, qWorldA, _frameB);
    }
  }

  /// Anchor point in [bodyA]'s local space.
  final Vector3 localAnchorA = localAnchorA?.clone() ?? Vector3.zero();

  /// Anchor point in [bodyB]'s local space.
  final Vector3 localAnchorB = localAnchorB?.clone() ?? Vector3.zero();

  final Quaternion _frameA = Quaternion.identity();
  final Quaternion _frameB = Quaternion.identity();

  /// Lower translational bounds `(x, y, z)` in joint frame `A`.
  final Vector3 linearLowerLimit = linearLowerLimit?.clone() ?? Vector3.zero();

  /// Upper translational bounds `(x, y, z)` in joint frame `A`.
  final Vector3 linearUpperLimit = linearUpperLimit?.clone() ?? Vector3.zero();

  /// Lower rotational bounds `(rx, ry, rz)` (radians) in joint frame `A`.
  final Vector3 angularLowerLimit =
      angularLowerLimit?.clone() ?? Vector3.zero();

  /// Upper rotational bounds `(rx, ry, rz)` (radians) in joint frame `A`.
  final Vector3 angularUpperLimit =
      angularUpperLimit?.clone() ?? Vector3.zero();

  /// Linear spring stiffness `(kx, ky, kz)` (`N/m`).
  final Vector3 linearSpringStiffness =
      linearSpringStiffness?.clone() ?? Vector3.zero();

  /// Linear spring damping `(cx, cy, cz)` (`N*s/m`).
  final Vector3 linearSpringDamping =
      linearSpringDamping?.clone() ?? Vector3.zero();

  /// Angular spring stiffness `(kx, ky, kz)` (`N*m/rad`).
  final Vector3 angularSpringStiffness =
      angularSpringStiffness?.clone() ?? Vector3.zero();

  /// Angular spring damping `(cx, cy, cz)` (`N*m*s/rad`).
  final Vector3 angularSpringDamping =
      angularSpringDamping?.clone() ?? Vector3.zero();

  /// Rest linear target `(x, y, z)` for linear springs.
  final Vector3 linearEquilibrium =
      linearEquilibrium?.clone() ?? Vector3.zero();

  /// Rest angular target `(rx, ry, rz)` for angular springs.
  final Vector3 angularEquilibrium =
      angularEquilibrium?.clone() ?? Vector3.zero();

  final Vector3 _wA = Vector3.zero();
  final Vector3 _wB = Vector3.zero();
  final Vector3 _rA = Vector3.zero();
  final Vector3 _rAEff = Vector3.zero();
  final Vector3 _rB = Vector3.zero();
  final Quaternion _qWorldA = Quaternion.identity();
  final Quaternion _qWorldB = Quaternion.identity();
  final Quaternion _qRel = Quaternion.identity();

  final List<Vector3> _linAxes = [
    Vector3.zero(),
    Vector3.zero(),
    Vector3.zero(),
  ];
  final List<_Axis1DState> _linStates = [
    _Axis1DState(),
    _Axis1DState(),
    _Axis1DState(),
  ];
  final List<_Axis1DState> _linSprings = [
    _Axis1DState(),
    _Axis1DState(),
    _Axis1DState(),
  ];

  final List<Vector3> _angAxes = [
    Vector3.zero(),
    Vector3.zero(),
    Vector3.zero(),
  ];
  final List<_Axis1DState> _angStates = [
    _Axis1DState(),
    _Axis1DState(),
    _Axis1DState(),
  ];
  final List<_Axis1DState> _angSprings = [
    _Axis1DState(),
    _Axis1DState(),
    _Axis1DState(),
  ];

  final Vector3 _scratch = Vector3.zero();
  final Vector3 _anglesScratch = Vector3.zero();

  /// Computes current linear displacement `(x, y, z)` in joint frame `A`.
  Vector3 get currentLinearOffset {
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    _quatMul(bodyA.bodyRotation, _frameA, _qWorldA);
    final diff = _wB - _wA;
    final local = Vector3.zero();
    unrotateVectorByQuat(_qWorldA, diff, local);
    return local;
  }

  /// Computes current relative rotation angles `(rx, ry, rz)` in joint frame
  /// `A`.
  Vector3 get currentAngularOffset {
    _quatMul(bodyA.bodyRotation, _frameA, _qWorldA);
    _quatMul(bodyB.bodyRotation, _frameB, _qWorldB);
    _quatMulConjA(_qWorldA, _qWorldB, _qRel);
    final out = Vector3.zero();
    _extractIntrinsicXyzAngles(_qRel, out);
    return out;
  }

  @override
  void prepare(double dt) {
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    final dx = _wB.x - _wA.x;
    final dy = _wB.y - _wA.y;
    final dz = _wB.z - _wA.z;
    _rAEff.setValues(_rA.x + dx, _rA.y + dy, _rA.z + dz);

    _quatMul(bodyA.bodyRotation, _frameA, _qWorldA);
    _quatMul(bodyB.bodyRotation, _frameB, _qWorldB);
    _quatMulConjA(_qWorldA, _qWorldB, _qRel);

    _scratch.setValues(1.0, 0.0, 0.0);
    rotateVectorByQuat(_qWorldA, _scratch, _linAxes[0]);
    _scratch.setValues(0.0, 1.0, 0.0);
    rotateVectorByQuat(_qWorldA, _scratch, _linAxes[1]);
    _scratch.setValues(0.0, 0.0, 1.0);
    rotateVectorByQuat(_qWorldA, _scratch, _linAxes[2]);

    for (var i = 0; i < 3; i++) {
      _angAxes[i].setFrom(_linAxes[i]);
    }
    _extractIntrinsicXyzAngles(_qRel, _anglesScratch);

    final invDt = dt > 1e-9 ? 1.0 / dt : 0.0;
    const beta = 0.22;

    for (var i = 0; i < 3; i++) {
      final axis = _linAxes[i];
      final pos = dx * axis.x + dy * axis.y + dz * axis.z;
      final k = computeLinearAxisK(bodyA, _rAEff, bodyB, _rB, axis, _scratch);
      _prepareAxisLimit(
        state: _linStates[i],
        value: pos,
        lower: linearLowerLimit[i],
        upper: linearUpperLimit[i],
        k: k,
        betaInvDt: beta * invDt,
      );
      _prepareAxisSpring(
        state: _linSprings[i],
        error: pos - linearEquilibrium[i],
        stiffness: linearSpringStiffness[i],
        damping: linearSpringDamping[i],
        k: k,
        dt: dt,
      );
    }

    for (var i = 0; i < 3; i++) {
      final axis = _angAxes[i];
      final ang = _anglesScratch[i];
      _sumInvInertiaMul(bodyA, bodyB, axis, _scratch);
      final k = axis.dot(_scratch);
      _prepareAxisLimit(
        state: _angStates[i],
        value: ang,
        lower: angularLowerLimit[i],
        upper: angularUpperLimit[i],
        k: k,
        betaInvDt: 0.25 * invDt,
      );
      _prepareAxisSpring(
        state: _angSprings[i],
        error: ang - angularEquilibrium[i],
        stiffness: angularSpringStiffness[i],
        damping: angularSpringDamping[i],
        k: k,
        dt: dt,
      );
    }
  }

  static void _prepareAxisLimit({
    required _Axis1DState state,
    required double value,
    required double lower,
    required double upper,
    required double k,
    required double betaInvDt,
  }) {
    state.accum = 0.0;
    state.gamma = 0.0;
    state.effMass = k > 1e-12 ? 1.0 / k : 0.0;
    if (lower > upper) {
      // Free axis (`lower > upper`).
      state.mode = 0;
      state.bias = 0.0;
      return;
    }
    if ((upper - lower).abs() < 1e-4) {
      state.mode = 2;
      state.bias = (value - lower) * betaInvDt;
    } else if (value <= lower) {
      state.mode = -1;
      state.bias = (value - lower) * betaInvDt;
    } else if (value >= upper) {
      state.mode = 1;
      state.bias = (value - upper) * betaInvDt;
    } else {
      state.mode = 0;
      state.bias = 0.0;
    }
  }

  static void _prepareAxisSpring({
    required _Axis1DState state,
    required double error,
    required double stiffness,
    required double damping,
    required double k,
    required double dt,
  }) {
    state.accum = 0.0;
    if ((stiffness <= 0.0 && damping <= 0.0) || k <= 1e-12 || dt <= 1e-9) {
      state.mode = 0;
      state.effMass = 0.0;
      state.bias = 0.0;
      state.gamma = 0.0;
      return;
    }
    final denom = dt * (damping + dt * stiffness);
    if (denom <= 1e-12) {
      state.mode = 0;
      state.effMass = 0.0;
      return;
    }
    final gamma = 1.0 / denom;
    state.mode = 2;
    state.gamma = gamma;
    state.bias = error * dt * stiffness * gamma;
    state.effMass = 1.0 / (k + gamma);
  }

  @override
  void solveVelocity(double dt) {
    // 1. Linear springs + limits.
    for (var i = 0; i < 3; i++) {
      final axis = _linAxes[i];
      final sp = _linSprings[i];
      if (sp.mode != 0 && sp.effMass > 0.0) {
        final vRel = _relVelAlongAxis(bodyA, _rAEff, bodyB, _rB, axis);
        final dImp = -sp.effMass * (vRel + sp.bias + sp.gamma * sp.accum);
        sp.accum += dImp;
        if (dImp.abs() > 1e-12) {
          _applyLinearPairImpulse(
            bodyA,
            _rAEff,
            bodyB,
            _rB,
            axis.x * dImp,
            axis.y * dImp,
            axis.z * dImp,
            _scratch,
          );
        }
      }

      final lim = _linStates[i];
      if (lim.mode != 0 && lim.effMass > 0.0) {
        final vRel = _relVelAlongAxis(bodyA, _rAEff, bodyB, _rB, axis);
        final dImp = _clampLimitDelta(lim, -lim.effMass * (vRel + lim.bias));
        if (dImp.abs() > 1e-12) {
          _applyLinearPairImpulse(
            bodyA,
            _rAEff,
            bodyB,
            _rB,
            axis.x * dImp,
            axis.y * dImp,
            axis.z * dImp,
            _scratch,
          );
        }
      }
    }

    // 2. Angular springs + limits.
    for (var i = 0; i < 3; i++) {
      final axis = _angAxes[i];
      final sp = _angSprings[i];
      if (sp.mode != 0 && sp.effMass > 0.0) {
        final dw =
            (bodyB.angularVelocity.x - bodyA.angularVelocity.x) * axis.x +
            (bodyB.angularVelocity.y - bodyA.angularVelocity.y) * axis.y +
            (bodyB.angularVelocity.z - bodyA.angularVelocity.z) * axis.z;
        final dImp = -sp.effMass * (dw + sp.bias + sp.gamma * sp.accum);
        sp.accum += dImp;
        if (dImp.abs() > 1e-12) {
          _applyAngularPairImpulse(
            bodyA,
            bodyB,
            axis.x * dImp,
            axis.y * dImp,
            axis.z * dImp,
            _scratch,
          );
        }
      }

      final lim = _angStates[i];
      if (lim.mode != 0 && lim.effMass > 0.0) {
        final dw =
            (bodyB.angularVelocity.x - bodyA.angularVelocity.x) * axis.x +
            (bodyB.angularVelocity.y - bodyA.angularVelocity.y) * axis.y +
            (bodyB.angularVelocity.z - bodyA.angularVelocity.z) * axis.z;
        final dImp = _clampLimitDelta(lim, -lim.effMass * (dw + lim.bias));
        if (dImp.abs() > 1e-12) {
          _applyAngularPairImpulse(
            bodyA,
            bodyB,
            axis.x * dImp,
            axis.y * dImp,
            axis.z * dImp,
            _scratch,
          );
        }
      }
    }
  }

  static double _clampLimitDelta(_Axis1DState lim, double rawDelta) {
    if (lim.mode == -1) {
      final prev = lim.accum;
      lim.accum = math.max(0.0, prev + rawDelta);
      return lim.accum - prev;
    }
    if (lim.mode == 1) {
      final prev = lim.accum;
      lim.accum = math.min(0.0, prev + rawDelta);
      return lim.accum - prev;
    }
    lim.accum += rawDelta;
    return rawDelta;
  }

  @override
  void solvePosition() {
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    final dx = _wB.x - _wA.x;
    final dy = _wB.y - _wA.y;
    final dz = _wB.z - _wA.z;
    _rAEff.setValues(_rA.x + dx, _rA.y + dy, _rA.z + dz);

    _quatMul(bodyA.bodyRotation, _frameA, _qWorldA);
    _scratch.setValues(1.0, 0.0, 0.0);
    rotateVectorByQuat(_qWorldA, _scratch, _linAxes[0]);
    _scratch.setValues(0.0, 1.0, 0.0);
    rotateVectorByQuat(_qWorldA, _scratch, _linAxes[1]);
    _scratch.setValues(0.0, 0.0, 1.0);
    rotateVectorByQuat(_qWorldA, _scratch, _linAxes[2]);

    for (var i = 0; i < 3; i++) {
      final lo = linearLowerLimit[i];
      final hi = linearUpperLimit[i];
      if (lo > hi) {
        continue;
      }
      final axis = _linAxes[i];
      final pos = dx * axis.x + dy * axis.y + dz * axis.z;
      var err = 0.0;
      if (pos < lo) {
        err = pos - lo;
      } else if (pos > hi) {
        err = pos - hi;
      }
      if (err.abs() > 1e-4) {
        final k = computeLinearAxisK(
          bodyA,
          _rAEff,
          bodyB,
          _rB,
          axis,
          _scratch,
        );
        if (k > 1e-12) {
          final lambda = -(err * 0.45) / k;
          _applyPositionPairImpulse(
            bodyA,
            _rAEff,
            bodyB,
            _rB,
            axis.x * lambda,
            axis.y * lambda,
            axis.z * lambda,
            _scratch,
          );
        }
      }
    }

    _quatMul(bodyA.bodyRotation, _frameA, _qWorldA);
    _quatMul(bodyB.bodyRotation, _frameB, _qWorldB);
    _quatMulConjA(_qWorldA, _qWorldB, _qRel);
    _extractIntrinsicXyzAngles(_qRel, _anglesScratch);

    for (var i = 0; i < 3; i++) {
      final lo = angularLowerLimit[i];
      final hi = angularUpperLimit[i];
      if (lo > hi) {
        continue;
      }
      final ang = _anglesScratch[i];
      var err = 0.0;
      if (ang < lo) {
        err = ang - lo;
      } else if (ang > hi) {
        err = ang - hi;
      }
      if (err.abs() > 1e-4) {
        final axis = _linAxes[i];
        _sumInvInertiaMul(bodyA, bodyB, axis, _scratch);
        final k = axis.dot(_scratch);
        if (k > 1e-12) {
          final tau = -(err * 0.45) / k;
          _applyAngularPositionPairImpulse(
            bodyA,
            bodyB,
            axis.x * tau,
            axis.y * tau,
            axis.z * tau,
            _scratch,
          );
        }
      }
    }
  }
}

class _Axis1DState() {
  int mode = 0;
  double effMass = 0.0;
  double bias = 0.0;
  double gamma = 0.0;
  double accum = 0.0;
}
