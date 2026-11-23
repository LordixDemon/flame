part of 'physics_world_3d.dart';

class _ContactConstraint3D() {
  late RigidBody3D bodyA;
  late RigidBody3D bodyB;
  int manifoldIndex = 0;
  final Vector3 normal = Vector3.zero();
  final Vector3 t1 = Vector3.zero();
  final Vector3 t2 = Vector3.zero();
  double restitution = 0.0;
  double friction = 0.0;
  double restitutionThreshold = 0.5;

  // Whether each body takes impulses (dynamic and awake), and its inverse
  // mass as seen by this contact: a sleeping or static partner counts as
  // infinitely heavy, consistently in effective masses and impulses.
  bool useA = false;
  bool useB = false;
  double imA = 0.0;
  double imB = 0.0;

  final List<_ContactPointState> _points = [];
  int pointCount = 0;

  // Impulses at the end of the previous step, per point: feature id, then
  // `jn, jtx, jty, jtz` and the point's offset on body A in A's frame.
  static const int historyStride = 7;
  Int32List prevIds = Int32List(4);
  Float64List prevImpulses = Float64List(4 * historyStride);
  int prevCount = 0;

  /// Distance within which a point without a matching feature id takes over
  /// the impulse of the nearest unmatched point of the previous step.
  double matchDistance = 0.008;

  static final _ContactConstraintScratch _scratch = _ContactConstraintScratch();

  void clearHistory() {
    prevCount = 0;
  }

  void appendHistory(int id, Float64List values, int offset) {
    _ensureHistory(prevCount + 1);
    prevIds[prevCount] = id;
    prevImpulses.setRange(
      prevCount * historyStride,
      (prevCount + 1) * historyStride,
      values,
      offset,
    );
    prevCount++;
  }

  void _ensureHistory(int count) {
    if (prevIds.length < count) {
      final cap = count * 2;
      prevIds = Int32List(cap)..setRange(0, prevCount, prevIds);
      prevImpulses = Float64List(cap * historyStride)
        ..setRange(0, prevCount * historyStride, prevImpulses);
    }
  }

  void loadFromBuffer(
    RigidBody3D a,
    RigidBody3D b,
    MutableManifoldBuffer3D buf,
    int mIdx,
    double threshold,
    double matchDist,
  ) {
    matchDistance = matchDist;
    _begin(
      a,
      b,
      mIdx,
      threshold,
      buf.normalX(mIdx),
      buf.normalY(mIdx),
      buf.normalZ(mIdx),
    );
    final start = buf.contactStart(mIdx);
    final end = start + buf.contactLength(mIdx);
    for (var c = start; c < end; c++) {
      _addPoint(
        buf.pointAX(c),
        buf.pointAY(c),
        buf.pointAZ(c),
        buf.pointBX(c),
        buf.pointBY(c),
        buf.pointBZ(c),
        buf.pointDepth(c),
        buf.featureId(c),
      );
    }
    _matchHistory();
  }

  void load(
    RigidBody3D a,
    RigidBody3D b,
    CollisionManifold3D manifold,
    int mIdx,
    double threshold,
    double matchDist,
  ) {
    matchDistance = matchDist;
    final n = manifold.normal;
    _begin(a, b, mIdx, threshold, n.x, n.y, n.z);
    final contacts = manifold.contacts;
    for (var i = 0; i < contacts.length; i++) {
      final cp = contacts[i];
      final pa = cp.pointA;
      final pb = cp.pointB;
      _addPoint(
        pa.x,
        pa.y,
        pa.z,
        pb.x,
        pb.y,
        pb.z,
        cp.penetrationDepth,
        cp.featureId,
      );
    }
    _matchHistory();
  }

  void loadSinglePoint(
    RigidBody3D a,
    RigidBody3D b,
    double nx,
    double ny,
    double nz,
    double px,
    double py,
    double pz,
    double depth,
    double threshold,
  ) {
    _begin(a, b, 0, threshold, nx, ny, nz);
    prevCount = 0;
    _addPoint(px, py, pz, px, py, pz, depth, 0);
  }

  void _begin(
    RigidBody3D a,
    RigidBody3D b,
    int mIdx,
    double threshold,
    double nx,
    double ny,
    double nz,
  ) {
    bodyA = a;
    bodyB = b;
    manifoldIndex = mIdx;
    restitutionThreshold = threshold;
    normal.setValues(nx, ny, nz);
    buildOrthonormalBasis3D(normal, t1, t2);
    restitution = _resolveRestitution(a, b);
    friction = _resolveFriction(a, b);
    useA =
        a.bodyType == BodyType3D.dynamic &&
        !a.isSleeping &&
        a.inverseMass > 0.0;
    useB =
        b.bodyType == BodyType3D.dynamic &&
        !b.isSleeping &&
        b.inverseMass > 0.0;
    imA = useA ? a.inverseMass : 0.0;
    imB = useB ? b.inverseMass : 0.0;
    pointCount = 0;
  }

