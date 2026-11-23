part of 'physics_world_3d.dart';

extension _PhysicsWorldContactSolver3D on PhysicsWorld3D {
  void _buildContactConstraints(CollisionSystem3D? colSys) {
    _constraints.clear();
    final wakeVelThresh2 =
        (sleepLinearThreshold * 2.0) * (sleepLinearThreshold * 2.0);

    // Track which bodies already initiated their broadphase query:
    // 0 = initially inactive (may become active if woken), 1 = active pending,
    // 2 = already queried (skip in reverse checks to test each pair once).
    for (var i = 0; i < _activeBodies.length; i++) {
      final b = _activeBodies[i];
      b.solverIndex = PhysicsWorld3D._isInactive(b) ? 0 : 1;
    }

    for (var i = 0; i < _activeBodies.length; i++) {
      final bodyA = _activeBodies[i];
      if (PhysicsWorld3D._isInactive(bodyA)) {
        continue;
      }
      bodyA.solverIndex = 2;
      _queryBody = bodyA;
      _pairCandidates.clear();
      broadphaseTree.queryAabbCallback(bodyA.cachedWorldAabb, _onBodyCandidate);
      if (_pairCandidates.length > 1) {
        _pairCandidates.sort(PhysicsWorld3D._compareIds);
      }

      for (var j = 0; j < _pairCandidates.length; j++) {
        final bodyB = _pairCandidates[j];
        final first = bodyA.deterministicId < bodyB.deterministicId
            ? bodyA
            : bodyB;
        final second = identical(first, bodyA) ? bodyB : bodyA;
        _manifoldBuffer.clear();
        Narrowphase3D.testAllInto(
          first.shape,
          first.bodyWorldMatrix,
          second.shape,
          second.bodyWorldMatrix,
          _manifoldBuffer,
        );
        if (_manifoldBuffer.isEmpty) {
          continue;
        }
        _wakeOnContactBuffer(first, second, _manifoldBuffer, wakeVelThresh2);
        _addPairConstraintsFromBuffer(first, second, _manifoldBuffer);
      }

      // Static colliders hold up awake dynamic bodies.
      if (colSys != null &&
          bodyA.bodyType == BodyType3D.dynamic &&
          !bodyA.isSleeping) {
        _colliderCandidates.clear();
        colSys.broadphaseTree.queryAabbCallback(
          bodyA.cachedWorldAabb,
          _onColliderCandidate,
        );
        if (_colliderCandidates.length > 1) {
          _colliderCandidates.sort(_colliderComparator);
        }
        for (var k = 0; k < _colliderCandidates.length; k++) {
          final collider = _colliderCandidates[k];
          _manifoldBuffer.clear();
          Narrowphase3D.testAllInto(
            bodyA.shape,
            bodyA.bodyWorldMatrix,
            collider.shape,
            collider.colliderWorldMatrix,
            _manifoldBuffer,
          );
          if (_manifoldBuffer.isEmpty) {
            continue;
          }
          _addPairConstraintsFromBuffer(
            bodyA,
            _colliderProxy(collider),
            _manifoldBuffer,
          );
        }
      }
    }
    for (var i = 0; i < _activeBodies.length; i++) {
      _activeBodies[i].solverIndex = -1;
    }
    _queryBody = null;
    _sweepStalePairs();
  }

  void _wakeOnContactBuffer(
    RigidBody3D bodyA,
    RigidBody3D bodyB,
    MutableManifoldBuffer3D buffer,
    double wakeVelThresh2,
  ) {
    final aSleeping = bodyA.bodyType == BodyType3D.dynamic && bodyA.isSleeping;
    final bSleeping = bodyB.bodyType == BodyType3D.dynamic && bodyB.isSleeping;
    if (aSleeping == bSleeping) {
      return;
    }
    final sleeper = aSleeping ? bodyA : bodyB;
    final other = aSleeping ? bodyB : bodyA;
    if (other.bodyType == BodyType3D.kinematic) {
      // A moving kinematic body pushes whatever it touches.
      sleeper.wakeUp();
      return;
    }
    if (other.bodyType != BodyType3D.dynamic) {
      return;
    }
    final deepest = buffer.maxPenetrationDepth;
    final dvx = bodyB.linearVelocity.x - bodyA.linearVelocity.x;
    final dvy = bodyB.linearVelocity.y - bodyA.linearVelocity.y;
    final dvz = bodyB.linearVelocity.z - bodyA.linearVelocity.z;
    // A partner that is moving (its sleep timer was reset, or it was just
    // woken) wakes the sleeper, so a touching group wakes as a whole.
    if (other.sleepTimer == 0.0 ||
        dvx * dvx + dvy * dvy + dvz * dvz > wakeVelThresh2 ||
        deepest > 0.01) {
      bodyA.wakeUp();
      bodyB.wakeUp();
    }
  }

