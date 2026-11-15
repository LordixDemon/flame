import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/canvas3d/lighting_kernel_3d.dart';
import 'package:flame/src/canvas3d/material_3d.dart';
import 'package:flame/src/canvas3d/mesh_3d.dart';
import 'package:flame/src/canvas3d/primitives_3d.dart';
import 'package:flame/src/canvas3d/scene_environment_3d.dart';
import 'package:flame/src/game/game.dart';

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
  final (double, double, double, double)? rotationQuat,
  final Color tint = const Color(0xFFFFFFFF),
  final double opacity = 1.0,
  final double emissive = 0.0,
  final Rect? uvRectPx,
  final Material3D? material,
  final bool visible = true,
  final bool castGroundShadow = false,
  final double groundZ = 0.0,
  final Color shadowColor = const Color(0xFF16131F),
  final double shadowOpacity = 0.24,
}) {
  /// Returns a modified copy of this instance descriptor.
  StaticMeshInstance3D copyWith({
    Mesh3D? mesh,
    double? worldX,
    double? worldY,
    double? worldZ,
    double? scaleX,
    double? scaleY,
    double? scaleZ,
    double? yawRad,
    double? pitchRad,
    double? rollRad,
    (double, double, double, double)? rotationQuat,
    bool clearRotationQuat = false,
    Color? tint,
    double? opacity,
    double? emissive,
    Rect? uvRectPx,
    bool clearUvRectPx = false,
    Material3D? material,
    bool clearMaterial = false,
    bool? visible,
    bool? castGroundShadow,
    double? groundZ,
    Color? shadowColor,
    double? shadowOpacity,
  }) {
    return StaticMeshInstance3D(
      mesh: mesh ?? this.mesh,
      worldX: worldX ?? this.worldX,
      worldY: worldY ?? this.worldY,
      worldZ: worldZ ?? this.worldZ,
      scaleX: scaleX ?? this.scaleX,
      scaleY: scaleY ?? this.scaleY,
      scaleZ: scaleZ ?? this.scaleZ,
      yawRad: yawRad ?? this.yawRad,
      pitchRad: pitchRad ?? this.pitchRad,
      rollRad: rollRad ?? this.rollRad,
      rotationQuat: clearRotationQuat
          ? null
          : (rotationQuat ?? this.rotationQuat),
      tint: tint ?? this.tint,
      opacity: opacity ?? this.opacity,
      emissive: emissive ?? this.emissive,
      uvRectPx: clearUvRectPx ? null : (uvRectPx ?? this.uvRectPx),
      material: clearMaterial ? null : (material ?? this.material),
      visible: visible ?? this.visible,
      castGroundShadow: castGroundShadow ?? this.castGroundShadow,
      groundZ: groundZ ?? this.groundZ,
      shadowColor: shadowColor ?? this.shadowColor,
      shadowOpacity: shadowOpacity ?? this.shadowOpacity,
    );
  }
}

/// Pre-baked SoA cache for static or semi-static 3D scene geometry (such as
/// terrain tiles, islands, board frames, and resting buildings).
///
/// Separates world/lighting vertex shading (`geometryBakeCount`) from 2D camera
/// screen projection (`projectionBakeCount`), preserves UV texture coordinates
/// and per-instance [Material3D] assignments, and supports surgical `O(V_slot)`
/// partial slot updates via [updateInstance].
class StaticMeshChunk3D() {
  final List<StaticMeshInstance3D> _instances = <StaticMeshInstance3D>[];
  final Set<int> _dirtySlots = <int>{};
  final Float32List _rotScratch = Float32List(9);

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
  int _partialSlotRebakeCount = 0;
  int _projectionBakeCount = 0;
  int _lastCulledMicroTriangles = 0;

  // Per-slot slices inside baked buffers for O(V_slot) partial updates
  Int32List _slotVertStart = Int32List(0);
  Int32List _slotVertCap = Int32List(0);
  Int32List _slotTriStart = Int32List(0);
  Int32List _slotTriCap = Int32List(0);
  Uint8List _slotTriActive = Uint8List(0);
  Int32List _slotShadowStart = Int32List(0);
  Int32List _slotShadowCap = Int32List(0);
  Int32List _slotShadowActiveCount = Int32List(0);

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
  Float32List _vertTexU = Float32List(0);
  Float32List _vertTexV = Float32List(0);
  Uint8List _vertTexPixelSpace = Uint8List(0);
  Int32List _vertColor = Int32List(0);

