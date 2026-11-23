part of 'joints_3d.dart';

/// Fixed-rod or spring-damper 1-DOF distance constraint between `localAnchorA`
/// on [bodyA] and `localAnchorB` on [bodyB].
class DistanceJoint3D({
  required super.bodyA,
  required super.bodyB,
  Vector3? localAnchorA,
  Vector3? localAnchorB,
  double? length,
  var double frequencyHz = 0.0,
  var double dampingRatio = 0.7,
  super.collideConnected,
}) extends Joint3D {
  this {
    if (length != null) {
      this.length = math.max(0.0, length);
    } else {
      final rotA = Vector3.zero();
      final rotB = Vector3.zero();
      rotateVectorByQuat(bodyA.bodyRotation, this.localAnchorA, rotA);
      rotateVectorByQuat(bodyB.bodyRotation, this.localAnchorB, rotB);
      final pA = bodyA.bodyPosition + rotA;
      final pB = bodyB.bodyPosition + rotB;
      this.length = pA.distanceTo(pB);
    }
  }

  /// Anchor point in [bodyA]'s local space.
  final Vector3 localAnchorA = localAnchorA?.clone() ?? Vector3.zero();

  /// Anchor point in [bodyB]'s local space.
  final Vector3 localAnchorB = localAnchorB?.clone() ?? Vector3.zero();

  /// Target rest length in world units.
  late double length;

  final Vector3 _rA = Vector3.zero();
  final Vector3 _rB = Vector3.zero();
  final Vector3 _wA = Vector3.zero();
  final Vector3 _wB = Vector3.zero();
  final Vector3 _u = Vector3.zero();
  final Vector3 _scratch = Vector3.zero();
  double _effMass = 0.0;
  double _bias = 0.0;
  double _gamma = 0.0;
  double _accumImpulse = 0.0;

  @override
  void prepare(double dt) {
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);

    final dx = _wB.x - _wA.x;
    final dy = _wB.y - _wA.y;
    final dz = _wB.z - _wA.z;
    final curLen = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (curLen > 1e-7) {
      _u.setValues(dx / curLen, dy / curLen, dz / curLen);
    } else {
      _u.setValues(0.0, 1.0, 0.0);
    }

    final k = computeLinearAxisK(bodyA, _rA, bodyB, _rB, _u, _scratch);
    final rawMass = k > 1e-12 ? 1.0 / k : 0.0;
    final c = curLen - length;

    if (frequencyHz > 0.0 && rawMass > 0.0 && dt > 0.0) {
      final omega = 2.0 * math.pi * frequencyHz;
      final d = 2.0 * rawMass * dampingRatio * omega;
      final springK = rawMass * omega * omega;
      final h = dt;
      _gamma = h * (d + h * springK);
      _gamma = _gamma > 1e-12 ? 1.0 / _gamma : 0.0;
      _bias = c * h * springK * _gamma;
      final invEff = k + _gamma;
      _effMass = invEff > 1e-12 ? 1.0 / invEff : 0.0;
    } else {
      _gamma = 0.0;
      _bias = 0.0;
      _effMass = rawMass;
    }
    _accumImpulse = 0.0;
  }

  @override
  void solveVelocity(double dt) {
    if (_effMass <= 0.0) {
      return;
    }
    final vRel = _relVelAlongAxis(bodyA, _rA, bodyB, _rB, _u);
    final impulse = -_effMass * (vRel + _bias + _gamma * _accumImpulse);
    _accumImpulse += impulse;
    _applyLinearPairImpulse(
      bodyA,
      _rA,
      bodyB,
      _rB,
      _u.x * impulse,
      _u.y * impulse,
      _u.z * impulse,
      _scratch,
    );
  }

  @override
  void solvePosition() {
    if (frequencyHz > 0.0) {
      return;
    }
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    final dx = _wB.x - _wA.x;
    final dy = _wB.y - _wA.y;
    final dz = _wB.z - _wA.z;
    final curLen = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (curLen <= 1e-7) {
      return;
    }
    _u.setValues(dx / curLen, dy / curLen, dz / curLen);
    final err = (curLen - length) * 0.5;
    if (err.abs() <= 1e-5) {
      return;
    }
    final k = computeLinearAxisK(bodyA, _rA, bodyB, _rB, _u, _scratch);
    if (k <= 1e-12) {
      return;
    }
    final lambda = -err / k;
    _applyPositionPairImpulse(
      bodyA,
      _rA,
      bodyB,
      _rB,
      _u.x * lambda,
      _u.y * lambda,
      _u.z * lambda,
      _scratch,
    );
  }
}

/// 3-DOF point-to-point (spherical / ball-and-socket) joint locking
/// [localAnchorA] on [bodyA] to [localAnchorB] on [bodyB].
class BallSocketJoint3D({
  required super.bodyA,
  required super.bodyB,
  Vector3? localAnchorA,
  Vector3? localAnchorB,
  super.collideConnected,
}) extends Joint3D {
  /// Anchor point in [bodyA]'s local space.
  final Vector3 localAnchorA = localAnchorA?.clone() ?? Vector3.zero();

  /// Anchor point in [bodyB]'s local space.
  final Vector3 localAnchorB = localAnchorB?.clone() ?? Vector3.zero();

  final Vector3 _rA = Vector3.zero();
  final Vector3 _rB = Vector3.zero();
  final Vector3 _wA = Vector3.zero();
  final Vector3 _wB = Vector3.zero();
  final Matrix3 _effMass3 = Matrix3.zero();
  final Vector3 _bias = Vector3.zero();
  final Vector3 _rhs = Vector3.zero();
  final Vector3 _imp = Vector3.zero();
  final Vector3 _scratch = Vector3.zero();

  @override
  void prepare(double dt) {
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    _buildPointToPointInvK(bodyA, _rA, bodyB, _rB, _effMass3);

    if (dt > 1e-9) {
      const beta = 0.2;
      final scale = beta / dt;
      _bias.setValues(
        (_wB.x - _wA.x) * scale,
        (_wB.y - _wA.y) * scale,
        (_wB.z - _wA.z) * scale,
      );
    } else {
      _bias.setZero();
    }
  }

  @override
  void solveVelocity(double dt) {
    _relVel3(bodyA, _rA, bodyB, _rB, _rhs);
    _rhs.add(_bias);
    _mulMat3Neg(_effMass3, _rhs, _imp);
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
  }

  @override
  void solvePosition() {
    _computeWorldAnchorAndLever(bodyA, localAnchorA, _wA, _rA);
    _computeWorldAnchorAndLever(bodyB, localAnchorB, _wB, _rB);
    final ex = _wB.x - _wA.x;
    final ey = _wB.y - _wA.y;
    final ez = _wB.z - _wA.z;
    if (ex * ex + ey * ey + ez * ez <= 1e-9) {
      return;
    }
    _buildPointToPointInvK(bodyA, _rA, bodyB, _rB, _effMass3);
    _rhs.setValues(ex * 0.4, ey * 0.4, ez * 0.4);
    _mulMat3Neg(_effMass3, _rhs, _imp);
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
}
