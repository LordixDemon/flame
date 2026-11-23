import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:meta/meta.dart';

part 'chunked_terrain_mesher_3d.dart';
part 'chunked_terrain_raycast_3d.dart';

/// Normalized 4-layer biome weights (`sand + grass + rock + snow == 1.0`) at a
/// point on a [ChunkedTerrain3D].
class TerrainBiomeWeights3D(
  final double sand,
  final double grass,
  final double rock,
  final double snow,
);

/// Configurable 4-biome elevation and slope palette (`sand -> grass -> rock ->
/// snow`) baked into [ChunkedTerrain3D] vertex colors.
class const TerrainBiomePalette3D({
  /// Low-elevation shoreline/desert tint.
  final Color sandColor = const Color(0xFFE3C888),

  /// Mid-elevation meadow/forest tint.
  final Color grassColor = const Color(0xFF4C8C3B),

  /// Steep-cliff and upper-ridge stone tint.
  final Color rockColor = const Color(0xFF75716C),

  /// High-altitude peak snow tint.
  final Color snowColor = const Color(0xFFF3F7FB),

  /// Normalized height `[0..1]` below which sand dominates flat terrain.
  final double sandMaxHeight = 0.18,

  /// Normalized height `[0..1]` above which snow dominates moderate slopes.
  final double snowMinHeight = 0.74,

  /// Unit normal `Y` threshold below which steep slopes transition to rock.
  final double rockSlopeNormalMaxY = 0.76,

  /// Transition half-width for smooth biome blending.
  final double blendSharpness = 0.12,
}) {
  /// Evaluates normalized 4-biome weights from [normalizedHeight] (`[0..1]`)
  /// and upward surface normal component [normalY] (`[0..1]`).
  TerrainBiomeWeights3D evaluateWeights(
    double normalizedHeight,
    double normalY,
  ) {
    final h = normalizedHeight.clamp(0.0, 1.0);
    final ny = normalY.clamp(0.0, 1.0);
    final w = math.max(0.02, blendSharpness);

    final steepRock =
        1.0 -
        _smoothstep(
          rockSlopeNormalMaxY - w,
          rockSlopeNormalMaxY + w,
          ny,
        );
    final highRock =
        _smoothstep(snowMinHeight - w * 2.0, snowMinHeight, h) *
        (1.0 - _smoothstep(snowMinHeight, snowMinHeight + w, h)) *
        0.55;
    final rockRaw = math.max(steepRock, highRock).clamp(0.0, 1.0);

    final flatMask = (1.0 - rockRaw).clamp(0.0, 1.0);
    final sandFactor =
        1.0 - _smoothstep(sandMaxHeight - w, sandMaxHeight + w, h);
    final snowFactor =
        _smoothstep(snowMinHeight - w, snowMinHeight + w, h) *
        _smoothstep(rockSlopeNormalMaxY - 0.15, rockSlopeNormalMaxY + 0.05, ny);
    final grassFactor = (1.0 - sandFactor - snowFactor).clamp(0.0, 1.0);

    var wSand = flatMask * sandFactor;
    var wGrass = flatMask * grassFactor;
    var wSnow = flatMask * snowFactor + (1.0 - flatMask) * snowFactor * 0.25;
    var wRock = rockRaw * (1.0 - snowFactor * 0.25);

    final sum = wSand + wGrass + wRock + wSnow;
    if (sum > 1e-8) {
      final inv = 1.0 / sum;
      wSand *= inv;
      wGrass *= inv;
      wRock *= inv;
      wSnow *= inv;
    } else {
      wGrass = 1.0;
    }
    return TerrainBiomeWeights3D(wSand, wGrass, wRock, wSnow);
  }

  /// Blends the 4 biome colors using [evaluateWeights].
  Color evaluateColor(double normalizedHeight, double normalY) {
    final h = normalizedHeight.clamp(0.0, 1.0);
    final ny = normalY.clamp(0.0, 1.0);
    final w = math.max(0.02, blendSharpness);

    final steepRock =
        1.0 -
        _smoothstep(
          rockSlopeNormalMaxY - w,
          rockSlopeNormalMaxY + w,
          ny,
        );
    final highRock =
        _smoothstep(snowMinHeight - w * 2.0, snowMinHeight, h) *
        (1.0 - _smoothstep(snowMinHeight, snowMinHeight + w, h)) *
        0.55;
    final rockRaw = math.max(steepRock, highRock).clamp(0.0, 1.0);

    final flatMask = (1.0 - rockRaw).clamp(0.0, 1.0);
    final sandFactor =
        1.0 - _smoothstep(sandMaxHeight - w, sandMaxHeight + w, h);
    final snowFactor =
        _smoothstep(snowMinHeight - w, snowMinHeight + w, h) *
        _smoothstep(rockSlopeNormalMaxY - 0.15, rockSlopeNormalMaxY + 0.05, ny);
    final grassFactor = (1.0 - sandFactor - snowFactor).clamp(0.0, 1.0);

    var wSand = flatMask * sandFactor;
    var wGrass = flatMask * grassFactor;
    var wSnow = flatMask * snowFactor + (1.0 - flatMask) * snowFactor * 0.25;
    var wRock = rockRaw * (1.0 - snowFactor * 0.25);

    final sum = wSand + wGrass + wRock + wSnow;
    if (sum > 1e-8) {
      final inv = 1.0 / sum;
      wSand *= inv;
      wGrass *= inv;
      wRock *= inv;
      wSnow *= inv;
    } else {
      wGrass = 1.0;
    }
    final r =
        sandColor.r * wSand +
        grassColor.r * wGrass +
        rockColor.r * wRock +
        snowColor.r * wSnow;
    final g =
        sandColor.g * wSand +
        grassColor.g * wGrass +
        rockColor.g * wRock +
        snowColor.g * wSnow;
    final b =
        sandColor.b * wSand +
        grassColor.b * wGrass +
        rockColor.b * wRock +
        snowColor.b * wSnow;
    return Color.from(
      alpha: 1,
      red: r.clamp(0.0, 1.0),
      green: g.clamp(0.0, 1.0),
      blue: b.clamp(0.0, 1.0),
    );
  }

  /// Writes the blended 4-biome RGBA color directly into [out] at [offset]
  /// without allocating.
  @internal
  void writeColorTo(
    double normalizedHeight,
    double normalY,
    Float32List out,
    int offset,
  ) {
    final h = normalizedHeight.clamp(0.0, 1.0);
    final ny = normalY.clamp(0.0, 1.0);
    final w = math.max(0.02, blendSharpness);

    final steepRock =
        1.0 -
        _smoothstep(
          rockSlopeNormalMaxY - w,
          rockSlopeNormalMaxY + w,
          ny,
        );
    final highRock =
        _smoothstep(snowMinHeight - w * 2.0, snowMinHeight, h) *
        (1.0 - _smoothstep(snowMinHeight, snowMinHeight + w, h)) *
        0.55;
    final rockRaw = math.max(steepRock, highRock).clamp(0.0, 1.0);

    final flatMask = (1.0 - rockRaw).clamp(0.0, 1.0);
    final sandFactor =
        1.0 - _smoothstep(sandMaxHeight - w, sandMaxHeight + w, h);
    final snowFactor =
        _smoothstep(snowMinHeight - w, snowMinHeight + w, h) *
        _smoothstep(rockSlopeNormalMaxY - 0.15, rockSlopeNormalMaxY + 0.05, ny);
    final grassFactor = (1.0 - sandFactor - snowFactor).clamp(0.0, 1.0);

    var wSand = flatMask * sandFactor;
    var wGrass = flatMask * grassFactor;
    var wSnow = flatMask * snowFactor + (1.0 - flatMask) * snowFactor * 0.25;
    var wRock = rockRaw * (1.0 - snowFactor * 0.25);

    final sum = wSand + wGrass + wRock + wSnow;
    if (sum > 1e-8) {
      final inv = 1.0 / sum;
      wSand *= inv;
      wGrass *= inv;
      wRock *= inv;
      wSnow *= inv;
    } else {
      wGrass = 1.0;
    }
    final r =
        sandColor.r * wSand +
        grassColor.r * wGrass +
        rockColor.r * wRock +
        snowColor.r * wSnow;
    final g =
        sandColor.g * wSand +
        grassColor.g * wGrass +
        rockColor.g * wRock +
        snowColor.g * wSnow;
    final b =
        sandColor.b * wSand +
        grassColor.b * wGrass +
        rockColor.b * wRock +
        snowColor.b * wSnow;
    out
      ..[offset] = r.clamp(0.0, 1.0)
      ..[offset + 1] = g.clamp(0.0, 1.0)
      ..[offset + 2] = b.clamp(0.0, 1.0)
      ..[offset + 3] = 1.0;
  }

  static double _smoothstep(double edge0, double edge1, double x) {
    if (edge1 <= edge0) {
      return x >= edge0 ? 1.0 : 0.0;
    }
    final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }
}

