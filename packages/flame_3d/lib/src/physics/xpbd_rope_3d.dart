part of 'xpbd_cloth_3d.dart';

/// Zero-GC 3D XPBD `segmentCount`-segment rope/chain [Object3D] component with
/// sphere/capsule collider push-out, tubular [Surface] extrusion, and optional
/// two-way tension coupling to an [attachedBody] [RigidBody3D].
class XpbdRope3D({
  required Vector3 startPoint,
  required Vector3 endPoint,
  final int segmentCount = 16,
  final double radius = 0.04,
  final int radialSegments = 6,
  Material? material,
  var Color color = const Color(0xFFFFFFFF),
  bool pinStart = true,
  bool pinEnd = false,
  var RigidBody3D? attachedBody,
  Vector3? bodyLocalAnchor,
  var bool attachAtEnd = true,
  var double totalMass = 0.5,
  var double compliance = 0.0,
  var double bendingCompliance = 0.02,
  var double damping = 0.02,
  Vector3? gravity,
  var int substeps = 4,
  var int solverIterations = 6,
  var bool autoStep = true,
  List<XpbdSphereCollider3D>? sphereColliders,
  List<XpbdCapsuleCollider3D>? capsuleColliders,
  super.position,
  super.scale,
  super.rotation,
  super.children,
  super.castsShadows,
  super.cameraMask,
}) extends Object3D {
  this
    : assert(segmentCount >= 2, 'segmentCount must be >= 2'),
      assert(radius > 0, 'radius must be positive'),
      assert(radialSegments >= 3, 'radialSegments must be >= 3'),
      assert(totalMass > 0, 'totalMass must be positive') {
    final pCount = segmentCount + 1;
    _pos = Float32List(pCount * 3);
    _prevPos = Float32List(pCount * 3);
    _vel = Float32List(pCount * 3);
    _invMass = Float32List(pCount);

    final invParticleMass = pCount / totalMass;
    for (var i = 0; i < pCount; i++) {
      final t = i / segmentCount;
      final o = i * 3;
      _pos[o] = startPoint.x + (endPoint.x - startPoint.x) * t;
      _pos[o + 1] = startPoint.y + (endPoint.y - startPoint.y) * t;
      _pos[o + 2] = startPoint.z + (endPoint.z - startPoint.z) * t;
      _prevPos[o] = _pos[o];
      _prevPos[o + 1] = _pos[o + 1];
      _prevPos[o + 2] = _pos[o + 2];

      final pinned = (i == 0 && pinStart) || (i == pCount - 1 && pinEnd);
      _invMass[i] = pinned ? 0.0 : invParticleMass;
    }

    final edgesA = <int>[];
    final edgesB = <int>[];
    final restLens = <double>[];
    final compliances = <double>[];
    void addConstraint(int a, int b, double comp) {
      edgesA.add(a);
      edgesB.add(b);
      final oa = a * 3;
      final ob = b * 3;
      final ex = _pos[ob] - _pos[oa];
      final ey = _pos[ob + 1] - _pos[oa + 1];
      final ez = _pos[ob + 2] - _pos[oa + 2];
      restLens.add(math.sqrt(ex * ex + ey * ey + ez * ez));
      compliances.add(math.max(0.0, comp));
    }

    for (var i = 0; i < segmentCount; i++) {
      addConstraint(i, i + 1, compliance);
      if (i + 2 <= segmentCount) {
        addConstraint(i, i + 2, bendingCompliance);
      }
    }
    _constraintCount = edgesA.length;
    _edgeA = Int32List.fromList(edgesA);
    _edgeB = Int32List.fromList(edgesB);
    _restLen = Float32List.fromList(restLens);
    _compliance = Float32List.fromList(compliances);
    _lambda = Float32List(_constraintCount);

    // Build tubular cylinder mesh (`(segmentCount + 1) x (radial + 1)`).
    final cols = radialSegments + 1;
    _ringCos = Float32List(cols);
    _ringSin = Float32List(cols);
    for (var j = 0; j < cols; j++) {
      final phi = (j / radialSegments) * math.pi * 2.0;
      _ringCos[j] = math.cos(phi);
      _ringSin[j] = math.sin(phi);
    }
    final vertCount = pCount * cols;
    final layout = VertexLayout.standard;
    final stride = layout.strideInFloats;
    _posAttrOffset = layout.offsetOf(VertexLayout.positionAttribute) ?? 0;
    _uvAttrOffset = layout.offsetOf('vertexTexCoord') ?? -1;
    _colAttrOffset = layout.offsetOf('vertexColor') ?? -1;
    _nrmAttrOffset = layout.offsetOf('vertexNormal') ?? -1;
    _vertexStride = stride;

    final verts = Float32List(vertCount * stride);
    for (var i = 0; i < pCount; i++) {
      final vCoord = i / segmentCount;
      for (var j = 0; j < cols; j++) {
        final uCoord = j / radialSegments;
        final base = (i * cols + j) * stride;
        if (_uvAttrOffset >= 0) {
          verts[base + _uvAttrOffset] = uCoord;
          verts[base + _uvAttrOffset + 1] = vCoord;
        }
        if (_colAttrOffset >= 0) {
          verts[base + _colAttrOffset] = 1.0;
          verts[base + _colAttrOffset + 1] = 1.0;
          verts[base + _colAttrOffset + 2] = 1.0;
          verts[base + _colAttrOffset + 3] = 1.0;
        }
      }
    }

    final quadCount = segmentCount * radialSegments;
    final indices = vertCount > 0xFFFF
        ? Uint32List(quadCount * 6)
        : Uint16List(quadCount * 6);
    var k = 0;
    for (var i = 0; i < segmentCount; i++) {
      final r0 = i * cols;
      final r1 = (i + 1) * cols;
      for (var j = 0; j < radialSegments; j++) {
        final i0 = r0 + j;
        final i1 = i0 + 1;
        final i2 = r1 + j + 1;
        final i3 = r1 + j;
        indices[k] = i0;
        indices[k + 1] = i2;
        indices[k + 2] = i1;
        indices[k + 3] = i0;
        indices[k + 4] = i3;
        indices[k + 5] = i2;
        k += 6;
      }
    }

    _surface = Surface.fromBuffers(
      vertices: verts,
      indices: indices,
      layout: layout,
      material: material,
    );
    _syncTubeSurface();
  }

  /// Gravitational acceleration (`m/s^2`), `(0, -9.81, 0)` by default.
  final Vector3 gravity = gravity?.clone() ?? Vector3(0.0, -9.81, 0.0);

  /// Anchor point in [attachedBody]'s local space.
  final Vector3 bodyLocalAnchor = bodyLocalAnchor?.clone() ?? Vector3.zero();

  /// Analytical sphere colliders pushing rope particles outward.
  final List<XpbdSphereCollider3D> sphereColliders = sphereColliders != null
      ? List<XpbdSphereCollider3D>.of(sphereColliders)
      : <XpbdSphereCollider3D>[];

  /// Analytical capsule colliders pushing rope particles outward.
  final List<XpbdCapsuleCollider3D> capsuleColliders = capsuleColliders != null
      ? List<XpbdCapsuleCollider3D>.of(capsuleColliders)
      : <XpbdCapsuleCollider3D>[];

  late final Float32List _pos;
  late final Float32List _prevPos;
  late final Float32List _vel;
  late final Float32List _invMass;
  late final Int32List _edgeA;
  late final Int32List _edgeB;
  late final Float32List _restLen;
  late final Float32List _compliance;
  late final Float32List _lambda;
  late final int _constraintCount;

  late final int _posAttrOffset;
  late final int _uvAttrOffset;
  late final int _colAttrOffset;
  late final int _nrmAttrOffset;
  late final int _vertexStride;
  late final Surface _surface;
  late final Float32List _ringCos;
  late final Float32List _ringSin;

  Float32List _localSpheres = Float32List(16);
  int _localSphereCount = 0;
  Float32List _localCapsules = Float32List(28);
  int _localCapsuleCount = 0;

  final Aabb3 _localAabb = Aabb3();
  final Matrix4 _invWorld = Matrix4.identity();
  final Vector3 _localGrav = Vector3.zero();
  final Vector3 _localColA = Vector3.zero();
  final Vector3 _localColB = Vector3.zero();
  final Vector3 _anchorWorld = Vector3.zero();
  final Vector3 _anchorLocal = Vector3.zero();
  final Vector3 _impulseWorld = Vector3.zero();
  final Vector3 _tangent = Vector3.zero();
  final Vector3 _prevTangent = Vector3.zero();
  final Vector3 _normalFrame = Vector3.zero();
  final Vector3 _binormal = Vector3.zero();
  final Vector3 _rotAxis = Vector3.zero();

  /// Underlying GPU-ready tubular [Surface].
  Surface get surface => _surface;

  /// Number of simulated rope particles (`segmentCount + 1`).
  int get particleCount => segmentCount + 1;

  /// Reads the local-space position of rope particle [index] into [out].
  Vector3 getParticlePosition(int index, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    final o = index * 3;
    res.setValues(_pos[o], _pos[o + 1], _pos[o + 2]);
    return res;
  }

  /// Sets the local-space position of rope particle [index] and zeroes its
  /// velocity.
  void setParticlePosition(int index, Vector3 localPosition) {
    final o = index * 3;
    _pos[o] = localPosition.x;
    _pos[o + 1] = localPosition.y;
    _pos[o + 2] = localPosition.z;
    _prevPos[o] = localPosition.x;
    _prevPos[o + 1] = localPosition.y;
    _prevPos[o + 2] = localPosition.z;
    _vel[o] = 0.0;
    _vel[o + 1] = 0.0;
    _vel[o + 2] = 0.0;
  }

  @override
  bool get usesDefaultFrustumVisibility => runtimeType == XpbdRope3D;

  @override
  Aabb3? computeLocalAabb() => _localAabb;

  @override
  void update(double dt) {
    super.update(dt);
    if (autoStep && dt > 0.0) {
      step(math.min(dt, 1.0 / 30.0));
    }
  }

  /// Advances the XPBD rope simulation by [dt] seconds and updates [surface].
  void step(double dt) {
    if (dt <= 0.0) {
      return;
    }
    final pCount = segmentCount + 1;
    final h = dt / substeps;
    final invH = 1.0 / h;
    final invH2 = invH * invH;
    final dampScale = 1.0 / (1.0 + math.max(0.0, damping) * h);

    final wMat = worldTransformMatrix;
    _invWorld.setFrom(wMat);
    if (_invWorld.invert().abs() < 1e-15) {
      _invWorld.setIdentity();
    }
    _transformDir(_invWorld.storage, gravity, _localGrav);
    _prepareLocalColliders();

    final body = attachedBody;
    final attachIdx = attachAtEnd ? pCount - 1 : 0;

    for (var sub = 0; sub < substeps; sub++) {
      // If attached to a static/kinematic RigidBody3D, track its anchor
      // kinematically.
      if (body != null && body.inverseMass <= 0.0) {
        _evalBodyAnchorLocal(body, _invWorld.storage, _anchorLocal);
        final ao = attachIdx * 3;
        _pos[ao] = _anchorLocal.x;
        _pos[ao + 1] = _anchorLocal.y;
        _pos[ao + 2] = _anchorLocal.z;
        _invMass[attachIdx] = 0.0;
      }

      for (var i = 0; i < pCount; i++) {
        final w = _invMass[i];
        final o = i * 3;
        _prevPos[o] = _pos[o];
        _prevPos[o + 1] = _pos[o + 1];
        _prevPos[o + 2] = _pos[o + 2];
        if (w <= 0.0) {
          continue;
        }
        final vx = (_vel[o] + _localGrav.x * h) * dampScale;
        final vy = (_vel[o + 1] + _localGrav.y * h) * dampScale;
        final vz = (_vel[o + 2] + _localGrav.z * h) * dampScale;
        _vel[o] = vx;
        _vel[o + 1] = vy;
        _vel[o + 2] = vz;
        _pos[o] += vx * h;
        _pos[o + 1] += vy * h;
        _pos[o + 2] += vz * h;
      }

      _lambda.fillRange(0, _constraintCount, 0.0);
      var attachLambda = 0.0;

      for (var iter = 0; iter < solverIterations; iter++) {
        _solveXpbdDistanceConstraints(
          _constraintCount,
          _edgeA,
          _edgeB,
          _invMass,
          _restLen,
          _compliance,
          _pos,
          _lambda,
          invH2,
        );

        // Two-way XPBD attachment constraint to a dynamic RigidBody3D.
        if (body != null && body.inverseMass > 0.0) {
          _evalBodyAnchorLocal(body, _invWorld.storage, _anchorLocal);
          final ao = attachIdx * 3;
          final dx = _pos[ao] - _anchorLocal.x;
          final dy = _pos[ao + 1] - _anchorLocal.y;
          final dz = _pos[ao + 2] - _anchorLocal.z;
          final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
          if (dist > 1e-8) {
            final wP = _invMass[attachIdx];
            final wBody = body.inverseMass;
            final wSum = wP + wBody;
            if (wSum > 0.0) {
              final dLambda = (-dist - 0.0 * attachLambda) / wSum;
              attachLambda += dLambda;
              final nx = dx / dist;
              final ny = dy / dist;
              final nz = dz / dist;
              if (wP > 0.0) {
                _pos[ao] += nx * (dLambda * wP);
                _pos[ao + 1] += ny * (dLambda * wP);
                _pos[ao + 2] += nz * (dLambda * wP);
              }
              // Apply equal-and-opposite positional/velocity pull on `body`.
              final jMag = -dLambda * invH;
              _localColA.setValues(nx * jMag, ny * jMag, nz * jMag);
              _transformDir(wMat.storage, _localColA, _impulseWorld);
              body.applyImpulse(_impulseWorld, worldPoint: _anchorWorld);
              body.bodyPosition.addScaled(
                _impulseWorld,
                h * body.inverseMass * 0.5,
              );
            }
          }
        }

        for (var s = 0; s < _localSphereCount; s++) {
          final o = s * 4;
          _pushOutSphere(
            _pos,
            _invMass,
            pCount,
            _localSpheres[o],
            _localSpheres[o + 1],
            _localSpheres[o + 2],
            _localSpheres[o + 3],
          );
        }
        for (var c = 0; c < _localCapsuleCount; c++) {
          final o = c * 7;
          _pushOutCapsule(
            _pos,
            _invMass,
            pCount,
            _localCapsules[o],
            _localCapsules[o + 1],
            _localCapsules[o + 2],
            _localCapsules[o + 3],
            _localCapsules[o + 4],
            _localCapsules[o + 5],
            _localCapsules[o + 6],
          );
        }
      }

      _deriveXpbdVelocities(pCount, _invMass, _pos, _prevPos, _vel, invH);
    }

    _syncTubeSurface();
  }

  void _prepareLocalColliders() {
    final invM = _invWorld.storage;
    var sCount = 0;
    for (var s = 0; s < sphereColliders.length; s++) {
      final needed = (sCount + 1) * 4;
      if (_localSpheres.length < needed) {
        _localSpheres = Float32List(_localSpheres.length * 2)
          ..setRange(0, sCount * 4, _localSpheres);
      }
      final sph = sphereColliders[s];
      _transformPt(invM, sph.center, _localColA);
      final o = sCount * 4;
      _localSpheres[o] = _localColA.x;
      _localSpheres[o + 1] = _localColA.y;
      _localSpheres[o + 2] = _localColA.z;
      _localSpheres[o + 3] = sph.radius + radius;
      sCount++;
    }
    _localSphereCount = sCount;

    var cCount = 0;
    for (var c = 0; c < capsuleColliders.length; c++) {
      final needed = (cCount + 1) * 7;
      if (_localCapsules.length < needed) {
        _localCapsules = Float32List(_localCapsules.length * 2)
          ..setRange(0, cCount * 7, _localCapsules);
      }
      final cap = capsuleColliders[c];
      _transformPt(invM, cap.pointA, _localColA);
      _transformPt(invM, cap.pointB, _localColB);
      final o = cCount * 7;
      _localCapsules[o] = _localColA.x;
      _localCapsules[o + 1] = _localColA.y;
      _localCapsules[o + 2] = _localColA.z;
      _localCapsules[o + 3] = _localColB.x;
      _localCapsules[o + 4] = _localColB.y;
      _localCapsules[o + 5] = _localColB.z;
      _localCapsules[o + 6] = cap.radius + radius;
      cCount++;
    }
    _localCapsuleCount = cCount;
  }

  void _evalBodyAnchorLocal(
    RigidBody3D body,
    Float32List invWorldStorage,
    Vector3 outLocal,
  ) {
    final m = body.bodyWorldMatrix.storage;
    final a = bodyLocalAnchor;
    _anchorWorld.setValues(
      m[0] * a.x + m[4] * a.y + m[8] * a.z + m[12],
      m[1] * a.x + m[5] * a.y + m[9] * a.z + m[13],
      m[2] * a.x + m[6] * a.y + m[10] * a.z + m[14],
    );
    _transformPt(invWorldStorage, _anchorWorld, outLocal);
  }

  void _syncTubeSurface() {
    final pCount = segmentCount + 1;
    final cols = radialSegments + 1;
    final vBuf = _surface.vertexData;

    _computeRopeTangent(0, pCount, _tangent);
    if (_tangent.y.abs() < 0.9) {
      _normalFrame.setValues(_tangent.z, 0.0, -_tangent.x);
    } else {
      _normalFrame.setValues(0.0, -_tangent.z, _tangent.y);
    }
    _normalFrame.normalize();
    _prevTangent.setFrom(_tangent);

    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;

    for (var i = 0; i < pCount; i++) {
      _computeRopeTangent(i, pCount, _tangent);
      if (i > 0) {
        // Parallel transport: turn the frame by the rotation taking the
        // previous tangent onto this one (Rodrigues; vector_math's
        // `Quaternion.rotate` would apply the inverse rotation).
        _prevTangent.crossInto(_tangent, _rotAxis);
        final sinA = _rotAxis.length;
        if (sinA > 1e-6) {
          _rotAxis.scale(1.0 / sinA);
          final cosA = _prevTangent.dot(_tangent).clamp(-1.0, 1.0);
          final kx = _rotAxis.x;
          final ky = _rotAxis.y;
          final kz = _rotAxis.z;
          final vx = _normalFrame.x;
          final vy = _normalFrame.y;
          final vz = _normalFrame.z;
          final kv = kx * vx + ky * vy + kz * vz;
          _normalFrame
            ..setValues(
              vx * cosA + (ky * vz - kz * vy) * sinA + kx * kv * (1 - cosA),
              vy * cosA + (kz * vx - kx * vz) * sinA + ky * kv * (1 - cosA),
              vz * cosA + (kx * vy - ky * vx) * sinA + kz * kv * (1 - cosA),
            )
            ..normalize();
        }
        _prevTangent.setFrom(_tangent);
      }
      _tangent.crossInto(_normalFrame, _binormal);
      _binormal.normalize();

      final po = i * 3;
      final cx = _pos[po];
      final cy = _pos[po + 1];
      final cz = _pos[po + 2];

      if (cx - radius < minX) {
        minX = cx - radius;
      }
      if (cy - radius < minY) {
        minY = cy - radius;
      }
      if (cz - radius < minZ) {
        minZ = cz - radius;
      }
      if (cx + radius > maxX) {
        maxX = cx + radius;
      }
      if (cy + radius > maxY) {
        maxY = cy + radius;
      }
      if (cz + radius > maxZ) {
        maxZ = cz + radius;
      }

      for (var j = 0; j < cols; j++) {
        final cosP = _ringCos[j];
        final sinP = _ringSin[j];

        final nx = _normalFrame.x * cosP + _binormal.x * sinP;
        final ny = _normalFrame.y * cosP + _binormal.y * sinP;
        final nz = _normalFrame.z * cosP + _binormal.z * sinP;

        final vb = (i * cols + j) * _vertexStride;
        vBuf[vb + _posAttrOffset] = cx + nx * radius;
        vBuf[vb + _posAttrOffset + 1] = cy + ny * radius;
        vBuf[vb + _posAttrOffset + 2] = cz + nz * radius;
        if (_nrmAttrOffset >= 0) {
          vBuf[vb + _nrmAttrOffset] = nx;
          vBuf[vb + _nrmAttrOffset + 1] = ny;
          vBuf[vb + _nrmAttrOffset + 2] = nz;
        }
      }
    }

    _localAabb.min.setValues(minX, minY, minZ);
    _localAabb.max.setValues(maxX, maxY, maxZ);
    _surface.updateVertices(vBuf, aabb: _localAabb);
    markAabbDirty();
    // The vertices were written in place: report it, so that retained
    // layers and kept shadows follow.
    markDrawDirty();
  }

  void _computeRopeTangent(int i, int pCount, Vector3 out) {
    final i0 = math.max(0, i - 1) * 3;
    final i1 = math.min(pCount - 1, i + 1) * 3;
    out.setValues(
      _pos[i1] - _pos[i0],
      _pos[i1 + 1] - _pos[i0 + 1],
      _pos[i1 + 2] - _pos[i0 + 2],
    );
    if (out.length2 > 1e-12) {
      out.normalize();
    } else {
      out.setValues(0.0, -1.0, 0.0);
    }
  }

  @override
  void draw(covariant RenderContext3D context) {
    context.drawSurface(
      _surface,
      transform: worldTransformMatrix,
      color: color,
    );
  }

  @override
  void onRemove() {
    _surface.dispose();
    super.onRemove();
  }
}

