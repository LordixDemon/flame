import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/canvas3d/matcap_shader_3d.dart';
import 'package:flame/src/canvas3d/mesh_3d.dart';
import 'package:flutter/painting.dart';

/// Hemisphere + directional sun lighting configuration for
/// [BatchMeshRenderer3D].
class DirectionalLight3D({
  double sunDirX = -0.45,
  double sunDirY = -0.35,
  double sunDirZ = 0.82,
  var Color sunColor = const Color(0xFFFFF4DC),
  var Color skyColor = const Color(0xFFD6ECFF),
  var Color groundColor = const Color(0xFF6D5D53),
  var double ambientIntensity = 0.44,
  var double diffuseIntensity = 0.66,
  var double rimIntensity = 0.16,
}) {
  this {
    setDirection(sunDirX, sunDirY, sunDirZ);
  }

  double _lx = -0.45;
  double _ly = -0.35;
  double _lz = 0.82;

  /// Unit vector X pointing towards the directional light source.
  double get dirX => _lx;

  /// Unit vector Y pointing towards the directional light source.
  double get dirY => _ly;

  /// Unit vector Z pointing towards the directional light source.
  double get dirZ => _lz;

  /// Normalizes and updates the directional light vector `(x, y, z)`.
  void setDirection(double x, double y, double z) {
    final len = math.sqrt(x * x + y * y + z * z);
    if (len > 1e-7) {
      _lx = x / len;
      _ly = y / len;
      _lz = z / len;
    }
  }
}