  void _addPoint(
    double pax,
    double pay,
    double paz,
    double pbx,
    double pby,
    double pbz,
    double depth,
    int featureId,
  ) {
    if (_points.length <= pointCount) {
      _points.add(_ContactPointState());
    }
    final p = _points[pointCount++];
    final posA = bodyA.bodyPosition;
    final posB = bodyB.bodyPosition;
    final comA = bodyA.worldCenterOfMass;
    p.rA.setValues(pax - comA.x, pay - comA.y, paz - comA.z);
    final comB = bodyB.worldCenterOfMass;
    p.rB.setValues(pbx - comB.x, pby - comB.y, pbz - comB.z);
    _scratch.offA.setValues(pax - posA.x, pay - posA.y, paz - posA.z);
    _scratch.offB.setValues(pbx - posB.x, pby - posB.y, pbz - posB.z);
    unrotateVectorByQuat(bodyA.bodyRotation, _scratch.offA, p.localOffsetA);
    unrotateVectorByQuat(bodyB.bodyRotation, _scratch.offB, p.localOffsetB);
    p
      ..depth = depth
      ..separation =
          (pbx - pax) * normal.x +
          (pby - pay) * normal.y +
          (pbz - paz) * normal.z
      ..featureId = featureId
      ..hasWarm = false
      ..jn = 0.0
      ..jt1 = 0.0
      ..jt2 = 0.0;
  }

  /// Gives each point last step's impulse of the point with the same feature
  /// id; then each point still without one takes the impulse of the nearest
  /// remaining point of the previous step within [matchDistance] (on body A).
  /// Each previous point is used once.
  void _matchHistory() {
    if (prevCount == 0) {
      return;
    }
    var consumed = 0;
    for (var i = 0; i < pointCount; i++) {
      final p = _points[i];
      for (var k = 0; k < prevCount && k < 30; k++) {
        if ((consumed & (1 << k)) == 0 && prevIds[k] == p.featureId) {
          _takeHistory(p, k);
          consumed |= 1 << k;
          break;
        }
      }
    }
    final maxD2 = matchDistance * matchDistance;
    for (var i = 0; i < pointCount; i++) {
      final p = _points[i];
      if (p.hasWarm) {
        continue;
      }
      var match = -1;
      var bestD2 = maxD2;
      final la = p.localOffsetA;
      for (var k = 0; k < prevCount && k < 30; k++) {
        if ((consumed & (1 << k)) != 0) {
          continue;
        }
        final o = k * historyStride;
        final dx = prevImpulses[o + 4] - la.x;
        final dy = prevImpulses[o + 5] - la.y;
        final dz = prevImpulses[o + 6] - la.z;
        final d2 = dx * dx + dy * dy + dz * dz;
        if (d2 < bestD2) {
          bestD2 = d2;
          match = k;
        }
      }
      if (match >= 0) {
        _takeHistory(p, match);
        consumed |= 1 << match;
      }
    }
  }

  void _takeHistory(_ContactPointState p, int k) {
    final o = k * historyStride;
    p
      ..hasWarm = true
      ..warmJn = prevImpulses[o]
      ..warmJtx = prevImpulses[o + 1]
      ..warmJty = prevImpulses[o + 2]
      ..warmJtz = prevImpulses[o + 3];
  }

  static double _resolveRestitution(RigidBody3D a, RigidBody3D b) {
    final mA = a.material;
    final mB = b.material;
    if (mA == null && mB == null) {
      return math.max(a.restitution, b.restitution);
    }
    final modeA = mA?.restitutionCombine ?? PhysicsCombineMode3D.maximum;
    final modeB = mB?.restitutionCombine ?? PhysicsCombineMode3D.maximum;
    final mode = modeA.index >= modeB.index ? modeA : modeB;
    return mode
        .combine(
          mA?.restitution ?? a.restitution,
          mB?.restitution ?? b.restitution,
        )
        .clamp(0.0, 1.0);
  }