void _pushOutSphere(
  Float32List pos,
  Float32List invMass,
  int count,
  double cx,
  double cy,
  double cz,
  double minR,
) {
  final r2 = minR * minR;
  for (var i = 0; i < count; i++) {
    if (invMass[i] <= 0.0) {
      continue;
    }
    final o = i * 3;
    final dx = pos[o] - cx;
    final dy = pos[o + 1] - cy;
    final dz = pos[o + 2] - cz;
    final d2 = dx * dx + dy * dy + dz * dz;
    if (d2 < r2) {
      if (d2 > 1e-12) {
        final s = minR / math.sqrt(d2);
        pos[o] = cx + dx * s;
        pos[o + 1] = cy + dy * s;
        pos[o + 2] = cz + dz * s;
      } else {
        pos[o] = cx;
        pos[o + 1] = cy + minR;
        pos[o + 2] = cz;
      }
    }
  }
}

void _pushOutCapsule(
  Float32List pos,
  Float32List invMass,
  int count,
  double ax,
  double ay,
  double az,
  double bx,
  double by,
  double bz,
  double minR,
) {
  final abx = bx - ax;
  final aby = by - ay;
  final abz = bz - az;
  final abLen2 = abx * abx + aby * aby + abz * abz;
  final r2 = minR * minR;

  for (var i = 0; i < count; i++) {
    if (invMass[i] <= 0.0) {
      continue;
    }
    final o = i * 3;
    final px = pos[o];
    final py = pos[o + 1];
    final pz = pos[o + 2];
    final t = abLen2 > 1e-14
        ? (((px - ax) * abx + (py - ay) * aby + (pz - az) * abz) / abLen2)
              .clamp(0.0, 1.0)
        : 0.0;
    final cx = ax + abx * t;
    final cy = ay + aby * t;
    final cz = az + abz * t;
    final dx = px - cx;
    final dy = py - cy;
    final dz = pz - cz;
    final d2 = dx * dx + dy * dy + dz * dz;
    if (d2 < r2) {
      if (d2 > 1e-12) {
        final s = minR / math.sqrt(d2);
        pos[o] = cx + dx * s;
        pos[o + 1] = cy + dy * s;
        pos[o + 2] = cz + dz * s;
      } else {
        pos[o] = cx;
        pos[o + 1] = cy + minR;
        pos[o + 2] = cz;
      }
    }
  }
}

