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

  static final Vector3 _normalScratch = Vector3.zero();

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

  void _syncInverseWorld(Matrix4 worldMat) {
    final ver = worldTransformVersion;
    if (ver == _invWorldVer) {
      return;
    }
    _invWorldVer = ver;
    _invWorldIsIdentity = worldMat.isIdentity();
    if (_invWorldIsIdentity) {
      _invWorldValid = true;
      return;
    }
    _invWorldScratch.setFrom(worldMat);
    _invWorldValid = _invWorldScratch.invert().abs() > 1e-15;
  }

  @override
  RayHit3D? raycast(
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) {
    if (!(maxDistance > 0)) {
      return null;
    }
    final worldMat = worldTransformMatrix;
    _syncInverseWorld(worldMat);
    if (!_invWorldIsIdentity && !_invWorldValid) {
      return null;
    }

    if (_invWorldIsIdentity) {
      if (!rayHitsAabb(worldRay, _localAabb, maxDistance)) {
        return null;
      }
    } else {
      _worldNodeBox
        ..setFrom(_localAabb)
        ..transform(worldMat);
      if (!rayHitsAabb(worldRay, _worldNodeBox, maxDistance)) {
        return null;
      }
    }

    final ox = worldRay.origin.x;
    final oy = worldRay.origin.y;
    final oz = worldRay.origin.z;
    final dx = worldRay.direction.x;
    final dy = worldRay.direction.y;
    final dz = worldRay.direction.z;

    final double lox;
    final double loy;
    final double loz;
    final double ldx;
    final double ldy;
    final double ldz;
    if (_invWorldIsIdentity) {
      lox = ox;
      loy = oy;
      loz = oz;
      ldx = dx;
      ldy = dy;
      ldz = dz;
    } else {
      final m = _invWorldScratch.storage;
      lox = m[0] * ox + m[4] * oy + m[8] * oz + m[12];
      loy = m[1] * ox + m[5] * oy + m[9] * oz + m[13];
      loz = m[2] * ox + m[6] * oy + m[10] * oz + m[14];
      ldx = m[0] * dx + m[4] * dy + m[8] * dz;
      ldy = m[1] * dx + m[5] * dy + m[9] * dz;
      ldz = m[2] * dx + m[6] * dy + m[10] * dz;
    }

    final invDx = ldx.abs() > 1e-18 ? 1.0 / ldx : double.infinity;
    final invDy = ldy.abs() > 1e-18 ? 1.0 / ldy : double.infinity;
    final invDz = ldz.abs() > 1e-18 ? 1.0 / ldz : double.infinity;
    final effectiveCull = cullMode ?? material.renderState.cullMode;

    final dxCell = worldWidth / (gridColumns - 1);
    final dzCell = worldDepth / (gridRows - 1);
    final halfW = worldWidth * 0.5;
    final halfD = worldDepth * 0.5;

    _TerrainQuadNode3D? bestNode;
    var bestDist = maxDistance;
    var bestLocalX = 0.0;
    var bestLocalY = 0.0;
    var bestLocalZ = 0.0;
    var bestNx = 0.0;
    var bestNy = 1.0;
    var bestNz = 0.0;
    var bestTriIndex = 0;
    var bestSurfaceIndex = 0;
    var leafIdx = 0;

    final stack = _nodeStack..clear();
    for (var i = _roots.length - 1; i >= 0; i--) {
      stack.add(_roots[i]);
    }
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      if (!_localRayHitsAabb(
        lox,
        loy,
        loz,
        ldx,
        ldy,
        ldz,
        invDx,
        invDy,
        invDz,
        node.localBounds,
        bestDist,
      )) {
        continue;
      }
      final kids = node.children;
      if (kids != null && kids.isNotEmpty) {
        for (var i = kids.length - 1; i >= 0; i--) {
          stack.add(kids[i]);
        }
        continue;
      }

      final curLeaf = leafIdx++;
      final step = node.step;
      final cEnd = node.colEnd;
      final rEnd = node.rowEnd;
      final strideCols = (cEnd - node.colStart + step - 1) ~/ step;
      var rCell = 0;

      for (var r0 = node.rowStart; r0 < rEnd; r0 += step, rCell++) {
        final r1 = r0 + step < rEnd ? r0 + step : rEnd;
        final z0 = -halfD + r0 * dzCell;
        final z1 = -halfD + r1 * dzCell;
        final rowBase0 = r0 * gridColumns;
        final rowBase1 = r1 * gridColumns;
        var cCell = 0;

        for (var c0 = node.colStart; c0 < cEnd; c0 += step, cCell++) {
          final c1 = c0 + step < cEnd ? c0 + step : cEnd;
          final x0 = -halfW + c0 * dxCell;
          final x1 = -halfW + c1 * dxCell;
          final h00 = heights[rowBase0 + c0];
          final h10 = heights[rowBase0 + c1];
          final h01 = heights[rowBase1 + c0];
          final h11 = heights[rowBase1 + c1];

          var minY = h00;
          var maxY = h00;
          if (h10 < minY) {
            minY = h10;
          }
          if (h10 > maxY) {
            maxY = h10;
          }
          if (h01 < minY) {
            minY = h01;
          }
          if (h01 > maxY) {
            maxY = h01;
          }
          if (h11 < minY) {
            minY = h11;
          }
          if (h11 > maxY) {
            maxY = h11;
          }

          if (!_localRayHitsExtents(
            lox,
            loy,
            loz,
            ldx,
            ldy,
            ldz,
            invDx,
            invDy,
            invDz,
            x0,
            minY,
            z0,
            x1,
            maxY,
            z1,
            bestDist,
          )) {
            continue;
          }

          final triBase = (rCell * strideCols + cCell) * 2;

          // Tri 1: (v00, v01, v11)
          final t1 = _intersectLocalTri(
            lox,
            loy,
            loz,
            ldx,
            ldy,
            ldz,
            x0,
            h00,
            z0,
            x0,
            h01,
            z1,
            x1,
            h11,
            z1,
            bestDist,
            effectiveCull,
          );
          if (t1 >= 0.0 && t1 < bestDist) {
            bestDist = t1;
            bestNode = node;
            bestSurfaceIndex = curLeaf;
            bestTriIndex = triBase;
            bestLocalX = lox + ldx * t1;
            bestLocalY = loy + ldy * t1;
            bestLocalZ = loz + ldz * t1;
            const e1x = 0.0;
            final e1y = h01 - h00;
            final e1z = z1 - z0;
            final e2x = x1 - x0;
            final e2y = h11 - h00;
            final e2z = z1 - z0;
            bestNx = e1y * e2z - e1z * e2y;
            bestNy = e1z * e2x - e1x * e2z;
            bestNz = e1x * e2y - e1y * e2x;
          }

          // Tri 2: (v00, v11, v10)
          final t2 = _intersectLocalTri(
            lox,
            loy,
            loz,
            ldx,
            ldy,
            ldz,
            x0,
            h00,
            z0,
            x1,
            h11,
            z1,
            x1,
            h10,
            z0,
            bestDist,
            effectiveCull,
          );
          if (t2 >= 0.0 && t2 < bestDist) {
            bestDist = t2;
            bestNode = node;
            bestSurfaceIndex = curLeaf;
            bestTriIndex = triBase + 1;
            bestLocalX = lox + ldx * t2;
            bestLocalY = loy + ldy * t2;
            bestLocalZ = loz + ldz * t2;
            final e1x = x1 - x0;
            final e1y = h11 - h00;
            final e1z = z1 - z0;
            final e2x = x1 - x0;
            final e2y = h10 - h00;
            const e2z = 0.0;
            bestNx = e1y * e2z - e1z * e2y;
            bestNy = e1z * e2x - e1x * e2z;
            bestNz = e1x * e2y - e1y * e2x;
          }
        }
      }
    }

    if (bestNode == null) {
      return null;
    }

    final nLen = math.sqrt(bestNx * bestNx + bestNy * bestNy + bestNz * bestNz);
    if (nLen > 1e-12) {
      bestNx /= nLen;
      bestNy /= nLen;
      bestNz /= nLen;
    } else {
      bestNx = 0.0;
      bestNy = 1.0;
      bestNz = 0.0;
    }

    double wnx;
    double wny;
    double wnz;
    if (_invWorldIsIdentity) {
      wnx = bestNx;
      wny = bestNy;
      wnz = bestNz;
    } else {
      final m = _invWorldScratch.storage;
      wnx = m[0] * bestNx + m[1] * bestNy + m[2] * bestNz;
      wny = m[4] * bestNx + m[5] * bestNy + m[6] * bestNz;
      wnz = m[8] * bestNx + m[9] * bestNy + m[10] * bestNz;
      final wnLen = math.sqrt(wnx * wnx + wny * wny + wnz * wnz);
      if (wnLen > 1e-12) {
        wnx /= wnLen;
        wny /= wnLen;
        wnz /= wnLen;
      }
    }

    final hitSurface =
        bestNode.cachedSurface ??
        (_raycastFallbackSurface ??= Surface.fromBuffers(
          vertices: Float32List(VertexLayout.standard.strideInFloats),
          indices: Uint16List(0),
          material: material,
          aabb: Aabb3.copy(_localAabb),
        ));

    return RayHit3D(
      object: this,
      surface: hitSurface,
      surfaceIndex: bestSurfaceIndex,
      distance: bestDist,
      worldPoint: Vector3(
        ox + dx * bestDist,
        oy + dy * bestDist,
        oz + dz * bestDist,
      ),
      worldNormal: Vector3(wnx, wny, wnz),
      localPoint: Vector3(bestLocalX, bestLocalY, bestLocalZ),
      localNormal: Vector3(bestNx, bestNy, bestNz),
      triangleIndex: bestTriIndex,
    );
  }

  static bool _localRayHitsAabb(
    double ox,
    double oy,
    double oz,
    double dx,
    double dy,
    double dz,
    double invDx,
    double invDy,
    double invDz,
    Aabb3 box,
    double maxDist,
  ) => _localRayHitsExtents(
    ox,
    oy,
    oz,
    dx,
    dy,
    dz,
    invDx,
    invDy,
    invDz,
    box.min.x,
    box.min.y,
    box.min.z,
    box.max.x,
    box.max.y,
    box.max.z,
    maxDist,
  );

  static bool _localRayHitsExtents(
    double ox,
    double oy,
    double oz,
    double dx,
    double dy,
    double dz,
    double invDx,
    double invDy,
    double invDz,
    double minX,
    double minY,
    double minZ,
    double maxX,
    double maxY,
    double maxZ,
    double maxDist,
  ) {
    var tMin = 0.0;
    var tMax = maxDist;

    if (dx.abs() <= 1e-18) {
      if (ox < minX || ox > maxX) {
        return false;
      }
    } else {
      var t0 = (minX - ox) * invDx;
      var t1 = (maxX - ox) * invDx;
      if (t0 > t1) {
        final tmp = t0;
        t0 = t1;
        t1 = tmp;
      }
      if (t0 > tMin) {
        tMin = t0;
      }
      if (t1 < tMax) {
        tMax = t1;
      }
      if (tMax < tMin) {
        return false;
      }
    }

    if (dy.abs() <= 1e-18) {
      if (oy < minY || oy > maxY) {
        return false;
      }
    } else {
      var t0 = (minY - oy) * invDy;
      var t1 = (maxY - oy) * invDy;
      if (t0 > t1) {
        final tmp = t0;
        t0 = t1;
        t1 = tmp;
      }
      if (t0 > tMin) {
        tMin = t0;
      }
      if (t1 < tMax) {
        tMax = t1;
      }
      if (tMax < tMin) {
        return false;
      }
    }

    if (dz.abs() <= 1e-18) {
      if (oz < minZ || oz > maxZ) {
        return false;
      }
    } else {
      var t0 = (minZ - oz) * invDz;
      var t1 = (maxZ - oz) * invDz;
      if (t0 > t1) {
        final tmp = t0;
        t0 = t1;
        t1 = tmp;
      }
      if (t0 > tMin) {
        tMin = t0;
      }
      if (t1 < tMax) {
        tMax = t1;
      }
      if (tMax < tMin) {
        return false;
      }
    }

    return true;
  }

  static double _intersectLocalTri(
    double ox,
    double oy,
    double oz,
    double dx,
    double dy,
    double dz,
    double ax,
    double ay,
    double az,
    double bx,
    double by,
    double bz,
    double cx,
    double cy,
    double cz,
    double maxDist,
    CullMode cullMode,
  ) {
    final e1x = bx - ax;
    final e1y = by - ay;
    final e1z = bz - az;
    final e2x = cx - ax;
    final e2y = cy - ay;
    final e2z = cz - az;

    final px = dy * e2z - dz * e2y;
    final py = dz * e2x - dx * e2z;
    final pz = dx * e2y - dy * e2x;

    final det = e1x * px + e1y * py + e1z * pz;
    switch (cullMode) {
      case CullMode.backFace:
        if (det <= 1e-12) {
          return -1.0;
        }
      case CullMode.frontFace:
        if (det >= -1e-12) {
          return -1.0;
        }
      case CullMode.none:
        if (det.abs() <= 1e-12) {
          return -1.0;
        }
    }

    final invDet = 1.0 / det;
    final tx = ox - ax;
    final ty = oy - ay;
    final tz = oz - az;
    final u = (tx * px + ty * py + tz * pz) * invDet;
    if (u < -1e-6 || u > 1.0 + 1e-6) {
      return -1.0;
    }

    final qx = ty * e1z - tz * e1y;
    final qy = tz * e1x - tx * e1z;
    final qz = tx * e1y - ty * e1x;
    final v = (dx * qx + dy * qy + dz * qz) * invDet;
    if (v < -1e-6 || u + v > 1.0 + 1e-6) {
      return -1.0;
    }

    final t = (e2x * qx + e2y * qy + e2z * qz) * invDet;
    if (t < 0.0 || t >= maxDist) {
      return -1.0;
    }
    return t;
  }

  void _selectNodesInto(
    List<_TerrainQuadNode3D> out,
    Vector3 worldCameraPos,
    Frustum? worldFrustum,
  ) {
    out.clear();
    final worldMat = worldTransformMatrix;
    _syncInverseWorld(worldMat);

    if (_invWorldIsIdentity) {
      _localCamScratch.setFrom(worldCameraPos);
    } else if (_invWorldValid) {
      final m = _invWorldScratch.storage;
      final cx = worldCameraPos.x;
      final cy = worldCameraPos.y;
      final cz = worldCameraPos.z;
      _localCamScratch.setValues(
        m[0] * cx + m[4] * cy + m[8] * cz + m[12],
        m[1] * cx + m[5] * cy + m[9] * cz + m[13],
        m[2] * cx + m[6] * cy + m[10] * cz + m[14],
      );
    } else {
      _localCamScratch.setFrom(worldCameraPos);
    }

    final camX = _localCamScratch.x;
    final camY = _localCamScratch.y;
    final camZ = _localCamScratch.z;
    final nodeStack = _nodeStack..clear();
    final insideStack = _insideStack..clear();
    for (var i = _roots.length - 1; i >= 0; i--) {
      nodeStack.add(_roots[i]);
      insideStack.add(false);
    }

    while (nodeStack.isNotEmpty) {
      final node = nodeStack.removeLast();
      var inside = insideStack.removeLast();
      if (!inside && worldFrustum != null) {
        final Aabb3 box;
        if (_invWorldIsIdentity) {
          box = node.localBounds;
        } else {
          box = _worldNodeBox
            ..setFrom(node.localBounds)
            ..transform(worldMat);
        }
        final res = box.frustumCullTest(worldFrustum);
        if (res == CullResult.outside) {
          continue;
        }
        inside = res == CullResult.inside;
      }

      final kids = node.children;
      if (kids != null && kids.isNotEmpty && node.lodLevel > 0) {
        final distSq = _distanceSqPointToAabb(
          camX,
          camY,
          camZ,
          node.localBounds,
        );
        final spanX = node.localBounds.max.x - node.localBounds.min.x;
        final spanZ = node.localBounds.max.z - node.localBounds.min.z;
        final splitThreshold = math.max(spanX, spanZ) * lodSplitFactor;
        if (distSq < splitThreshold * splitThreshold) {
          for (var i = kids.length - 1; i >= 0; i--) {
            nodeStack.add(kids[i]);
            insideStack.add(inside);
          }
          continue;
        }
      }

      out.add(node);
    }
  }

  void _buildQuadtree() {
    final cellsX = gridColumns - 1;
    final cellsZ = gridRows - 1;
    final maxStep = 1 << (lodLevels - 1);

    final minTotalCells = math.min(cellsX, cellsZ);
    final autoLeaf = math.max(1, minTotalCells ~/ maxStep);
    final leafCells = math.min(leafChunkQuads, autoLeaf);
    final rootSpan = leafCells * maxStep;

    _roots.clear();
    for (var r0 = 0; r0 < cellsZ; r0 += rootSpan) {
      final r1 = math.min(cellsZ, r0 + rootSpan);
      for (var c0 = 0; c0 < cellsX; c0 += rootSpan) {
        final c1 = math.min(cellsX, c0 + rootSpan);
        _roots.add(_buildNodeRecursive(c0, c1, r0, r1, lodLevels - 1));
      }
    }
  }

  _TerrainQuadNode3D _buildNodeRecursive(
    int c0,
    int c1,
    int r0,
    int r1,
    int lod,
  ) {
    final bounds = _computeRegionBounds(c0, c1, r0, r1);
    final node = _TerrainQuadNode3D(
      colStart: c0,
      colEnd: c1,
      rowStart: r0,
      rowEnd: r1,
      lodLevel: lod,
      localBounds: bounds,
    );

    if (lod > 0) {
      final childStep = 1 << (lod - 1);
      final spanC = c1 - c0;
      final spanR = r1 - r0;
      if (spanC >= childStep * 2 || spanR >= childStep * 2) {
        final midC = _alignedMidpoint(c0, c1, childStep);
        final midR = _alignedMidpoint(r0, r1, childStep);
        final kids = <_TerrainQuadNode3D>[];
        if (midC > c0 && midR > r0) {
          kids.add(_buildNodeRecursive(c0, midC, r0, midR, lod - 1));
        }
        if (c1 > midC && midR > r0) {
          kids.add(_buildNodeRecursive(midC, c1, r0, midR, lod - 1));
        }
        if (midC > c0 && r1 > midR) {
          kids.add(_buildNodeRecursive(c0, midC, midR, r1, lod - 1));
        }
        if (c1 > midC && r1 > midR) {
          kids.add(_buildNodeRecursive(midC, c1, midR, r1, lod - 1));
        }
        if (kids.length > 1) {
          node.children = kids;
        }
      }
    }
    return node;
  }

  static int _alignedMidpoint(int start, int end, int alignStep) {
    final span = end - start;
    if (span <= alignStep) {
      return end;
    }
    final rawHalf = span >> 1;
    final aligned = (rawHalf ~/ alignStep) * alignStep;
    final stepOffset = math.max(alignStep, aligned);
    return math.min(end, start + stepOffset);
  }

  Aabb3 _computeRegionBounds(int c0, int c1, int r0, int r1) {
    final x0 = -worldWidth * 0.5 + (c0 / (gridColumns - 1)) * worldWidth;
    final x1 = -worldWidth * 0.5 + (c1 / (gridColumns - 1)) * worldWidth;
    final z0 = -worldDepth * 0.5 + (r0 / (gridRows - 1)) * worldDepth;
    final z1 = -worldDepth * 0.5 + (r1 / (gridRows - 1)) * worldDepth;

    var minH = double.infinity;
    var maxH = double.negativeInfinity;
    for (var r = r0; r <= r1; r++) {
      final rowBase = r * gridColumns;
      for (var c = c0; c <= c1; c++) {
        final h = heights[rowBase + c];
        if (h < minH) {
          minH = h;
        }
        if (h > maxH) {
          maxH = h;
        }
      }
    }
    return Aabb3.minMax(
      Vector3(x0, minH - skirtDepth, z0),
      Vector3(x1, maxH, z1),
    );
  }

  Surface _ensureChunkSurface(_TerrainQuadNode3D node) {
    final existing = node.cachedSurface;
    if (existing != null) {
      return existing;
    }

    final step = node.step;
    final cols = _buildSampleAxis(node.colStart, node.colEnd, step);
    final rows = _buildSampleAxis(node.rowStart, node.rowEnd, step);
    final nCols = cols.length;
    final nRows = rows.length;

    final topVertCount = nCols * nRows;
    final skirtVertCount = 2 * nCols + 2 * nRows;
    final totalVerts = topVertCount + skirtVertCount;

    final stride = VertexLayout.standard.strideInFloats;
    final verts = Float32List(totalVerts * stride);

    final inv2Dx = 1.0 / (2.0 * (worldWidth / (gridColumns - 1)));
    final inv2Dz = 1.0 / (2.0 * (worldDepth / (gridRows - 1)));
    final invColsMinus1 = 1.0 / (gridColumns - 1);
    final invRowsMinus1 = 1.0 / (gridRows - 1);
    final halfW = worldWidth * 0.5;
    final halfD = worldDepth * 0.5;
    final baseMinH = math.min(0.0, _minElevation);
    final invMaxHeight = 1.0 / maxHeight;

    // 1. Top grid vertices.
    var vCursor = 0;
    for (var r = 0; r < nRows; r++) {
      final rSample = rows[r];
      for (var c = 0; c < nCols; c++) {
        _writeChunkVertex(
          verts,
          stride,
          vCursor++,
          cols[c],
          rSample,
          0.0,
          invColsMinus1,
          invRowsMinus1,
          halfW,
          halfD,
          inv2Dx,
          inv2Dz,
          baseMinH,
          invMaxHeight,
        );
      }
    }

    // 2. Vertical skirt bottom vertices along North, South, West, East borders.
    final northSkirtStart = vCursor;
    for (var c = 0; c < nCols; c++) {
      _writeChunkVertex(
        verts,
        stride,
        vCursor++,
        cols[c],
        rows[0],
        -skirtDepth,
        invColsMinus1,
        invRowsMinus1,
        halfW,
        halfD,
        inv2Dx,
        inv2Dz,
        baseMinH,
        invMaxHeight,
      );
    }
    final southSkirtStart = vCursor;
    for (var c = 0; c < nCols; c++) {
      _writeChunkVertex(
        verts,
        stride,
        vCursor++,
        cols[c],
        rows[nRows - 1],
        -skirtDepth,
        invColsMinus1,
        invRowsMinus1,
        halfW,
        halfD,
        inv2Dx,
        inv2Dz,
        baseMinH,
        invMaxHeight,
      );
    }
    final westSkirtStart = vCursor;
    for (var r = 0; r < nRows; r++) {
      _writeChunkVertex(
        verts,
        stride,
        vCursor++,
        cols[0],
        rows[r],
        -skirtDepth,
        invColsMinus1,
        invRowsMinus1,
        halfW,
        halfD,
        inv2Dx,
        inv2Dz,
        baseMinH,
        invMaxHeight,
      );
    }
    final eastSkirtStart = vCursor;
    for (var r = 0; r < nRows; r++) {
      _writeChunkVertex(
        verts,
        stride,
        vCursor++,
        cols[nCols - 1],
        rows[r],
        -skirtDepth,
        invColsMinus1,
        invRowsMinus1,
        halfW,
        halfD,
        inv2Dx,
        inv2Dz,
        baseMinH,
        invMaxHeight,
      );
    }

    final topQuads = (nCols - 1) * (nRows - 1);
    final skirtQuads = 2 * (nCols - 1) + 2 * (nRows - 1);
    final totalIndices = (topQuads + skirtQuads) * 6;
    final List<int> indices = totalVerts > 0xFFFF
        ? Uint32List(totalIndices)
        : Uint16List(totalIndices);

    var k = 0;
    // Top grid triangles (CCW +Y up).
    for (var r = 0; r < nRows - 1; r++) {
      final row0 = r * nCols;
      final row1 = (r + 1) * nCols;
      for (var c = 0; c < nCols - 1; c++) {
        final i0 = row0 + c;
        final i1 = i0 + 1;
        final i2 = row1 + c + 1;
        final i3 = row1 + c;
        indices
          ..[k] = i0
          ..[k + 1] = i3
          ..[k + 2] = i2
          ..[k + 3] = i0
          ..[k + 4] = i2
          ..[k + 5] = i1;
        k += 6;
      }
    }

    // North skirt (r = 0, outward normal -Z).
    for (var c = 0; c < nCols - 1; c++) {
      final t0 = c;
      final t1 = c + 1;
      final b0 = northSkirtStart + c;
      final b1 = northSkirtStart + c + 1;
      indices
        ..[k] = t0
        ..[k + 1] = t1
        ..[k + 2] = b1
        ..[k + 3] = t0
        ..[k + 4] = b1
        ..[k + 5] = b0;
      k += 6;
    }

    // South skirt (r = nRows - 1, outward normal +Z).
    final lastRowBase = (nRows - 1) * nCols;
    for (var c = 0; c < nCols - 1; c++) {
      final t0 = lastRowBase + c;
      final t1 = lastRowBase + c + 1;
      final b0 = southSkirtStart + c;
      final b1 = southSkirtStart + c + 1;
      indices
        ..[k] = t0
        ..[k + 1] = b0
        ..[k + 2] = b1
        ..[k + 3] = t0
        ..[k + 4] = b1
        ..[k + 5] = t1;
      k += 6;
    }

    // West skirt (c = 0, outward normal -X).
    for (var r = 0; r < nRows - 1; r++) {
      final t0 = r * nCols;
      final t1 = (r + 1) * nCols;
      final b0 = westSkirtStart + r;
      final b1 = westSkirtStart + r + 1;
      indices
        ..[k] = t0
        ..[k + 1] = b0
        ..[k + 2] = b1
        ..[k + 3] = t0
        ..[k + 4] = b1
        ..[k + 5] = t1;
      k += 6;
    }

    // East skirt (c = nCols - 1, outward normal +X).
    for (var r = 0; r < nRows - 1; r++) {
      final t0 = r * nCols + (nCols - 1);
      final t1 = (r + 1) * nCols + (nCols - 1);
      final b0 = eastSkirtStart + r;
      final b1 = eastSkirtStart + r + 1;
      indices
        ..[k] = t0
        ..[k + 1] = t1
        ..[k + 2] = b1
        ..[k + 3] = t0
        ..[k + 4] = b1
        ..[k + 5] = b0;
      k += 6;
    }

    final surface = Surface.fromBuffers(
      vertices: verts,
      indices: indices,
      material: material,
      aabb: Aabb3.copy(node.localBounds),
    );
    node
      ..cachedSurface = surface
      ..topVertexCount = topVertCount
      ..skirtVertexCount = skirtVertCount
      ..skirtTriangleCount = skirtQuads * 2;
    return surface;
  }

  void _writeChunkVertex(
    Float32List verts,
    int stride,
    int vertIdx,
    int cSample,
    int rSample,
    double yOffset,
    double invColsMinus1,
    double invRowsMinus1,
    double halfW,
    double halfD,
    double inv2Dx,
    double inv2Dz,
    double baseMinH,
    double invMaxHeight,
  ) {
    final uNorm = cSample * invColsMinus1;
    final vNorm = rSample * invRowsMinus1;
    final x = -halfW + uNorm * worldWidth;
    final z = -halfD + vNorm * worldDepth;
    final rowOff = rSample * gridColumns;
    final h = heights[rowOff + cSample];

    final cPrev = cSample > 0 ? cSample - 1 : 0;
    final cNext = cSample + 1 < gridColumns ? cSample + 1 : gridColumns - 1;
    final rPrev = rSample > 0 ? rSample - 1 : 0;
    final rNext = rSample + 1 < gridRows ? rSample + 1 : gridRows - 1;

    final dhdx = (heights[rowOff + cNext] - heights[rowOff + cPrev]) * inv2Dx;
    final dhdz =
        (heights[rNext * gridColumns + cSample] -
            heights[rPrev * gridColumns + cSample]) *
        inv2Dz;
    final invN = 1.0 / math.sqrt(dhdx * dhdx + dhdz * dhdz + 1.0);
    final nx = -dhdx * invN;
    final ny = invN;
    final nz = -dhdz * invN;

    final hNorm = ((h - baseMinH) * invMaxHeight).clamp(0.0, 1.0);
    final o = vertIdx * stride;
    verts
      ..[o] = x
      ..[o + 1] = h + yOffset
      ..[o + 2] = z
      ..[o + 3] = uNorm * uvScale
      ..[o + 4] = vNorm * uvScale;
    biomePalette.writeColorTo(hNorm, ny, verts, o + 5);
    verts
      ..[o + 9] = nx
      ..[o + 10] = ny
      ..[o + 11] = nz;
  }

  static Int32List _buildSampleAxis(int start, int end, int step) {
    final count = ((end - start + step - 1) ~/ step) + 1;
    final out = Int32List(count);
    var idx = 0;
    for (var v = start; v < end; v += step) {
      out[idx++] = v;
    }
    out[idx] = end;
    return out;
  }

  static double _distanceSqPointToAabb(
    double px,
    double py,
    double pz,
    Aabb3 box,
  ) {
    final dx = px < box.min.x
        ? box.min.x - px
        : (px > box.max.x ? px - box.max.x : 0.0);
    final dy = py < box.min.y
        ? box.min.y - py
        : (py > box.max.y ? py - box.max.y : 0.0);
    final dz = pz < box.min.z
        ? box.min.z - pz
        : (pz > box.max.z ? pz - box.max.z : 0.0);
    return dx * dx + dy * dy + dz * dz;
  }
}
