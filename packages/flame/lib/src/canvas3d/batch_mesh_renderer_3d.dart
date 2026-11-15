import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/canvas3d/deformable_mesh_3d.dart';
import 'package:flame/src/canvas3d/matcap_shader_3d.dart';
import 'package:flame/src/canvas3d/material_3d.dart';
import 'package:flame/src/canvas3d/mesh_3d.dart';
import 'package:flame/src/canvas3d/mesh_lod_chain_3d.dart';
import 'package:flame/src/canvas3d/scene_environment_3d.dart';
import 'package:flame/src/canvas3d/static_mesh_chunk_3d.dart';
import 'package:flame/src/game/graphics_settings.dart';
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

  /// Computes a fast 31-bit state signature across light direction, colors, and
  /// intensities so [StaticMeshChunk3D] automatically invalidates on lighting
  /// changes.
  int computeSignature() {
    var h = 17;
    h = 0x1fffffff & (h * 31 + (_lx * 10000).round());
    h = 0x1fffffff & (h * 31 + (_ly * 10000).round());
    h = 0x1fffffff & (h * 31 + (_lz * 10000).round());
    h = 0x1fffffff & (h * 31 + sunColor.toARGB32());
    h = 0x1fffffff & (h * 31 + skyColor.toARGB32());
    h = 0x1fffffff & (h * 31 + groundColor.toARGB32());
    h = 0x1fffffff & (h * 31 + (ambientIntensity * 1000).round());
    h = 0x1fffffff & (h * 31 + (diffuseIntensity * 1000).round());
    h = 0x1fffffff & (h * 31 + (rimIntensity * 1000).round());
    return h;
  }
}

/// Triangle depth representative mode used by [BatchMeshRenderer3D] when
/// sorting triangles back-to-front.
enum TriangleDepthMode3D() {
  /// Mean depth of the three vertices (`(d0 + d1 + d2) / 3`).
  centroid,

  /// Closest vertex to the camera (`max(d0, d1, d2)`).
  nearestVertex,

  /// Farthest vertex from the camera (`min(d0, d1, d2)`).
  farthestVertex,
}