/// Diagnostic descriptor for a visible terrain quadtree leaf selected during a
/// [ChunkedTerrain3D] CDLOD traversal.
class TerrainChunkSelection3D({
  required final int colStart,
  required final int colEnd,
  required final int rowStart,
  required final int rowEnd,
  required final int lodLevel,
  required final int step,
  required final Aabb3 localBounds,
  required final Surface surface,
  required final int topVertexCount,
  required final int skirtVertexCount,
  required final int skirtTriangleCount,
});

class _TerrainQuadNode3D({
  required final int colStart,
  required final int colEnd,
  required final int rowStart,
  required final int rowEnd,
  required final int lodLevel,
  required final Aabb3 localBounds,
}) {
  final int step = 1 << lodLevel;
  List<_TerrainQuadNode3D>? children;

  Surface? cachedSurface;
  int topVertexCount = 0;
  int skirtVertexCount = 0;
  int skirtTriangleCount = 0;

  void dispose() {
    cachedSurface?.dispose();
    cachedSurface = null;
    final kids = children;
    if (kids != null) {
      for (var i = 0; i < kids.length; i++) {
        kids[i].dispose();
      }
    }
  }
}

/// Quadtree level-of-detail heightmap terrain [Object3D].
///
/// Selects visible quadtree chunks per pass using the distance to the viewer
/// (`RenderContext3D.viewerPosition`, the main camera also in shadow passes)
/// and frustum culling (`step = 1` nearby, `step = 2, 4, 8` in the
/// distance). Levels switch at once, without geomorphing. Cracks between
/// chunks of different levels are hidden by vertical perimeter skirts
/// [skirtDepth] deep. Bakes smooth 4-biome (`sand -> grass -> rock -> snow`)
/// vertex colors and provides `O(1)` bilinear [sampleHeight] and
/// [sampleNormal] queries. Call [markHeightsChanged] after editing
/// [heights].
class ChunkedTerrain3D({
  required Float32List heights,

  /// Number of height samples along `+X`.
  required final int gridColumns,

  /// Number of height samples along `+Z`.
  required final int gridRows,

  /// Total horizontal terrain extent along `X`.
  required final double worldWidth,

  /// Total horizontal terrain extent along `Z`.
  required final double worldDepth,
  double? maxHeight,

  /// Number of quadtree LOD tiers (`4` -> `step = 1, 2, 4, 8`).
  final int lodLevels = 4,

  /// Target quad resolution along each axis of a finest (`step = 1`) leaf
  /// chunk.
  final int leafChunkQuads = 8,

  /// Distance multiplier (`distance < chunkExtent * lodSplitFactor`) triggering
  /// quadtree subdivision to finer LODs.
  final double lodSplitFactor = 1.35,
  double? skirtDepth,

  /// Texture coordinate tiling across the full terrain span.
  final double uvScale = 8.0,

  /// 4-biome color splat configuration.
  final TerrainBiomePalette3D biomePalette = const TerrainBiomePalette3D(),
  Material? material,
  super.position,
  super.scale,
  super.rotation,
  super.children,
  super.castsShadows,
  super.cameraMask,
}) extends Object3D {
  /// Builds a quadtree CDLOD terrain from `heights` (`gridColumns * gridRows`
  /// elevation samples).
  this
    : assert(
        gridColumns >= 2 && gridRows >= 2,
        'Terrain grid must be at least 2x2',
      ),
      assert(
        worldWidth > 0 && worldDepth > 0,
        'worldWidth and worldDepth must be positive',
      ),
      assert(
        heights.length == gridColumns * gridRows,
        'heights.length must equal gridColumns * gridRows',
      ),
      assert(
        lodLevels >= 1 && lodLevels <= 8,
        'lodLevels must be in 1..8',
      ),
      assert(leafChunkQuads >= 1, 'leafChunkQuads must be at least 1') {
    _computeElevationRange();
    this.maxHeight = (maxHeight != null && maxHeight > 0)
        ? maxHeight
        : math.max(1.0, _maxElevation - _minElevation);
    this.skirtDepth = (skirtDepth != null && skirtDepth > 0)
        ? skirtDepth
        : math.max(0.5, this.maxHeight * 0.35);
    _updateLocalAabb();
    _buildQuadtree();
  }

  void _computeElevationRange() {
    var minH = double.infinity;
    var maxH = double.negativeInfinity;
    for (var i = 0; i < heights.length; i++) {
      final h = heights[i];
      if (h < minH) {
        minH = h;
      }
      if (h > maxH) {
        maxH = h;
      }
    }
    if (!minH.isFinite) {
      minH = 0;
      maxH = 0;
    }
    _minElevation = minH;
    _maxElevation = maxH;
  }

  void _updateLocalAabb() {
    _localAabb
      ..min.setValues(
        -worldWidth * 0.5,
        _minElevation - skirtDepth,
        -worldDepth * 0.5,
      )
      ..max.setValues(
        worldWidth * 0.5,
        _maxElevation,
        worldDepth * 0.5,
      );
  }

  /// Rebuilds the terrain after [heights] were edited in place: drops every
  /// chunk surface built so far (chunks are built again as they are drawn)
  /// and recomputes the elevation range, the bounds and the quadtree.
  /// [maxHeight] and [skirtDepth] keep their values. Decals projected onto
  /// the terrain must be projected again.
  void markHeightsChanged() {
    for (var i = 0; i < _roots.length; i++) {
      _roots[i].dispose();
    }
    _raycastFallbackSurface?.dispose();
    _raycastFallbackSurface = null;
    _roots.clear();
    _selectedNodes.clear();
    _computeElevationRange();
    _updateLocalAabb();
    _buildQuadtree();
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
  }

  /// Elevation sample grid (`gridColumns * gridRows`).
  final Float32List heights = Float32List.fromList(heights);

  /// Reference elevation span used to normalize biome heights `[0..1]`.
  late final double maxHeight;

  /// Vertical drop depth of crack-sealing perimeter skirts on every chunk.
  late final double skirtDepth;

  /// Shared terrain [Material].
  final Material material =
      material ?? SpatialMaterial(metallic: 0.05, roughness: 0.88);

  /// Procedural multi-octave fBm heightfield factory for islands, valleys, and
  /// mountain ranges.
  factory ChunkedTerrain3D.procedural({
    int gridColumns = 129,
    int gridRows = 129,
    double worldWidth = 128.0,
    double worldDepth = 128.0,
    double maxHeight = 18.0,
    double frequency = 0.055,
    int lodLevels = 4,
    int leafChunkQuads = 8,
    double lodSplitFactor = 1.35,
    double? skirtDepth,
    double uvScale = 12.0,
    TerrainBiomePalette3D biomePalette = const TerrainBiomePalette3D(),
    Material? material,
    Vector3? position,
  }) {
    final heights = Float32List(gridColumns * gridRows);
    for (var r = 0; r < gridRows; r++) {
      final nz = (r / (gridRows - 1)) * 2.0 - 1.0;
      final wz = nz * worldDepth * 0.5;
      for (var c = 0; c < gridColumns; c++) {
        final nx = (c / (gridColumns - 1)) * 2.0 - 1.0;
        final wx = nx * worldWidth * 0.5;
        final n0 =
            math.sin(wx * frequency + 0.3) * math.cos(wz * frequency - 0.4);
        final n1 =
            0.5 *
            math.sin((wx * 2.1 - wz * 1.6) * frequency + 1.2) *
            math.cos((wx * 1.4 + wz * 2.3) * frequency);
        final n2 = 0.25 * math.cos((wx * 4.3 + wz * 3.9) * frequency);
        final raw = ((n0 + n1 + n2) / 1.75) * 0.5 + 0.5;
        heights[r * gridColumns + c] = raw.clamp(0.0, 1.0) * maxHeight;
      }
    }
    return ChunkedTerrain3D(
      heights: heights,
      gridColumns: gridColumns,
      gridRows: gridRows,
      worldWidth: worldWidth,
      worldDepth: worldDepth,
      maxHeight: maxHeight,
      lodLevels: lodLevels,
      leafChunkQuads: leafChunkQuads,
      lodSplitFactor: lodSplitFactor,
      skirtDepth: skirtDepth,
      uvScale: uvScale,
      biomePalette: biomePalette,
      material: material,
      position: position,
    );
  }

  late double _minElevation;
  late double _maxElevation;
  final Aabb3 _localAabb = Aabb3();
  final List<_TerrainQuadNode3D> _roots = <_TerrainQuadNode3D>[];
  final List<_TerrainQuadNode3D> _selectedNodes = <_TerrainQuadNode3D>[];
  final List<_TerrainQuadNode3D> _nodeStack = <_TerrainQuadNode3D>[];
  final List<bool> _insideStack = <bool>[];
  final Aabb3 _worldNodeBox = Aabb3();
  final Matrix4 _invWorldScratch = Matrix4.identity();
  final Vector3 _localCamScratch = Vector3.zero();
  Surface? _raycastFallbackSurface;
  int _invWorldVer = -1;
  bool _invWorldIsIdentity = true;
  bool _invWorldValid = true;

  int _lastDrawnChunkCount = 0;

  /// Number of CDLOD chunks drawn in the most recent pass.
  int get lastDrawnChunkCount => _lastDrawnChunkCount;

  /// Minimum height sample in [heights].
  double get minElevation => _minElevation;

  /// Maximum height sample in [heights].
  double get maxElevation => _maxElevation;

  /// Bilinearly samples the local terrain height at `(x, z)` in
  /// `[-worldWidth/2 .. worldWidth/2] x [-worldDepth/2 .. worldDepth/2]`.
  double sampleHeight(double x, double z) {
    final fx = ((x + worldWidth * 0.5) / worldWidth * (gridColumns - 1)).clamp(
      0.0,
      gridColumns - 1.0,
    );
    final fz = ((z + worldDepth * 0.5) / worldDepth * (gridRows - 1)).clamp(
      0.0,
      gridRows - 1.0,
    );
    final c0 = fx.floor().clamp(0, gridColumns - 1);
    final r0 = fz.floor().clamp(0, gridRows - 1);
    final c1 = math.min(gridColumns - 1, c0 + 1);
    final r1 = math.min(gridRows - 1, r0 + 1);
    final tx = fx - c0;
    final tz = fz - r0;

    final h00 = heights[r0 * gridColumns + c0];
    final h10 = heights[r0 * gridColumns + c1];
    final h01 = heights[r1 * gridColumns + c0];
    final h11 = heights[r1 * gridColumns + c1];

    final h0 = h00 + (h10 - h00) * tx;
    final h1 = h01 + (h11 - h01) * tx;
    return h0 + (h1 - h0) * tz;
  }

  /// Samples the unit upward terrain normal at local `(x, z)` via central
  /// finite differences.
  Vector3 sampleNormal(double x, double z, {Vector3? out}) {
    final res = out ?? Vector3.zero();
    final epsX = worldWidth / (gridColumns - 1) * 0.5;
    final epsZ = worldDepth / (gridRows - 1) * 0.5;
    final dhdx =
        (sampleHeight(x + epsX, z) - sampleHeight(x - epsX, z)) / (2.0 * epsX);
    final dhdz =
        (sampleHeight(x, z + epsZ) - sampleHeight(x, z - epsZ)) / (2.0 * epsZ);
    res
      ..setValues(-dhdx, 1.0, -dhdz)
      ..normalize();
    return res;
  }

  /// Evaluates the 4-biome weights `(sand, grass, rock, snow)` at local
  /// `(x, z)`.
  TerrainBiomeWeights3D sampleBiomeWeights(double x, double z) {
    final h = sampleHeight(x, z);
    final n = sampleNormal(x, z, out: _normalScratch);
    final hNorm = ((h - math.min(0.0, _minElevation)) / maxHeight).clamp(
      0.0,
      1.0,
    );
    return biomePalette.evaluateWeights(hNorm, n.y);
  }

  final Vector3 _normalScratch = Vector3.zero();

  /// Selects the visible CDLOD quadtree leaf chunks for [cameraPosition] (in
  /// world space) and optional world [frustum], building chunk surfaces lazily.
  List<TerrainChunkSelection3D> selectVisibleChunks({
    required Vector3 cameraPosition,
    Frustum? frustum,
  }) {
    _selectNodesInto(_selectedNodes, cameraPosition, frustum);
    return <TerrainChunkSelection3D>[
      for (final node in _selectedNodes)
        TerrainChunkSelection3D(
          colStart: node.colStart,
          colEnd: node.colEnd,
          rowStart: node.rowStart,
          rowEnd: node.rowEnd,
          lodLevel: node.lodLevel,
          step: node.step,
          localBounds: Aabb3.copy(node.localBounds),
          surface: _ensureChunkSurface(node),
          topVertexCount: node.topVertexCount,
          skirtVertexCount: node.skirtVertexCount,
          skirtTriangleCount: node.skirtTriangleCount,
        ),
    ];
  }

  @override
  bool get usesDefaultFrustumVisibility => runtimeType == ChunkedTerrain3D;

  @override
  Aabb3? computeLocalAabb() => _localAabb;

  @override
  void onRemove() {
    for (var i = 0; i < _roots.length; i++) {
      _roots[i].dispose();
    }
    _raycastFallbackSurface?.dispose();
    _raycastFallbackSurface = null;
    super.onRemove();
  }

  @override
  void draw(covariant RenderContext3D context) {
    // Detail follows the viewer, also in shadow passes (where the camera is
    // the light's view, centered on the world origin): the terrain casts
    // shadows from the chunks the main pass shows.
    _selectNodesInto(_selectedNodes, context.viewerPosition, context.frustum);
    _lastDrawnChunkCount = _selectedNodes.length;
    if (_selectedNodes.isEmpty) {
      return;
    }

    final worldMat = worldTransformMatrix;
    for (var i = 0; i < _selectedNodes.length; i++) {
      final surface = _ensureChunkSurface(_selectedNodes[i]);
      context.drawSurface(
        surface,
        transform: worldMat,
        material: material,
      );
    }
  }

  @override
  RayHit3D? raycast(
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) => _raycastImpl(worldRay, maxDistance: maxDistance, cullMode: cullMode);
}
