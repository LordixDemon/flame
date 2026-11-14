import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/src/canvas3d/batch_mesh_renderer_3d.dart';
import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/canvas3d/matcap_shader_3d.dart';
import 'package:flame/src/canvas3d/mesh_3d.dart';
import 'package:flame/src/canvas3d/scene_environment_3d.dart';

/// Descriptor for a single static 3D mesh placement inside a
/// [StaticMeshChunk3D].
class const StaticMeshInstance3D({
  required final Mesh3D mesh,
  required final double worldX,
  required final double worldY,
  final double worldZ = 0.0,
  final double scaleX = 1.0,
  final double scaleY = 1.0,
  final double scaleZ = 1.0,
  final double yawRad = 0.0,
  final double pitchRad = 0.0,
  final double rollRad = 0.0,
  final Color tint = const Color(0xFFFFFFFF),
  final double opacity = 1.0,
  final double emissive = 0.0,
  final bool castGroundShadow = false,
  final double groundZ = 0.0,
  final Color shadowColor = const Color(0xFF16131F),
  final double shadowOpacity = 0.24,
});

/// Pre-baked SoA cache for static or semi-static 3D scene geometry (such as
/// terrain tiles, islands, board frames, and resting buildings).
///
/// Separates world/lighting vertex shading (`geometryBakeCount`) from 2D camera
/// screen projection (`projectionBakeCount`):
/// - On stationary camera frames, `BatchMeshRenderer3D.enqueueStaticChunk`
///   copies pre-lit, pre-culled triangles via `setRange` with zero trig,
///   lighting, or projection math.
/// - During pure 2D camera pan/zoom (`camera.basisVersion` and `light`
///   unchanged), world-rotated positions, normals, MatCap UVs, and lit vertex
///   colors remain cached and only fast 2D screen coordinates are refreshed.
class StaticMeshChunk3D() {
  final List<StaticMeshInstance3D> _instances = <StaticMeshInstance3D>[];

  bool _geometryDirty = true;
  bool _projectionDirty = true;
  bool _boundsDirty = true;

  double _boundMinX = 0.0;
  double _boundMinY = 0.0;
  double _boundMinZ = 0.0;
  double _boundMaxX = 0.0;
  double _boundMaxY = 0.0;
  double _boundMaxZ = 0.0;
  double _boundCenterX = 0.0;
  double _boundCenterY = 0.0;
  double _boundCenterZ = 0.0;
  double _boundRadius = 0.0;

  int _cachedBasisVersion = -1;
  int _cachedLightVersion = -1;
  int _cachedEnvSignature = -1;
  int _cachedShadowSignature = -1;
  bool? _cachedBackfaceCulling;
  double _cachedMinTriangleArea = -1.0;
  double _cachedCamX = double.nan;
  double _cachedCamY = double.nan;
  double _cachedPersp = double.nan;
  Offset _cachedOrigin = const Offset(double.nan, double.nan);

  int _geometryBakeCount = 0;
  int _projectionBakeCount = 0;
  int _lastCulledMicroTriangles = 0;

  // Cached world-space & shaded vertex data
  int _totalVertices = 0;
  Float32List _anchorX = Float32List(0);
  Float32List _anchorY = Float32List(0);
  Float32List _rx = Float32List(0);
  Float32List _ry = Float32List(0);
  Float32List _rz = Float32List(0);
  Float32List _worldPosX = Float32List(0);
  Float32List _worldPosY = Float32List(0);
  Float32List _vertU = Float32List(0);
  Float32List _vertV = Float32List(0);
  Int32List _vertColor = Int32List(0);

  // Raw triangle indices into chunk vertices
  int _rawTriCount = 0;
  Int32List _rawTriA = Int32List(0);
  Int32List _rawTriB = Int32List(0);
  Int32List _rawTriC = Int32List(0);