/// Zero-allocation Struct-of-Arrays 3D mesh batcher onto Flutter's standard
/// `Canvas` (`Canvas.drawVertices`).
///
/// Transforms, lights, back-face culls, near-plane clips in perspective mode,
/// globally depth-sorts across `[sortOrder, depth + depthBias]` and multiple
/// [Material3D]s (textures, MatCap presets, and [ui.BlendMode]s), and batches
/// arbitrary [Mesh3D], [MorphMeshWorkspace3D], [SkinnedMeshWorkspace3D], and
/// [StaticMeshChunk3D] instances into minimal `Vertices.raw` GPU draw calls.
class BatchMeshRenderer3D({
  DirectionalLight3D? light,
  this.environment,
  var bool backfaceCulling = true,
  var TriangleDepthMode3D depthMode = TriangleDepthMode3D.centroid,
  this.shadowsEnabled = true,
  this.shadowOpacityMultiplier = 1.0,
  this.cullBackfaceShadows = true,
  this.shadowHeightFalloff = 0.0,
  this.frustumCullMeshes = true,
  this.cullScreenBounds,
  this.minTrianglePixelArea = 0.0,
  int initialVertexCapacity = 512,
  int initialTriangleCapacity = 512,
}) {
  /// Active scene lighting parameters.
  final DirectionalLight3D light = light ?? DirectionalLight3D();

  /// Optional 3D scene environment supplying SoA [PointLight3D]s and
  /// atmospheric distance/height fog.
  SceneEnvironment3D? environment;

  /// Whether ground-projected shadows are emitted (`false` skips shadow
  /// projection globally, e.g. on `GraphicsQualityTier.low`).
  bool shadowsEnabled;

  /// Global multiplier applied to every mesh's `shadowOpacity`.
  double shadowOpacityMultiplier;

  /// When `true` (default), only triangles facing the directional light source
  /// project ground shadow geometry, eliminating double-darkening alpha overlap
  /// artifacts on closed convex meshes and halving shadow triangle count.
  bool cullBackfaceShadows;

  /// Per-unit height attenuation factor (`>= 0.0`) softening shadow opacity as
  /// `worldZ - groundZ` increases (`alpha / (1 + dz * shadowHeightFalloff)`).
  double shadowHeightFalloff;

  /// Whether [enqueueMesh] and [enqueueStaticChunk] perform `O(1)` 3D bounding-
  /// sphere frustum culling against [cullScreenBounds].
  bool frustumCullMeshes;

  /// Optional screen/canvas culling rectangle in the same coordinate space as
  /// projected mesh vertices (`null` disables frustum culling).
  Rect? cullScreenBounds;

  /// Minimum projected triangle area in square pixels (`0.0` disables); smaller
  /// sub-pixel micro-triangles are culled during zoom-out views.
  double minTrianglePixelArea;

  final Paint _meshPaint = Paint()..isAntiAlias = true;
  final Paint _shadowPaint = Paint()..isAntiAlias = true;
  final Float32List _rotScratch = Float32List(9);
  final Int32List _clipPoly = Int32List(4);
  final List<Material3D?> _materials = <Material3D?>[null];

  Float32List _vertX = Float32List(initialVertexCapacity);
  Float32List _vertY = Float32List(initialVertexCapacity);
  Float32List _vertDepth = Float32List(initialVertexCapacity);
  Float32List _vertCamX = Float32List(initialVertexCapacity);
  Float32List _vertCamY = Float32List(initialVertexCapacity);
  Float32List _vertCamZ = Float32List(initialVertexCapacity);
  Float32List _vertU = Float32List(initialVertexCapacity);
  Float32List _vertV = Float32List(initialVertexCapacity);
  Float32List _vertTexU = Float32List(initialVertexCapacity);
  Float32List _vertTexV = Float32List(initialVertexCapacity);
  Uint8List _vertTexPixelSpace = Uint8List(initialVertexCapacity);
  Int32List _vertColor = Int32List(initialVertexCapacity);

  Int32List _triV0 = Int32List(initialTriangleCapacity);
  Int32List _triV1 = Int32List(initialTriangleCapacity);
  Int32List _triV2 = Int32List(initialTriangleCapacity);
  Uint16List _triMatSlot = Uint16List(initialTriangleCapacity);
  Int32List _triSortOrder = Int32List(initialTriangleCapacity);
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
  int _frustumCulledMeshes = 0;
  int _culledMicroTriangles = 0;
  int _nearPlaneClippedTriangles = 0;

  int _lastFlushTriangles = 0;
  int _lastFlushShadowTriangles = 0;
  int _lastFlushDrawCalls = 0;
  int _lastFlushMaterialSwitches = 0;
  int _lastFrustumCulledMeshes = 0;
  int _lastCulledMicroTriangles = 0;
  int _lastNearPlaneClippedTriangles = 0;

  /// Visible front-facing triangles submitted in the most recent flush.
  int get lastFlushTriangles => _lastFlushTriangles;

  /// Ground-projected shadow triangles submitted in the most recent shadow
  /// flush.
  int get lastFlushShadowTriangles => _lastFlushShadowTriangles;

  /// Total `Canvas.drawVertices` calls issued in the most recent flush.
  int get lastFlushDrawCalls => _lastFlushDrawCalls;

  /// Number of contiguous material state transitions emitted across
  /// depth-sorted geometry in the most recent geometry flush.
  int get lastFlushMaterialSwitches => _lastFlushMaterialSwitches;

  /// Meshes skipped by 3D bounding-sphere frustum culling in the most recent
  /// flush.
  int get lastFrustumCulledMeshes => _lastFrustumCulledMeshes;

  /// Sub-pixel micro-triangles culled by [minTrianglePixelArea] in the most
  /// recent flush.
  int get lastCulledMicroTriangles => _lastCulledMicroTriangles;

  /// Triangles clipped against `CameraRig3D.nearClip` in perspective mode
  /// during the most recent flush.
  int get lastNearPlaneClippedTriangles => _lastNearPlaneClippedTriangles;

  /// Number of [enqueueMesh] calls accumulated in the active batch.
  int get activeEnqueuedMeshes => _enqueuedMeshes;

  /// Number of ground-shadow triangles currently queued in the active batch.
  int get pendingShadowTriangleCount => _shadowTriCount;

  /// Number of lit 3D geometry triangles currently queued in the active batch.
  int get pendingGeometryTriangleCount => _triCount;

  static Uint16List _buildSequentialIndices(int vertexCount) {
    final clamped = math.min(vertexCount, 65535);
    final out = Uint16List(clamped);
    for (var i = 0; i < clamped; i++) {
      out[i] = i;
    }
    return out;
  }

  int _internMaterial(Material3D? mat) {
    if (mat == null) {
      return 0;
    }
    for (var i = 1; i < _materials.length; i++) {
      if (_materials[i] == mat) {
        return i;
      }
    }
    _materials.add(mat);
    return _materials.length - 1;
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
    _vertCamX = Float32List(cap)..setRange(0, _vertCount, _vertCamX);
    _vertCamY = Float32List(cap)..setRange(0, _vertCount, _vertCamY);
    _vertCamZ = Float32List(cap)..setRange(0, _vertCount, _vertCamZ);
    _vertU = Float32List(cap)..setRange(0, _vertCount, _vertU);
    _vertV = Float32List(cap)..setRange(0, _vertCount, _vertV);
    _vertTexU = Float32List(cap)..setRange(0, _vertCount, _vertTexU);
    _vertTexV = Float32List(cap)..setRange(0, _vertCount, _vertTexV);
    _vertTexPixelSpace = Uint8List(cap)
      ..setRange(0, _vertCount, _vertTexPixelSpace);
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
    _triMatSlot = Uint16List(cap)..setRange(0, _triCount, _triMatSlot);
    _triSortOrder = Int32List(cap)..setRange(0, _triCount, _triSortOrder);
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
    _frustumCulledMeshes = 0;
    _culledMicroTriangles = 0;
    _nearPlaneClippedTriangles = 0;
    if (_materials.length > 1) {
      _materials
        ..clear()
        ..add(null);
    }
  }

  /// Synchronizes shadow and anti-aliasing toggles from [profile].
  void applyGraphicsProfile(GraphicsProfile profile) {
    shadowsEnabled = profile.shadowsEnabled;
    shadowOpacityMultiplier = profile.shadowOpacityScale;
    _meshPaint.isAntiAlias = profile.antiAliasing;
    _shadowPaint.isAntiAlias = profile.antiAliasing;
  }

  /// Selects the appropriate [Mesh3D] tier from [lodChain] for [camera] and
  /// enqueues it (returning the selected mesh, or `null` when sub-pixel
  /// culled).
  Mesh3D? enqueueLodMesh(
    MeshLodChain3D lodChain, {
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
    (double, double, double, double)? rotationQuat,
    Float32List? rotationMatrix3,
    double lodBias = 0.0,
    Color tint = const Color(0xFFFFFFFF),
    double opacity = 1.0,
    double emissive = 0.0,
    Color? rimColor,
    double rimHighlightIntensity = 0.0,
    Rect? uvRectPx,
    Material3D? material,
    int sortOrder = 0,
    double depthBias = 0.0,
    bool castGroundShadow = false,
    bool doubleSidedShadow = false,
    double groundZ = 0.0,
    Color shadowColor = const Color(0xFF16131F),
    double shadowOpacity = 0.24,
  }) {
    final selected = lodChain.selectMesh(
      camera: camera,
      scaleX: scaleX,
      scaleY: scaleY,
      scaleZ: scaleZ,
      lodBias: lodBias,
    );
    if (selected == null) {
      return null;
    }
    enqueueMesh(
      selected,
      camera: camera,
      worldX: worldX,
      worldY: worldY,
      worldZ: worldZ,
      canvasOrigin: canvasOrigin,
      scaleX: scaleX,
      scaleY: scaleY,
      scaleZ: scaleZ,
      yawRad: yawRad,
      pitchRad: pitchRad,
      rollRad: rollRad,
      rotationQuat: rotationQuat,
      rotationMatrix3: rotationMatrix3,
      tint: tint,
      opacity: opacity,
      emissive: emissive,
      rimColor: rimColor,
      rimHighlightIntensity: rimHighlightIntensity,
      uvRectPx: uvRectPx,
      material: material,
      sortOrder: sortOrder,
      depthBias: depthBias,
      castGroundShadow: castGroundShadow,
      doubleSidedShadow: doubleSidedShadow,
      groundZ: groundZ,
      shadowColor: shadowColor,
      shadowOpacity: shadowOpacity,
    );
    return selected;
  }

  /// Evaluates [morphWorkspace] (zero heap allocations) and enqueues its
  /// deformed vertices and normals directly into the active batch.
  void enqueueMorphMesh(
    MorphMeshWorkspace3D morphWorkspace, {
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
    (double, double, double, double)? rotationQuat,
    Float32List? rotationMatrix3,
    Color tint = const Color(0xFFFFFFFF),
    double opacity = 1.0,
    double emissive = 0.0,
    Color? rimColor,
    double rimHighlightIntensity = 0.0,
    Rect? uvRectPx,
    Material3D? material,
    int sortOrder = 0,
    double depthBias = 0.0,
    bool castGroundShadow = false,
    bool doubleSidedShadow = false,
    double groundZ = 0.0,
    Color shadowColor = const Color(0xFF16131F),
    double shadowOpacity = 0.24,
  }) {
    morphWorkspace.evaluateIfDirty();
    final base = morphWorkspace.baseMesh;
    enqueueDeformedBuffers(
      positions: morphWorkspace.deformedPositions,
      normals: morphWorkspace.deformedNormals,
      indices: base.indices,
      boundingRadius: morphWorkspace.boundingRadius,
      minZ: morphWorkspace.minZ,
      maxZ: morphWorkspace.maxZ,
      uvs: base.uvs,
      ambientOcclusion: base.ambientOcclusion,
      vertexColors: base.vertexColors,
      camera: camera,
      worldX: worldX,
      worldY: worldY,
      worldZ: worldZ,
      canvasOrigin: canvasOrigin,
      scaleX: scaleX,
      scaleY: scaleY,
      scaleZ: scaleZ,
      yawRad: yawRad,
      pitchRad: pitchRad,
      rollRad: rollRad,
      rotationQuat: rotationQuat,
      rotationMatrix3: rotationMatrix3,
      tint: tint,
      opacity: opacity,
      emissive: emissive,
      rimColor: rimColor,
      rimHighlightIntensity: rimHighlightIntensity,
      uvRectPx: uvRectPx,
      material: material,
      sortOrder: sortOrder,
      depthBias: depthBias,
      castGroundShadow: castGroundShadow,
      doubleSidedShadow: doubleSidedShadow,
      groundZ: groundZ,
      shadowColor: shadowColor,
      shadowOpacity: shadowOpacity,
    );
  }

  /// Evaluates [skinnedWorkspace] (zero heap allocations) and enqueues its
  /// bone-deformed vertices and normals directly into the active batch.
  void enqueueSkinnedMesh(
    SkinnedMeshWorkspace3D skinnedWorkspace, {
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
    (double, double, double, double)? rotationQuat,
    Float32List? rotationMatrix3,
    Color tint = const Color(0xFFFFFFFF),
    double opacity = 1.0,
    double emissive = 0.0,
    Color? rimColor,
    double rimHighlightIntensity = 0.0,
    Rect? uvRectPx,
    Material3D? material,
    int sortOrder = 0,
    double depthBias = 0.0,
    bool castGroundShadow = false,
    bool doubleSidedShadow = false,
    double groundZ = 0.0,
    Color shadowColor = const Color(0xFF16131F),
    double shadowOpacity = 0.24,
  }) {
    skinnedWorkspace.evaluateIfDirty();
    final base = skinnedWorkspace.baseMesh;
    enqueueDeformedBuffers(
      positions: skinnedWorkspace.skinnedPositions,
      normals: skinnedWorkspace.skinnedNormals,
      indices: base.indices,
      boundingRadius: skinnedWorkspace.boundingRadius,
      minZ: skinnedWorkspace.minZ,
      maxZ: skinnedWorkspace.maxZ,
      uvs: base.uvs,
      ambientOcclusion: base.ambientOcclusion,
      vertexColors: base.vertexColors,
      camera: camera,
      worldX: worldX,
      worldY: worldY,
      worldZ: worldZ,
      canvasOrigin: canvasOrigin,
      scaleX: scaleX,
      scaleY: scaleY,
      scaleZ: scaleZ,
      yawRad: yawRad,
      pitchRad: pitchRad,
      rollRad: rollRad,
      rotationQuat: rotationQuat,
      rotationMatrix3: rotationMatrix3,
      tint: tint,
      opacity: opacity,
      emissive: emissive,
      rimColor: rimColor,
      rimHighlightIntensity: rimHighlightIntensity,
      uvRectPx: uvRectPx,
      material: material,
      sortOrder: sortOrder,
      depthBias: depthBias,
      castGroundShadow: castGroundShadow,
      doubleSidedShadow: doubleSidedShadow,
      groundZ: groundZ,
      shadowColor: shadowColor,
      shadowOpacity: shadowOpacity,
    );
  }

  /// Transforms, shades, culls, and appends [mesh] into the active batch.
  ///
  /// Orientation can be supplied via gimbal-lock-free [rotationMatrix3]
  /// (`Float32List` of length `>= 9`), unit [rotationQuat] `(qx, qy, qz, qw)`,
  /// or Euler `(yawRad, pitchRad, rollRad)`.
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
    (double, double, double, double)? rotationQuat,
    Float32List? rotationMatrix3,
    Color tint = const Color(0xFFFFFFFF),
    double opacity = 1.0,
    double emissive = 0.0,
    Color? rimColor,
    double rimHighlightIntensity = 0.0,
    Rect? uvRectPx,
    Material3D? material,
    int sortOrder = 0,
    double depthBias = 0.0,
    bool castGroundShadow = false,
    bool doubleSidedShadow = false,
    double groundZ = 0.0,
    Color shadowColor = const Color(0xFF16131F),
    double shadowOpacity = 0.24,
  }) {
    enqueueDeformedBuffers(
      positions: mesh.positions,
      normals: mesh.normals,
      indices: mesh.indices,
      boundingRadius: mesh.boundingRadius,
      minZ: mesh.minZ,
      maxZ: mesh.maxZ,
      uvs: mesh.uvs,
      ambientOcclusion: mesh.ambientOcclusion,
      vertexColors: mesh.vertexColors,
      camera: camera,
      worldX: worldX,
      worldY: worldY,
      worldZ: worldZ,
      canvasOrigin: canvasOrigin,
      scaleX: scaleX,
      scaleY: scaleY,
      scaleZ: scaleZ,
      yawRad: yawRad,
      pitchRad: pitchRad,
      rollRad: rollRad,
      rotationQuat: rotationQuat,
      rotationMatrix3: rotationMatrix3,
      tint: tint,
      opacity: opacity,
      emissive: emissive,
      rimColor: rimColor,
      rimHighlightIntensity: rimHighlightIntensity,
      uvRectPx: uvRectPx,
      material: material,
      sortOrder: sortOrder,
      depthBias: depthBias,
      castGroundShadow: castGroundShadow,
      doubleSidedShadow: doubleSidedShadow,
      groundZ: groundZ,
      shadowColor: shadowColor,
      shadowOpacity: shadowOpacity,
    );
  }

  /// Low-level zero-allocation entry point streaming pre-allocated vertex
  /// [positions], [normals], and 16-bit [indices] directly into the internal
  /// SoA lighting & depth-sorting buffers without constructing a [Mesh3D].
  void enqueueDeformedBuffers({
    required Float32List positions,
    required Float32List normals,
    required Uint16List indices,
    required double boundingRadius,
    required double minZ,
    required double maxZ,
    required CameraRig3D camera,
    required double worldX,
    required double worldY,
    Float32List? uvs,
    Float32List? ambientOcclusion,
    Int32List? vertexColors,
    double worldZ = 0.0,
    Offset canvasOrigin = Offset.zero,
    double scaleX = 1.0,
    double scaleY = 1.0,
    double scaleZ = 1.0,
    double yawRad = 0.0,
    double pitchRad = 0.0,
    double rollRad = 0.0,
    (double, double, double, double)? rotationQuat,
    Float32List? rotationMatrix3,
    Color tint = const Color(0xFFFFFFFF),
    double opacity = 1.0,
    double emissive = 0.0,
    Color? rimColor,
    double rimHighlightIntensity = 0.0,
    Rect? uvRectPx,
    Material3D? material,
    int sortOrder = 0,
    double depthBias = 0.0,
    bool castGroundShadow = false,
    bool doubleSidedShadow = false,
    double groundZ = 0.0,
    Color shadowColor = const Color(0xFF16131F),
    double shadowOpacity = 0.24,
  }) {
    _enqueueIndexedBuffers(
      positions: positions,
      normals: normals,
      indices16: indices,
      indices32: null,
      boundingRadius: boundingRadius,
      minZ: minZ,
      maxZ: maxZ,
      camera: camera,
      worldX: worldX,
      worldY: worldY,
      uvs: uvs,
      ambientOcclusion: ambientOcclusion,
      vertexColors: vertexColors,
      worldZ: worldZ,
      canvasOrigin: canvasOrigin,
      scaleX: scaleX,
      scaleY: scaleY,
      scaleZ: scaleZ,
      yawRad: yawRad,
      pitchRad: pitchRad,
      rollRad: rollRad,
      rotationQuat: rotationQuat,
      rotationMatrix3: rotationMatrix3,
      tint: tint,
      opacity: opacity,
      emissive: emissive,
      rimColor: rimColor,
      rimHighlightIntensity: rimHighlightIntensity,
      uvRectPx: uvRectPx,
      material: material,
      sortOrder: sortOrder,
      depthBias: depthBias,
      castGroundShadow: castGroundShadow,
      doubleSidedShadow: doubleSidedShadow,
      groundZ: groundZ,
      shadowColor: shadowColor,
      shadowOpacity: shadowOpacity,
    );
  }

  /// Streams 32-bit indexed geometry (`> 65,535` vertices) directly into the
  /// internal 32-bit SoA vertex/triangle batcher, automatically chunking into
  /// `<= 21,840`-triangle `Vertices.raw` GPU draw calls during [flushGeometry].
  void enqueueLargeBuffers32({
    required Float32List positions,
    required Float32List normals,
    required Uint32List indices,
    required double boundingRadius,
    required double minZ,
    required double maxZ,
    required CameraRig3D camera,
    required double worldX,
    required double worldY,
    Float32List? uvs,
    Float32List? ambientOcclusion,
    Int32List? vertexColors,
    double worldZ = 0.0,
    Offset canvasOrigin = Offset.zero,
    double scaleX = 1.0,
    double scaleY = 1.0,
    double scaleZ = 1.0,
    double yawRad = 0.0,
    double pitchRad = 0.0,
    double rollRad = 0.0,
    (double, double, double, double)? rotationQuat,
    Float32List? rotationMatrix3,
    Color tint = const Color(0xFFFFFFFF),
    double opacity = 1.0,
    double emissive = 0.0,
    Color? rimColor,
    double rimHighlightIntensity = 0.0,
    Rect? uvRectPx,
    Material3D? material,
    int sortOrder = 0,
    double depthBias = 0.0,
    bool castGroundShadow = false,
    bool doubleSidedShadow = false,
    double groundZ = 0.0,
    Color shadowColor = const Color(0xFF16131F),
    double shadowOpacity = 0.24,
  }) {
    _enqueueIndexedBuffers(
      positions: positions,
      normals: normals,
      indices16: null,
      indices32: indices,
      boundingRadius: boundingRadius,
      minZ: minZ,
      maxZ: maxZ,
      camera: camera,
      worldX: worldX,
      worldY: worldY,
      uvs: uvs,
      ambientOcclusion: ambientOcclusion,
      vertexColors: vertexColors,
      worldZ: worldZ,
      canvasOrigin: canvasOrigin,
      scaleX: scaleX,
      scaleY: scaleY,
      scaleZ: scaleZ,
      yawRad: yawRad,
      pitchRad: pitchRad,
      rollRad: rollRad,
      rotationQuat: rotationQuat,
      rotationMatrix3: rotationMatrix3,
      tint: tint,
      opacity: opacity,
      emissive: emissive,
      rimColor: rimColor,
      rimHighlightIntensity: rimHighlightIntensity,
      uvRectPx: uvRectPx,
      material: material,
      sortOrder: sortOrder,
      depthBias: depthBias,
      castGroundShadow: castGroundShadow,
      doubleSidedShadow: doubleSidedShadow,
      groundZ: groundZ,
      shadowColor: shadowColor,
      shadowOpacity: shadowOpacity,
    );
  }

  void _enqueueIndexedBuffers({
    required Float32List positions,
    required Float32List normals,
    required Uint16List? indices16,
    required Uint32List? indices32,
    required double boundingRadius,
    required double minZ,
    required double maxZ,
    required CameraRig3D camera,
    required double worldX,
    required double worldY,
    Float32List? uvs,
    Float32List? ambientOcclusion,
    Int32List? vertexColors,
    double worldZ = 0.0,
    Offset canvasOrigin = Offset.zero,
    double scaleX = 1.0,
    double scaleY = 1.0,
    double scaleZ = 1.0,
    double yawRad = 0.0,
    double pitchRad = 0.0,
    double rollRad = 0.0,
    (double, double, double, double)? rotationQuat,
    Float32List? rotationMatrix3,
    Color tint = const Color(0xFFFFFFFF),
    double opacity = 1.0,
    double emissive = 0.0,
    Color? rimColor,
    double rimHighlightIntensity = 0.0,
    Rect? uvRectPx,
    Material3D? material,
    int sortOrder = 0,
    double depthBias = 0.0,
    bool castGroundShadow = false,
    bool doubleSidedShadow = false,
    double groundZ = 0.0,
    Color shadowColor = const Color(0xFF16131F),
    double shadowOpacity = 0.24,
  }) {
    final clampedOpacity = opacity.clamp(0.0, 1.0);
    final rawIdxLen = indices16?.length ?? indices32!.length;
    final mTriCount = rawIdxLen ~/ 3;
    if (clampedOpacity <= 0.0 || mTriCount == 0) {
      return;
    }

    final anchorWorld = camera.gridToScreen(worldX, worldY);
    final effShadowOpacity = (castGroundShadow && shadowsEnabled)
        ? shadowOpacity * shadowOpacityMultiplier.clamp(0.0, 2.0)
        : 0.0;

    final cullRect = cullScreenBounds;
    if (frustumCullMeshes && cullRect != null) {
      final maxScale = math.max(
        scaleX.abs(),
        math.max(scaleY.abs(), scaleZ.abs()),
      );
      final midLocalZ = (minZ + maxZ) * 0.5 * scaleZ;
      final (cx, cy) = camera.projectAnchored(
        anchorWorld: anchorWorld,
        canvasOrigin: canvasOrigin,
        rx: 0.0,
        ry: 0.0,
        rz: worldZ + midLocalZ,
      );
      var radPx = boundingRadius * maxScale * camera.focalScalePx * 1.35;
      if (effShadowOpacity > 0.0 && light.dirZ > 0.08) {
        final maxH = math.max(
          0.0,
          worldZ + maxZ.abs() * scaleZ.abs() - groundZ,
        );
        radPx += (maxH / light.dirZ) * camera.focalScalePx;
      }
      if (cx + radPx < cullRect.left ||
          cx - radPx > cullRect.right ||
          cy + radPx < cullRect.top ||
          cy - radPx > cullRect.bottom) {
        _frustumCulledMeshes++;
        return;
      }
    }

    _enqueuedMeshes++;

    final vCount = positions.length ~/ 3;
    final baseVertex = _vertCount;
    _ensureVertexCapacity(baseVertex + vCount);

    final double r00;
    final double r01;
    final double r02;
    final double r10;
    final double r11;
    final double r12;
    final double r20;
    final double r21;
    final double r22;

    if (rotationMatrix3 != null && rotationMatrix3.length >= 9) {
      r00 = rotationMatrix3[0];
      r01 = rotationMatrix3[1];
      r02 = rotationMatrix3[2];
      r10 = rotationMatrix3[3];
      r11 = rotationMatrix3[4];
      r12 = rotationMatrix3[5];
      r20 = rotationMatrix3[6];
      r21 = rotationMatrix3[7];
      r22 = rotationMatrix3[8];
    } else if (rotationQuat != null) {
      final (qx, qy, qz, qw) = rotationQuat;
      Quaternion3D.writeMatrix3(qx, qy, qz, qw, _rotScratch);
      r00 = _rotScratch[0];
      r01 = _rotScratch[1];
      r02 = _rotScratch[2];
      r10 = _rotScratch[3];
      r11 = _rotScratch[4];
      r12 = _rotScratch[5];
      r20 = _rotScratch[6];
      r21 = _rotScratch[7];
      r22 = _rotScratch[8];
    } else {
      final cy = math.cos(yawRad);
      final sy = math.sin(yawRad);
      final cp = math.cos(pitchRad);
      final sp = math.sin(pitchRad);
      final cr = math.cos(rollRad);
      final sr = math.sin(rollRad);

      r00 = cy * cp;
      r01 = cy * sp * sr - sy * cr;
      r02 = cy * sp * cr + sy * sr;
      r10 = sy * cp;
      r11 = sy * sp * sr + cy * cr;
      r12 = sy * sp * cr - cy * sr;
      r20 = -sp;
      r21 = cp * sr;
      r22 = cp * cr;
    }

    final invSx = scaleX.abs() > 1e-6 ? 1.0 / scaleX : 1.0;
    final invSy = scaleY.abs() > 1e-6 ? 1.0 / scaleY : 1.0;
    final invSz = scaleZ.abs() > 1e-6 ? 1.0 / scaleZ : 1.0;

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
    final isPerspective =
        camera.projectionMode == CameraProjectionMode3D.perspective;
    final nearClip = camera.nearClip;

    for (var v = 0; v < vCount; v++) {
      final pIdx = v * 3;
      final lxPos = positions[pIdx] * scaleX;
      final lyPos = positions[pIdx + 1] * scaleY;
      final lzPos = positions[pIdx + 2] * scaleZ;

      final rx = r00 * lxPos + r01 * lyPos + r02 * lzPos;
      final ry = r10 * lxPos + r11 * lyPos + r12 * lzPos;
      final rz = r20 * lxPos + r21 * lyPos + r22 * lzPos + worldZ;

      final double sx;
      final double sy;
      var camX = 0.0;
      var camY = 0.0;
      var camZ = nearClip;
      if (isPerspective) {
        (camX, camY, camZ) = camera.worldToCameraSpace(
          worldX + rx,
          worldY + ry,
          rz,
        );
        if (camZ >= nearClip) {
          (sx, sy) = camera.projectCameraSpace(
            camX,
            camY,
            camZ,
            canvasOrigin: canvasOrigin,
          );
        } else {
          sx = 0.0;
          sy = 0.0;
        }
      } else {
        (sx, sy) = camera.projectAnchored(
          anchorWorld: anchorWorld,
          canvasOrigin: canvasOrigin,
          rx: rx,
          ry: ry,
          rz: rz,
        );
      }

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
      final double meshTexU;
      final double meshTexV;
      final int texPixelSpace;
      if (uvs != null) {
        final uvBase = v * 2;
        if (uvRectPx != null) {
          meshTexU = uvRectPx.left + uvs[uvBase] * uvRectPx.width;
          meshTexV = uvRectPx.top + uvs[uvBase + 1] * uvRectPx.height;
          texPixelSpace = 1;
        } else {
          meshTexU = uvs[uvBase];
          meshTexV = uvs[uvBase + 1];
          texPixelSpace = 0;
        }
      } else {
        meshTexU = u;
        meshTexV = texV;
        texPixelSpace = 1;
      }

      final hemiMix = (wnz * 0.5 + 0.5).clamp(0.0, 1.0);
      final ambR = (gndR + (skyR - gndR) * hemiMix) * ambInt;
      final ambG = (gndG + (skyG - gndG) * hemiMix) * ambInt;
      final ambB = (gndB + (skyB - gndB) * hemiMix) * ambInt;

      final nDotL = math.max(0.0, wnx * lx + wny * ly + wnz * lz);
      final clampedVz = vz.clamp(0.0, 1.0);
      final rim = math.pow(1.0 - clampedVz, 2.2) * rimInt;
      final fresnel = (rimColor != null && rimHighlightIntensity > 0.0)
          ? (1.0 - clampedVz) * (1.0 - clampedVz) * rimHighlightIntensity
          : 0.0;
      final ao = ambientOcclusion != null ? ambientOcclusion[v] : 1.0;

      var baseR = tintR;
      var baseG = tintG;
      var baseB = tintB;
      var baseA = tintA;
      if (vertexColors != null) {
        final vc = vertexColors[v];
        baseA *= ((vc >>> 24) & 0xFF) / 255.0;
        baseR *= ((vc >>> 16) & 0xFF) / 255.0;
        baseG *= ((vc >>> 8) & 0xFF) / 0xFF;
        baseB *= (vc & 0xFF) / 255.0;
      }

      final addRimR = fresnel > 0.0 ? rimColor!.r * fresnel : 0.0;
      final addRimG = fresnel > 0.0 ? rimColor!.g * fresnel : 0.0;
      final addRimB = fresnel > 0.0 ? rimColor!.b * fresnel : 0.0;

      final env = environment;
      var ptR = 0.0;
      var ptG = 0.0;
      var ptB = 0.0;
      if (env != null && env.pointLightCount > 0) {
        (ptR, ptG, ptB) = env.samplePointLights(
          wx: worldX + rx,
          wy: worldY + ry,
          wz: rz,
          nx: wnx,
          ny: wny,
          nz: wnz,
        );
      }

      var lr =
          (baseR * (ambR * ao + sunR * nDotL * difInt + ptR + emissive) +
                  rim * skyR +
                  addRimR)
              .clamp(0.0, 1.0);
      var lg =
          (baseG * (ambG * ao + sunG * nDotL * difInt + ptG + emissive) +
                  rim * skyG +
                  addRimG)
              .clamp(0.0, 1.0);
      var lb =
          (baseB * (ambB * ao + sunB * nDotL * difInt + ptB + emissive) +
                  rim * skyB +
                  addRimB)
              .clamp(0.0, 1.0);

      final vDepth = camera.viewDepth(worldX + rx, worldY + ry, rz);
      if (env != null && env.fogEnabled) {
        final fog = env.computeFogFactor(viewDepth: vDepth, worldZ: rz);
        if (fog > 0.0) {
          lr += (env.fogColor.r - lr) * fog;
          lg += (env.fogColor.g - lg) * fog;
          lb += (env.fogColor.b - lb) * fog;
        }
      }

      final outSlot = baseVertex + v;
      _vertX[outSlot] = sx;
      _vertY[outSlot] = sy;
      _vertDepth[outSlot] = vDepth;
      if (isPerspective) {
        _vertCamX[outSlot] = camX;
        _vertCamY[outSlot] = camY;
        _vertCamZ[outSlot] = camZ;
      }
      _vertU[outSlot] = u;
      _vertV[outSlot] = texV;
      _vertTexU[outSlot] = meshTexU;
      _vertTexV[outSlot] = meshTexV;
      _vertTexPixelSpace[outSlot] = texPixelSpace;
      _vertColor[outSlot] =
          ((baseA * 255.0).round().clamp(0, 255) << 24) |
          ((lr * 255.0).round().clamp(0, 255) << 16) |
          ((lg * 255.0).round().clamp(0, 255) << 8) |
          (lb * 255.0).round().clamp(0, 255);
    }
    _vertCount += vCount;

    final matSlot = _internMaterial(material);
    _ensureTriangleCapacity(_triCount + mTriCount);

    final minArea = minTrianglePixelArea;
    final reverseWinding = (scaleX * scaleY * scaleZ) < 0.0;
    for (var t = 0; t < mTriCount; t++) {
      final idxBase = t * 3;
      final int a;
      final int b;
      final int c;
      if (indices16 != null) {
        a = baseVertex + indices16[idxBase];
        if (reverseWinding) {
          b = baseVertex + indices16[idxBase + 2];
          c = baseVertex + indices16[idxBase + 1];
        } else {
          b = baseVertex + indices16[idxBase + 1];
          c = baseVertex + indices16[idxBase + 2];
        }
      } else {
        a = baseVertex + indices32![idxBase];
        if (reverseWinding) {
          b = baseVertex + indices32[idxBase + 2];
          c = baseVertex + indices32[idxBase + 1];
        } else {
          b = baseVertex + indices32[idxBase + 1];
          c = baseVertex + indices32[idxBase + 2];
        }
      }

      if (isPerspective) {
        final za = _vertCamZ[a];
        final zb = _vertCamZ[b];
        final zc = _vertCamZ[c];
        if (za < nearClip || zb < nearClip || zc < nearClip) {
          if (za < nearClip && zb < nearClip && zc < nearClip) {
            continue;
          }
          _clipAndEmitPerspectiveTriangle(
            a: a,
            b: b,
            c: c,
            nearClip: nearClip,
            camera: camera,
            canvasOrigin: canvasOrigin,
            matSlot: matSlot,
            sortOrder: sortOrder,
            depthBias: depthBias,
            minArea: minArea,
          );
          continue;
        }
      }

      _emitProjectedTriangle(
        a: a,
        b: b,
        c: c,
        matSlot: matSlot,
        sortOrder: sortOrder,
        depthBias: depthBias,
        minArea: minArea,
      );
    }

    if (effShadowOpacity > 0.0 && lz > 0.08) {
      _ensureShadowCapacity(_shadowTriCount + mTriCount);
      final baseShadowAlpha = effShadowOpacity * clampedOpacity * 255.0;
      final shadowRgb = shadowColor.toARGB32() & 0x00FFFFFF;
      final slopeX = -lx / lz;
      final slopeY = -ly / lz;

      (double, double, double) worldRelPos(int pIdx) {
        final lxPos = positions[pIdx] * scaleX;
        final lyPos = positions[pIdx + 1] * scaleY;
        final lzPos = positions[pIdx + 2] * scaleZ;
        return (
          r00 * lxPos + r01 * lyPos + r02 * lzPos,
          r10 * lxPos + r11 * lyPos + r12 * lzPos,
          r20 * lxPos + r21 * lyPos + r22 * lzPos + worldZ,
        );
      }

      for (var t = 0; t < mTriCount; t++) {
        final idxBase = t * 3;
        final int i0;
        final int i1;
        final int i2;
        if (indices16 != null) {
          i0 = indices16[idxBase] * 3;
          if (reverseWinding) {
            i1 = indices16[idxBase + 2] * 3;
            i2 = indices16[idxBase + 1] * 3;
          } else {
            i1 = indices16[idxBase + 1] * 3;
            i2 = indices16[idxBase + 2] * 3;
          }
        } else {
          i0 = indices32![idxBase] * 3;
          if (reverseWinding) {
            i1 = indices32[idxBase + 2] * 3;
            i2 = indices32[idxBase + 1] * 3;
          } else {
            i1 = indices32[idxBase + 1] * 3;
            i2 = indices32[idxBase + 2] * 3;
          }
        }

        final (rx0, ry0, rz0) = worldRelPos(i0);
        final (rx1, ry1, rz1) = worldRelPos(i1);
        final (rx2, ry2, rz2) = worldRelPos(i2);

        if (cullBackfaceShadows && !doubleSidedShadow) {
          final e1x = rx1 - rx0;
          final e1y = ry1 - ry0;
          final e1z = rz1 - rz0;
          final e2x = rx2 - rx0;
          final e2y = ry2 - ry0;
          final e2z = rz2 - rz0;
          final fnx = e1y * e2z - e1z * e2y;
          final fny = e1z * e2x - e1x * e2z;
          final fnz = e1x * e2y - e1y * e2x;
          if (fnx * lx + fny * ly + fnz * lz <= 1e-6) {
            continue;
          }
        }

        final dz0 = math.max(0.0, rz0 - groundZ);
        final dz1 = math.max(0.0, rz1 - groundZ);
        final dz2 = math.max(0.0, rz2 - groundZ);

        final (sx0, sy0) = camera.projectAnchored(
          anchorWorld: anchorWorld,
          canvasOrigin: canvasOrigin,
          rx: rx0 + slopeX * dz0,
          ry: ry0 + slopeY * dz0,
          rz: groundZ,
        );
        final (sx1, sy1) = camera.projectAnchored(
          anchorWorld: anchorWorld,
          canvasOrigin: canvasOrigin,
          rx: rx1 + slopeX * dz1,
          ry: ry1 + slopeY * dz1,
          rz: groundZ,
        );
        final (sx2, sy2) = camera.projectAnchored(
          anchorWorld: anchorWorld,
          canvasOrigin: canvasOrigin,
          rx: rx2 + slopeX * dz2,
          ry: ry2 + slopeY * dz2,
          rz: groundZ,
        );

        int shadowArgbForHeight(double dz) {
          final atten = shadowHeightFalloff > 0.0
              ? 1.0 / (1.0 + dz * shadowHeightFalloff)
              : 1.0;
          final a = (baseShadowAlpha * atten).round().clamp(0, 255);
          return (a << 24) | shadowRgb;
        }

        final pOut = _shadowTriCount * 6;
        final cOut = _shadowTriCount * 3;
        _shadowPositions[pOut] = sx0;
        _shadowPositions[pOut + 1] = sy0;
        _shadowPositions[pOut + 2] = sx1;
        _shadowPositions[pOut + 3] = sy1;
        _shadowPositions[pOut + 4] = sx2;
        _shadowPositions[pOut + 5] = sy2;
        _shadowColors[cOut] = shadowArgbForHeight(dz0);
        _shadowColors[cOut + 1] = shadowArgbForHeight(dz1);
        _shadowColors[cOut + 2] = shadowArgbForHeight(dz2);
        _shadowTriCount++;
      }
    }
  }

  double _computeTriangleDepth(double d0, double d1, double d2) {
    return switch (depthMode) {
      TriangleDepthMode3D.centroid => (d0 + d1 + d2) * (1.0 / 3.0),
      TriangleDepthMode3D.nearestVertex => math.max(d0, math.max(d1, d2)),
      TriangleDepthMode3D.farthestVertex => math.min(d0, math.min(d1, d2)),
    };
  }

  void _emitProjectedTriangle({
    required int a,
    required int b,
    required int c,
    required int matSlot,
    required int sortOrder,
    required double depthBias,
    required double minArea,
  }) {
    final ax = _vertX[a];
    final ay = _vertY[a];
    final cross =
        (_vertX[b] - ax) * (_vertY[c] - ay) -
        (_vertY[b] - ay) * (_vertX[c] - ax);
    if (backfaceCulling && cross <= 1e-3) {
      return;
    }
    if (minArea > 0.0 && cross.abs() * 0.5 < minArea) {
      _culledMicroTriangles++;
      return;
    }

    _ensureTriangleCapacity(_triCount + 1);
    final slot = _triCount++;
    _triV0[slot] = a;
    _triV1[slot] = b;
    _triV2[slot] = c;
    _triMatSlot[slot] = matSlot;
    _triSortOrder[slot] = sortOrder;
    _triDepth[slot] =
        _computeTriangleDepth(_vertDepth[a], _vertDepth[b], _vertDepth[c]) +
        depthBias;
    _triOrder[slot] = slot;
  }

  int _interpolateClippedVertex(
    int p,
    int q,
    double frac,
    double nearClip,
    CameraRig3D camera,
    Offset canvasOrigin,
  ) {
    final slot = _vertCount++;
    final cx = _vertCamX[p] + (_vertCamX[q] - _vertCamX[p]) * frac;
    final cy = _vertCamY[p] + (_vertCamY[q] - _vertCamY[p]) * frac;
    final (sx, sy) = camera.projectCameraSpace(
      cx,
      cy,
      nearClip,
      canvasOrigin: canvasOrigin,
    );
    _vertX[slot] = sx;
    _vertY[slot] = sy;
    _vertCamX[slot] = cx;
    _vertCamY[slot] = cy;
    _vertCamZ[slot] = nearClip;
    _vertDepth[slot] = _vertDepth[p] + (_vertDepth[q] - _vertDepth[p]) * frac;
    _vertU[slot] = _vertU[p] + (_vertU[q] - _vertU[p]) * frac;
    _vertV[slot] = _vertV[p] + (_vertV[q] - _vertV[p]) * frac;
    _vertTexU[slot] = _vertTexU[p] + (_vertTexU[q] - _vertTexU[p]) * frac;
    _vertTexV[slot] = _vertTexV[p] + (_vertTexV[q] - _vertTexV[p]) * frac;
    _vertTexPixelSpace[slot] = _vertTexPixelSpace[p];

    final cp = _vertColor[p];
    final cq = _vertColor[q];
    final ap = (cp >>> 24) & 0xFF;
    final rp = (cp >>> 16) & 0xFF;
    final gp = (cp >>> 8) & 0xFF;
    final bp = cp & 0xFF;
    final aq = (cq >>> 24) & 0xFF;
    final rq = (cq >>> 16) & 0xFF;
    final gq = (cq >>> 8) & 0xFF;
    final bq = cq & 0xFF;
    final ai = (ap + (aq - ap) * frac).round().clamp(0, 255);
    final ri = (rp + (rq - rp) * frac).round().clamp(0, 255);
    final gi = (gp + (gq - gp) * frac).round().clamp(0, 255);
    final bi = (bp + (bq - bp) * frac).round().clamp(0, 255);
    _vertColor[slot] = (ai << 24) | (ri << 16) | (gi << 8) | bi;
    return slot;
  }

  void _clipAndEmitPerspectiveTriangle({
    required int a,
    required int b,
    required int c,
    required double nearClip,
    required CameraRig3D camera,
    required Offset canvasOrigin,
    required int matSlot,
    required int sortOrder,
    required double depthBias,
    required double minArea,
  }) {
    _ensureVertexCapacity(_vertCount + 2);
    _ensureTriangleCapacity(_triCount + 2);

    var polyCount = 0;

    void clipEdge(int p, int q) {
      final zp = _vertCamZ[p];
      final zq = _vertCamZ[q];
      final inP = zp >= nearClip;
      final inQ = zq >= nearClip;
      if (inP) {
        _clipPoly[polyCount++] = p;
      }
      if (inP != inQ) {
        final denom = zq - zp;
        final frac = denom.abs() > 1e-9
            ? ((nearClip - zp) / denom).clamp(0.0, 1.0)
            : 0.5;
        _clipPoly[polyCount++] = _interpolateClippedVertex(
          p,
          q,
          frac,
          nearClip,
          camera,
          canvasOrigin,
        );
      }
    }

    clipEdge(a, b);
    clipEdge(b, c);
    clipEdge(c, a);

    if (polyCount < 3) {
      return;
    }
    _nearPlaneClippedTriangles++;
    _emitProjectedTriangle(
      a: _clipPoly[0],
      b: _clipPoly[1],
      c: _clipPoly[2],
      matSlot: matSlot,
      sortOrder: sortOrder,
      depthBias: depthBias,
      minArea: minArea,
    );
    if (polyCount == 4) {
      _emitProjectedTriangle(
        a: _clipPoly[0],
        b: _clipPoly[2],
        c: _clipPoly[3],
        matSlot: matSlot,
        sortOrder: sortOrder,
        depthBias: depthBias,
        minArea: minArea,
      );
    }
  }

  /// Appends a pre-baked [StaticMeshChunk3D] into the active batch using fast
  /// typed-array range copies, preserving both texture UVs (`mesh.uvs` /
  /// `uvRectPx`) and per-instance [Material3D] assignments, and participating
  /// seamlessly in global depth sorting alongside dynamic [enqueueMesh] calls.
  void enqueueStaticChunk(
    StaticMeshChunk3D chunk, {
    required CameraRig3D camera,
    Offset canvasOrigin = Offset.zero,
    Material3D? materialOverride,
    int sortOrder = 0,
    double depthBias = 0.0,
  }) {
    final cullRect = cullScreenBounds;
    if (frustumCullMeshes && cullRect != null && chunk.instanceCount > 0) {
      final (cx3, cy3, cz3, rad3) = chunk.worldBoundingSphere;
      if (rad3 <= 0.0) {
        return;
      }
      final (sx, sy) = camera.projectAnchored(
        anchorWorld: camera.gridToScreen(cx3, cy3),
        canvasOrigin: canvasOrigin,
        rx: 0.0,
        ry: 0.0,
        rz: cz3,
      );
      final radPx = rad3 * camera.focalScalePx * 1.45;
      if (sx + radPx < cullRect.left ||
          sx - radPx > cullRect.right ||
          sy + radPx < cullRect.top ||
          sy - radPx > cullRect.bottom) {
        _frustumCulledMeshes += chunk.instanceCount;
        return;
      }
    }

    chunk.prepare(
      camera: camera,
      light: light,
      environment: environment,
      shadowsEnabled: shadowsEnabled,
      shadowOpacityMultiplier: shadowOpacityMultiplier,
      cullBackfaceShadows: cullBackfaceShadows,
      shadowHeightFalloff: shadowHeightFalloff,
      minTrianglePixelArea: minTrianglePixelArea,
      canvasOrigin: canvasOrigin,
      backfaceCulling: backfaceCulling,
    );
    _culledMicroTriangles += chunk.lastCulledMicroTriangles;
    final vCount = chunk.vertexCount;
    final tCount = chunk.visibleTriCount;
    final (uBuf, vBuf, texUBuf, texVBuf, texPxBuf, colBuf, shTris) = chunk
        .internalBuffers();
    if (vCount == 0 || (tCount == 0 && shTris == 0)) {
      return;
    }
    _enqueuedMeshes += chunk.instanceCount;

    if (tCount > 0) {
      final baseVertex = _vertCount;
      _ensureVertexCapacity(baseVertex + vCount);

      _vertX.setRange(baseVertex, baseVertex + vCount, chunk.projectedVertX);
      _vertY.setRange(baseVertex, baseVertex + vCount, chunk.projectedVertY);
      _vertDepth.setRange(
        baseVertex,
        baseVertex + vCount,
        chunk.projectedVertDepth,
      );
      _vertU.setRange(baseVertex, baseVertex + vCount, uBuf);
      _vertV.setRange(baseVertex, baseVertex + vCount, vBuf);
      _vertTexU.setRange(baseVertex, baseVertex + vCount, texUBuf);
      _vertTexV.setRange(baseVertex, baseVertex + vCount, texVBuf);
      _vertTexPixelSpace.setRange(baseVertex, baseVertex + vCount, texPxBuf);
      _vertColor.setRange(baseVertex, baseVertex + vCount, colBuf);
      _vertCount += vCount;

      final overrideSlot = materialOverride != null
          ? _internMaterial(materialOverride)
          : -1;
      final chunkMats = chunk.materials;
      final remappedSlots = Uint16List(chunkMats.length);
      if (overrideSlot < 0) {
        for (var m = 1; m < chunkMats.length; m++) {
          remappedSlots[m] = _internMaterial(chunkMats[m]);
        }
      }

      final baseTri = _triCount;
      _ensureTriangleCapacity(baseTri + tCount);
      final visA = chunk.visibleTriA;
      final visB = chunk.visibleTriB;
      final visC = chunk.visibleTriC;
      final visD = chunk.visibleTriDepth;
      final visM = chunk.visibleTriMatIdx;
      for (var t = 0; t < tCount; t++) {
        final slot = baseTri + t;
        _triV0[slot] = baseVertex + visA[t];
        _triV1[slot] = baseVertex + visB[t];
        _triV2[slot] = baseVertex + visC[t];
        _triMatSlot[slot] = overrideSlot >= 0
            ? overrideSlot
            : remappedSlots[visM[t]];
        _triSortOrder[slot] = sortOrder;
        _triDepth[slot] = visD[t] + depthBias;
        _triOrder[slot] = slot;
      }
      _triCount += tCount;
    }

    if (shTris > 0) {
      _ensureShadowCapacity(_shadowTriCount + shTris);
      _shadowPositions.setRange(
        _shadowTriCount * 6,
        (_shadowTriCount + shTris) * 6,
        chunk.projectedShadowPositions,
      );
      _shadowColors.setRange(
        _shadowTriCount * 3,
        (_shadowTriCount + shTris) * 3,
        chunk.projectedShadowColors,
      );
      _shadowTriCount += shTris;
    }
  }

  void _sortTrianglesBackToFront(int count) {
    const gaps = <int>[701, 301, 132, 57, 23, 10, 4, 1];
    for (var g = 0; g < gaps.length; g++) {
      final gap = gaps[g];
      if (gap >= count) {
        continue;
      }
      for (var i = gap; i < count; i++) {
        final tempIdx = _triOrder[i];
        final tempSort = _triSortOrder[tempIdx];
        final tempDepth = _triDepth[tempIdx];
        var j = i;
        while (j >= gap) {
          final prevIdx = _triOrder[j - gap];
          final prevSort = _triSortOrder[prevIdx];
          if (prevSort < tempSort ||
              (prevSort == tempSort && _triDepth[prevIdx] <= tempDepth)) {
            break;
          }
          _triOrder[j] = prevIdx;
          j -= gap;
        }
        _triOrder[j] = tempIdx;
      }
    }
  }

  /// Flushes ONLY the accumulated ground-projected shadow triangles onto
  /// [canvas] (ideal for `RenderPass.shadows` in a multi-pass camera while
  /// keeping lit 3D geometry queued for `RenderPass.opaque` via
  /// [flushGeometry]).
  int flushShadows(Canvas canvas, {bool clear = true}) {
    _lastFlushShadowTriangles = _shadowTriCount;
    var draws = 0;
    const maxTrisPerChunk = 21840;

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
        draws++;
        offsetTri += chunkTris;
      }
    }

    if (clear) {
      _shadowTriCount = 0;
    }
    _lastFlushDrawCalls = draws;
    return draws;
  }

  /// Flushes ONLY the accumulated lit 3D geometry onto [canvas], globally
  /// sorting triangles back-to-front across all [Material3D]s and coalescing
  /// contiguous material runs into minimal `Canvas.drawVertices` calls.
  int flushGeometry(
    Canvas canvas, {
    MatCapShader3D? matCapShader,
    MatCapPreset3D? matCapPreset,
    ui.Shader? textureShader,
    double textureWidth = 1.0,
    double textureHeight = 1.0,
    bool clear = true,
  }) {
    _lastFlushTriangles = _triCount;
    _lastFlushMaterialSwitches = 0;
    _lastFrustumCulledMeshes = _frustumCulledMeshes;
    _lastCulledMicroTriangles = _culledMicroTriangles;
    _lastNearPlaneClippedTriangles = _nearPlaneClippedTriangles;
    var draws = 0;

    const maxTrisPerChunk = 21840;

    if (_triCount > 0) {
      if (_triCount > 1) {
        _sortTrianglesBackToFront(_triCount);
      }

      var cursor = 0;
      var prevMatSlot = -1;
      while (cursor < _triCount) {
        final matSlot = _triMatSlot[_triOrder[cursor]];
        if (matSlot != prevMatSlot) {
          if (prevMatSlot != -1) {
            _lastFlushMaterialSwitches++;
          }
          prevMatSlot = matSlot;
        }

        // Measure contiguous run sharing the same material slot (capped at
        // Uint16 index limit of 21,840 triangles = 65,520 vertices).
        var runLen = 1;
        final maxRun = math.min(maxTrisPerChunk, _triCount - cursor);
        while (runLen < maxRun &&
            _triMatSlot[_triOrder[cursor + runLen]] == matSlot) {
          runLen++;
        }

        final mat = _materials[matSlot];
        final ui.Shader? activeShader;
        final bool useTextureUvs;
        final double texW;
        final double texH;
        final ui.BlendMode vertexBlend;
        final ui.BlendMode paintBlend;

        if (mat == null) {
          final hasDefaultTex = textureShader != null;
          final hasDefaultMatCap =
              !hasDefaultTex && matCapShader != null && matCapPreset != null;
          activeShader = hasDefaultTex
              ? textureShader
              : (hasDefaultMatCap
                    ? matCapShader.shaderFor(matCapPreset)
                    : null);
          useTextureUvs = hasDefaultTex;
          texW = textureWidth;
          texH = textureHeight;
          vertexBlend = activeShader != null
              ? ui.BlendMode.modulate
              : ui.BlendMode.dst;
          paintBlend = ui.BlendMode.srcOver;
        } else {
          switch (mat.shading) {
            case MaterialShading3D.unshaded:
              activeShader = null;
              useTextureUvs = false;
              texW = 1.0;
              texH = 1.0;
              vertexBlend = ui.BlendMode.dst;
              paintBlend = mat.blendMode == ui.BlendMode.dst
                  ? ui.BlendMode.srcOver
                  : mat.blendMode;
            case MaterialShading3D.matCap:
              activeShader = matCapShader != null && mat.matCapPreset != null
                  ? matCapShader.shaderFor(mat.matCapPreset!)
                  : null;
              useTextureUvs = false;
              texW = 1.0;
              texH = 1.0;
              vertexBlend = activeShader != null
                  ? ui.BlendMode.modulate
                  : ui.BlendMode.dst;
              paintBlend = mat.blendMode == ui.BlendMode.modulate
                  ? ui.BlendMode.srcOver
                  : mat.blendMode;
            case MaterialShading3D.texture:
              activeShader = mat.textureShader;
              useTextureUvs = activeShader != null;
              texW = mat.textureWidth;
              texH = mat.textureHeight;
              vertexBlend = activeShader != null
                  ? ui.BlendMode.modulate
                  : ui.BlendMode.dst;
              paintBlend = mat.blendMode == ui.BlendMode.modulate
                  ? ui.BlendMode.srcOver
                  : mat.blendMode;
          }
        }

        final emitUvs = activeShader != null;
        _meshPaint
          ..shader = activeShader
          ..blendMode = paintBlend;

        for (var k = 0; k < runLen; k++) {
          final tri = _triOrder[cursor + k];
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

          if (emitUvs) {
            if (useTextureUvs) {
              _outUvs[pOut] = _vertTexPixelSpace[a] != 0
                  ? _vertTexU[a]
                  : _vertTexU[a] * texW;
              _outUvs[pOut + 1] = _vertTexPixelSpace[a] != 0
                  ? _vertTexV[a]
                  : _vertTexV[a] * texH;
              _outUvs[pOut + 2] = _vertTexPixelSpace[b] != 0
                  ? _vertTexU[b]
                  : _vertTexU[b] * texW;
              _outUvs[pOut + 3] = _vertTexPixelSpace[b] != 0
                  ? _vertTexV[b]
                  : _vertTexV[b] * texH;
              _outUvs[pOut + 4] = _vertTexPixelSpace[c] != 0
                  ? _vertTexU[c]
                  : _vertTexU[c] * texW;
              _outUvs[pOut + 5] = _vertTexPixelSpace[c] != 0
                  ? _vertTexV[c]
                  : _vertTexV[c] * texH;
            } else {
              _outUvs[pOut] = _vertU[a];
              _outUvs[pOut + 1] = _vertV[a];
              _outUvs[pOut + 2] = _vertU[b];
              _outUvs[pOut + 3] = _vertV[b];
              _outUvs[pOut + 4] = _vertU[c];
              _outUvs[pOut + 5] = _vertV[c];
            }
          }

          final cOut = k * 3;
          _outColors[cOut] = _vertColor[a];
          _outColors[cOut + 1] = _vertColor[b];
          _outColors[cOut + 2] = _vertColor[c];
        }

        final vertLen = runLen * 3;
        final vertices = ui.Vertices.raw(
          ui.VertexMode.triangles,
          Float32List.sublistView(_outPositions, 0, runLen * 6),
          textureCoordinates: emitUvs
              ? Float32List.sublistView(_outUvs, 0, runLen * 6)
              : null,
          colors: Int32List.sublistView(_outColors, 0, vertLen),
          indices: Uint16List.sublistView(_outIndices, 0, vertLen),
        );
        canvas.drawVertices(vertices, vertexBlend, _meshPaint);
        vertices.dispose();
        draws++;
        cursor += runLen;
      }
      _meshPaint
        ..shader = null
        ..blendMode = ui.BlendMode.srcOver;
    }

    if (clear) {
      _vertCount = 0;
      _triCount = 0;
      _enqueuedMeshes = 0;
      _frustumCulledMeshes = 0;
      _culledMicroTriangles = 0;
      _nearPlaneClippedTriangles = 0;
      if (_materials.length > 1) {
        _materials
          ..clear()
          ..add(null);
      }
    }
    _lastFlushDrawCalls = draws;
    return draws;
  }

  /// Submits all accumulated shadow and 3D mesh triangles onto [canvas],
  /// chunking automatically if vertex counts exceed `65535` and disposing all
  /// native `ui.Vertices` handles immediately.
  void flushBatch(
    Canvas canvas, {
    MatCapShader3D? matCapShader,
    MatCapPreset3D? matCapPreset,
    ui.Shader? textureShader,
    double textureWidth = 1.0,
    double textureHeight = 1.0,
  }) {
    final shDraws = flushShadows(canvas);
    final geoDraws = flushGeometry(
      canvas,
      matCapShader: matCapShader,
      matCapPreset: matCapPreset,
      textureShader: textureShader,
      textureWidth: textureWidth,
      textureHeight: textureHeight,
    );
    _lastFlushDrawCalls = shDraws + geoDraws;
  }
}
