import 'dart:collection' show UnmodifiableListView;
import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame_3d/game.dart';

/// Kind of shadow tile packed inside a [ShadowAtlas3D].
enum ShadowAtlasTileKind3D() {
  /// Orthographic directional cascade (`0..3`).
  directionalCascade,

  /// Perspective cone spotlight shadow map (`0..1`).
  spotLight,

  /// Omnidirectional `PointLight` `+Z` front paraboloid hemisphere.
  pointParaboloidFront,

  /// Omnidirectional `PointLight` `-Z` back paraboloid hemisphere.
  pointParaboloidBack,
}

/// Rectangular viewport/scissor tile allocated inside a [ShadowAtlas3D].
class ShadowAtlasTile3D({
  required final ShadowAtlasTileKind3D kind,
  required final int lightIndex,
  required final int subIndex,
  required final int x,
  required final int y,
  required final int width,
  required final int height,
  required final int atlasWidth,
  required final int atlasHeight,
  final Matrix4? view,
  final Matrix4? projection,
  final Matrix4? viewProjection,
  final Vector3? lightPosition,
  final double lightRange = 10.0,
  final double texelWorldSize = 0.01,
  final double depthBias = 1.0,
  final double softness = 1.0,
  final double strength = 1.0,
  final double blendRange = 0.1,
  final Color color = const Color(0xFF000000),
}) {
  /// Normalized atlas UV rectangle `(offsetU, offsetV, scaleU, scaleV)`.
  late final Vector4 uvRect = Vector4(
    x / atlasWidth,
    y / atlasHeight,
    width / atlasWidth,
    height / atlasHeight,
  );
}

/// Shelf / grid tile packer for a unified multi-light shadow atlas texture
/// of up to [atlasSize] by [atlasSize] texels.
///
/// Packs up to `4` directional CSM cascades, up to `2` simultaneous `SpotLight`
/// shadow maps, and `PointLight` Dual-Paraboloid (`+Z` and `-Z`) hemisphere
/// tiles into non-overlapping `setViewport` + `setScissor` rectangles inside a
/// single GPU render pass. The shadow pass sizes the atlas of each frame to
/// its tiles (see [reset]).
class ShadowAtlas3D({
  /// The largest width and height of the atlas, in texels.
  final int atlasSize = 4096,
}) {
  final List<ShadowAtlasTile3D> _tiles = [];

  int _shelfX = 0;
  int _shelfY = 0;
  int _shelfHeight = 0;

  /// The width of the atlas tiles are packed into, in texels, see [reset].
  int get width => _width;
  int _width = atlasSize;

  /// The height of the atlas tiles are packed into, in texels, see [reset].
  int get height => _height;
  int _height = atlasSize;

  /// Tiles allocated for the current frame: a read-only view that follows
  /// the allocations.
  late final List<ShadowAtlasTile3D> tiles = UnmodifiableListView(_tiles);

  /// Clears all tile allocations for a new frame, packing the next tiles
  /// into an atlas of [width] by [height] texels ([atlasSize] by default,
  /// clamped to it).
  void reset({int? width, int? height}) {
    _tiles.clear();
    _shelfX = 0;
    _shelfY = 0;
    _shelfHeight = 0;
    _width = math.min(width ?? atlasSize, atlasSize);
    _height = math.min(height ?? atlasSize, atlasSize);
  }

  /// The number of columns of the grid that holds [totalTiles] square tiles:
  /// the smallest whose square is at least [totalTiles].
  static int columnsFor(int totalTiles) {
    var columns = 1;
    while (columns * columns < totalTiles) {
      columns++;
    }
    return columns;
  }

  /// The number of rows of the grid of [columnsFor] columns that holds
  /// [totalTiles] square tiles.
  static int rowsFor(int totalTiles) {
    final columns = columnsFor(totalTiles);
    return math.max(1, (totalTiles + columns - 1) ~/ columns);
  }

  /// The side of the square tiles so that [totalTiles] of them fit in a grid
  /// (see [columnsFor]) within [atlasSize]: [preferred] (at least 16) when
  /// they fit, smaller otherwise.
  int recommendedTileSize(int totalTiles, {int preferred = 1024}) {
    final columns = columnsFor(math.max(1, totalTiles));
    final rows = rowsFor(math.max(1, totalTiles));
    final largest = atlasSize ~/ math.max(columns, rows);
    return math.max(16, math.min(preferred, largest));
  }

  /// Allocates a square [tileSize]x[tileSize] tile inside the atlas, returning
  /// `null` if the atlas is full.
  ShadowAtlasTile3D? allocateTile({
    required ShadowAtlasTileKind3D kind,
    required int lightIndex,
    required int tileSize,
    int subIndex = 0,
    Matrix4? view,
    Matrix4? projection,
    Matrix4? viewProjection,
    Vector3? lightPosition,
    double lightRange = 10.0,
    double texelWorldSize = 0.01,
    double depthBias = 1.0,
    double softness = 1.0,
    double strength = 1.0,
    double blendRange = 0.1,
    Color color = const Color(0xFF000000),
  }) {
    if (tileSize <= 0 || tileSize > _width || tileSize > _height) {
      return null;
    }
    if (_shelfX + tileSize > _width) {
      _shelfX = 0;
      _shelfY += _shelfHeight;
      _shelfHeight = 0;
    }
    if (_shelfY + tileSize > _height) {
      return null;
    }

    final tile = ShadowAtlasTile3D(
      kind: kind,
      lightIndex: lightIndex,
      subIndex: subIndex,
      x: _shelfX,
      y: _shelfY,
      width: tileSize,
      height: tileSize,
      atlasWidth: _width,
      atlasHeight: _height,
      view: view?.clone(),
      projection: projection?.clone(),
      viewProjection: viewProjection?.clone(),
      lightPosition: lightPosition?.clone(),
      lightRange: lightRange,
      texelWorldSize: texelWorldSize,
      depthBias: depthBias,
      softness: softness,
      strength: strength,
      blendRange: blendRange,
      color: color,
    );
    _tiles.add(tile);
    _shelfX += tileSize;
    if (tileSize > _shelfHeight) {
      _shelfHeight = tileSize;
    }
    return tile;
  }
}