  // Raw triangle indices into chunk vertices + per-triangle material index
  int _rawTriCount = 0;
  Int32List _rawTriA = Int32List(0);
  Int32List _rawTriB = Int32List(0);
  Int32List _rawTriC = Int32List(0);
  Int32List _rawTriOwnerSlot = Int32List(0);
  Uint16List _rawTriMatIdx = Uint16List(0);
  final List<Material3D?> _chunkMaterials = <Material3D?>[null];

  // Cached shadow world footprints
  Float32List _shAnchorX = Float32List(0);
  Float32List _shAnchorY = Float32List(0);
  Float32List _shRx = Float32List(0);
  Float32List _shRy = Float32List(0);
  Float32List _shGroundZ = Float32List(0);
  Int32List _shCornerArgb = Int32List(0);
  Uint8List _shActive = Uint8List(0);

  // Projected outputs ready for O(T) copy into BatchMeshRenderer3D
  Float32List projectedVertX = Float32List(0);
  Float32List projectedVertY = Float32List(0);
  Float32List projectedVertDepth = Float32List(0);
  int visibleTriCount = 0;
  Int32List visibleTriA = Int32List(0);
  Int32List visibleTriB = Int32List(0);
  Int32List visibleTriC = Int32List(0);
  Float32List visibleTriDepth = Float32List(0);
  Uint16List visibleTriMatIdx = Uint16List(0);
  int projectedShadowTriCount = 0;
  Float32List projectedShadowPositions = Float32List(0);
  Int32List projectedShadowColors = Int32List(0);

  /// Number of static mesh instances registered in this chunk.
  int get instanceCount => _instances.length;

  /// Total vertex count across all registered instances.
  int get vertexCount => _totalVertices;

  /// Number of full chunk geometry/lighting bakes executed.
  int get geometryBakeCount => _geometryBakeCount;

  /// Number of surgical single-slot partial rebakes executed via
  /// [updateInstance] or [setInstanceVisible] without rebuilding the full
  /// chunk.
  int get partialSlotRebakeCount => _partialSlotRebakeCount;

  /// Number of times 2D screen coordinates and backface culling were baked.
  int get projectionBakeCount => _projectionBakeCount;

  /// Sub-pixel micro-triangles culled during the latest projection bake.
  int get lastCulledMicroTriangles => _lastCulledMicroTriangles;

  /// Reads the instance descriptor currently stored at [slot].
  StaticMeshInstance3D instanceAt(int slot) => _instances[slot];

  int _internChunkMaterial(Material3D? mat) =>
      LightingKernel3D.internMaterial(_chunkMaterials, mat);