  // Cached shadow world footprints
  int _shadowTriCount = 0;
  Float32List _shAnchorX = Float32List(0);
  Float32List _shAnchorY = Float32List(0);
  Float32List _shRx = Float32List(0);
  Float32List _shRy = Float32List(0);
  Float32List _shGroundZ = Float32List(0);
  Int32List _shArgb = Int32List(0);

  // Projected outputs ready for O(T) copy into BatchMeshRenderer3D
  Float32List projectedVertX = Float32List(0);
  Float32List projectedVertY = Float32List(0);
  Float32List projectedVertDepth = Float32List(0);
  int visibleTriCount = 0;
  Int32List visibleTriA = Int32List(0);
  Int32List visibleTriB = Int32List(0);
  Int32List visibleTriC = Int32List(0);
  Float32List visibleTriDepth = Float32List(0);
  Float32List projectedShadowPositions = Float32List(0);
  Int32List projectedShadowColors = Int32List(0);

  /// Number of static mesh instances registered in this chunk.
  int get instanceCount => _instances.length;

  /// Total vertex count across all registered instances.
  int get vertexCount => _totalVertices;

  /// Number of times world normals, MatCap UVs, and lighting colors were baked.
  int get geometryBakeCount => _geometryBakeCount;

  /// Number of times 2D screen coordinates and backface culling were baked.
  int get projectionBakeCount => _projectionBakeCount;

  /// Sub-pixel micro-triangles culled during the latest projection bake.
  int get lastCulledMicroTriangles => _lastCulledMicroTriangles;

