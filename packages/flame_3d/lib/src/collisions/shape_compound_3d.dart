part of 'shapes_3d.dart';

/// Child shape entry inside a [CompoundShape3D] with its local [position],
/// [rotation], and optional relative [massWeight].
class CompoundChildShape3D({
  required final CollisionShape3D shape,
  Vector3? position,
  Quaternion? rotation,
  final double massWeight = 1.0,
}) {
  this : assert(massWeight >= 0, 'massWeight must be non-negative') {
    if (this.rotation.length2 > 1e-12) {
      this.rotation.normalize();
    } else {
      this.rotation.setValues(0.0, 0.0, 0.0, 1.0);
    }
    localTransform.setFromTranslationRotationScale(
      this.position,
      this.rotation,
      _unitScaleVec,
    );
    shape.computeWorldAabb(localTransform, localAabb);
  }

  /// Local translation of [shape] inside the parent [CompoundShape3D].
  final Vector3 position = position?.clone() ?? Vector3.zero();

  /// Local rotation of [shape] inside the parent [CompoundShape3D].
  final Quaternion rotation = rotation?.clone() ?? Quaternion.identity();

  /// Precomputed `4x4` local transform combining [position] and [rotation].
  final Matrix4 localTransform = Matrix4.identity();

  /// Precomputed local-space AABB of this child inside the compound frame.
  final Aabb3 localAabb = Aabb3();

  static final Vector3 _unitScaleVec = Vector3.all(1.0);
}

/// Composite 3D collision shape formed from one or more [CompoundChildShape3D]
/// sub-shapes, supporting concave rigid bodies with exact composite AABB,
/// raycasting, narrowphase contact generation, and Huygens–Steiner
/// parallel-axis center-of-mass and inertia tensor calculation.
class CompoundShape3D(List<CompoundChildShape3D> children) extends Shape3D {
  this : assert(children.isNotEmpty, 'CompoundShape3D requires >= 1 child') {
    _localAabb
      ..min.setFrom(this.children.first.localAabb.min)
      ..max.setFrom(this.children.first.localAabb.max);
    for (var i = 1; i < this.children.length; i++) {
      _localAabb.hull(this.children[i].localAabb);
    }

    var totalW = 0.0;
    var sumVolume = 0.0;
    final rotCom = Vector3.zero();
    for (var i = 0; i < this.children.length; i++) {
      final c = this.children[i];
      final vol = math.max(1e-6, c.shape.estimateLocalVolume());
      sumVolume += vol;
      final w = vol * c.massWeight;
      _childWeights[i] = w;
      totalW += w;

      // `localTransform` rotates like `asRotationMatrix()`; vector_math's
      // `Quaternion.rotate` would apply the inverse rotation.
      c.localTransform.rotate3(rotCom..setFrom(c.shape.localCenterOfMass));
      final cx = c.position.x + rotCom.x;
      final cy = c.position.y + rotCom.y;
      final cz = c.position.z + rotCom.z;
      _childComCoords[i * 3] = cx;
      _childComCoords[i * 3 + 1] = cy;
      _childComCoords[i * 3 + 2] = cz;
    }

    _totalVolume = sumVolume;
    if (totalW > 1e-12) {
      var comX = 0.0;
      var comY = 0.0;
      var comZ = 0.0;
      for (var i = 0; i < this.children.length; i++) {
        final frac = _childWeights[i] / totalW;
        _childWeights[i] = frac;
        comX += frac * _childComCoords[i * 3];
        comY += frac * _childComCoords[i * 3 + 1];
        comZ += frac * _childComCoords[i * 3 + 2];
      }
      _centerOfMass.setValues(comX, comY, comZ);
    } else {
      final frac = 1.0 / this.children.length;
      for (var i = 0; i < this.children.length; i++) {
        _childWeights[i] = frac;
      }
      _centerOfMass.setZero();
    }
  }

  /// Immutable list of child shapes in local space.
  final List<CompoundChildShape3D> children = List.unmodifiable(children);

  final Aabb3 _localAabb = Aabb3();
  final Vector3 _centerOfMass = Vector3.zero();
  final Float64List _childWeights = Float64List(children.length);
  final Float64List _childComCoords = Float64List(children.length * 3);
  double _totalVolume = 0.0;

  /// Volume-weighted composite center-of-mass offset in local space.
  Vector3 get centerOfMass => _centerOfMass;

  @override
  Vector3 get localCenterOfMass => _centerOfMass;

  @override
  double get inscribedSphereRadius {
    var best = double.infinity;
    for (var i = 0; i < children.length; i++) {
      final r = children[i].shape.inscribedSphereRadius;
      if (r > 0.0 && r < best) {
        best = r;
      }
    }
    return best.isFinite ? best : 0.05;
  }

  @override
  double estimateLocalVolume() => _totalVolume;