void _transformPt(Float32List m, Vector3 v, Vector3 out) {
  out.setValues(
    m[0] * v.x + m[4] * v.y + m[8] * v.z + m[12],
    m[1] * v.x + m[5] * v.y + m[9] * v.z + m[13],
    m[2] * v.x + m[6] * v.y + m[10] * v.z + m[14],
  );
}

void _transformDir(Float32List m, Vector3 v, Vector3 out) {
  out.setValues(
    m[0] * v.x + m[4] * v.y + m[8] * v.z,
    m[1] * v.x + m[5] * v.y + m[9] * v.z,
    m[2] * v.x + m[6] * v.y + m[10] * v.z,
  );
}

void _solveXpbdDistanceConstraints(
  int constraintCount,
  Int32List edgeA,
  Int32List edgeB,
  Float32List invMass,
  Float32List restLen,
  Float32List compliance,
  Float32List pos,
  Float32List lambda,
  double invH2,
) {
  for (var k = 0; k < constraintCount; k++) {
    final a = edgeA[k];
    final b = edgeB[k];
    final wA = invMass[a];
    final wB = invMass[b];
    final wSum = wA + wB;
    if (wSum <= 0.0) {
      continue;
    }
    final oa = a * 3;
    final ob = b * 3;
    final dx = pos[oa] - pos[ob];
    final dy = pos[oa + 1] - pos[ob + 1];
    final dz = pos[oa + 2] - pos[ob + 2];
    final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
    if (dist <= 1e-9) {
      continue;
    }
    final cErr = dist - restLen[k];
    final alphaTilde = compliance[k] * invH2;
    final dLambda = (-cErr - alphaTilde * lambda[k]) / (wSum + alphaTilde);
    lambda[k] += dLambda;
    final s = dLambda / dist;
    if (wA > 0.0) {
      pos[oa] += dx * (s * wA);
      pos[oa + 1] += dy * (s * wA);
      pos[oa + 2] += dz * (s * wA);
    }
    if (wB > 0.0) {
      pos[ob] -= dx * (s * wB);
      pos[ob + 1] -= dy * (s * wB);
      pos[ob + 2] -= dz * (s * wB);
    }
  }
}

void _deriveXpbdVelocities(
  int count,
  Float32List invMass,
  Float32List pos,
  Float32List prevPos,
  Float32List vel,
  double invH,
) {
  for (var i = 0; i < count; i++) {
    if (invMass[i] <= 0.0) {
      continue;
    }
    final o = i * 3;
    vel[o] = (pos[o] - prevPos[o]) * invH;
    vel[o + 1] = (pos[o + 1] - prevPos[o + 1]) * invH;
    vel[o + 2] = (pos[o + 2] - prevPos[o + 2]) * invH;
  }
}