  void _ensureBounds() {
    if (!_boundsDirty) {
      return;
    }
    _boundsDirty = false;
    if (_instances.isEmpty) {
      _boundMinX = 0.0;
      _boundMinY = 0.0;
      _boundMinZ = 0.0;
      _boundMaxX = 0.0;
      _boundMaxY = 0.0;
      _boundMaxZ = 0.0;
      _boundCenterX = 0.0;
      _boundCenterY = 0.0;
      _boundCenterZ = 0.0;
      _boundRadius = 0.0;
      return;
    }
    var loX = double.infinity;
    var loY = double.infinity;
    var loZ = double.infinity;
    var hiX = double.negativeInfinity;
    var hiY = double.negativeInfinity;
    var hiZ = double.negativeInfinity;
    for (var i = 0; i < _instances.length; i++) {
      final inst = _instances[i];
      final maxS = math.max(
        inst.scaleX.abs(),
        math.max(inst.scaleY.abs(), inst.scaleZ.abs()),
      );
      final r = inst.mesh.boundingRadius * maxS;
      if (inst.worldX - r < loX) {
        loX = inst.worldX - r;
      }
      if (inst.worldX + r > hiX) {
        hiX = inst.worldX + r;
      }
      if (inst.worldY - r < loY) {
        loY = inst.worldY - r;
      }
      if (inst.worldY + r > hiY) {
        hiY = inst.worldY + r;
      }
      if (inst.worldZ - r < loZ) {
        loZ = inst.worldZ - r;
      }
      if (inst.worldZ + r > hiZ) {
        hiZ = inst.worldZ + r;
      }
    }
    _boundMinX = loX;
    _boundMinY = loY;
    _boundMinZ = loZ;
    _boundMaxX = hiX;
    _boundMaxY = hiY;
    _boundMaxZ = hiZ;
    _boundCenterX = (loX + hiX) * 0.5;
    _boundCenterY = (loY + hiY) * 0.5;
    _boundCenterZ = (loZ + hiZ) * 0.5;
    final dx = (hiX - loX) * 0.5;
    final dy = (hiY - loY) * 0.5;
    final dz = (hiZ - loZ) * 0.5;
    _boundRadius = math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  /// Cached world-space bounding sphere `(cx, cy, cz, radius)` enclosing all
  /// instances in this chunk.
  (double cx, double cy, double cz, double radius) get worldBoundingSphere {
    _ensureBounds();
    return (_boundCenterX, _boundCenterY, _boundCenterZ, _boundRadius);
  }

  /// Appends [instance] to this chunk and marks cached buffers dirty.
  void addInstance(StaticMeshInstance3D instance) {
    _instances.add(instance);
    _boundsDirty = true;
    invalidate();
  }

  /// Removes all instances from this chunk.
  void clear() {
    _instances.clear();
    _totalVertices = 0;
    _rawTriCount = 0;
    _shadowTriCount = 0;
    visibleTriCount = 0;
    _boundsDirty = true;
    invalidate();
  }

  /// Forces both lighting and screen projection caches to rebuild on next draw.
  void invalidate() {
    _geometryDirty = true;
    _projectionDirty = true;
  }

  /// Ensures cached vertex lighting and 2D screen projections are up to date
  /// for [camera], [light], [canvasOrigin], and [backfaceCulling].
  void prepare({
    required CameraRig3D camera,
    required DirectionalLight3D light,
    required Offset canvasOrigin,
    required bool backfaceCulling,
    SceneEnvironment3D? environment,
    bool shadowsEnabled = true,
    double shadowOpacityMultiplier = 1.0,
    double minTrianglePixelArea = 0.0,
  }) {
    if (_instances.isEmpty) {
      _totalVertices = 0;
      visibleTriCount = 0;
      _shadowTriCount = 0;
      _lastCulledMicroTriangles = 0;
      return;
    }

    _ensureBounds();
    final lightVer = light.computeSignature();
    final envSig = environment != null
        ? environment.computeSignatureForBounds(
            minX: _boundMinX,
            minY: _boundMinY,
            minZ: _boundMinZ,
            maxX: _boundMaxX,
            maxY: _boundMaxY,
            maxZ: _boundMaxZ,
          )
        : 0;
    final shadowSig = shadowsEnabled
        ? (1000 + (shadowOpacityMultiplier.clamp(0.0, 2.0) * 500.0).round())
        : 0;

    if (_geometryDirty ||
        _cachedBasisVersion != camera.basisVersion ||
        _cachedLightVersion != lightVer ||
        _cachedEnvSignature != envSig ||
        _cachedShadowSignature != shadowSig) {
      _bakeGeometryAndLighting(
        camera: camera,
        light: light,
        environment: environment,
        shadowsEnabled: shadowsEnabled,
        shadowOpacityMultiplier: shadowOpacityMultiplier,
      );
      _cachedBasisVersion = camera.basisVersion;
      _cachedLightVersion = lightVer;
      _cachedEnvSignature = envSig;
      _cachedShadowSignature = shadowSig;
      _geometryDirty = false;
      _projectionDirty = true;
    }

    final persp = camera.perspectiveStrength;
    if (_projectionDirty ||
        _cachedBackfaceCulling != backfaceCulling ||
        (minTrianglePixelArea - _cachedMinTriangleArea).abs() > 1e-4 ||
        (camera.camWorldX - _cachedCamX).abs() > 1e-3 ||
        (camera.camWorldY - _cachedCamY).abs() > 1e-3 ||
        (persp - _cachedPersp).abs() > 1e-6 ||
        canvasOrigin != _cachedOrigin) {
      _bakeScreenProjection(
        camera: camera,
        canvasOrigin: canvasOrigin,
        backfaceCulling: backfaceCulling,
        minTrianglePixelArea: minTrianglePixelArea,
      );
      _cachedBackfaceCulling = backfaceCulling;
      _cachedMinTriangleArea = minTrianglePixelArea;
      _cachedCamX = camera.camWorldX;
      _cachedCamY = camera.camWorldY;
      _cachedPersp = persp;
      _cachedOrigin = canvasOrigin;
      _projectionDirty = false;
    }
  }

  void _bakeGeometryAndLighting({
    required CameraRig3D camera,
    required DirectionalLight3D light,
    required SceneEnvironment3D? environment,
    required bool shadowsEnabled,
    required double shadowOpacityMultiplier,
  }) {
    _geometryBakeCount++;

    var vTotal = 0;
    var tTotal = 0;
    var sTotal = 0;
    final lz = light.dirZ;
    final shScale = shadowsEnabled
        ? shadowOpacityMultiplier.clamp(0.0, 2.0)
        : 0.0;
    for (var i = 0; i < _instances.length; i++) {
      final inst = _instances[i];
      if (inst.opacity <= 0.0 || inst.mesh.triangleCount == 0) {
        continue;
      }
      vTotal += inst.mesh.vertexCount;
      tTotal += inst.mesh.triangleCount;
      if (inst.castGroundShadow &&
          inst.shadowOpacity * shScale > 0.0 &&
          lz > 0.08) {
        sTotal += inst.mesh.triangleCount;
      }
    }

    if (_anchorX.length < vTotal) {
      _anchorX = Float32List(vTotal);
      _anchorY = Float32List(vTotal);
      _rx = Float32List(vTotal);
      _ry = Float32List(vTotal);
      _rz = Float32List(vTotal);
      _worldPosX = Float32List(vTotal);
      _worldPosY = Float32List(vTotal);
      _vertU = Float32List(vTotal);
      _vertV = Float32List(vTotal);
      _vertColor = Int32List(vTotal);
      projectedVertX = Float32List(vTotal);
      projectedVertY = Float32List(vTotal);
      projectedVertDepth = Float32List(vTotal);
    }
    if (_rawTriA.length < tTotal) {
      _rawTriA = Int32List(tTotal);
      _rawTriB = Int32List(tTotal);
      _rawTriC = Int32List(tTotal);
      visibleTriA = Int32List(tTotal);
      visibleTriB = Int32List(tTotal);
      visibleTriC = Int32List(tTotal);
      visibleTriDepth = Float32List(tTotal);
    }
    if (_shArgb.length < sTotal) {
      _shAnchorX = Float32List(sTotal);
      _shAnchorY = Float32List(sTotal);
      _shRx = Float32List(sTotal * 3);
      _shRy = Float32List(sTotal * 3);
      _shGroundZ = Float32List(sTotal);
      _shArgb = Int32List(sTotal);
      projectedShadowPositions = Float32List(sTotal * 6);
      projectedShadowColors = Int32List(sTotal * 3);
    }

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
    const matCapRes = MatCapShader3D.resolution;

    var vCursor = 0;
    var tCursor = 0;
    var sCursor = 0;

    for (var i = 0; i < _instances.length; i++) {
      final inst = _instances[i];
      final clampedOpacity = inst.opacity.clamp(0.0, 1.0);
      if (clampedOpacity <= 0.0 || inst.mesh.triangleCount == 0) {
        continue;
      }
      final mesh = inst.mesh;
      final baseVert = vCursor;

      final cy = math.cos(inst.yawRad);
      final sy = math.sin(inst.yawRad);
      final cp = math.cos(inst.pitchRad);
      final sp = math.sin(inst.pitchRad);
      final cr = math.cos(inst.rollRad);
      final sr = math.sin(inst.rollRad);

      final r00 = cy * cp;
      final r01 = cy * sp * sr - sy * cr;
      final r02 = cy * sp * cr + sy * sr;
      final r10 = sy * cp;
      final r11 = sy * sp * sr + cy * cr;
      final r12 = sy * sp * cr - cy * sr;
      final r20 = -sp;
      final r21 = cp * sr;
      final r22 = cp * cr;

      final invSx = inst.scaleX.abs() > 1e-6 ? 1.0 / inst.scaleX : 1.0;
      final invSy = inst.scaleY.abs() > 1e-6 ? 1.0 / inst.scaleY : 1.0;
      final invSz = inst.scaleZ.abs() > 1e-6 ? 1.0 / inst.scaleZ : 1.0;

      final anchor = camera.gridToScreen(inst.worldX, inst.worldY);
      final positions = mesh.positions;
      final normals = mesh.normals;
      final aoList = mesh.ambientOcclusion;
      final vColors = mesh.vertexColors;

      final tintR = inst.tint.r;
      final tintG = inst.tint.g;
      final tintB = inst.tint.b;
      final tintA = inst.tint.a * clampedOpacity;

      final vCount = mesh.vertexCount;
      for (var v = 0; v < vCount; v++) {
        final pIdx = v * 3;
        final lxPos = positions[pIdx] * inst.scaleX;
        final lyPos = positions[pIdx + 1] * inst.scaleY;
        final lzPos = positions[pIdx + 2] * inst.scaleZ;

        final rx = r00 * lxPos + r01 * lyPos + r02 * lzPos;
        final ry = r10 * lxPos + r11 * lyPos + r12 * lzPos;
        final rz = r20 * lxPos + r21 * lyPos + r22 * lzPos + inst.worldZ;
        final wx = inst.worldX + rx;
        final wy = inst.worldY + ry;

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
          baseG *= ((vc >>> 8) & 0xFF) / 255.0;
          baseB *= (vc & 0xFF) / 255.0;
        }

        var ptR = 0.0;
        var ptG = 0.0;
        var ptB = 0.0;
        if (environment != null && environment.pointLightCount > 0) {
          (ptR, ptG, ptB) = environment.samplePointLights(
            wx: wx,
            wy: wy,
            wz: rz,
            nx: wnx,
            ny: wny,
            nz: wnz,
          );
        }

        var lr =
            (baseR * (ambR * ao + sunR * nDotL * difInt + ptR + inst.emissive) +
                    rim * skyR)
                .clamp(0.0, 1.0);
        var lg =
            (baseG * (ambG * ao + sunG * nDotL * difInt + ptG + inst.emissive) +
                    rim * skyG)
                .clamp(0.0, 1.0);
        var lb =
            (baseB * (ambB * ao + sunB * nDotL * difInt + ptB + inst.emissive) +
                    rim * skyB)
                .clamp(0.0, 1.0);

        if (environment != null && environment.fogEnabled) {
          final vDepth = camera.viewDepth(wx, wy, rz);
          final fog = environment.computeFogFactor(
            viewDepth: vDepth,
            worldZ: rz,
          );
          if (fog > 0.0) {
            lr += (environment.fogColor.r - lr) * fog;
            lg += (environment.fogColor.g - lg) * fog;
            lb += (environment.fogColor.b - lb) * fog;
          }
        }

        final slot = vCursor++;
        _anchorX[slot] = anchor.dx;
        _anchorY[slot] = anchor.dy;
        _rx[slot] = rx;
        _ry[slot] = ry;
        _rz[slot] = rz;
        _worldPosX[slot] = wx;
        _worldPosY[slot] = wy;
        _vertU[slot] = u;
        _vertV[slot] = texV;
        _vertColor[slot] =
            ((baseA * 255.0).round().clamp(0, 255) << 24) |
            ((lr * 255.0).round().clamp(0, 255) << 16) |
            ((lg * 255.0).round().clamp(0, 255) << 8) |
            (lb * 255.0).round().clamp(0, 255);
      }

      final indices = mesh.indices;
      final mTriCount = indices.length ~/ 3;
      for (var t = 0; t < mTriCount; t++) {
        final idxBase = t * 3;
        _rawTriA[tCursor] = baseVert + indices[idxBase];
        _rawTriB[tCursor] = baseVert + indices[idxBase + 1];
        _rawTriC[tCursor] = baseVert + indices[idxBase + 2];
        tCursor++;
      }

      final effShOpacity = inst.shadowOpacity * shScale;
      if (inst.castGroundShadow && effShOpacity > 0.0 && lz > 0.08) {
        final shadowAlpha = (effShOpacity * clampedOpacity * 255.0)
            .round()
            .clamp(0, 255);
        final shadowArgb =
            (shadowAlpha << 24) | (inst.shadowColor.toARGB32() & 0x00FFFFFF);
        final slopeX = -lx / lz;
        final slopeY = -ly / lz;

        for (var t = 0; t < mTriCount; t++) {
          final idxBase = t * 3;
          final sSlot = sCursor++;
          _shAnchorX[sSlot] = anchor.dx;
          _shAnchorY[sSlot] = anchor.dy;
          _shGroundZ[sSlot] = inst.groundZ;
          _shArgb[sSlot] = shadowArgb;

          for (var corner = 0; corner < 3; corner++) {
            final vSlot = baseVert + indices[idxBase + corner];
            final dz = math.max(0.0, _rz[vSlot] - inst.groundZ);
            _shRx[sSlot * 3 + corner] = _rx[vSlot] + slopeX * dz;
            _shRy[sSlot * 3 + corner] = _ry[vSlot] + slopeY * dz;
          }
        }
      }
    }

    _totalVertices = vCursor;
    _rawTriCount = tCursor;
    _shadowTriCount = sCursor;
  }