  /// Deduplicated chunk material table (`index 0` is `null` default material).
  List<Material3D?> get materials => _chunkMaterials;

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
    var anyVisible = false;
    for (var i = 0; i < _instances.length; i++) {
      final inst = _instances[i];
      if (!inst.visible || inst.opacity <= 0.0) {
        continue;
      }
      anyVisible = true;
      final maxS = math.max(
        inst.scaleX.abs(),
        math.max(inst.scaleY.abs(), inst.scaleZ.abs()),
      );
      final r = inst.mesh.boundingRadius * maxS;
      if (inst.worldX - r < loX) {
        loX = inst.worldX - r;
      }
      if (inst.worldY - r < loY) {
        loY = inst.worldY - r;
      }
      if (inst.worldZ - r < loZ) {
        loZ = inst.worldZ - r;
      }
      if (inst.worldX + r > hiX) {
        hiX = inst.worldX + r;
      }
      if (inst.worldY + r > hiY) {
        hiY = inst.worldY + r;
      }
      if (inst.worldZ + r > hiZ) {
        hiZ = inst.worldZ + r;
      }
    }
    if (!anyVisible) {
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

  /// World-space bounding sphere `(cx, cy, cz, radius)` enclosing all visible
  /// instances in this chunk.
  (double cx, double cy, double cz, double radius) get worldBoundingSphere {
    _ensureBounds();
    return (_boundCenterX, _boundCenterY, _boundCenterZ, _boundRadius);
  }

  /// Appends [instance] to this chunk, marks geometry dirty, and returns its
  /// `0`-based slot handle for subsequent `O(V_slot)` [updateInstance] calls.
  int addInstance(StaticMeshInstance3D instance) {
    final slot = _instances.length;
    _instances.add(instance);
    _geometryDirty = true;
    _boundsDirty = true;
    Game.notifyVisualMutation();
    return slot;
  }

  /// Shorthand alias for [addInstance].
  int add(StaticMeshInstance3D instance) => addInstance(instance);

  /// Appends all [instances] and marks geometry dirty.
  void addAll(Iterable<StaticMeshInstance3D> instances) {
    _instances.addAll(instances);
    _geometryDirty = true;
    _boundsDirty = true;
    Game.notifyVisualMutation();
  }

  /// Surgically updates the instance at [slot].
  ///
  /// When the chunk has already been baked once and [next] has identical vertex
  /// count, triangle count, and shadow-slot reservation (`castGroundShadow`),
  /// only [slot]'s slice is re-shaded on the next [prepare] (`O(V_slot)`),
  /// avoiding a full-chunk geometry rebuild.
  void updateInstance(int slot, StaticMeshInstance3D next) {
    RangeError.checkValidIndex(slot, _instances, 'slot');
    final prev = _instances[slot];
    _instances[slot] = next;
    _boundsDirty = true;
    Game.notifyVisualMutation();
    if (_geometryDirty || slot >= _slotVertCap.length) {
      _geometryDirty = true;
      return;
    }
    final prevShadowCap = prev.castGroundShadow ? prev.mesh.triangleCount : 0;
    final nextShadowCap = next.castGroundShadow ? next.mesh.triangleCount : 0;
    if (prev.mesh.vertexCount == next.mesh.vertexCount &&
        prev.mesh.triangleCount == next.mesh.triangleCount &&
        prevShadowCap == nextShadowCap) {
      _dirtySlots.add(slot);
      _projectionDirty = true;
    } else {
      _geometryDirty = true;
    }
  }

  /// Toggles visibility of [slot] in `O(1)` without rebuilding other instances.
  void setInstanceVisible(int slot, {required bool visible}) {
    RangeError.checkValidIndex(slot, _instances, 'slot');
    final cur = _instances[slot];
    if (cur.visible == visible) {
      return;
    }
    updateInstance(slot, cur.copyWith(visible: visible));
  }

  /// Removes all instances and resets dirty flags.
  void clear() {
    if (_instances.isNotEmpty) {
      Game.notifyVisualMutation();
    }
    _instances.clear();
    _dirtySlots.clear();
    _chunkMaterials
      ..clear()
      ..add(null);
    _totalVertices = 0;
    _rawTriCount = 0;
    visibleTriCount = 0;
    projectedShadowTriCount = 0;
    _geometryDirty = true;
    _projectionDirty = true;
    _boundsDirty = true;
  }

  /// Explicitly forces a full geometry + lighting rebake on the next [prepare]
  /// call.
  void markDirty() {
    _geometryDirty = true;
    _boundsDirty = true;
  }

  /// Ensures world lighting and 2D screen projections are up to date for
  /// [camera], [light], and [environment].
  void prepare({
    required CameraRig3D camera,
    required DirectionalLight3D light,
    SceneEnvironment3D? environment,
    bool shadowsEnabled = true,
    double shadowOpacityMultiplier = 1.0,
    bool cullBackfaceShadows = true,
    double shadowHeightFalloff = 0.0,
    double minTrianglePixelArea = 0.0,
    Offset canvasOrigin = Offset.zero,
    bool backfaceCulling = true,
  }) {
    if (_instances.isEmpty) {
      _totalVertices = 0;
      visibleTriCount = 0;
      projectedShadowTriCount = 0;
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
        ? (1000 +
              (shadowOpacityMultiplier.clamp(0.0, 2.0) * 500.0).round() * 31 +
              (cullBackfaceShadows ? 17 : 3) +
              (shadowHeightFalloff * 1000.0).round() * 7)
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
        cullBackfaceShadows: cullBackfaceShadows,
        shadowHeightFalloff: shadowHeightFalloff,
      );
      _dirtySlots.clear();
      _cachedBasisVersion = camera.basisVersion;
      _cachedLightVersion = lightVer;
      _cachedEnvSignature = envSig;
      _cachedShadowSignature = shadowSig;
      _geometryDirty = false;
      _projectionDirty = true;
    } else if (_dirtySlots.isNotEmpty) {
      for (final slot in _dirtySlots) {
        _bakeSingleSlot(
          slot: slot,
          camera: camera,
          light: light,
          environment: environment,
          shadowsEnabled: shadowsEnabled,
          shadowOpacityMultiplier: shadowOpacityMultiplier,
          cullBackfaceShadows: cullBackfaceShadows,
          shadowHeightFalloff: shadowHeightFalloff,
        );
        _partialSlotRebakeCount++;
      }
      _dirtySlots.clear();
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
    required bool cullBackfaceShadows,
    required double shadowHeightFalloff,
  }) {
    _geometryBakeCount++;
    _chunkMaterials
      ..clear()
      ..add(null);

    final iCount = _instances.length;
    if (_slotVertCap.length < iCount) {
      _slotVertStart = Int32List(iCount);
      _slotVertCap = Int32List(iCount);
      _slotTriStart = Int32List(iCount);
      _slotTriCap = Int32List(iCount);
      _slotTriActive = Uint8List(iCount);
      _slotShadowStart = Int32List(iCount);
      _slotShadowCap = Int32List(iCount);
      _slotShadowActiveCount = Int32List(iCount);
    }

    var vTotal = 0;
    var tTotal = 0;
    var sTotal = 0;
    for (var i = 0; i < iCount; i++) {
      final inst = _instances[i];
      final vc = inst.mesh.vertexCount;
      final tc = inst.mesh.triangleCount;
      final sc = inst.castGroundShadow ? tc : 0;
      _slotVertStart[i] = vTotal;
      _slotVertCap[i] = vc;
      _slotTriStart[i] = tTotal;
      _slotTriCap[i] = tc;
      _slotShadowStart[i] = sTotal;
      _slotShadowCap[i] = sc;
      vTotal += vc;
      tTotal += tc;
      sTotal += sc;
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
      _vertTexU = Float32List(vTotal);
      _vertTexV = Float32List(vTotal);
      _vertTexPixelSpace = Uint8List(vTotal);
      _vertColor = Int32List(vTotal);
      projectedVertX = Float32List(vTotal);
      projectedVertY = Float32List(vTotal);
      projectedVertDepth = Float32List(vTotal);
    }
    if (_rawTriA.length < tTotal) {
      _rawTriA = Int32List(tTotal);
      _rawTriB = Int32List(tTotal);
      _rawTriC = Int32List(tTotal);
      _rawTriOwnerSlot = Int32List(tTotal);
      _rawTriMatIdx = Uint16List(tTotal);
      visibleTriA = Int32List(tTotal);
      visibleTriB = Int32List(tTotal);
      visibleTriC = Int32List(tTotal);
      visibleTriDepth = Float32List(tTotal);
      visibleTriMatIdx = Uint16List(tTotal);
    }
    if (_shAnchorX.length < sTotal) {
      _shAnchorX = Float32List(sTotal);
      _shAnchorY = Float32List(sTotal);
      _shRx = Float32List(sTotal * 3);
      _shRy = Float32List(sTotal * 3);
      _shGroundZ = Float32List(sTotal);
      _shCornerArgb = Int32List(sTotal * 3);
      _shActive = Uint8List(sTotal);
      projectedShadowPositions = Float32List(sTotal * 6);
      projectedShadowColors = Int32List(sTotal * 3);
    }

    _totalVertices = vTotal;
    _rawTriCount = tTotal;

    for (var i = 0; i < iCount; i++) {
      _bakeSingleSlot(
        slot: i,
        camera: camera,
        light: light,
        environment: environment,
        shadowsEnabled: shadowsEnabled,
        shadowOpacityMultiplier: shadowOpacityMultiplier,
        cullBackfaceShadows: cullBackfaceShadows,
        shadowHeightFalloff: shadowHeightFalloff,
      );
    }
  }

