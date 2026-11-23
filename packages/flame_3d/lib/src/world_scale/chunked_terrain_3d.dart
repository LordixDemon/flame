import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';

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
    final weights = evaluateWeights(normalizedHeight, normalY);
    final r =
        sandColor.r * weights.sand +
        grassColor.r * weights.grass +
        rockColor.r * weights.rock +
        snowColor.r * weights.snow;
    final g =
        sandColor.g * weights.sand +
        grassColor.g * weights.grass +
        rockColor.g * weights.rock +
        snowColor.g * weights.snow;
    final b =
        sandColor.b * weights.sand +
        grassColor.b * weights.grass +
        rockColor.b * weights.rock +
        snowColor.b * weights.snow;
    return Color.from(
      alpha: 1,
      red: r.clamp(0.0, 1.0),
      green: g.clamp(0.0, 1.0),
      blue: b.clamp(0.0, 1.0),
    );
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
  final Aabb3 _worldNodeBox = Aabb3();
  final Matrix4 _invWorldScratch = Matrix4.identity();
  final Vector3 _localCamScratch = Vector3.zero();

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
  Aabb3? computeLocalAabb() => _localAabb;

  @override
  void onRemove() {
    for (var i = 0; i < _roots.length; i++) {
      _roots[i].dispose();
    }
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
  }) {
    if (!(maxDistance > 0)) {
      return null;
    }
    final worldMat = worldTransformMatrix;
    RayHit3D? best;
    var limit = maxDistance;
    var idx = 0;

    void visit(_TerrainQuadNode3D node) {
      _worldNodeBox
        ..setFrom(node.localBounds)
        ..transform(worldMat);
      if (!rayHitsAabb(worldRay, _worldNodeBox, limit)) {
        return;
      }
      final kids = node.children;
      if (kids != null && kids.isNotEmpty) {
        for (var i = 0; i < kids.length; i++) {
          visit(kids[i]);
        }
        return;
      }
      final surface = _ensureChunkSurface(node);
      final hit = RayHit3D.intersectSurface(
        owner: this,
        surface: surface,
        surfaceIndex: idx++,
        modelMatrix: worldMat,
        worldRay: worldRay,
        maxDistance: limit,
        cullMode: cullMode ?? material.renderState.cullMode,
      );
      if (hit != null && hit.distance < limit) {
        limit = hit.distance;
        best = hit;
      }
    }

    for (var i = 0; i < _roots.length; i++) {
      visit(_roots[i]);
    }
    return best;
  }

  void _selectNodesInto(
    List<_TerrainQuadNode3D> out,
    Vector3 worldCameraPos,
    Frustum? worldFrustum,
  ) {
    out.clear();
    final worldMat = worldTransformMatrix;
    final isIdentity = worldMat.isIdentity();

    if (isIdentity) {
      _localCamScratch.setFrom(worldCameraPos);
    } else {
      _invWorldScratch.setFrom(worldMat);
      if (_invWorldScratch.invert().abs() > 1e-15) {
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
    }

    void visit(_TerrainQuadNode3D node, {required bool parentInsideFrustum}) {
      var inside = parentInsideFrustum;
      if (!inside && worldFrustum != null) {
        final Aabb3 box;
        if (isIdentity) {
          box = node.localBounds;
        } else {
          box = _worldNodeBox
            ..setFrom(node.localBounds)
            ..transform(worldMat);
        }
        final res = box.frustumCullTest(worldFrustum);
        if (res == CullResult.outside) {
          return;
        }
        inside = res == CullResult.inside;
      }

      final kids = node.children;
      if (kids != null && kids.isNotEmpty && node.lodLevel > 0) {
        final dist = _distancePointToAabb(_localCamScratch, node.localBounds);
        final spanX = node.localBounds.max.x - node.localBounds.min.x;
        final spanZ = node.localBounds.max.z - node.localBounds.min.z;
        final splitThreshold = math.max(spanX, spanZ) * lodSplitFactor;
        if (dist < splitThreshold) {
          for (var i = 0; i < kids.length; i++) {
            visit(kids[i], parentInsideFrustum: inside);
          }
          return;
        }
      }

      out.add(node);
    }

    for (var i = 0; i < _roots.length; i++) {
      visit(_roots[i], parentInsideFrustum: false);
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

    final dxCell = worldWidth / (gridColumns - 1);
    final dzCell = worldDepth / (gridRows - 1);
    final halfW = worldWidth * 0.5;
    final halfD = worldDepth * 0.5;
    final baseMinH = math.min(0.0, _minElevation);

    double hAt(int ic, int ir) {
      final cc = ic.clamp(0, gridColumns - 1);
      final cr = ir.clamp(0, gridRows - 1);
      return heights[cr * gridColumns + cc];
    }

    void writeVertex(int vertIdx, int cSample, int rSample, double yOffset) {
      final uNorm = cSample / (gridColumns - 1);
      final vNorm = rSample / (gridRows - 1);
      final x = -halfW + uNorm * worldWidth;
      final z = -halfD + vNorm * worldDepth;
      final h = heights[rSample * gridColumns + cSample];

      final dhdx =
          (hAt(cSample + 1, rSample) - hAt(cSample - 1, rSample)) /
          (2.0 * dxCell);
      final dhdz =
          (hAt(cSample, rSample + 1) - hAt(cSample, rSample - 1)) /
          (2.0 * dzCell);
      final invN = 1.0 / math.sqrt(dhdx * dhdx + dhdz * dhdz + 1.0);
      final nx = -dhdx * invN;
      final ny = invN;
      final nz = -dhdz * invN;

      final hNorm = ((h - baseMinH) / maxHeight).clamp(0.0, 1.0);
      final col = biomePalette.evaluateColor(hNorm, ny);

      final o = vertIdx * stride;
      verts
        ..[o] = x
        ..[o + 1] = h + yOffset
        ..[o + 2] = z
        ..[o + 3] = uNorm * uvScale
        ..[o + 4] = vNorm * uvScale
        ..[o + 5] = col.r
        ..[o + 6] = col.g
        ..[o + 7] = col.b
        ..[o + 8] = col.a
        ..[o + 9] = nx
        ..[o + 10] = ny
        ..[o + 11] = nz;
    }

    // 1. Top grid vertices.
    var vCursor = 0;
    for (var r = 0; r < nRows; r++) {
      final rSample = rows[r];
      for (var c = 0; c < nCols; c++) {
        writeVertex(vCursor++, cols[c], rSample, 0);
      }
    }

    // 2. Vertical skirt bottom vertices along North, South, West, East borders.
    final northSkirtStart = vCursor;
    for (var c = 0; c < nCols; c++) {
      writeVertex(vCursor++, cols[c], rows[0], -skirtDepth);
    }
    final southSkirtStart = vCursor;
    for (var c = 0; c < nCols; c++) {
      writeVertex(vCursor++, cols[c], rows[nRows - 1], -skirtDepth);
    }
    final westSkirtStart = vCursor;
    for (var r = 0; r < nRows; r++) {
      writeVertex(vCursor++, cols[0], rows[r], -skirtDepth);
    }
    final eastSkirtStart = vCursor;
    for (var r = 0; r < nRows; r++) {
      writeVertex(vCursor++, cols[nCols - 1], rows[r], -skirtDepth);
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

  static double _distancePointToAabb(Vector3 p, Aabb3 box) {
    final dx = p.x < box.min.x
        ? box.min.x - p.x
        : (p.x > box.max.x ? p.x - box.max.x : 0.0);
    final dy = p.y < box.min.y
        ? box.min.y - p.y
        : (p.y > box.max.y ? p.y - box.max.y : 0.0);
    final dz = p.z < box.min.z
        ? box.min.z - p.z
        : (p.z > box.max.z ? p.z - box.max.z : 0.0);
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }
}
