import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/resources.dart';

/// Analytical world-space sphere obstacle for [XpbdCloth3D] and [XpbdRope3D]
/// particle push-out.
class XpbdSphereCollider3D({
  required Vector3 center,
  required final double radius,
}) {
  this : assert(radius > 0, 'radius must be positive');

  /// World-space sphere center.
  final Vector3 center = center.clone();
}

/// Analytical world-space capsule obstacle (`[pointA, pointB]`, [radius]) for
/// [XpbdCloth3D] and [XpbdRope3D] particle push-out.
class XpbdCapsuleCollider3D({
  required Vector3 pointA,
  required Vector3 pointB,
  required final double radius,
}) {
  this : assert(radius > 0, 'radius must be positive');

  /// World-space first segment endpoint.
  final Vector3 pointA = pointA.clone();

  /// World-space second segment endpoint.
  final Vector3 pointB = pointB.clone();
}

/// Zero-GC 3D **Extended Position-Based Dynamics (XPBD)** grid cloth
/// [Object3D] component.
///
/// Simulates a `columns x rows` particle grid with structural, shear, and
/// bending distance constraints (`compliance / dt^2`), gravity, triangle-normal
/// aerodynamic wind lift/drag, sphere and capsule collider push-out, and
/// in-place `Float32List` position + smooth normal uploads to [surface].
class XpbdCloth3D({
  final int columns = 16,
  final int rows = 16,
  final double width = 2.0,
  final double height = 2.0,
  Material? material,
  var Color color = const Color(0xFFFFFFFF),
  bool startHorizontal = false,
  bool pinTopCorners = true,
  bool pinTopEdge = false,
  Set<int>? pinnedVertices,
  var double totalMass = 1.0,
  var double structuralCompliance = 0.0,
  var double shearCompliance = 0.0001,
  var double bendingCompliance = 0.01,
  var double damping = 0.015,
  Vector3? gravity,
  Vector3? windVelocity,
  var double windDragCoefficient = 1.2,
  var int substeps = 4,
  var int solverIterations = 4,
  var double particleThickness = 0.03,
  var bool autoStep = true,
  List<XpbdSphereCollider3D>? sphereColliders,
  List<XpbdCapsuleCollider3D>? capsuleColliders,
  List<Collider3D>? worldColliders,
  super.position,
  super.scale,
  super.rotation,
  super.children,
  super.castsShadows,
  super.cameraMask,
}) extends Object3D {
  this
    : assert(columns >= 2 && rows >= 2, 'Cloth grid must be at least 2x2'),
      assert(width > 0 && height > 0, 'width and height must be positive'),
      assert(totalMass > 0, 'totalMass must be positive'),
      assert(substeps >= 1 && solverIterations >= 1, 'substeps/iters >= 1') {
    final vertCount = columns * rows;
    _pos = Float32List(vertCount * 3);
    _prevPos = Float32List(vertCount * 3);
    _vel = Float32List(vertCount * 3);
    _invMass = Float32List(vertCount);
    _windForce = Float32List(vertCount * 3);
    _normals = Float32List(vertCount * 3);

    final invParticleMass = vertCount / totalMass;
    final dx = width / (columns - 1);
    final dy = height / (rows - 1);
    final halfW = width * 0.5;
    final halfH = height * 0.5;

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < columns; c++) {
        final idx = r * columns + c;
        final o = idx * 3;
        final lx = -halfW + c * dx;
        if (startHorizontal) {
          _pos[o] = lx;
          _pos[o + 1] = 0.0;
          _pos[o + 2] = -halfH + r * dy;
        } else {
          // Row 0 at top (`+halfH` or `0`), hanging along `-Y`.
          _pos[o] = lx;
          _pos[o + 1] = halfH - r * dy;
          _pos[o + 2] = 0.0;
        }
        _prevPos[o] = _pos[o];
        _prevPos[o + 1] = _pos[o + 1];
        _prevPos[o + 2] = _pos[o + 2];

        final pinned =
            (pinnedVertices != null && pinnedVertices.contains(idx)) ||
            (pinTopEdge && r == 0) ||
            (pinTopCorners && r == 0 && (c == 0 || c == columns - 1));
        _invMass[idx] = pinned ? 0.0 : invParticleMass;
      }
    }

    // Build structural, shear, and bending XPBD distance constraints.
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

    for (var r = 0; r < rows; r++) {
      for (var c = 0; c < columns; c++) {
        final i = r * columns + c;
        // Structural.
        if (c + 1 < columns) {
          addConstraint(i, i + 1, structuralCompliance);
        }
        if (r + 1 < rows) {
          addConstraint(i, i + columns, structuralCompliance);
        }
        // Shear diagonals.
        if (c + 1 < columns && r + 1 < rows) {
          addConstraint(i, i + columns + 1, shearCompliance);
          addConstraint(i + 1, i + columns, shearCompliance);
        }
        // Bending (2-hop).
        if (c + 2 < columns) {
          addConstraint(i, i + 2, bendingCompliance);
        }
        if (r + 2 < rows) {
          addConstraint(i, i + 2 * columns, bendingCompliance);
        }
      }
    }

    _constraintCount = edgesA.length;
    _edgeA = Int32List.fromList(edgesA);
    _edgeB = Int32List.fromList(edgesB);
    _restLen = Float32List.fromList(restLens);
    _compliance = Float32List.fromList(compliances);
    _lambda = Float32List(_constraintCount);

    // Build triangle indices (`2` CCW triangles per grid quad).
    final quadCount = (columns - 1) * (rows - 1);
    final triIndices = vertCount > 0xFFFF
        ? Uint32List(quadCount * 6)
        : Uint16List(quadCount * 6);
    var k = 0;
    for (var r = 0; r < rows - 1; r++) {
      final row0 = r * columns;
      final row1 = (r + 1) * columns;
      for (var c = 0; c < columns - 1; c++) {
        final i0 = row0 + c;
        final i1 = i0 + 1;
        final i2 = row1 + c + 1;
        final i3 = row1 + c;
        triIndices[k] = i0;
        triIndices[k + 1] = i3;
        triIndices[k + 2] = i2;
        triIndices[k + 3] = i0;
        triIndices[k + 4] = i2;
        triIndices[k + 5] = i1;
        k += 6;
      }
    }
    _triIndices = triIndices;

    final layout = VertexLayout.standard;
    final stride = layout.strideInFloats;
    _posAttrOffset = layout.offsetOf(VertexLayout.positionAttribute) ?? 0;
    _uvAttrOffset = layout.offsetOf('vertexTexCoord') ?? -1;
    _colAttrOffset = layout.offsetOf('vertexColor') ?? -1;
    _nrmAttrOffset = layout.offsetOf('vertexNormal') ?? -1;
    _vertexStride = stride;

    final initialVerts = Float32List(vertCount * stride);
    for (var r = 0; r < rows; r++) {
      final vCoord = r / (rows - 1);
      for (var c = 0; c < columns; c++) {
        final uCoord = c / (columns - 1);
        final idx = r * columns + c;
        final base = idx * stride;
        if (_uvAttrOffset >= 0) {
          initialVerts[base + _uvAttrOffset] = uCoord;
          initialVerts[base + _uvAttrOffset + 1] = vCoord;
        }
        if (_colAttrOffset >= 0) {
          initialVerts[base + _colAttrOffset] = 1.0;
          initialVerts[base + _colAttrOffset + 1] = 1.0;
          initialVerts[base + _colAttrOffset + 2] = 1.0;
          initialVerts[base + _colAttrOffset + 3] = 1.0;
        }
      }
    }

    _surface = Surface.fromBuffers(
      vertices: initialVerts,
      indices: triIndices,
      layout: layout,
      material: material,
    );
    _syncSurfaceBuffer();
  }

  /// Gravitational acceleration (`m/s^2`), `(0, -9.81, 0)` by default.
  final Vector3 gravity = gravity?.clone() ?? Vector3(0.0, -9.81, 0.0);

  /// World-space ambient wind velocity (`m/s`).
  final Vector3 windVelocity = windVelocity?.clone() ?? Vector3.zero();

  /// Analytical sphere colliders pushing cloth vertices outward.
  final List<XpbdSphereCollider3D> sphereColliders = sphereColliders != null
      ? List<XpbdSphereCollider3D>.of(sphereColliders)
      : <XpbdSphereCollider3D>[];

  /// Analytical capsule colliders pushing cloth vertices outward.
  final List<XpbdCapsuleCollider3D> capsuleColliders = capsuleColliders != null
      ? List<XpbdCapsuleCollider3D>.of(capsuleColliders)
      : <XpbdCapsuleCollider3D>[];

  /// Optional [Collider3D]s (spheres/capsules) pushing cloth vertices outward.
  final List<Collider3D> worldColliders = worldColliders != null
      ? List<Collider3D>.of(worldColliders)
      : <Collider3D>[];

  late final Float32List _pos;
  late final Float32List _prevPos;
  late final Float32List _vel;
  late final Float32List _invMass;
  late final Float32List _windForce;
  late final Float32List _normals;
  late final Int32List _edgeA;
  late final Int32List _edgeB;
  late final Float32List _restLen;
  late final Float32List _compliance;
  late final Float32List _lambda;
  late final List<int> _triIndices;
  late final int _constraintCount;

  late final int _posAttrOffset;
  late final int _uvAttrOffset;
  late final int _colAttrOffset;
  late final int _nrmAttrOffset;
  late final int _vertexStride;
  late final Surface _surface;

  final Aabb3 _localAabb = Aabb3();
  final Matrix4 _invWorld = Matrix4.identity();
  final Vector3 _localGrav = Vector3.zero();
  final Vector3 _localWind = Vector3.zero();
  final Vector3 _localColA = Vector3.zero();
  final Vector3 _localColB = Vector3.zero();

  /// Underlying GPU-ready [Surface] updated in place each simulation step.
  Surface get surface => _surface;

  /// Total number of simulated cloth particles (`columns * rows`).
  int get vertexCount => columns * rows;

  /// Total number of structural + shear + bending XPBD constraints.
  int get constraintCount => _constraintCount;

  /// Linear index `row * columns + col` of grid vertex `(col, row)`.
  int vertexIndex(int col, int row) => row * columns + col;

  /// Reads the local-space position of particle [index] into [out].
  Vector3 getVertexPosition(int index, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    final o = index * 3;
    res.setValues(_pos[o], _pos[o + 1], _pos[o + 2]);
    return res;
  }

  /// Reads the local-space smooth normal of particle [index] into [out].
  Vector3 getVertexNormal(int index, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    final o = index * 3;
    res.setValues(_normals[o], _normals[o + 1], _normals[o + 2]);
    return res;
  }

  /// Pins or unpins particle [index].
  void setVertexPinned(int index, {required bool pinned}) {
    if (pinned) {
      _invMass[index] = 0.0;
      final o = index * 3;
      _vel[o] = 0.0;
      _vel[o + 1] = 0.0;
      _vel[o + 2] = 0.0;
    } else {
      _invMass[index] = (columns * rows) / totalMass;
    }
  }

  /// Teleports particle [index] to [localPosition] and zeroes its velocity.
  void setVertexPosition(int index, Vector3 localPosition) {
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
  Aabb3? computeLocalAabb() => _localAabb;

  @override
  void update(double dt) {
    super.update(dt);
    if (autoStep && dt > 0.0) {
      step(math.min(dt, 1.0 / 30.0));
    }
  }

  /// Advances the XPBD cloth simulation by [dt] seconds with zero heap
  /// allocations and uploads updated positions + smooth normals to [surface].
  void step(double dt) {
    if (dt <= 0.0) {
      return;
    }
    final n = columns * rows;
    final h = dt / substeps;
    final invH = 1.0 / h;
    final invH2 = invH * invH;
    final dampScale = 1.0 / (1.0 + math.max(0.0, damping) * h);

    _invWorld.setFrom(worldTransformMatrix);
    if (_invWorld.invert().abs() < 1e-15) {
      _invWorld.setIdentity();
    }
    _transformDir(_invWorld.storage, gravity, _localGrav);
    _transformDir(_invWorld.storage, windVelocity, _localWind);
    final hasWind = windDragCoefficient > 0.0 && _localWind.length2 > 1e-8;

    for (var sub = 0; sub < substeps; sub++) {
      // 1. Optional aerodynamic wind force normal to each cloth triangle.
      if (hasWind) {
        _windForce.fillRange(0, n * 3, 0.0);
        final wx = _localWind.x;
        final wy = _localWind.y;
        final wz = _localWind.z;
        final dragHalf = 0.5 * windDragCoefficient;

        for (var t = 0; t < _triIndices.length; t += 3) {
          final i0 = _triIndices[t] * 3;
          final i1 = _triIndices[t + 1] * 3;
          final i2 = _triIndices[t + 2] * 3;

          final e1x = _pos[i1] - _pos[i0];
          final e1y = _pos[i1 + 1] - _pos[i0 + 1];
          final e1z = _pos[i1 + 2] - _pos[i0 + 2];
          final e2x = _pos[i2] - _pos[i0];
          final e2y = _pos[i2 + 1] - _pos[i0 + 1];
          final e2z = _pos[i2 + 2] - _pos[i0 + 2];

          // `cross = e1 x e2`, `||cross|| = 2 * triArea`.
          final cx = e1y * e2z - e1z * e2y;
          final cy = e1z * e2x - e1x * e2z;
          final cz = e1x * e2y - e1y * e2x;
          final twoArea = math.sqrt(cx * cx + cy * cy + cz * cz);
          if (twoArea <= 1e-10) {
            continue;
          }
          final invTwoArea = 1.0 / twoArea;
          final nx = cx * invTwoArea;
          final ny = cy * invTwoArea;
          final nz = cz * invTwoArea;

          final vTriX = (_vel[i0] + _vel[i1] + _vel[i2]) * (1.0 / 3.0);
          final vTriY =
              (_vel[i0 + 1] + _vel[i1 + 1] + _vel[i2 + 1]) * (1.0 / 3.0);
          final vTriZ =
              (_vel[i0 + 2] + _vel[i1 + 2] + _vel[i2 + 2]) * (1.0 / 3.0);

          final rvx = wx - vTriX;
          final rvy = wy - vTriY;
          final rvz = wz - vTriZ;
          final rvLen = math.sqrt(rvx * rvx + rvy * rvy + rvz * rvz);
          if (rvLen <= 1e-8) {
            continue;
          }
          // `F = 0.5 * Cd * (vRel . nHat) * |vRel| * area * nHat`, split `/ 3`.
          final vn = rvx * nx + rvy * ny + rvz * nz;
          final fPerVert =
              dragHalf * vn * rvLen * (0.5 * twoArea) * (1.0 / 3.0);
          final fx = nx * fPerVert;
          final fy = ny * fPerVert;
          final fz = nz * fPerVert;

          _windForce[i0] += fx;
          _windForce[i0 + 1] += fy;
          _windForce[i0 + 2] += fz;
          _windForce[i1] += fx;
          _windForce[i1 + 1] += fy;
          _windForce[i1 + 2] += fz;
          _windForce[i2] += fx;
          _windForce[i2 + 1] += fy;
          _windForce[i2 + 2] += fz;
        }
      }

      // 2. Symplectic prediction.
      final gx = _localGrav.x;
      final gy = _localGrav.y;
      final gz = _localGrav.z;
      for (var i = 0; i < n; i++) {
        final w = _invMass[i];
        final o = i * 3;
        _prevPos[o] = _pos[o];
        _prevPos[o + 1] = _pos[o + 1];
        _prevPos[o + 2] = _pos[o + 2];
        if (w <= 0.0) {
          continue;
        }
        var vx = _vel[o] + gx * h;
        var vy = _vel[o + 1] + gy * h;
        var vz = _vel[o + 2] + gz * h;
        if (hasWind) {
          vx += _windForce[o] * w * h;
          vy += _windForce[o + 1] * w * h;
          vz += _windForce[o + 2] * w * h;
        }
        vx *= dampScale;
        vy *= dampScale;
        vz *= dampScale;
        _vel[o] = vx;
        _vel[o + 1] = vy;
        _vel[o + 2] = vz;
        _pos[o] += vx * h;
        _pos[o + 1] += vy * h;
        _pos[o + 2] += vz * h;
      }

      // 3. XPBD constraint & collider projection iterations.
      _lambda.fillRange(0, _constraintCount, 0.0);
      for (var iter = 0; iter < solverIterations; iter++) {
        for (var k = 0; k < _constraintCount; k++) {
          final a = _edgeA[k];
          final b = _edgeB[k];
          final wA = _invMass[a];
          final wB = _invMass[b];
          final wSum = wA + wB;
          if (wSum <= 0.0) {
            continue;
          }
          final oa = a * 3;
          final ob = b * 3;
          final dx = _pos[oa] - _pos[ob];
          final dy = _pos[oa + 1] - _pos[ob + 1];
          final dz = _pos[oa + 2] - _pos[ob + 2];
          final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
          if (dist <= 1e-9) {
            continue;
          }
          final cErr = dist - _restLen[k];
          final alphaTilde = _compliance[k] * invH2;
          final dLambda =
              (-cErr - alphaTilde * _lambda[k]) / (wSum + alphaTilde);
          _lambda[k] += dLambda;
          final s = dLambda / dist;
          if (wA > 0.0) {
            _pos[oa] += dx * (s * wA);
            _pos[oa + 1] += dy * (s * wA);
            _pos[oa + 2] += dz * (s * wA);
          }
          if (wB > 0.0) {
            _pos[ob] -= dx * (s * wB);
            _pos[ob + 1] -= dy * (s * wB);
            _pos[ob + 2] -= dz * (s * wB);
          }
        }

        _solveColliderPushOut(n);
      }

      // 4. Derive post-projection velocities.
      for (var i = 0; i < n; i++) {
        if (_invMass[i] <= 0.0) {
          continue;
        }
        final o = i * 3;
        _vel[o] = (_pos[o] - _prevPos[o]) * invH;
        _vel[o + 1] = (_pos[o + 1] - _prevPos[o + 1]) * invH;
        _vel[o + 2] = (_pos[o + 2] - _prevPos[o + 2]) * invH;
      }
    }

    _syncSurfaceBuffer();
  }

  void _solveColliderPushOut(int particleCount) {
    final invM = _invWorld.storage;

    for (var s = 0; s < sphereColliders.length; s++) {
      final sph = sphereColliders[s];
      _transformPt(invM, sph.center, _localColA);
      _pushOutSphere(
        _pos,
        _invMass,
        particleCount,
        _localColA.x,
        _localColA.y,
        _localColA.z,
        sph.radius + particleThickness,
      );
    }

    for (var c = 0; c < capsuleColliders.length; c++) {
      final cap = capsuleColliders[c];
      _transformPt(invM, cap.pointA, _localColA);
      _transformPt(invM, cap.pointB, _localColB);
      _pushOutCapsule(
        _pos,
        _invMass,
        particleCount,
        _localColA,
        _localColB,
        cap.radius + particleThickness,
      );
    }

    for (var i = 0; i < worldColliders.length; i++) {
      final col = worldColliders[i];
      final shape = col.shape;
      final cm = col.colliderWorldMatrix;
      if (shape is SphereShape3D) {
        _localColB.setValues(cm.storage[12], cm.storage[13], cm.storage[14]);
        _transformPt(invM, _localColB, _localColA);
        _pushOutSphere(
          _pos,
          _invMass,
          particleCount,
          _localColA.x,
          _localColA.y,
          _localColA.z,
          shape.worldRadius(cm) + particleThickness,
        );
      } else if (shape is CapsuleShape3D) {
        final r = shape.worldSpine(cm, _worldSegA, _worldSegB);
        _transformPt(invM, _worldSegA, _localColA);
        _transformPt(invM, _worldSegB, _localColB);
        _pushOutCapsule(
          _pos,
          _invMass,
          particleCount,
          _localColA,
          _localColB,
          r + particleThickness,
        );
      }
    }
  }

  void _syncSurfaceBuffer() {
    final n = columns * rows;
    _normals.fillRange(0, n * 3, 0.0);

    for (var t = 0; t < _triIndices.length; t += 3) {
      final v0 = _triIndices[t];
      final v1 = _triIndices[t + 1];
      final v2 = _triIndices[t + 2];
      final o0 = v0 * 3;
      final o1 = v1 * 3;
      final o2 = v2 * 3;

      final e1x = _pos[o1] - _pos[o0];
      final e1y = _pos[o1 + 1] - _pos[o0 + 1];
      final e1z = _pos[o1 + 2] - _pos[o0 + 2];
      final e2x = _pos[o2] - _pos[o0];
      final e2y = _pos[o2 + 1] - _pos[o0 + 1];
      final e2z = _pos[o2 + 2] - _pos[o0 + 2];

      final nx = e1y * e2z - e1z * e2y;
      final ny = e1z * e2x - e1x * e2z;
      final nz = e1x * e2y - e1y * e2x;

      _normals[o0] += nx;
      _normals[o0 + 1] += ny;
      _normals[o0 + 2] += nz;
      _normals[o1] += nx;
      _normals[o1 + 1] += ny;
      _normals[o1 + 2] += nz;
      _normals[o2] += nx;
      _normals[o2 + 1] += ny;
      _normals[o2 + 2] += nz;
    }

    final vBuf = _surface.vertexData;
    var minX = double.infinity;
    var minY = double.infinity;
    var minZ = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    var maxZ = double.negativeInfinity;

    for (var i = 0; i < n; i++) {
      final o = i * 3;
      final px = _pos[o];
      final py = _pos[o + 1];
      final pz = _pos[o + 2];

      if (px < minX) {
        minX = px;
      }
      if (py < minY) {
        minY = py;
      }
      if (pz < minZ) {
        minZ = pz;
      }
      if (px > maxX) {
        maxX = px;
      }
      if (py > maxY) {
        maxY = py;
      }
      if (pz > maxZ) {
        maxZ = pz;
      }

      var nx = _normals[o];
      var ny = _normals[o + 1];
      var nz = _normals[o + 2];
      final nLen = math.sqrt(nx * nx + ny * ny + nz * nz);
      if (nLen > 1e-12) {
        nx /= nLen;
        ny /= nLen;
        nz /= nLen;
      } else {
        nx = 0.0;
        ny = 0.0;
        nz = 1.0;
      }
      _normals[o] = nx;
      _normals[o + 1] = ny;
      _normals[o + 2] = nz;

      final vb = i * _vertexStride;
      vBuf[vb + _posAttrOffset] = px;
      vBuf[vb + _posAttrOffset + 1] = py;
      vBuf[vb + _posAttrOffset + 2] = pz;
      if (_nrmAttrOffset >= 0) {
        vBuf[vb + _nrmAttrOffset] = nx;
        vBuf[vb + _nrmAttrOffset + 1] = ny;
        vBuf[vb + _nrmAttrOffset + 2] = nz;
      }
    }

    _localAabb.min.setValues(
      minX - particleThickness,
      minY - particleThickness,
      minZ - particleThickness,
    );
    _localAabb.max.setValues(
      maxX + particleThickness,
      maxY + particleThickness,
      maxZ + particleThickness,
    );
    _surface.updateVertices(vBuf, aabb: _localAabb);
    markAabbDirty();
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

  static final Vector3 _worldSegA = Vector3.zero();
  static final Vector3 _worldSegB = Vector3.zero();
}

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
  final Quaternion _stepQuat = Quaternion.identity();

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
        for (var k = 0; k < _constraintCount; k++) {
          final a = _edgeA[k];
          final b = _edgeB[k];
          final wA = _invMass[a];
          final wB = _invMass[b];
          final wSum = wA + wB;
          if (wSum <= 0.0) {
            continue;
          }
          final oa = a * 3;
          final ob = b * 3;
          final dx = _pos[oa] - _pos[ob];
          final dy = _pos[oa + 1] - _pos[ob + 1];
          final dz = _pos[oa + 2] - _pos[ob + 2];
          final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
          if (dist <= 1e-9) {
            continue;
          }
          final cErr = dist - _restLen[k];
          final alphaTilde = _compliance[k] * invH2;
          final dLambda =
              (-cErr - alphaTilde * _lambda[k]) / (wSum + alphaTilde);
          _lambda[k] += dLambda;
          final s = dLambda / dist;
          if (wA > 0.0) {
            _pos[oa] += dx * (s * wA);
            _pos[oa + 1] += dy * (s * wA);
            _pos[oa + 2] += dz * (s * wA);
          }
          if (wB > 0.0) {
            _pos[ob] -= dx * (s * wB);
            _pos[ob + 1] -= dy * (s * wB);
            _pos[ob + 2] -= dz * (s * wB);
          }
        }

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

        for (var s = 0; s < sphereColliders.length; s++) {
          final sph = sphereColliders[s];
          _transformPt(_invWorld.storage, sph.center, _localColA);
          _pushOutSphere(
            _pos,
            _invMass,
            pCount,
            _localColA.x,
            _localColA.y,
            _localColA.z,
            sph.radius + radius,
          );
        }
        for (var c = 0; c < capsuleColliders.length; c++) {
          final cap = capsuleColliders[c];
          _transformPt(_invWorld.storage, cap.pointA, _localColA);
          _transformPt(_invWorld.storage, cap.pointB, _localColB);
          _pushOutCapsule(
            _pos,
            _invMass,
            pCount,
            _localColA,
            _localColB,
            cap.radius + radius,
          );
        }
      }

      for (var i = 0; i < pCount; i++) {
        if (_invMass[i] <= 0.0) {
          continue;
        }
        final o = i * 3;
        _vel[o] = (_pos[o] - _prevPos[o]) * invH;
        _vel[o + 1] = (_pos[o + 1] - _prevPos[o + 1]) * invH;
        _vel[o + 2] = (_pos[o + 2] - _prevPos[o + 2]) * invH;
      }
    }

    _syncTubeSurface();
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
        _rotAxis.setFrom(_prevTangent.cross(_tangent));
        final sinA = _rotAxis.length;
        if (sinA > 1e-6) {
          _rotAxis.scale(1.0 / sinA);
          final cosA = _prevTangent.dot(_tangent).clamp(-1.0, 1.0);
          _stepQuat.setAxisAngle(_rotAxis, math.atan2(sinA, cosA));
          _stepQuat.rotate(_normalFrame);
          _normalFrame.normalize();
        }
        _prevTangent.setFrom(_tangent);
      }
      _binormal
        ..setFrom(_tangent.cross(_normalFrame))
        ..normalize();

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
        final phi = (j / radialSegments) * math.pi * 2.0;
        final cosP = math.cos(phi);
        final sinP = math.sin(phi);

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
  Vector3 a,
  Vector3 b,
  double minR,
) {
  final abx = b.x - a.x;
  final aby = b.y - a.y;
  final abz = b.z - a.z;
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
        ? (((px - a.x) * abx + (py - a.y) * aby + (pz - a.z) * abz) / abLen2)
              .clamp(0.0, 1.0)
        : 0.0;
    final cx = a.x + abx * t;
    final cy = a.y + aby * t;
    final cz = a.z + abz * t;
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
