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
///
/// The atlas reuses its tiles from frame to frame: a tile read from
/// [ShadowAtlas3D.tiles] holds the values of the current frame only.
class ShadowAtlasTile3D({
  required ShadowAtlasTileKind3D kind,
  required int lightIndex,
  required int subIndex,
  required int x,
  required int y,
  required int width,
  required int height,
  required int atlasWidth,
  required int atlasHeight,
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
  /// Creates a tile; [view], [projection], [viewProjection] and
  /// [lightPosition] are copied.
  this {
    _set(
      kind: kind,
      lightIndex: lightIndex,
      subIndex: subIndex,
      x: x,
      y: y,
      width: width,
      height: height,
      atlasWidth: atlasWidth,
      atlasHeight: atlasHeight,
      view: view,
      projection: projection,
      viewProjection: viewProjection,
      lightPosition: lightPosition,
      lightRange: lightRange,
      texelWorldSize: texelWorldSize,
      depthBias: depthBias,
      softness: softness,
      strength: strength,
      blendRange: blendRange,
      color: color,
    );
  }

  /// What the tile holds.
  ShadowAtlasTileKind3D get kind => _kind;
  late ShadowAtlasTileKind3D _kind;

  /// The index of the tile's light in its block.
  int get lightIndex => _lightIndex;
  int _lightIndex = 0;

  /// The cascade of a directional light, or the hemisphere of a point light.
  int get subIndex => _subIndex;
  int _subIndex = 0;

  /// The left edge of the tile in the atlas, in texels.
  int get x => _x;
  int _x = 0;

  /// The top edge of the tile in the atlas, in texels.
  int get y => _y;
  int _y = 0;

  /// The width of the tile, in texels.
  int get width => _width;
  int _width = 0;

  /// The height of the tile, in texels.
  int get height => _height;
  int _height = 0;

  /// The width of the atlas, in texels.
  int get atlasWidth => _atlasWidth;
  int _atlasWidth = 1;

  /// The height of the atlas, in texels.
  int get atlasHeight => _atlasHeight;
  int _atlasHeight = 1;

  /// The light's view, or `null` for a point light's tile.
  Matrix4? get view => _hasMatrices ? _view : null;

  /// The light's projection, or `null` for a point light's tile.
  Matrix4? get projection => _hasMatrices ? _projection : null;

  /// `projection * view`, or `null` for a point light's tile.
  Matrix4? get viewProjection => _hasMatrices ? _viewProjection : null;

  final Matrix4 _view = Matrix4.identity();
  final Matrix4 _projection = Matrix4.identity();
  final Matrix4 _viewProjection = Matrix4.identity();
  bool _hasMatrices = false;

  /// The position of the tile's light, when given.
  Vector3? get lightPosition => _hasLightPosition ? _lightPosition : null;
  final Vector3 _lightPosition = Vector3.zero();
  bool _hasLightPosition = false;

  /// The reach of the tile's light.
  double get lightRange => _lightRange;
  double _lightRange = 10;

  /// The size of a texel of the tile in world units.
  double get texelWorldSize => _texelWorldSize;
  double _texelWorldSize = 0.01;

  /// The depth bias of the tile's light, in texels.
  double get depthBias => _depthBias;
  double _depthBias = 1;

  /// The radius of the filter of the tile's light, in texels.
  double get softness => _softness;
  double _softness = 1;

  /// The strength of the shadows of the tile's light.
  double get strength => _strength;
  double _strength = 1;

  /// The fraction of the border of a cascade over which it blends into the
  /// next one.
  double get blendRange => _blendRange;
  double _blendRange = 0.1;

  /// The color of the shadows of the tile's light.
  Color get color => _color;
  Color _color = const Color(0xFF000000);

  /// Normalized atlas UV rectangle `(offsetU, offsetV, scaleU, scaleV)`.
  Vector4 get uvRect => _uvRect;
  final Vector4 _uvRect = Vector4.zero();

  void _set({
    required ShadowAtlasTileKind3D kind,
    required int lightIndex,
    required int subIndex,
    required int x,
    required int y,
    required int width,
    required int height,
    required int atlasWidth,
    required int atlasHeight,
    required Matrix4? view,
    required Matrix4? projection,
    required Matrix4? viewProjection,
    required Vector3? lightPosition,
    required double lightRange,
    required double texelWorldSize,
    required double depthBias,
    required double softness,
    required double strength,
    required double blendRange,
    required Color color,
  }) {
    _kind = kind;
    _lightIndex = lightIndex;
    _subIndex = subIndex;
    _x = x;
    _y = y;
    _width = width;
    _height = height;
    _atlasWidth = atlasWidth;
    _atlasHeight = atlasHeight;
    _hasMatrices = view != null && projection != null && viewProjection != null;
    if (_hasMatrices) {
      _view.setFrom(view!);
      _projection.setFrom(projection!);
      _viewProjection.setFrom(viewProjection!);
    }
    _hasLightPosition = lightPosition != null;
    if (lightPosition != null) {
      _lightPosition.setFrom(lightPosition);
    }
    _lightRange = lightRange;
    _texelWorldSize = texelWorldSize;
    _depthBias = depthBias;
    _softness = softness;
    _strength = strength;
    _blendRange = blendRange;
    _color = color;
    _uvRect.setValues(
      x / atlasWidth,
      y / atlasHeight,
      width / atlasWidth,
      height / atlasHeight,
    );
  }
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

  // The tiles of earlier frames, reused by [allocateTile].
  final List<ShadowAtlasTile3D> _pool = [];

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
  /// `null` if the atlas is full. The tile object of the same rank in an
  /// earlier frame is reused, with the matrices and the position copied.
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

    final index = _tiles.length;
    final ShadowAtlasTile3D tile;
    if (index < _pool.length) {
      tile = _pool[index]
        .._set(
          kind: kind,
          lightIndex: lightIndex,
          subIndex: subIndex,
          x: _shelfX,
          y: _shelfY,
          width: tileSize,
          height: tileSize,
          atlasWidth: _width,
          atlasHeight: _height,
          view: view,
          projection: projection,
          viewProjection: viewProjection,
          lightPosition: lightPosition,
          lightRange: lightRange,
          texelWorldSize: texelWorldSize,
          depthBias: depthBias,
          softness: softness,
          strength: strength,
          blendRange: blendRange,
          color: color,
        );
    } else {
      tile = ShadowAtlasTile3D(
        kind: kind,
        lightIndex: lightIndex,
        subIndex: subIndex,
        x: _shelfX,
        y: _shelfY,
        width: tileSize,
        height: tileSize,
        atlasWidth: _width,
        atlasHeight: _height,
        view: view,
        projection: projection,
        viewProjection: viewProjection,
        lightPosition: lightPosition,
        lightRange: lightRange,
        texelWorldSize: texelWorldSize,
        depthBias: depthBias,
        softness: softness,
        strength: strength,
        blendRange: blendRange,
        color: color,
      );
      _pool.add(tile);
    }
    _tiles.add(tile);
    _shelfX += tileSize;
    if (tileSize > _shelfHeight) {
      _shelfHeight = tileSize;
    }
    return tile;
  }
}