/// Zero-allocation Struct-of-Arrays 3D mesh batcher onto Flutter's standard
/// `Canvas` (`Canvas.drawVertices`).
///
/// Transforms, lights, back-face culls, depth-sorts, and batches arbitrary
/// [Mesh3D] instances across a frame or `RenderPass` into a single GPU
/// `Vertices.raw` draw call (plus an optional single height-projected ground
/// shadow draw call), deterministically disposing native `ui.Vertices` handles
/// immediately after submission.
class BatchMeshRenderer3D({
  DirectionalLight3D? light,
  var bool backfaceCulling = true,
  int initialVertexCapacity = 512,
  int initialTriangleCapacity = 512,
}) {
  /// Active scene lighting parameters.
  final DirectionalLight3D light = light ?? DirectionalLight3D();

  final Paint _meshPaint = Paint()..isAntiAlias = true;
  final Paint _shadowPaint = Paint()..isAntiAlias = true;

  Float32List _vertX = Float32List(initialVertexCapacity);
  Float32List _vertY = Float32List(initialVertexCapacity);
  Float32List _vertDepth = Float32List(initialVertexCapacity);
  Float32List _vertU = Float32List(initialVertexCapacity);
  Float32List _vertV = Float32List(initialVertexCapacity);
  Int32List _vertColor = Int32List(initialVertexCapacity);

  Int32List _triV0 = Int32List(initialTriangleCapacity);
  Int32List _triV1 = Int32List(initialTriangleCapacity);
  Int32List _triV2 = Int32List(initialTriangleCapacity);
  Float32List _triDepth = Float32List(initialTriangleCapacity);
  Int32List _triOrder = Int32List(initialTriangleCapacity);

  Float32List _outPositions = Float32List(initialTriangleCapacity * 6);
  Float32List _outUvs = Float32List(initialTriangleCapacity * 6);
  Int32List _outColors = Int32List(initialTriangleCapacity * 3);
  Uint16List _outIndices = _buildSequentialIndices(
    initialTriangleCapacity * 3,
  );

  Float32List _shadowPositions = Float32List(initialTriangleCapacity * 6);
  Int32List _shadowColors = Int32List(initialTriangleCapacity * 3);

  int _vertCount = 0;
  int _triCount = 0;
  int _shadowTriCount = 0;
  int _enqueuedMeshes = 0;

  int _lastFlushTriangles = 0;
  int _lastFlushShadowTriangles = 0;
  int _lastFlushDrawCalls = 0;

  /// Visible front-facing triangles submitted in the most recent [flushBatch].
  int get lastFlushTriangles => _lastFlushTriangles;

  /// Ground-projected shadow triangles submitted in the most recent
  /// [flushBatch].
  int get lastFlushShadowTriangles => _lastFlushShadowTriangles;

  /// Total `Canvas.drawVertices` calls issued in the most recent [flushBatch].
  int get lastFlushDrawCalls => _lastFlushDrawCalls;

  /// Number of [enqueueMesh] calls accumulated in the active batch.
  int get activeEnqueuedMeshes => _enqueuedMeshes;

  static Uint16List _buildSequentialIndices(int vertexCount) {
    final clamped = math.min(vertexCount, 65535);
    final out = Uint16List(clamped);
    for (var i = 0; i < clamped; i++) {
      out[i] = i;
    }
    return out;
  }

  void _ensureVertexCapacity(int needed) {
    if (needed <= _vertX.length) {
      return;
    }
    var cap = _vertX.length * 2;
    while (cap < needed) {
      cap *= 2;
    }
    _vertX = Float32List(cap)..setRange(0, _vertCount, _vertX);
    _vertY = Float32List(cap)..setRange(0, _vertCount, _vertY);
    _vertDepth = Float32List(cap)..setRange(0, _vertCount, _vertDepth);
    _vertU = Float32List(cap)..setRange(0, _vertCount, _vertU);
    _vertV = Float32List(cap)..setRange(0, _vertCount, _vertV);
    _vertColor = Int32List(cap)..setRange(0, _vertCount, _vertColor);
  }

  void _ensureTriangleCapacity(int needed) {
    if (needed <= _triV0.length) {
      return;
    }
    var cap = _triV0.length * 2;
    while (cap < needed) {
      cap *= 2;
    }
    _triV0 = Int32List(cap)..setRange(0, _triCount, _triV0);
    _triV1 = Int32List(cap)..setRange(0, _triCount, _triV1);
    _triV2 = Int32List(cap)..setRange(0, _triCount, _triV2);
    _triDepth = Float32List(cap)..setRange(0, _triCount, _triDepth);
    _triOrder = Int32List(cap)..setRange(0, _triCount, _triOrder);
    _outPositions = Float32List(cap * 6);
    _outUvs = Float32List(cap * 6);
    _outColors = Int32List(cap * 3);
    _outIndices = _buildSequentialIndices(cap * 3);
  }

  void _ensureShadowCapacity(int neededTris) {
    if (neededTris * 6 <= _shadowPositions.length) {
      return;
    }
    var cap = (_shadowPositions.length ~/ 6) * 2;
    while (cap < neededTris) {
      cap *= 2;
    }
    _shadowPositions = Float32List(cap * 6)
      ..setRange(0, _shadowTriCount * 6, _shadowPositions);
    _shadowColors = Int32List(cap * 3)
      ..setRange(0, _shadowTriCount * 3, _shadowColors);
    if (cap * 3 > _outIndices.length) {
      _outIndices = _buildSequentialIndices(cap * 3);
    }
  }

  /// Resets the batch accumulators for a new frame or render pass.
  void beginBatch() {
    _vertCount = 0;
    _triCount = 0;
    _shadowTriCount = 0;
    _enqueuedMeshes = 0;
  }

  /// Transforms, shades, culls, and appends [mesh] into the active batch.
  void enqueueMesh(
    Mesh3D mesh, {
    required CameraRig3D camera,
    required double worldX,
    required double worldY,
    double worldZ = 0.0,
    Offset canvasOrigin = Offset.zero,
    double scaleX = 1.0,
    double scaleY = 1.0,
    double scaleZ = 1.0,
    double yawRad = 0.0,
    double pitchRad = 0.0,
    double rollRad = 0.0,
    Color tint = const Color(0xFFFFFFFF),
    double opacity = 1.0,
    double emissive = 0.0,
    bool castGroundShadow = false,
    double groundZ = 0.0,
    Color shadowColor = const Color(0xFF16131F),
    double shadowOpacity = 0.24,
  }) {
    final clampedOpacity = opacity.clamp(0.0, 1.0);
    if (clampedOpacity <= 0.0 || mesh.triangleCount == 0) {
      return;
    }
    _enqueuedMeshes++;

    final vCount = mesh.vertexCount;
    final baseVertex = _vertCount;
    _ensureVertexCapacity(baseVertex + vCount);

    // Rotation matrix R = Rz(yaw) * Ry(pitch) * Rx(roll)
    final cy = math.cos(yawRad);
    final sy = math.sin(yawRad);
    final cp = math.cos(pitchRad);
    final sp = math.sin(pitchRad);
    final cr = math.cos(rollRad);
    final sr = math.sin(rollRad);

    final r00 = cy * cp;
    final r01 = cy * sp * sr - sy * cr;
    final r02 = cy * sp * cr + sy * sr;
    final r10 = sy * cp;
    final r11 = sy * sp * sr + cy * cr;
    final r12 = sy * sp * cr - cy * sr;
    final r20 = -sp;
    final r21 = cp * sr;
    final r22 = cp * cr;

    final invSx = scaleX.abs() > 1e-6 ? 1.0 / scaleX : 1.0;
    final invSy = scaleY.abs() > 1e-6 ? 1.0 / scaleY : 1.0;
    final invSz = scaleZ.abs() > 1e-6 ? 1.0 / scaleZ : 1.0;

    final anchorWorld = camera.gridToScreen(worldX, worldY);
    final positions = mesh.positions;
    final normals = mesh.normals;
    final aoList = mesh.ambientOcclusion;
    final vColors = mesh.vertexColors;

    final tintR = tint.r;
    final tintG = tint.g;
    final tintB = tint.b;
    final tintA = tint.a * clampedOpacity;

    final sunR = light.sunColor.r;
    final sunG = light.sunColor.g;
    final sunB = light.sunColor.b;
    final skyR = light.skyColor.r;
    final skyG = light.skyColor.g;
    final skyB = light.skyColor.b;
    final gndR = light.groundColor.r;
    final gndG = light.groundColor.g;
    final gndB = light.groundColor.b;

    final ambInt = light.ambientIntensity;
    final difInt = light.diffuseIntensity;
    final rimInt = light.rimIntensity;
    final lx = light.dirX;
    final ly = light.dirY;
    final lz = light.dirZ;

    const matCapRes = MatCapShader3D.resolution;

    for (var v = 0; v < vCount; v++) {
      final pIdx = v * 3;
      final lxPos = positions[pIdx] * scaleX;
      final lyPos = positions[pIdx + 1] * scaleY;
      final lzPos = positions[pIdx + 2] * scaleZ;

      final rx = r00 * lxPos + r01 * lyPos + r02 * lzPos;
      final ry = r10 * lxPos + r11 * lyPos + r12 * lzPos;
      final rz = r20 * lxPos + r21 * lyPos + r22 * lzPos + worldZ;

      final (sx, sy) = camera.projectAnchored(
        anchorWorld: anchorWorld,
        canvasOrigin: canvasOrigin,
        rx: rx,
        ry: ry,
        rz: rz,
      );

      final snx = normals[pIdx] * invSx;
      final sny = normals[pIdx + 1] * invSy;
      final snz = normals[pIdx + 2] * invSz;
      var wnx = r00 * snx + r01 * sny + r02 * snz;
      var wny = r10 * snx + r11 * sny + r12 * snz;
      var wnz = r20 * snx + r21 * sny + r22 * snz;
      final nLen = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
      if (nLen > 1e-7) {
        final invN = 1.0 / nLen;
        wnx *= invN;
        wny *= invN;
        wnz *= invN;
      }

      final (vx, vy, vz) = camera.worldNormalToView(wnx, wny, wnz);
      final u = (vx * 0.48 + 0.5).clamp(0.02, 0.98) * matCapRes;
      final texV = (0.5 - vy * 0.48).clamp(0.02, 0.98) * matCapRes;

      final hemiMix = (wnz * 0.5 + 0.5).clamp(0.0, 1.0);
      final ambR = (gndR + (skyR - gndR) * hemiMix) * ambInt;
      final ambG = (gndG + (skyG - gndG) * hemiMix) * ambInt;
      final ambB = (gndB + (skyB - gndB) * hemiMix) * ambInt;

      final nDotL = math.max(0.0, wnx * lx + wny * ly + wnz * lz);
      final rim = math.pow(1.0 - vz.clamp(0.0, 1.0), 2.2) * rimInt;
      final ao = aoList != null ? aoList[v] : 1.0;

      var baseR = tintR;
      var baseG = tintG;
      var baseB = tintB;
      var baseA = tintA;
      if (vColors != null) {
        final vc = vColors[v];
        baseA *= ((vc >>> 24) & 0xFF) / 255.0;
        baseR *= ((vc >>> 16) & 0xFF) / 255.0;
        baseG *= ((vc >>> 8) & 0xFF) / 0xFF;
        baseB *= (vc & 0xFF) / 255.0;
      }

      final lr =
          (baseR * (ambR * ao + sunR * nDotL * difInt + emissive) + rim * skyR)
              .clamp(0.0, 1.0);
      final lg =
          (baseG * (ambG * ao + sunG * nDotL * difInt + emissive) + rim * skyG)
              .clamp(0.0, 1.0);
      final lb =
          (baseB * (ambB * ao + sunB * nDotL * difInt + emissive) + rim * skyB)
              .clamp(0.0, 1.0);

      final outSlot = baseVertex + v;
      _vertX[outSlot] = sx;
      _vertY[outSlot] = sy;
      _vertDepth[outSlot] = camera.viewDepth(worldX + rx, worldY + ry, rz);
      _vertU[outSlot] = u;
      _vertV[outSlot] = texV;
      _vertColor[outSlot] =
          ((baseA * 255.0).round().clamp(0, 255) << 24) |
          ((lr * 255.0).round().clamp(0, 255) << 16) |
          ((lg * 255.0).round().clamp(0, 255) << 8) |
          (lb * 255.0).round().clamp(0, 255);
    }
    _vertCount += vCount;

    final indices = mesh.indices;
    final mTriCount = indices.length ~/ 3;
    _ensureTriangleCapacity(_triCount + mTriCount);

    for (var t = 0; t < mTriCount; t++) {
      final idxBase = t * 3;
      final a = baseVertex + indices[idxBase];
      final b = baseVertex + indices[idxBase + 1];
      final c = baseVertex + indices[idxBase + 2];

      if (backfaceCulling) {
        final ax = _vertX[a];
        final ay = _vertY[a];
        final cross =
            (_vertX[b] - ax) * (_vertY[c] - ay) -
            (_vertY[b] - ay) * (_vertX[c] - ax);
        if (cross <= 1e-3) {
          continue;
        }
      }

      final slot = _triCount++;
      _triV0[slot] = a;
      _triV1[slot] = b;
      _triV2[slot] = c;
      _triDepth[slot] = (_vertDepth[a] + _vertDepth[b] + _vertDepth[c]) / 3.0;
      _triOrder[slot] = slot;
    }

    if (castGroundShadow && shadowOpacity > 0.0 && lz > 0.08) {
      _ensureShadowCapacity(_shadowTriCount + mTriCount);
      final shadowAlpha = (shadowOpacity * clampedOpacity * 255.0)
          .round()
          .clamp(0, 255);
      final shadowArgb =
          (shadowAlpha << 24) | (shadowColor.toARGB32() & 0x00FFFFFF);
      final slopeX = -lx / lz;
      final slopeY = -ly / lz;

      for (var t = 0; t < mTriCount; t++) {
        final idxBase = t * 3;
        final i0 = indices[idxBase] * 3;
        final i1 = indices[idxBase + 1] * 3;
        final i2 = indices[idxBase + 2] * 3;

        (double, double) projectShadowVertex(int pIdx) {
          final lxPos = positions[pIdx] * scaleX;
          final lyPos = positions[pIdx + 1] * scaleY;
          final lzPos = positions[pIdx + 2] * scaleZ;
          final rx = r00 * lxPos + r01 * lyPos + r02 * lzPos;
          final ry = r10 * lxPos + r11 * lyPos + r12 * lzPos;
          final rz = r20 * lxPos + r21 * lyPos + r22 * lzPos + worldZ;
          final dz = math.max(0.0, rz - groundZ);
          return camera.projectAnchored(
            anchorWorld: anchorWorld,
            canvasOrigin: canvasOrigin,
            rx: rx + slopeX * dz,
            ry: ry + slopeY * dz,
            rz: groundZ,
          );
        }

        final (sx0, sy0) = projectShadowVertex(i0);
        final (sx1, sy1) = projectShadowVertex(i1);
        final (sx2, sy2) = projectShadowVertex(i2);

        final pOut = _shadowTriCount * 6;
        final cOut = _shadowTriCount * 3;
        _shadowPositions[pOut] = sx0;
        _shadowPositions[pOut + 1] = sy0;
        _shadowPositions[pOut + 2] = sx1;
        _shadowPositions[pOut + 3] = sy1;
        _shadowPositions[pOut + 4] = sx2;
        _shadowPositions[pOut + 5] = sy2;
        _shadowColors[cOut] = shadowArgb;
        _shadowColors[cOut + 1] = shadowArgb;
        _shadowColors[cOut + 2] = shadowArgb;
        _shadowTriCount++;
      }
    }
  }

  void _sortTrianglesBackToFront(int count) {
    // Ciura gap Shell-sort on _triOrder (zero heap allocations, O(N log N)
    // practical performance, optimal for mostly-ordered 3D scene batches).
    const gaps = <int>[701, 301, 132, 57, 23, 10, 4, 1];
    for (var g = 0; g < gaps.length; g++) {
      final gap = gaps[g];
      if (gap >= count) {
        continue;
      }
      for (var i = gap; i < count; i++) {
        final tempIdx = _triOrder[i];
        final tempDepth = _triDepth[tempIdx];
        var j = i;
        while (j >= gap) {
          final prevIdx = _triOrder[j - gap];
          final prevDepth = _triDepth[prevIdx];
          if (prevDepth <= tempDepth) {
            break;
          }
          _triOrder[j] = prevIdx;
          j -= gap;
        }
        _triOrder[j] = tempIdx;
      }
    }
  }

  /// Submits all accumulated shadow and 3D mesh triangles onto [canvas],
  /// chunking automatically if vertex counts exceed `65535` and disposing all
  /// native `ui.Vertices` handles immediately.
  void flushBatch(
    Canvas canvas, {
    MatCapShader3D? matCapShader,
    MatCapPreset3D? matCapPreset,
  }) {
    _lastFlushTriangles = _triCount;
    _lastFlushShadowTriangles = _shadowTriCount;
    _lastFlushDrawCalls = 0;

    const maxTrisPerChunk = 21840; // 21840 * 3 = 65520 <= 65535 Uint16 limit

    if (_shadowTriCount > 0) {
      _shadowPaint.shader = null;
      var offsetTri = 0;
      while (offsetTri < _shadowTriCount) {
        final chunkTris = math.min(
          maxTrisPerChunk,
          _shadowTriCount - offsetTri,
        );
        final vertLen = chunkTris * 3;
        final vertices = ui.Vertices.raw(
          ui.VertexMode.triangles,
          Float32List.sublistView(
            _shadowPositions,
            offsetTri * 6,
            (offsetTri + chunkTris) * 6,
          ),
          colors: Int32List.sublistView(
            _shadowColors,
            offsetTri * 3,
            (offsetTri + chunkTris) * 3,
          ),
          indices: Uint16List.sublistView(_outIndices, 0, vertLen),
        );
        canvas.drawVertices(vertices, ui.BlendMode.dst, _shadowPaint);
        vertices.dispose();
        _lastFlushDrawCalls++;
        offsetTri += chunkTris;
      }
    }

    if (_triCount > 0) {
      if (_triCount > 1) {
        _sortTrianglesBackToFront(_triCount);
      }

      final useMatCap = matCapShader != null && matCapPreset != null;
      _meshPaint.shader = useMatCap
          ? matCapShader.shaderFor(matCapPreset)
          : null;

      var offsetTri = 0;
      while (offsetTri < _triCount) {
        final chunkTris = math.min(maxTrisPerChunk, _triCount - offsetTri);
        for (var k = 0; k < chunkTris; k++) {
          final tri = _triOrder[offsetTri + k];
          final a = _triV0[tri];
          final b = _triV1[tri];
          final c = _triV2[tri];

          final pOut = k * 6;
          _outPositions[pOut] = _vertX[a];
          _outPositions[pOut + 1] = _vertY[a];
          _outPositions[pOut + 2] = _vertX[b];
          _outPositions[pOut + 3] = _vertY[b];
          _outPositions[pOut + 4] = _vertX[c];
          _outPositions[pOut + 5] = _vertY[c];

          if (useMatCap) {
            _outUvs[pOut] = _vertU[a];
            _outUvs[pOut + 1] = _vertV[a];
            _outUvs[pOut + 2] = _vertU[b];
            _outUvs[pOut + 3] = _vertV[b];
            _outUvs[pOut + 4] = _vertU[c];
            _outUvs[pOut + 5] = _vertV[c];
          }

          final cOut = k * 3;
          _outColors[cOut] = _vertColor[a];
          _outColors[cOut + 1] = _vertColor[b];
          _outColors[cOut + 2] = _vertColor[c];
        }

        final vertLen = chunkTris * 3;
        final vertices = ui.Vertices.raw(
          ui.VertexMode.triangles,
          Float32List.sublistView(_outPositions, 0, chunkTris * 6),
          textureCoordinates: useMatCap
              ? Float32List.sublistView(_outUvs, 0, chunkTris * 6)
              : null,
          colors: Int32List.sublistView(_outColors, 0, vertLen),
          indices: Uint16List.sublistView(_outIndices, 0, vertLen),
        );
        canvas.drawVertices(
          vertices,
          useMatCap ? ui.BlendMode.modulate : ui.BlendMode.dst,
          _meshPaint,
        );
        vertices.dispose();
        _lastFlushDrawCalls++;
        offsetTri += chunkTris;
      }
      _meshPaint.shader = null;
    }

    _vertCount = 0;
    _triCount = 0;
    _shadowTriCount = 0;
    _enqueuedMeshes = 0;
  }
}