  static double _resolveFriction(RigidBody3D a, RigidBody3D b) {
    final mA = a.material;
    final mB = b.material;
    if (mA == null && mB == null) {
      return math.sqrt(math.max(0.0, a.friction * b.friction));
    }
    final modeA = mA?.frictionCombine ?? PhysicsCombineMode3D.average;
    final modeB = mB?.frictionCombine ?? PhysicsCombineMode3D.average;
    final mode = modeA.index >= modeB.index ? modeA : modeB;
    return math.max(
      0.0,
      mode.combine(mA?.friction ?? a.friction, mB?.friction ?? b.friction),
    );
  }

  void prepare(Vector3 scratch, double dt, {required bool warmStart}) {
    final invDt = dt > 0.0 ? 1.0 / dt : 0.0;
    for (var i = 0; i < pointCount; i++) {
      final p = _points[i];
      p.effMassN = _axisMass(p.rA, p.rB, normal, scratch);
      p.effMassT1 = _axisMass(p.rA, p.rB, t1, scratch);
      p.effMassT2 = _axisMass(p.rA, p.rB, t2, scratch);

      // Measure pre-impact normal velocity BEFORE warm-starting!
      final vnPre = _relVelDot(p.rA, p.rB, normal);
      if (p.separation > 0.0) {
        // Speculative point: it may close its gap during this step, no more.
        p.bounceTargetVn = -p.separation * invDt;
        if (warmStart && p.hasWarm && p.warmJn > 0.0) {
          _applyWarm(p, scratch);
        } else {
          p
            ..jn = 0.0
            ..jt1 = 0.0
            ..jt2 = 0.0;
        }
        continue;
      }
      if (vnPre < -restitutionThreshold && restitution > 0.0) {
        p
          ..bounceTargetVn = -restitution * vnPre
          ..jn = 0.0
          ..jt1 = 0.0
          ..jt2 = 0.0;
        continue;
      }
      p.bounceTargetVn = 0.0;
      // Warm-start resting contacts only so bounces stay exact.
      if (warmStart && p.hasWarm) {
        _applyWarm(p, scratch);
      } else {
        p
          ..jn = 0.0
          ..jt1 = 0.0
          ..jt2 = 0.0;
      }
    }
  }

  void _applyWarm(_ContactPointState p, Vector3 scratch) {
    p
      ..jn = p.warmJn
      ..jt1 = p.warmJtx * t1.x + p.warmJty * t1.y + p.warmJtz * t1.z
      ..jt2 = p.warmJtx * t2.x + p.warmJty * t2.y + p.warmJtz * t2.z;
    final ix = normal.x * p.jn + t1.x * p.jt1 + t2.x * p.jt2;
    final iy = normal.y * p.jn + t1.y * p.jt1 + t2.y * p.jt2;
    final iz = normal.z * p.jn + t1.z * p.jt1 + t2.z * p.jt2;
    _applyImpulse(p.rA, p.rB, ix, iy, iz, scratch);
  }

  void solveVelocity(Vector3 scratch) {
    // Friction first, within the cone of the current normal impulses, then
    // the normal impulses, so non-penetration has the last word.
    if (friction > 0.0) {
      for (var i = 0; i < pointCount; i++) {
        final p = _points[i];
        if (p.jn <= 0.0) {
          continue;
        }
        final vt1 = _relVelDot(p.rA, p.rB, t1);
        final vt2 = _relVelDot(p.rA, p.rB, t2);
        final candT1 = p.jt1 - p.effMassT1 * vt1;
        final candT2 = p.jt2 - p.effMassT2 * vt2;
        final maxFriction = friction * p.jn;
        final mag2 = candT1 * candT1 + candT2 * candT2;

        double nextT1;
        double nextT2;
        if (mag2 > maxFriction * maxFriction && mag2 > 1e-24) {
          final scale = maxFriction / math.sqrt(mag2);
          nextT1 = candT1 * scale;
          nextT2 = candT2 * scale;
        } else {
          nextT1 = candT1;
          nextT2 = candT2;
        }

        final dJt1 = nextT1 - p.jt1;
        final dJt2 = nextT2 - p.jt2;
        p.jt1 = nextT1;
        p.jt2 = nextT2;
        if (dJt1.abs() > 1e-14 || dJt2.abs() > 1e-14) {
          _applyImpulse(
            p.rA,
            p.rB,
            t1.x * dJt1 + t2.x * dJt2,
            t1.y * dJt1 + t2.y * dJt2,
            t1.z * dJt1 + t2.z * dJt2,
            scratch,
          );
        }
      }
    }

    for (var i = 0; i < pointCount; i++) {
      final p = _points[i];
      final vn = _relVelDot(p.rA, p.rB, normal);
      var dJn = p.effMassN * (p.bounceTargetVn - vn);
      final prevJn = p.jn;
      p.jn = math.max(0.0, prevJn + dJn);
      dJn = p.jn - prevJn;
      if (dJn.abs() > 1e-14) {
        _applyImpulse(
          p.rA,
          p.rB,
          normal.x * dJn,
          normal.y * dJn,
          normal.z * dJn,
          scratch,
        );
      }
    }
  }

