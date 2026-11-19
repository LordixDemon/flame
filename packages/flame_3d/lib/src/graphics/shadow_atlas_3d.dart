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
  Vector4 get uvRect => Vector4(
    x / atlasWidth,
    y / atlasHeight,
    width / atlasWidth,
    height / atlasHeight,
  );
}

/// Shelf / grid tile packer for a unified multi-light shadow atlas texture
/// (`2048x2048` by default).
///
/// Packs up to `4` directional CSM cascades, up to `2` simultaneous `SpotLight`
/// shadow maps, and `PointLight` Dual-Paraboloid (`+Z` and `-Z`) hemisphere
/// tiles into non-overlapping `setViewport` + `setScissor` rectangles inside a
/// single GPU render pass.
class ShadowAtlas3D({
  final int atlasSize = 2048,
}) {
  final List<ShadowAtlasTile3D> _tiles = [];

  int _shelfX = 0;
  int _shelfY = 0;
  int _shelfHeight = 0;

  /// Tiles allocated for the current frame.
  List<ShadowAtlasTile3D> get tiles => List.unmodifiable(_tiles);

  /// Clears all tile allocations for a new frame.
  void reset() {
    _tiles.clear();
    _shelfX = 0;
    _shelfY = 0;
    _shelfHeight = 0;
  }

  /// Chooses a square tile resolution so [totalTiles] fit cleanly inside
  /// [atlasSize] (`1024` for `<= 4` tiles, `512` for `5..16` tiles).
  int recommendedTileSize(int totalTiles, {int preferred = 1024}) {
    final maxPerTile = totalTiles <= 4
        ? atlasSize ~/ 2
        : (totalTiles <= 16 ? atlasSize ~/ 4 : atlasSize ~/ 8);
    final clamped = preferred.clamp(64, maxPerTile);
    // Snap down to power-of-two tile size for clean shelf alignment.
    var pot = 64;
    while (pot * 2 <= clamped) {
      pot *= 2;
    }
    return pot;
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
    if (tileSize <= 0 || tileSize > atlasSize) {
      return null;
    }
    if (_shelfX + tileSize > atlasSize) {
      _shelfX = 0;
      _shelfY += _shelfHeight;
      _shelfHeight = 0;
    }
    if (_shelfY + tileSize > atlasSize) {
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
      atlasWidth: atlasSize,
      atlasHeight: atlasSize,
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
