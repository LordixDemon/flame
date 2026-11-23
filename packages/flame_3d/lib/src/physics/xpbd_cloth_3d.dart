import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/resources.dart';

part 'xpbd_rope_3d.dart';

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

        _solveColliderPushOut(n);
      }

      // 4. Derive post-projection velocities.
      _deriveXpbdVelocities(n, _invMass, _pos, _prevPos, _vel, invH);
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
    // The vertices were written in place: report it, so that retained
    // layers and kept shadows follow.
    markDrawDirty();
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