  void solvePosition(double slop) {
    if (!useA && !useB) {
      return;
    }
    final baumgarte = 0.25 / math.max(1, pointCount);
    final offA = _scratch.offA;
    final offB = _scratch.offB;
    final rA = _scratch.posRA;
    final rB = _scratch.posRB;
    final scratch = _scratch.posScratch;

    for (var i = 0; i < pointCount; i++) {
      final p = _points[i];
      rotateVectorByQuat(bodyA.bodyRotation, p.localOffsetA, offA);
      rotateVectorByQuat(bodyB.bodyRotation, p.localOffsetB, offB);
      final wAx = bodyA.bodyPosition.x + offA.x;
      final wAy = bodyA.bodyPosition.y + offA.y;
      final wAz = bodyA.bodyPosition.z + offA.z;
      final wBx = bodyB.bodyPosition.x + offB.x;
      final wBy = bodyB.bodyPosition.y + offB.y;
      final wBz = bodyB.bodyPosition.z + offB.z;

      // Current penetration along `normal` (`(wA - wB) . normal > 0`).
      final pen =
          (wAx - wBx) * normal.x +
          (wAy - wBy) * normal.y +
          (wAz - wBz) * normal.z;
      final corr = math.min(0.15, math.max(0.0, pen - slop) * baumgarte);
      if (corr <= 1e-7) {
        continue;
      }

      final comA = bodyA.worldCenterOfMass;
      rA.setValues(wAx - comA.x, wAy - comA.y, wAz - comA.z);
      final comB = bodyB.worldCenterOfMass;
      rB.setValues(wBx - comB.x, wBy - comB.y, wBz - comB.z);

      final massN = _axisMass(rA, rB, normal, scratch);
      if (massN <= 0.0) {
        continue;
      }
      final pImpulse = massN * corr;
      final px = normal.x * pImpulse;
      final py = normal.y * pImpulse;
      final pz = normal.z * pImpulse;

      applyPositionPairImpulseWithInvMass(
        bodyA,
        imA,
        rA,
        bodyB,
        imB,
        rB,
        px,
        py,
        pz,
        scratch,
      );
    }
  }

  void saveWarmImpulses() {
    prevCount = 0;
    _ensureHistory(pointCount);
    for (var i = 0; i < pointCount; i++) {
      final p = _points[i];
      prevIds[i] = p.featureId;
      final o = i * historyStride;
      prevImpulses[o] = p.jn;
      prevImpulses[o + 1] = t1.x * p.jt1 + t2.x * p.jt2;
      prevImpulses[o + 2] = t1.y * p.jt1 + t2.y * p.jt2;
      prevImpulses[o + 3] = t1.z * p.jt1 + t2.z * p.jt2;
      prevImpulses[o + 4] = p.localOffsetA.x;
      prevImpulses[o + 5] = p.localOffsetA.y;
      prevImpulses[o + 6] = p.localOffsetA.z;
    }
    prevCount = pointCount;
  }

  double _axisMass(Vector3 rA, Vector3 rB, Vector3 axis, Vector3 scratch) {
    final k = computeLinearAxisKWithInvMass(
      bodyA,
      imA,
      rA,
      bodyB,
      imB,
      rB,
      axis,
      scratch,
    );
    return k > 1e-12 ? 1.0 / k : 0.0;
  }

  double _relVelDot(Vector3 rA, Vector3 rB, Vector3 axis) =>
      relativeVelocityAlongAxis(bodyA, rA, bodyB, rB, axis);

  void _applyImpulse(
    Vector3 rA,
    Vector3 rB,
    double px,
    double py,
    double pz,
    Vector3 scratch,
  ) => applyLinearPairImpulseWithInvMass(
    bodyA,
    imA,
    rA,
    bodyB,
    imB,
    rB,
    px,
    py,
    pz,
    scratch,
  );
}

class _ContactConstraintScratch() {
  final Vector3 offA = Vector3.zero();
  final Vector3 offB = Vector3.zero();
  final Vector3 posRA = Vector3.zero();
  final Vector3 posRB = Vector3.zero();
  final Vector3 posScratch = Vector3.zero();
}