  void _bakeScreenProjection({
    required CameraRig3D camera,
    required Offset canvasOrigin,
    required bool backfaceCulling,
    required double minTrianglePixelArea,
  }) {
    _projectionBakeCount++;
    _lastCulledMicroTriangles = 0;

    for (var v = 0; v < _totalVertices; v++) {
      final (sx, sy) = camera.projectAnchored(
        anchorWorld: Offset(_anchorX[v], _anchorY[v]),
        canvasOrigin: canvasOrigin,
        rx: _rx[v],
        ry: _ry[v],
        rz: _rz[v],
      );
      projectedVertX[v] = sx;
      projectedVertY[v] = sy;
      projectedVertDepth[v] = camera.viewDepth(
        _worldPosX[v],
        _worldPosY[v],
        _rz[v],
      );
    }

    var visCount = 0;
    for (var t = 0; t < _rawTriCount; t++) {
      final a = _rawTriA[t];
      final b = _rawTriB[t];
      final c = _rawTriC[t];
      final ax = projectedVertX[a];
      final ay = projectedVertY[a];
      final cross =
          (projectedVertX[b] - ax) * (projectedVertY[c] - ay) -
          (projectedVertY[b] - ay) * (projectedVertX[c] - ax);
      if (backfaceCulling && cross <= 1e-3) {
        continue;
      }
      if (minTrianglePixelArea > 0.0 &&
          cross.abs() * 0.5 < minTrianglePixelArea) {
        _lastCulledMicroTriangles++;
        continue;
      }
      visibleTriA[visCount] = a;
      visibleTriB[visCount] = b;
      visibleTriC[visCount] = c;
      visibleTriDepth[visCount] =
          (projectedVertDepth[a] +
              projectedVertDepth[b] +
              projectedVertDepth[c]) /
          3.0;
      visCount++;
    }
    visibleTriCount = visCount;

    for (var s = 0; s < _shadowTriCount; s++) {
      final anchor = Offset(_shAnchorX[s], _shAnchorY[s]);
      final gz = _shGroundZ[s];
      final argb = _shArgb[s];
      final pOut = s * 6;
      final cOut = s * 3;
      for (var corner = 0; corner < 3; corner++) {
        final (sx, sy) = camera.projectAnchored(
          anchorWorld: anchor,
          canvasOrigin: canvasOrigin,
          rx: _shRx[s * 3 + corner],
          ry: _shRy[s * 3 + corner],
          rz: gz,
        );
        projectedShadowPositions[pOut + corner * 2] = sx;
        projectedShadowPositions[pOut + corner * 2 + 1] = sy;
      }
      projectedShadowColors[cOut] = argb;
      projectedShadowColors[cOut + 1] = argb;
      projectedShadowColors[cOut + 2] = argb;
    }
  }

  /// Internal accessor exposing cached UVs/colors/shadow count to
  /// [BatchMeshRenderer3D].
  (Float32List u, Float32List v, Int32List colors, int shadowTris)
  internalBuffers() => (_vertU, _vertV, _vertColor, _shadowTriCount);
}