  void _addPairConstraintsFromBuffer(
    RigidBody3D bodyA,
    RigidBody3D bodyB,
    MutableManifoldBuffer3D buffer,
  ) {
    final pair = _acquirePair(bodyA, bodyB)..lastTick = _tick;
    final count = buffer.manifoldCount;
    final matchDist = math.max(0.002, 2.0 * linearSlop);
    for (var m = 0; m < count; m++) {
      final c = pair.constraintAt(m)
        ..loadFromBuffer(
          bodyA,
          bodyB,
          buffer,
          m,
          restitutionVelocityThreshold,
          matchDist,
        );
      _constraints.add(c);
    }
    pair.manifoldCount = count;
  }

  _ContactPair3D _acquirePair(RigidBody3D bodyA, RigidBody3D bodyB) {
    var list = _pairsByBodyA[bodyA];
    if (list != null) {
      for (var i = 0; i < list.length; i++) {
        if (identical(list[i].bodyB, bodyB)) {
          return list[i];
        }
      }
    } else {
      list = _pairsByBodyA[bodyA] = <_ContactPair3D>[];
    }
    final pair = _pairPool.isNotEmpty
        ? _pairPool.removeLast()
        : _ContactPair3D();
    pair.reset(bodyA, bodyB);
    list.add(pair);
    _pairList.add(pair);
    return pair;
  }

  void _sweepStalePairs() {
    final tick = _tick;
    var write = 0;
    for (var i = 0; i < _pairList.length; i++) {
      final pair = _pairList[i];
      if (pair.lastTick == tick) {
        _pairList[write++] = pair;
        continue;
      }
      final list = _pairsByBodyA[pair.bodyA];
      if (list != null) {
        list.remove(pair);
        if (list.isEmpty) {
          _pairsByBodyA.remove(pair.bodyA);
        }
      }
      _pairPool.add(pair);
    }
    _pairList.length = write;
  }
}

/// Persistent contact state between two bodies (one constraint per manifold),
/// kept while they touch so impulses carry over to the next step.
class _ContactPair3D() {
  late RigidBody3D bodyA;
  late RigidBody3D bodyB;
  int lastTick = -1;
  int manifoldCount = 0;
  final List<_ContactConstraint3D> _manifolds = [];

  void reset(RigidBody3D a, RigidBody3D b) {
    bodyA = a;
    bodyB = b;
    lastTick = -1;
    manifoldCount = 0;
    for (var i = 0; i < _manifolds.length; i++) {
      _manifolds[i].clearHistory();
    }
  }

  _ContactConstraint3D constraintAt(int index) {
    while (_manifolds.length <= index) {
      _manifolds.add(_ContactConstraint3D());
    }
    final c = _manifolds[index];
    if (index >= manifoldCount) {
      // A manifold slot unused last step carries no history.
      c.clearHistory();
    }
    return c;
  }
}

class _ContactPointState() {
  final Vector3 localOffsetA = Vector3.zero();
  final Vector3 localOffsetB = Vector3.zero();
  final Vector3 rA = Vector3.zero();
  final Vector3 rB = Vector3.zero();
  double depth = 0.0;
  // Gap along the normal at creation (`> 0`: apart, a speculative point).
  double separation = 0.0;
  int featureId = 0;

  double effMassN = 0.0;
  double effMassT1 = 0.0;
  double effMassT2 = 0.0;
  double bounceTargetVn = 0.0;

  double jn = 0.0;
  double jt1 = 0.0;
  double jt2 = 0.0;

  // Last step's impulse of the point with the same feature id, if any.
  bool hasWarm = false;
  double warmJn = 0.0;
  double warmJtx = 0.0;
  double warmJty = 0.0;
  double warmJtz = 0.0;
}