  @override
  Aabb3 computeLocalAabb({Aabb3? out}) {
    final box = out ?? Aabb3();
    box.min.setFrom(_localAabb.min);
    box.max.setFrom(_localAabb.max);
    return box;
  }

  @override
  void computeWorldAabb(Matrix4 worldTransform, Aabb3 out) {
    final childMat = Matrix4.identity();
    final childBox = Aabb3();
    for (var i = 0; i < children.length; i++) {
      final c = children[i];
      childMat
        ..setFrom(worldTransform)
        ..multiply(c.localTransform);
      c.shape.computeWorldAabb(childMat, childBox);
      if (i == 0) {
        out.min.setFrom(childBox.min);
        out.max.setFrom(childBox.max);
      } else {
        out.hull(childBox);
      }
    }
  }

  @override
  void supportPoint(Vector3 worldDir, Matrix4 worldTransform, Vector3 out) {
    final childMat = Matrix4.identity();
    final cand = Vector3.zero();
    var bestDot = double.negativeInfinity;
    for (var i = 0; i < children.length; i++) {
      final c = children[i];
      childMat
        ..setFrom(worldTransform)
        ..multiply(c.localTransform);
      c.shape.supportPoint(worldDir, childMat, cand);
      final d = cand.dot(worldDir);
      if (d > bestDot) {
        bestDot = d;
        out.setFrom(cand);
      }
    }
  }

  @override
  (double distance, Vector3 normal)? raycast(
    Ray worldRay,
    Matrix4 worldTransform, {
    double maxDistance = double.infinity,
  }) {
    if (!(maxDistance >= 0.0)) {
      return null;
    }
    final childMat = Matrix4.identity();
    var limit = maxDistance;
    (double, Vector3)? best;
    for (var i = 0; i < children.length; i++) {
      final c = children[i];
      childMat
        ..setFrom(worldTransform)
        ..multiply(c.localTransform);
      final hit = c.shape.raycast(worldRay, childMat, maxDistance: limit);
      if (hit != null && hit.$1 <= limit) {
        limit = hit.$1;
        best = hit;
      }
    }
    return best;
  }

  /// Computes the exact `3x3` symmetric inertia tensor using the
  /// **Huygens–Steiner parallel-axis theorem**:
  /// `I_total = sum(R_i I_i R_i^T + m_i ((d_i . d_i) E - d_i (x) d_i))`.
  @override
  Matrix3 computeLocalInertiaTensor(
    double mass, {
    Matrix3? out,
    bool aboutCenterOfMass = true,
  }) {
    final res = out ?? Matrix3.zero();
    res.setZero();
    if (mass <= 0.0) {
      return res;
    }

    final refX = aboutCenterOfMass ? _centerOfMass.x : 0.0;
    final refY = aboutCenterOfMass ? _centerOfMass.y : 0.0;
    final refZ = aboutCenterOfMass ? _centerOfMass.z : 0.0;

    final childI = Matrix3.zero();
    final rotMat = Matrix3.zero();
    final temp = Matrix3.zero();
    final rotT = Matrix3.zero();
    final s = res.storage;

    for (var i = 0; i < children.length; i++) {
      final child = children[i];
      final mI = mass * _childWeights[i];
      if (mI <= 0.0) {
        continue;
      }
      child.shape.computeLocalInertiaTensor(mI, out: childI);
      rotMat.setFrom(child.rotation.asRotationMatrix());
      rotT
        ..setFrom(rotMat)
        ..transpose();
      // `temp = rotMat * childI * rotMat^T`.
      temp
        ..setFrom(rotMat)
        ..multiply(childI)
        ..multiply(rotT);

      final dx = _childComCoords[i * 3] - refX;
      final dy = _childComCoords[i * 3 + 1] - refY;
      final dz = _childComCoords[i * 3 + 2] - refZ;
      final d2 = dx * dx + dy * dy + dz * dz;

      final ts = temp.storage;
      s[0] += ts[0] + mI * (d2 - dx * dx);
      s[1] += ts[1] - mI * dy * dx;
      s[2] += ts[2] - mI * dz * dx;
      s[3] += ts[3] - mI * dx * dy;
      s[4] += ts[4] + mI * (d2 - dy * dy);
      s[5] += ts[5] - mI * dz * dy;
      s[6] += ts[6] - mI * dx * dz;
      s[7] += ts[7] - mI * dy * dz;
      s[8] += ts[8] + mI * (d2 - dz * dz);
    }
    return res;
  }

  @override
  Vector3 computeLocalInertiaDiagonal(double mass, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    if (mass <= 0.0) {
      res.setZero();
      return res;
    }
    computeLocalInertiaTensor(mass, out: _tensorScratch);
    final s = _tensorScratch.storage;
    res.setValues(s[0], s[4], s[8]);
    return res;
  }

  static final Matrix3 _tensorScratch = Matrix3.zero();
}
