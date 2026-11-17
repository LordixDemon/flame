import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/canvas3d/lighting_kernel_3d.dart';
import 'package:flame/src/canvas3d/matcap_shader_3d.dart';
import 'package:flame/src/canvas3d/material_3d.dart';
import 'package:flame/src/canvas3d/mesh_3d.dart';
import 'package:flame/src/canvas3d/mesh_lod_chain_3d.dart';
import 'package:flame/src/canvas3d/morph_mesh_3d.dart';
import 'package:flame/src/canvas3d/primitives_3d.dart';
import 'package:flame/src/canvas3d/scene_environment_3d.dart';
import 'package:flame/src/canvas3d/skinned_mesh_3d.dart';
import 'package:flame/src/canvas3d/static_mesh_chunk_3d.dart';
import 'package:flame/src/game/graphics_settings.dart';
import 'package:flutter/painting.dart';

/// Zero-allocation Struct-of-Arrays 3D mesh batcher onto Flutter's standard
/// `Canvas` (`Canvas.drawVertices`).
///
/// Transforms, lights, back-face culls, near-plane clips in perspective mode,
/// globally depth-sorts across `[sortOrder, depth + depthBias]` and multiple
/// [Material3D]s (textures, MatCap presets, and [ui.BlendMode]s), and batches
/// arbitrary [Mesh3D], [MorphMeshWorkspace3D], [SkinnedMeshWorkspace3D], and
/// [StaticMeshChunk3D] instances into minimal `Vertices.raw` GPU draw calls.
///
/// Triangles with the same `sortOrder` and depth are drawn in the order they
/// were enqueued. `depthMode` is read when a mesh or chunk is enqueued, so it
/// can be switched between enqueue calls (for example
/// [TriangleDepthMode3D.farthestVertex] for a large ground mesh and
/// [TriangleDepthMode3D.centroid] for the props standing on it).
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
  ///
  /// The test is conservative in both projection modes and under any mesh
  /// rotation: a mesh (or its ground shadow) that reaches into
  /// [cullScreenBounds] is never dropped.
  bool frustumCullMeshes;

  /// Optional screen/canvas culling rectangle in the same coordinate space as
  /// projected mesh vertices (`null` disables frustum culling).
  Rect? cullScreenBounds;

  /// Minimum projected triangle area in square screen pixels (`0.0`
  /// disables). Projected canvas areas are scaled by `CameraRig3D.camZoom`
  /// squared before they are compared with it.
  ///
  /// Smaller triangles are dropped per mesh (per instance of a
  /// [StaticMeshChunk3D]), and only where that cannot open holes: when the
  /// whole visible mesh is smaller than this area, or when its micro-triangles
  /// add up to at most 5 % of its visible area. A densely tessellated mesh
  /// that is still visible keeps every triangle; thin those out with a
  /// [MeshLodChain3D] instead.
  double minTrianglePixelArea;

  final Paint _meshPaint = Paint()..isAntiAlias = true;
  final Paint _shadowPaint = Paint()..isAntiAlias = true;
  final Float32List _rotScratch = Float32List(9);
  final Float32List _normalRotScratch = Float32List(9);
  double _matrixStretch = 1.0;
  bool _matrixMirrored = false;
  final Int32List _clipPoly = Int32List(4);
  int _clipPolyCount = 0;

  // World-relative vertex positions of the mesh being enqueued, kept only
  // while it casts a ground shadow.
  Float64List _relX = Float64List(0);
  Float64List _relY = Float64List(0);
  Float64List _relZ = Float64List(0);

  // Visible / micro-triangle area sums (doubled) of the mesh being enqueued.
  double _meshVisibleArea2 = 0.0;
  double _meshMicroArea2 = 0.0;
  int _meshMicroCount = 0;

  Uint16List _chunkMatRemap = Uint16List(8);
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

  /// Largest vertex count one `Vertices.raw` call can address with 16-bit
  /// indices.
  static const int _maxDrawVertices = 65535;

  /// Triangles per `Vertices.raw` call (`3 * 21,840 = 65,520` vertices).
  static const int _maxTrisPerDraw = 21840;

  static Uint16List _buildSequentialIndices(int vertexCount) {
    final clamped = math.min(vertexCount, _maxDrawVertices);
    final out = Uint16List(clamped);
    for (var i = 0; i < clamped; i++) {
      out[i] = i;
    }
    return out;
  }

  /// Doubles [current] (treating an empty buffer as one slot) until it holds
  /// [needed] entries.
  static int _grownCapacity(int current, int needed) {
    var cap = current < 1 ? 1 : current;
    while (cap < needed) {
      cap *= 2;
    }
    return cap;
  }

  /// Grows the sequential index buffer shared by the geometry and the shadow
  /// flush. It only ever grows: both flushes slice it from the start, so
  /// whichever of them needs more decides its length.
  void _ensureIndexCapacity(int vertexCount) {
    final needed = math.min(vertexCount, _maxDrawVertices);
    if (needed > _outIndices.length) {
      _outIndices = _buildSequentialIndices(needed);
    }
  }

  int _internMaterial(Material3D? mat) =>
      LightingKernel3D.internMaterial(_materials, mat);

  void _ensureVertexCapacity(int needed) {
    if (needed <= _vertX.length) {
      return;
    }
    final cap = _grownCapacity(_vertX.length, needed);
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
    final cap = _grownCapacity(_triV0.length, needed);
    _triV0 = Int32List(cap)..setRange(0, _triCount, _triV0);
    _triV1 = Int32List(cap)..setRange(0, _triCount, _triV1);
    _triV2 = Int32List(cap)..setRange(0, _triCount, _triV2);
    _triMatSlot = Uint16List(cap)..setRange(0, _triCount, _triMatSlot);
    _triSortOrder = Int32List(cap)..setRange(0, _triCount, _triSortOrder);
    _triDepth = Float32List(cap)..setRange(0, _triCount, _triDepth);
    _triOrder = Int32List(cap)..setRange(0, _triCount, _triOrder);
    // A flush never emits more than one draw call's worth at a time.
    final outTris = math.min(cap, _maxTrisPerDraw);
    if (outTris * 3 > _outColors.length) {
      _outPositions = Float32List(outTris * 6);
      _outUvs = Float32List(outTris * 6);
      _outColors = Int32List(outTris * 3);
    }
    _ensureIndexCapacity(outTris * 3);
  }

  void _ensureShadowCapacity(int neededTris) {
    if (neededTris * 6 <= _shadowPositions.length) {
      return;
    }
    final cap = _grownCapacity(_shadowPositions.length ~/ 6, neededTris);
    _shadowPositions = Float32List(cap * 6)
      ..setRange(0, _shadowTriCount * 6, _shadowPositions);
    _shadowColors = Int32List(cap * 3)
      ..setRange(0, _shadowTriCount * 3, _shadowColors);
    _ensureIndexCapacity(cap * 3);
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
  /// (row-major `Float32List` of length `>= 9`), unit [rotationQuat]
  /// `(qx, qy, qz, qw)`, or Euler `(yawRad, pitchRad, rollRad)`.
  ///
  /// [rotationMatrix3] is applied after `(scaleX, scaleY, scaleZ)` and may be
  /// any invertible linear matrix, not only a rotation: scale, shear and
  /// mirroring inside it are honoured by the normals, the triangle winding
  /// and the culling bounds (as `Node3D.worldLinearMatrix` relies on).
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
  ///
  /// [boundingRadius] must be at least the distance of the farthest vertex
  /// from the local origin; frustum culling relies on it alone, so that it
  /// holds under any rotation. [minZ] and [maxZ] are not needed for that and
  /// are accepted for source compatibility.
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

    LightingKernel3D.resolveRotationMatrix3(
      out: _rotScratch,
      rotationMatrix3: rotationMatrix3,
      rotationQuat: rotationQuat,
      yawRad: yawRad,
      pitchRad: pitchRad,
      rollRad: rollRad,
    );
    // Euler angles and quaternions always give a pure rotation. A matrix the
    // caller supplies may also carry scale, shear or a mirror, which changes
    // the normal transform, the triangle winding and the bounding radius.
    var normalRot = _rotScratch;
    _matrixStretch = 1.0;
    _matrixMirrored = false;
    if (rotationMatrix3 != null && rotationMatrix3.length >= 9) {
      normalRot = _classifyLinearMatrix();
    }
    final reverseWinding =
        ((scaleX * scaleY * scaleZ) < 0.0) != _matrixMirrored;

    final anchorWorld = camera.gridToScreen(worldX, worldY);
    final effShadowOpacity = (castGroundShadow && shadowsEnabled)
        ? shadowOpacity * shadowOpacityMultiplier.clamp(0.0, 2.0)
        : 0.0;
    final lx = light.dirX;
    final ly = light.dirY;
    final lz = light.dirZ;
    final castsShadow = effShadowOpacity > 0.0 && lz > 0.08;

    final cullRect = cullScreenBounds;
    if (frustumCullMeshes && cullRect != null) {
      final maxScale = math.max(
        scaleX.abs(),
        math.max(scaleY.abs(), scaleZ.abs()),
      );
      // `boundingRadius` is measured from the mesh origin, so this sphere
      // holds the mesh under any rotation.
      var radius = boundingRadius * maxScale * _matrixStretch;
      if (castsShadow) {
        radius += _shadowReach(worldZ + radius - groundZ, lz);
      }
      if (_sphereOutsideCullRect(
        camera,
        worldX,
        worldY,
        worldZ,
        radius,
        canvasOrigin,
        cullRect,
      )) {
        _frustumCulledMeshes++;
        return;
      }
    }

    _enqueuedMeshes++;

    final vCount = positions.length ~/ 3;
    final baseVertex = _vertCount;
    _ensureVertexCapacity(baseVertex + vCount);
    if (castsShadow && _relX.length < vCount) {
      final cap = _grownCapacity(_relX.length, vCount);
      _relX = Float64List(cap);
      _relY = Float64List(cap);
      _relZ = Float64List(cap);
    }

    final r00 = _rotScratch[0];
    final r01 = _rotScratch[1];
    final r02 = _rotScratch[2];
    final r10 = _rotScratch[3];
    final r11 = _rotScratch[4];
    final r12 = _rotScratch[5];
    final r20 = _rotScratch[6];
    final r21 = _rotScratch[7];
    final r22 = _rotScratch[8];

    final invSx = scaleX.abs() > 1e-6 ? 1.0 / scaleX : 1.0;
    final invSy = scaleY.abs() > 1e-6 ? 1.0 / scaleY : 1.0;
    final invSz = scaleZ.abs() > 1e-6 ? 1.0 / scaleZ : 1.0;

    final tintR = tint.r;
    final tintG = tint.g;
    final tintB = tint.b;
    final tintA = tint.a * clampedOpacity;

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
      final wx = worldX + rx;
      final wy = worldY + ry;
      if (castsShadow) {
        _relX[v] = rx;
        _relY[v] = ry;
        _relZ[v] = rz;
      }

      final double sx;
      final double sy;
      var camX = 0.0;
      var camY = 0.0;
      var camZ = nearClip;
      if (isPerspective) {
        (camX, camY, camZ) = camera.worldToCameraSpace(wx, wy, rz);
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

      final vDepth = camera.viewDepth(wx, wy, rz);
      final outSlot = baseVertex + v;
      _vertX[outSlot] = sx;
      _vertY[outSlot] = sy;
      _vertDepth[outSlot] = vDepth;
      if (isPerspective) {
        _vertCamX[outSlot] = camX;
        _vertCamY[outSlot] = camY;
        _vertCamZ[outSlot] = camZ;
      }

      LightingKernel3D.shadeVertexInto(
        vertexIndex: v,
        outSlot: outSlot,
        normals: normals,
        rot: normalRot,
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
        emissive: emissive,
        outVertU: _vertU,
        outVertV: _vertV,
        outVertTexU: _vertTexU,
        outVertTexV: _vertTexV,
        outVertTexPixelSpace: _vertTexPixelSpace,
        outVertColor: _vertColor,
        uvs: uvs,
        uvRectPx: uvRectPx,
        ambientOcclusion: ambientOcclusion,
        vertexColors: vertexColors,
        rimColor: rimColor,
        rimHighlightIntensity: rimHighlightIntensity,
      );
    }
    _vertCount += vCount;

    final matSlot = _internMaterial(material);
    _ensureTriangleCapacity(_triCount + mTriCount);

    final minArea2 = LightingKernel3D.microTriangleThreshold2(
      minTrianglePixelArea,
      camera,
    );
    final firstTriSlot = _triCount;
    _meshVisibleArea2 = 0.0;
    _meshMicroArea2 = 0.0;
    _meshMicroCount = 0;
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
            minArea2: minArea2,
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
        minArea2: minArea2,
      );
    }
    if (_meshMicroCount > 0) {
      _cullMicroTriangles(firstTriSlot, minArea2);
    }

    if (castsShadow) {
      _ensureShadowCapacity(_shadowTriCount + mTriCount);
      final baseShadowAlpha = effShadowOpacity * clampedOpacity * 255.0;
      final shadowRgb = shadowColor.toARGB32() & 0x00FFFFFF;
      final slopeX = -lx / lz;
      final slopeY = -ly / lz;
      final cullShadowBackfaces = cullBackfaceShadows && !doubleSidedShadow;

      for (var t = 0; t < mTriCount; t++) {
        final idxBase = t * 3;
        final int i0;
        final int i1;
        final int i2;
        if (indices16 != null) {
          i0 = indices16[idxBase];
          if (reverseWinding) {
            i1 = indices16[idxBase + 2];
            i2 = indices16[idxBase + 1];
          } else {
            i1 = indices16[idxBase + 1];
            i2 = indices16[idxBase + 2];
          }
        } else {
          i0 = indices32![idxBase];
          if (reverseWinding) {
            i1 = indices32[idxBase + 2];
            i2 = indices32[idxBase + 1];
          } else {
            i1 = indices32[idxBase + 1];
            i2 = indices32[idxBase + 2];
          }
        }

        final rx0 = _relX[i0];
        final ry0 = _relY[i0];
        final rz0 = _relZ[i0];
        final rx1 = _relX[i1];
        final ry1 = _relY[i1];
        final rz1 = _relZ[i1];
        final rx2 = _relX[i2];
        final ry2 = _relY[i2];
        final rz2 = _relZ[i2];

        if (cullShadowBackfaces) {
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

        final pOut = _shadowTriCount * 6;
        final cOut = _shadowTriCount * 3;
        _shadowPositions[pOut] = sx0;
        _shadowPositions[pOut + 1] = sy0;
        _shadowPositions[pOut + 2] = sx1;
        _shadowPositions[pOut + 3] = sy1;
        _shadowPositions[pOut + 4] = sx2;
        _shadowPositions[pOut + 5] = sy2;
        _shadowColors[cOut] = _shadowArgb(baseShadowAlpha, shadowRgb, dz0);
        _shadowColors[cOut + 1] = _shadowArgb(baseShadowAlpha, shadowRgb, dz1);
        _shadowColors[cOut + 2] = _shadowArgb(baseShadowAlpha, shadowRgb, dz2);
        _shadowTriCount++;
      }
    }
  }

  int _shadowArgb(double baseAlpha, int rgb, double heightAboveGround) {
    final atten = shadowHeightFalloff > 0.0
        ? 1.0 / (1.0 + heightAboveGround * shadowHeightFalloff)
        : 1.0;
    final a = (baseAlpha * atten).round().clamp(0, 255);
    return (a << 24) | rgb;
  }

  /// How far (in world units) a ground shadow can land from a caster whose
  /// highest point is [heightAboveGround] above the shadow plane: the drop to
  /// the plane plus the horizontal slide along the light direction.
  static double _shadowReach(double heightAboveGround, double lightDirZ) {
    if (heightAboveGround <= 0.0) {
      return 0.0;
    }
    return heightAboveGround * (1.0 + 1.0 / lightDirZ);
  }

  /// Inspects the caller-supplied linear matrix in [_rotScratch], records its
  /// largest stretch factor and handedness in [_matrixStretch] /
  /// [_matrixMirrored], and returns the matrix that transforms normals: the
  /// matrix itself for a pure rotation, otherwise its inverse transpose.
  Float32List _classifyLinearMatrix() {
    final m = _rotScratch;
    final m00 = m[0];
    final m01 = m[1];
    final m02 = m[2];
    final m10 = m[3];
    final m11 = m[4];
    final m12 = m[5];
    final m20 = m[6];
    final m21 = m[7];
    final m22 = m[8];

    // Squared column lengths and column dot products (entries of `M^T M`).
    final c00 = m00 * m00 + m10 * m10 + m20 * m20;
    final c11 = m01 * m01 + m11 * m11 + m21 * m21;
    final c22 = m02 * m02 + m12 * m12 + m22 * m22;
    final c01 = m00 * m01 + m10 * m11 + m20 * m21;
    final c02 = m00 * m02 + m10 * m12 + m20 * m22;
    final c12 = m01 * m02 + m11 * m12 + m21 * m22;

    final cof00 = m11 * m22 - m12 * m21;
    final cof01 = m12 * m20 - m10 * m22;
    final cof02 = m10 * m21 - m11 * m20;
    final det = m00 * cof00 + m01 * cof01 + m02 * cof02;

    const tol = 1e-4;
    if (det > 0.0 &&
        (c00 - 1.0).abs() < tol &&
        (c11 - 1.0).abs() < tol &&
        (c22 - 1.0).abs() < tol &&
        c01.abs() < tol &&
        c02.abs() < tol &&
        c12.abs() < tol) {
      return m;
    }

    final maxCol2 = math.max(c00, math.max(c11, c22));
    final orthogonalColumns =
        c01 * c01 <= tol * tol * c00 * c11 &&
        c02 * c02 <= tol * tol * c00 * c22 &&
        c12 * c12 <= tol * tol * c11 * c22;
    // Orthogonal columns: the longest column is the exact stretch. Otherwise
    // the Frobenius norm is a safe upper bound of it.
    _matrixStretch = math.sqrt(orthogonalColumns ? maxCol2 : c00 + c11 + c22);
    _matrixMirrored = det < 0.0;

    final cof10 = m02 * m21 - m01 * m22;
    final cof11 = m00 * m22 - m02 * m20;
    final cof12 = m01 * m20 - m00 * m21;
    final cof20 = m01 * m12 - m02 * m11;
    final cof21 = m02 * m10 - m00 * m12;
    final cof22 = m00 * m11 - m01 * m10;
    var maxAbs = cof00.abs();
    maxAbs = math.max(maxAbs, cof01.abs());
    maxAbs = math.max(maxAbs, cof02.abs());
    maxAbs = math.max(maxAbs, cof10.abs());
    maxAbs = math.max(maxAbs, cof11.abs());
    maxAbs = math.max(maxAbs, cof12.abs());
    maxAbs = math.max(maxAbs, cof20.abs());
    maxAbs = math.max(maxAbs, cof21.abs());
    maxAbs = math.max(maxAbs, cof22.abs());
    if (det.abs() < 1e-18 || maxAbs < 1e-18) {
      // Singular matrix: the surface collapsed, there is no normal to keep.
      return m;
    }
    // The inverse transpose is `cofactor / det`; normals are renormalised
    // afterwards, so only the sign of `det` matters.
    final k = (det < 0.0 ? -1.0 : 1.0) / maxAbs;
    final n = _normalRotScratch;
    n[0] = cof00 * k;
    n[1] = cof01 * k;
    n[2] = cof02 * k;
    n[3] = cof10 * k;
    n[4] = cof11 * k;
    n[5] = cof12 * k;
    n[6] = cof20 * k;
    n[7] = cof21 * k;
    n[8] = cof22 * k;
    return n;
  }

  /// Whether the world-space sphere `(cx, cy, cz, radius)` projects entirely
  /// outside [cullRect] (given in the canvas space of projected vertices).
  bool _sphereOutsideCullRect(
    CameraRig3D camera,
    double cx,
    double cy,
    double cz,
    double radius,
    Offset canvasOrigin,
    Rect cullRect,
  ) {
    if (camera.projectionMode == CameraProjectionMode3D.perspective) {
      final (camX, camY, camZ) = camera.worldToCameraSpace(cx, cy, cz);
      final nearClip = camera.nearClip;
      final zFar = camZ + radius;
      if (zFar < nearClip) {
        // Entirely behind the near plane: every triangle is clipped away.
        return true;
      }
      final zNear = math.max(nearClip, camZ - radius);
      final focal = camera.perspectiveFocalLengthPx;
      // `x / z` over the sphere peaks at the nearest depth when `x` points
      // away from the optical axis and at the farthest depth otherwise.
      final xMax = camX + radius;
      final xMin = camX - radius;
      final yMax = camY + radius;
      final yMin = camY - radius;
      final right = (xMax >= 0.0 ? xMax / zNear : xMax / zFar) * focal;
      final left = (xMin <= 0.0 ? xMin / zNear : xMin / zFar) * focal;
      final bottom = (yMax >= 0.0 ? yMax / zNear : yMax / zFar) * focal;
      final top = (yMin <= 0.0 ? yMin / zNear : yMin / zFar) * focal;
      final ox = camera.camWorldX - canvasOrigin.dx;
      final oy = camera.camWorldY - canvasOrigin.dy;
      return ox + right < cullRect.left ||
          ox + left > cullRect.right ||
          oy + bottom < cullRect.top ||
          oy + top > cullRect.bottom;
    }

    final anchor = camera.gridToScreen(cx, cy);
    final (sx, sy) = camera.projectAnchored(
      anchorWorld: anchor,
      canvasOrigin: canvasOrigin,
      rx: 0.0,
      ry: 0.0,
      rz: cz,
    );
    // A point at most `radius` from the centre lands within
    // `radius * focalScalePx` of it, grown by the height parallax, which
    // scales with the point's height and with the distance of its anchor from
    // the camera focus.
    final persp = camera.perspectiveStrength;
    final focusDist = math.max(
      (anchor.dx - camera.camWorldX).abs(),
      (anchor.dy - camera.camWorldY).abs(),
    );
    final radPx =
        (radius * camera.focalScalePx * (1.0 + (cz.abs() + radius) * persp) +
                radius * persp * focusDist) *
            1.001 +
        0.5;
    return sx + radPx < cullRect.left ||
        sx - radPx > cullRect.right ||
        sy + radPx < cullRect.top ||
        sy - radPx > cullRect.bottom;
  }

  void _cullMicroTriangles(int firstSlot, double minArea2) {
    if (!LightingKernel3D.shouldCullMicroTriangles(
      visibleArea2: _meshVisibleArea2,
      microArea2: _meshMicroArea2,
      minArea2: minArea2,
    )) {
      return;
    }
    var write = firstSlot;
    for (var read = firstSlot; read < _triCount; read++) {
      final a = _triV0[read];
      final b = _triV1[read];
      final c = _triV2[read];
      final ax = _vertX[a];
      final ay = _vertY[a];
      final cross =
          (_vertX[b] - ax) * (_vertY[c] - ay) -
          (_vertY[b] - ay) * (_vertX[c] - ax);
      if (cross.abs() < minArea2) {
        _culledMicroTriangles++;
        continue;
      }
      if (write != read) {
        _triV0[write] = a;
        _triV1[write] = b;
        _triV2[write] = c;
        _triMatSlot[write] = _triMatSlot[read];
        _triSortOrder[write] = _triSortOrder[read];
        _triDepth[write] = _triDepth[read];
      }
      _triOrder[write] = write;
      write++;
    }
    _triCount = write;
  }

  void _emitProjectedTriangle({
    required int a,
    required int b,
    required int c,
    required int matSlot,
    required int sortOrder,
    required double depthBias,
    required double minArea2,
  }) {
    final ax = _vertX[a];
    final ay = _vertY[a];
    final cross =
        (_vertX[b] - ax) * (_vertY[c] - ay) -
        (_vertY[b] - ay) * (_vertX[c] - ax);
    if (backfaceCulling && cross <= 1e-3) {
      return;
    }
    if (minArea2 > 0.0) {
      final area2 = cross.abs();
      _meshVisibleArea2 += area2;
      if (area2 < minArea2) {
        _meshMicroArea2 += area2;
        _meshMicroCount++;
      }
    }

    _ensureTriangleCapacity(_triCount + 1);
    final slot = _triCount++;
    _triV0[slot] = a;
    _triV1[slot] = b;
    _triV2[slot] = c;
    _triMatSlot[slot] = matSlot;
    _triSortOrder[slot] = sortOrder;
    _triDepth[slot] =
        depthMode.depthOf(_vertDepth[a], _vertDepth[b], _vertDepth[c]) +
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

  void _clipEdge(
    int p,
    int q,
    double nearClip,
    CameraRig3D camera,
    Offset canvasOrigin,
  ) {
    final zp = _vertCamZ[p];
    final zq = _vertCamZ[q];
    final inP = zp >= nearClip;
    final inQ = zq >= nearClip;
    if (inP) {
      _clipPoly[_clipPolyCount++] = p;
    }
    if (inP != inQ) {
      final denom = zq - zp;
      final frac = denom.abs() > 1e-9
          ? ((nearClip - zp) / denom).clamp(0.0, 1.0)
          : 0.5;
      _clipPoly[_clipPolyCount++] = _interpolateClippedVertex(
        p,
        q,
        frac,
        nearClip,
        camera,
        canvasOrigin,
      );
    }
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
    required double minArea2,
  }) {
    _ensureVertexCapacity(_vertCount + 2);
    _ensureTriangleCapacity(_triCount + 2);

    _clipPolyCount = 0;
    _clipEdge(a, b, nearClip, camera, canvasOrigin);
    _clipEdge(b, c, nearClip, camera, canvasOrigin);
    _clipEdge(c, a, nearClip, camera, canvasOrigin);

    final polyCount = _clipPolyCount;
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
      minArea2: minArea2,
    );
    if (polyCount == 4) {
      _emitProjectedTriangle(
        a: _clipPoly[0],
        b: _clipPoly[2],
        c: _clipPoly[3],
        matSlot: matSlot,
        sortOrder: sortOrder,
        depthBias: depthBias,
        minArea2: minArea2,
      );
    }
  }

  /// Appends a pre-baked [StaticMeshChunk3D] into the active batch using fast
  /// typed-array range copies, preserving both texture UVs (`mesh.uvs` /
  /// `uvRectPx`) and per-instance [Material3D] assignments, and participating
  /// in global depth sorting alongside dynamic [enqueueMesh] calls with the
  /// same [depthMode].
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
      var radius = rad3;
      if (shadowsEnabled && light.dirZ > 0.08) {
        radius += _shadowReach(chunk.shadowCasterHeight, light.dirZ);
      }
      if (_sphereOutsideCullRect(
        camera,
        cx3,
        cy3,
        cz3,
        radius,
        canvasOrigin,
        cullRect,
      )) {
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
      depthMode: depthMode,
    );
    _culledMicroTriangles += chunk.lastCulledMicroTriangles;
    final vCount = chunk.vertexCount;
    final tCount = chunk.visibleTriCount;
    final shTris = chunk.projectedShadowTriCount;
    if (vCount == 0 || (tCount == 0 && shTris == 0)) {
      return;
    }
    _enqueuedMeshes += chunk.instanceCount;

    if (tCount > 0) {
      final baseVertex = _vertCount;
      _ensureVertexCapacity(baseVertex + vCount);
      final endVertex = baseVertex + vCount;

      _vertX.setRange(baseVertex, endVertex, chunk.projectedVertX);
      _vertY.setRange(baseVertex, endVertex, chunk.projectedVertY);
      _vertDepth.setRange(baseVertex, endVertex, chunk.projectedVertDepth);
      _vertU.setRange(baseVertex, endVertex, chunk.bakedMatCapU);
      _vertV.setRange(baseVertex, endVertex, chunk.bakedMatCapV);
      _vertTexU.setRange(baseVertex, endVertex, chunk.bakedTexU);
      _vertTexV.setRange(baseVertex, endVertex, chunk.bakedTexV);
      _vertTexPixelSpace.setRange(
        baseVertex,
        endVertex,
        chunk.bakedTexPixelSpace,
      );
      _vertColor.setRange(baseVertex, endVertex, chunk.bakedVertColor);
      _vertCount += vCount;

      final overrideSlot = materialOverride != null
          ? _internMaterial(materialOverride)
          : -1;
      final chunkMats = chunk.materials;
      if (_chunkMatRemap.length < chunkMats.length) {
        _chunkMatRemap = Uint16List(
          _grownCapacity(_chunkMatRemap.length, chunkMats.length),
        );
      }
      final remappedSlots = _chunkMatRemap;
      remappedSlots[0] = 0;
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

  /// Orders [_triOrder] by `sortOrder`, then depth (farthest first), then
  /// submission order.
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
          if (prevSort < tempSort) {
            break;
          }
          if (prevSort == tempSort) {
            final prevDepth = _triDepth[prevIdx];
            // Equal keys fall back to submission order, so a tie never
            // depends on what else happens to share the batch.
            if (prevDepth < tempDepth ||
                (prevDepth == tempDepth && prevIdx < tempIdx)) {
              break;
            }
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
    const maxTrisPerChunk = _maxTrisPerDraw;

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

    const maxTrisPerChunk = _maxTrisPerDraw;

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