  void _bakeSingleSlot({
    required int slot,
    required CameraRig3D camera,
    required DirectionalLight3D light,
    required SceneEnvironment3D? environment,
    required bool shadowsEnabled,
    required double shadowOpacityMultiplier,
    required bool cullBackfaceShadows,
    required double shadowHeightFalloff,
  }) {
    final inst = _instances[slot];
    final baseVert = _slotVertStart[slot];
    final baseTri = _slotTriStart[slot];
    final baseSh = _slotShadowStart[slot];
    final shCap = _slotShadowCap[slot];

    if (shCap > 0) {
      _shActive.fillRange(baseSh, baseSh + shCap, 0);
    }
    _slotShadowActiveCount[slot] = 0;

    final clampedOpacity = inst.opacity.clamp(0.0, 1.0);
    if (!inst.visible ||
        clampedOpacity <= 0.0 ||
        inst.mesh.triangleCount == 0) {
      _slotTriActive[slot] = 0;
      return;
    }
    _slotTriActive[slot] = 1;

    final mesh = inst.mesh;
    LightingKernel3D.resolveRotationMatrix3(
      out: _rotScratch,
      rotationQuat: inst.rotationQuat,
      yawRad: inst.yawRad,
      pitchRad: inst.pitchRad,
      rollRad: inst.rollRad,
    );
    final r00 = _rotScratch[0];
    final r01 = _rotScratch[1];
    final r02 = _rotScratch[2];
    final r10 = _rotScratch[3];
    final r11 = _rotScratch[4];
    final r12 = _rotScratch[5];
    final r20 = _rotScratch[6];
    final r21 = _rotScratch[7];
    final r22 = _rotScratch[8];

    final invSx = inst.scaleX.abs() > 1e-6 ? 1.0 / inst.scaleX : 1.0;
    final invSy = inst.scaleY.abs() > 1e-6 ? 1.0 / inst.scaleY : 1.0;
    final invSz = inst.scaleZ.abs() > 1e-6 ? 1.0 / inst.scaleZ : 1.0;

    final lx = light.dirX;
    final ly = light.dirY;
    final lz = light.dirZ;

    final anchor = camera.gridToScreen(inst.worldX, inst.worldY);
    final positions = mesh.positions;
    final normals = mesh.normals;
    final meshUvs = mesh.uvs;
    final uvRect = inst.uvRectPx;
    final aoList = mesh.ambientOcclusion;
    final vColors = mesh.vertexColors;

    final tintR = inst.tint.r;
    final tintG = inst.tint.g;
    final tintB = inst.tint.b;
    final tintA = inst.tint.a * clampedOpacity;
    final hasFog = environment != null && environment.fogEnabled;

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
      final vDepth = hasFog ? camera.viewDepth(wx, wy, rz) : 0.0;

      final vSlot = baseVert + v;
      _anchorX[vSlot] = anchor.dx;
      _anchorY[vSlot] = anchor.dy;
      _rx[vSlot] = rx;
      _ry[vSlot] = ry;
      _rz[vSlot] = rz;
      _worldPosX[vSlot] = wx;
      _worldPosY[vSlot] = wy;

      LightingKernel3D.shadeVertexInto(
        vertexIndex: v,
        outSlot: vSlot,
        normals: normals,
        rot: _rotScratch,
        invSx: invSx,
        invSy: invSy,
        invSz: invSz,
        worldPosX: wx,
        worldPosY: wy,
        worldPosZ: rz,
        viewDepth: vDepth,
        camera: camera,
        light: light,
        environment: environment,
        tintR: tintR,
        tintG: tintG,
        tintB: tintB,
        tintA: tintA,
        emissive: inst.emissive,
        outVertU: _vertU,
        outVertV: _vertV,
        outVertTexU: _vertTexU,
        outVertTexV: _vertTexV,
        outVertTexPixelSpace: _vertTexPixelSpace,
        outVertColor: _vertColor,
        uvs: meshUvs,
        uvRectPx: uvRect,
        ambientOcclusion: aoList,
        vertexColors: vColors,
      );
    }

