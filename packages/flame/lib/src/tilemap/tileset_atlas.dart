import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/tilemap/autotile_composer.dart';

/// Tileset texture atlas mapping 1-based `TileGid.tileId` values to source
/// pixel rectangles and optional RPG Maker `A1–A4` [AutotileDefinition] blocks.
class TilesetAtlas({
  required this.image,
  required this.tilePxWidth,
  required this.tilePxHeight,
  this.firstGid = 1,
  int? explicitColumns,
  this.marginPx = 0,
  this.spacingPx = 0,
  Map<int, AutotileDefinition>? autotiles,
}) {
  final ui.Image image;
  final int tilePxWidth;
  final int tilePxHeight;
  final int firstGid;
  final int marginPx;
  final int spacingPx;

  final int columns =
      explicitColumns ??
      math.max(
        1,
        (image.width - marginPx * 2 + spacingPx) ~/ (tilePxWidth + spacingPx),
      );

  final Map<int, AutotileDefinition> _autotiles = autotiles != null
      ? Map<int, AutotileDefinition>.of(autotiles)
      : <int, AutotileDefinition>{};

  late final ui.ImageShader _shader = ui.ImageShader(
    image,
    ui.TileMode.clamp,
    ui.TileMode.clamp,
    Float64List.fromList(const <double>[
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
      0,
      0,
      0,
      0,
      1,
    ]),
  );

  /// Registers or replaces an [AutotileDefinition] for `def.tileId`.
  void registerAutotile(AutotileDefinition def) {
    _autotiles[def.tileId] = def;
  }

  /// Looks up an [AutotileDefinition] by `tileId`, or `null` for plain tiles.
  AutotileDefinition? autotileFor(int tileId) => _autotiles[tileId];

  /// Computes the source atlas [ui.Rect] in pixels for a plain non-autotile
  /// [tileId].
  ui.Rect sourceRectForTileId(int tileId) {
    final local = math.max(0, tileId - firstGid);
    final col = local % columns;
    final row = local ~/ columns;
    final x = marginPx + col * (tilePxWidth + spacingPx);
    final y = marginPx + row * (tilePxHeight + spacingPx);
    return ui.Rect.fromLTWH(
      x.toDouble(),
      y.toDouble(),
      tilePxWidth.toDouble(),
      tilePxHeight.toDouble(),
    );
  }

  /// Shared clamped `ImageShader` used when a chunk contains mirrored (`flipH`
  /// xor `flipV`) tiles rendered via `Vertices.raw`.
  ui.ImageShader get shader => _shader;

  /// Disposes the cached shader (does not dispose [image], which is owned by
  /// `Images` / `AssetScope`).
  void disposeShader() {
    _shader.dispose();
  }
}