    final matIdx = _internChunkMaterial(inst.material);
    final indices = mesh.indices;
    final mTriCount = indices.length ~/ 3;
    final reverseWinding = (inst.scaleX * inst.scaleY * inst.scaleZ) < 0.0;
    for (var t = 0; t < mTriCount; t++) {
      final idxBase = t * 3;
      final tSlot = baseTri + t;
      _rawTriA[tSlot] = baseVert + indices[idxBase];
      if (reverseWinding) {
        _rawTriB[tSlot] = baseVert + indices[idxBase + 2];
        _rawTriC[tSlot] = baseVert + indices[idxBase + 1];
      } else {
        _rawTriB[tSlot] = baseVert + indices[idxBase + 1];
        _rawTriC[tSlot] = baseVert + indices[idxBase + 2];
      }
      _rawTriOwnerSlot[tSlot] = slot;
      _rawTriMatIdx[tSlot] = matIdx;
    }

    final shScale = shadowsEnabled
        ? shadowOpacityMultiplier.clamp(0.0, 2.0)
        : 0.0;
    final effShOpacity = inst.shadowOpacity * shScale;
    if (inst.castGroundShadow && effShOpacity > 0.0 && lz > 0.08 && shCap > 0) {
      final baseShadowAlpha = effShOpacity * clampedOpacity * 255.0;
      final shadowRgb = inst.shadowColor.toARGB32() & 0x00FFFFFF;
      final slopeX = -lx / lz;
      final slopeY = -ly / lz;
      var activeSh = 0;

      for (var t = 0; t < mTriCount; t++) {
        final idxBase = t * 3;
        final v0 = baseVert + indices[idxBase];
        final v1 = baseVert + indices[idxBase + (reverseWinding ? 2 : 1)];
        final v2 = baseVert + indices[idxBase + (reverseWinding ? 1 : 2)];

        if (cullBackfaceShadows) {
          final e1x = _rx[v1] - _rx[v0];
          final e1y = _ry[v1] - _ry[v0];
          final e1z = _rz[v1] - _rz[v0];
          final e2x = _rx[v2] - _rx[v0];
          final e2y = _ry[v2] - _ry[v0];
          final e2z = _rz[v2] - _rz[v0];
          final fnx = e1y * e2z - e1z * e2y;
          final fny = e1z * e2x - e1x * e2z;
          final fnz = e1x * e2y - e1y * e2x;
          if (fnx * lx + fny * ly + fnz * lz <= 1e-6) {
            continue;
          }
        }

        final sSlot = baseSh + activeSh;
        activeSh++;
        _shActive[sSlot] = 1;
        _shAnchorX[sSlot] = anchor.dx;
        _shAnchorY[sSlot] = anchor.dy;
        _shGroundZ[sSlot] = inst.groundZ;

        for (var corner = 0; corner < 3; corner++) {
          final vSlot = baseVert + indices[idxBase + corner];
          final dz = math.max(0.0, _rz[vSlot] - inst.groundZ);
          _shRx[sSlot * 3 + corner] = _rx[vSlot] + slopeX * dz;
          _shRy[sSlot * 3 + corner] = _ry[vSlot] + slopeY * dz;
          final atten = shadowHeightFalloff > 0.0
              ? 1.0 / (1.0 + dz * shadowHeightFalloff)
              : 1.0;
          final cAlpha = (baseShadowAlpha * atten).round().clamp(0, 255);
          _shCornerArgb[sSlot * 3 + corner] = (cAlpha << 24) | shadowRgb;
        }
      }
      _slotShadowActiveCount[slot] = activeSh;
    }
  }

  void _bakeScreenProjection({
    required CameraRig3D camera,
    required Offset canvasOrigin,
    required bool backfaceCulling,
    required double minTrianglePixelArea,
  }) {
    _projectionBakeCount++;
    _lastCulledMicroTriangles = 0;

    final iCount = _instances.length;
    for (var s = 0; s < iCount; s++) {
      if (_slotTriActive[s] == 0) {
        continue;
      }
      final vStart = _slotVertStart[s];
      final vEnd = vStart + _slotVertCap[s];
      for (var v = vStart; v < vEnd; v++) {
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
    }

    var visCount = 0;
    for (var t = 0; t < _rawTriCount; t++) {
      final owner = _rawTriOwnerSlot[t];
      if (_slotTriActive[owner] == 0) {
        continue;
      }
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
      visibleTriMatIdx[visCount] = _rawTriMatIdx[t];
      visibleTriDepth[visCount] =
          (projectedVertDepth[a] +
              projectedVertDepth[b] +
              projectedVertDepth[c]) /
          3.0;
      visCount++;
    }
    visibleTriCount = visCount;

    var shOut = 0;
    for (var instIdx = 0; instIdx < iCount; instIdx++) {
      final activeSh = _slotShadowActiveCount[instIdx];
      if (activeSh == 0 || _slotTriActive[instIdx] == 0) {
        continue;
      }
      final baseSh = _slotShadowStart[instIdx];
      for (var k = 0; k < activeSh; k++) {
        final s = baseSh + k;
        if (_shActive[s] == 0) {
          continue;
        }
        final anchor = Offset(_shAnchorX[s], _shAnchorY[s]);
        final gz = _shGroundZ[s];
        final pOut = shOut * 6;
        final cOut = shOut * 3;
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
          projectedShadowColors[cOut + corner] = _shCornerArgb[s * 3 + corner];
        }
        shOut++;
      }
    }
    projectedShadowTriCount = shOut;
  }

  /// Internal accessor exposing cached UVs/colors/shadow count to
  /// `BatchMeshRenderer3D`.
  (
    Float32List u,
    Float32List v,
    Float32List texU,
    Float32List texV,
    Uint8List texPixelSpace,
    Int32List colors,
    int shadowTris,
  )
  internalBuffers() => (
    _vertU,
    _vertV,
    _vertTexU,
    _vertTexV,
    _vertTexPixelSpace,
    _vertColor,
    projectedShadowTriCount,
  );
}
