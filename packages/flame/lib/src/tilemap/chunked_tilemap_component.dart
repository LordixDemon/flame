import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/src/game/game.dart';
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

class _TileChunk() {
  bool dirty = true;

  int staticQuadCount = 0;
  Float32List staticTransforms = Float32List(0);
  Float32List staticRects = Float32List(0);

  int mirroredVertexCount = 0;
  ui.Vertices? mirroredVertices;

  int animQuadCount = 0;
  int animCycleLength = 1;
  Float32List animTransforms = Float32List(0);
  List<Float32List> animRectBanks = const <Float32List>[];
}

/// Spatially chunked, GPU-batched 2D tilemap layer supporting:
/// - `O(visible_chunks)` camera frustum culling (`16x16` default chunks),
/// - `1` `Canvas.drawRawAtlas` call per static chunk + `1` frame-banked
///   `Canvas.drawRawAtlas` call for animated RPG Maker `A1` water/waterfall
///   autotiles (`0` chunk geometry rebuilds when animation frames advance),
/// - Exact `TileGid` `90°/180°/270°` rotations and `flipH` / `flipV` mirrors,
/// - Surgical `setTileGid(col, row, gid)` dirtying only the `3x3` autotile
///   neighborhood (`1..4` chunks instead of the full map!).
class ChunkedTilemapComponent({
  required this.tileset,
  required this.mapWidth,
  required this.mapHeight,
  this.tileDestWidth = 32.0,
  this.tileDestHeight = 32.0,
  this.chunkSize = 16,
  this.animationStepDuration = 0.25,
  double opacity = 1.0,
  Uint32List? initialCells,
  super.position,
  super.scale,
  super.angle,
  super.anchor,
  super.priority,
  super.sortKey,
  super.cameraMask,
  super.key,
}) extends PositionComponent with HasVisibility {
  this {
    size.setValues(mapWidth * tileDestWidth, mapHeight * tileDestHeight);
    _chunkCols = (mapWidth + chunkSize - 1) ~/ chunkSize;
    _chunkRows = (mapHeight + chunkSize - 1) ~/ chunkSize;
    _chunks = List<_TileChunk>.generate(
      _chunkCols * _chunkRows,
      (_) => _TileChunk(),
      growable: false,
    );
    _cells = Uint32List(mapWidth * mapHeight);
    if (initialCells != null) {
      final copyLen = math.min(_cells.length, initialCells.length);
      _cells.setRange(0, copyLen, initialCells);
    }
    _syncPaintOpacity(opacity);
  }

  final TilesetAtlas tileset;
  final int mapWidth;
  final int mapHeight;
  final double tileDestWidth;
  final double tileDestHeight;
  final int chunkSize;

  /// Duration in seconds of one animated autotile (`A1`) step (`<= 0` pauses).
  double animationStepDuration;

  late final int _chunkCols;
  late final int _chunkRows;
  late final List<_TileChunk> _chunks;
  late final Uint32List _cells;

  double _opacity = 1.0;
  double _animAccum = 0.0;
  int _animStep = 0;

  int _lastRenderedChunkCount = 0;
  int _lastChunkRebuildCount = 0;
  int _lastDrawCallCount = 0;
  int _totalChunkRebuildCount = 0;

  final ui.Paint _atlasPaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.none
    ..isAntiAlias = false;
  final ui.Paint _mirrorPaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.none
    ..isAntiAlias = false;

  static final List<ui.Rect> _quadRectScratch = <ui.Rect>[];

  /// Layer opacity (`0.0 .. 1.0`), e.g. driven by `RoofOcclusionZone`.
  double get opacity => _opacity;
  set opacity(double value) {
    final clamped = value.clamp(0.0, 1.0);
    if ((_opacity - clamped).abs() > 1e-5) {
      _syncPaintOpacity(clamped);
      markSubtreeDirty();
      Game.notifyVisualMutation();
    }
  }

  void _syncPaintOpacity(double clamped) {
    _opacity = clamped;
    final alpha = (clamped * 255.0).round().clamp(0, 255);
    _atlasPaint.color = ui.Color.fromARGB(alpha, 255, 255, 255);
    _mirrorPaint.color = ui.Color.fromARGB(alpha, 255, 255, 255);
  }

  /// Current monotonic animation step index for `A1` animated autotiles.
  int get animationStep => _animStep;

  /// Number of chunks rendered during the most recent [render] pass.
  int get lastRenderedChunkCount => _lastRenderedChunkCount;

  /// Number of dirty chunks rebuilt during the most recent [render] pass.
  int get lastChunkRebuildCount => _lastChunkRebuildCount;

  /// Total chunk rebuilds across the lifetime of this component.
  int get totalChunkRebuildCount => _totalChunkRebuildCount;

  /// Total GPU `drawRawAtlas` + `drawVertices` calls in the most recent pass.
  int get lastDrawCallCount => _lastDrawCallCount;

  /// Number of horizontal chunks covering the map.
  int get chunkColumns => _chunkCols;

  /// Number of vertical chunks covering the map.
  int get chunkRows => _chunkRows;

  /// Whether `(col, row)` is within `[0, mapWidth) * [0, mapHeight)`.
  bool inBounds(int col, int row) =>
      col >= 0 && col < mapWidth && row >= 0 && row < mapHeight;

  /// Reads the packed [TileGid] at `(col, row)` (`TileGid.empty` if out of
  /// bounds).
  TileGid tileGidAt(int col, int row) {
    if (!inBounds(col, row)) {
      return TileGid.empty;
    }
    return TileGid(_cells[row * mapWidth + col]);
  }

  /// Convenience setter for an unflipped, unrotated `tileId` (`0` = empty).
  void setTileId(int col, int row, int tileId) {
    setTileGid(col, row, TileGid.pack(tileId));
  }

  /// Surgically sets `(col, row)` to [gid], dirtying ONLY the `1..4` spatial
  /// chunks touched by `(col, row)` and its `3x3` autotile neighborhood.
  void setTileGid(int col, int row, TileGid gid) {
    if (!inBounds(col, row)) {
      return;
    }
    final idx = row * mapWidth + col;
    if (_cells[idx] == gid.raw) {
      return;
    }
    _cells[idx] = gid.raw;

    final minCol = math.max(0, col - 1);
    final maxCol = math.min(mapWidth - 1, col + 1);
    final minRow = math.max(0, row - 1);
    final maxRow = math.min(mapHeight - 1, row + 1);

    final minCx = minCol ~/ chunkSize;
    final maxCx = maxCol ~/ chunkSize;
    final minCy = minRow ~/ chunkSize;
    final maxCy = maxRow ~/ chunkSize;

    for (var cy = minCy; cy <= maxCy; cy++) {
      for (var cx = minCx; cx <= maxCx; cx++) {
        _chunks[cy * _chunkCols + cx].dirty = true;
      }
    }
    markSubtreeDirty();
    Game.notifyVisualMutation();
  }

  /// Marks all chunks dirty (e.g. after registering new autotile rules).
  void invalidateAllChunks() {
    for (var i = 0; i < _chunks.length; i++) {
      _chunks[i].dirty = true;
    }
    markSubtreeDirty();
    Game.notifyVisualMutation();
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (animationStepDuration <= 0.0) {
      return;
    }
    _animAccum += dt;
    if (_animAccum >= animationStepDuration) {
      final steps = (_animAccum / animationStepDuration).floor();
      _animAccum -= steps * animationStepDuration;
      _animStep = (_animStep + steps) & 0x3FFFFFFF;
      markSubtreeDirty();
      Game.notifyVisualMutation();
    }
  }

  @override
  void render(ui.Canvas canvas) {
    _lastRenderedChunkCount = 0;
    _lastChunkRebuildCount = 0;
    _lastDrawCallCount = 0;
    if (_opacity <= 1e-4) {
      return;
    }

    var minCx = 0;
    var maxCx = _chunkCols - 1;
    var minCy = 0;
    var maxCy = _chunkRows - 1;

    final cam = CameraComponent.currentCamera;
    if (cam != null && angle == 0.0 && scale.x > 0.0 && scale.y > 0.0) {
      final vis = cam.visibleWorldRect;
      final worldPos = absoluteTopLeftPosition;
      final chunkW = chunkSize * tileDestWidth * scale.x;
      final chunkH = chunkSize * tileDestHeight * scale.y;
      if (chunkW > 0.0 && chunkH > 0.0) {
        minCx = ((vis.left - worldPos.x) / chunkW).floor().clamp(0, _chunkCols);
        maxCx = ((vis.right - worldPos.x) / chunkW).ceil().clamp(
          -1,
          _chunkCols - 1,
        );
        minCy = ((vis.top - worldPos.y) / chunkH).floor().clamp(0, _chunkRows);
        maxCy = ((vis.bottom - worldPos.y) / chunkH).ceil().clamp(
          -1,
          _chunkRows - 1,
        );
      }
    }

    if (minCx > maxCx || minCy > maxCy) {
      return;
    }

    var rebuilt = 0;
    var rendered = 0;
    var draws = 0;

    for (var cy = minCy; cy <= maxCy; cy++) {
      for (var cx = minCx; cx <= maxCx; cx++) {
        final chunk = _chunks[cy * _chunkCols + cx];
        if (chunk.dirty) {
          _rebuildChunk(chunk, cx, cy);
          rebuilt++;
          _totalChunkRebuildCount++;
        }
        rendered++;

        if (chunk.staticQuadCount > 0) {
          canvas.drawRawAtlas(
            tileset.image,
            chunk.staticTransforms,
            chunk.staticRects,
            null,
            null,
            null,
            _atlasPaint,
          );
          draws++;
        }

        if (chunk.mirroredVertices != null && chunk.mirroredVertexCount > 0) {
          _mirrorPaint.shader = tileset.shader;
          canvas.drawVertices(
            chunk.mirroredVertices!,
            ui.BlendMode.modulate,
            _mirrorPaint,
          );
          draws++;
        }

        if (chunk.animQuadCount > 0 && chunk.animRectBanks.isNotEmpty) {
          final bankIdx = _animStep % chunk.animCycleLength;
          canvas.drawRawAtlas(
            tileset.image,
            chunk.animTransforms,
            chunk.animRectBanks[bankIdx],
            null,
            null,
            null,
            _atlasPaint,
          );
          draws++;
        }
      }
    }

    _lastChunkRebuildCount = rebuilt;
    _lastRenderedChunkCount = rendered;
    _lastDrawCallCount = draws;
  }

  bool _matchesAutotile(AutotileDefinition def, int col, int row) {
    if (!inBounds(col, row)) {
      // Out-of-bounds edges seamlessly connect so map borders don't draw ugly
      // shore outlines along the edge of the screen (standard RPG Maker rule!).
      return true;
    }
    final otherId = TileGid(_cells[row * mapWidth + col]).tileId;
    if (otherId == def.tileId) {
      return true;
    }
    if (def.connectGroupId != null && otherId != 0) {
      final otherDef = tileset.autotileFor(otherId);
      if (otherDef != null && otherDef.connectGroupId == def.connectGroupId) {
        return true;
      }
    }
    return false;
  }

  void _rebuildChunk(_TileChunk chunk, int cx, int cy) {
    chunk.dirty = false;

    final startCol = cx * chunkSize;
    final endCol = math.min(mapWidth, startCol + chunkSize);
    final startRow = cy * chunkSize;
    final endRow = math.min(mapHeight, startRow + chunkSize);

    final staticTx = <double>[];
    final staticRx = <double>[];

    final mirrorPos = <double>[];
    final mirrorUv = <double>[];
    final mirrorIdx = <int>[];

    final animEntries =
        <
          ({
            AutotileDefinition def,
            AutotileSubtileQuad quad,
            double destX,
            double destY,
          })
        >[];
    var lcmCycle = 1;

    final halfDestW = tileDestWidth * 0.5;
    final halfDestH = tileDestHeight * 0.5;
    final halfSrcW = tileset.tilePxWidth * 0.5;
    final halfSrcH = tileset.tilePxHeight * 0.5;
    final scaleX = tileDestWidth / tileset.tilePxWidth;
    final scaleY = tileDestHeight / tileset.tilePxHeight;
    final uniformScale = (scaleX - scaleY).abs() <= 1e-5;

    for (var row = startRow; row < endRow; row++) {
      final destY = row * tileDestHeight;
      for (var col = startCol; col < endCol; col++) {
        final gid = TileGid(_cells[row * mapWidth + col]);
        if (gid.isEmpty) {
          continue;
        }
        final destX = col * tileDestWidth;
        final autoDef = tileset.autotileFor(gid.tileId);

        if (autoDef != null) {
          final quad = AutotileComposer.composeForCell(
            kind: autoDef.kind,
            col: col,
            row: row,
            matchesNeighbor: (nc, nr) => _matchesAutotile(autoDef, nc, nr),
          );
          if (autoDef.phaseCount > 1 && uniformScale) {
            animEntries.add((
              def: autoDef,
              quad: quad,
              destX: destX,
              destY: destY,
            ));
            lcmCycle = _lcm(lcmCycle, autoDef.phaseCount);
          } else {
            quad.writeSourceRects(
              originPxX: autoDef.blockOriginPxX,
              originPxY: autoDef.blockOriginPxY,
              halfTilePxW: halfSrcW,
              halfTilePxH: halfSrcH,
              out4: _quadRectScratch,
            );
            final dxOffsets = <double>[0, halfDestW, 0, halfDestW];
            final dyOffsets = <double>[0, 0, halfDestH, halfDestH];
            for (var q = 0; q < 4; q++) {
              final sr = _quadRectScratch[q];
              if (uniformScale) {
                staticTx.addAll(<double>[
                  scaleX,
                  0.0,
                  destX + dxOffsets[q],
                  destY + dyOffsets[q],
                ]);
                staticRx.addAll(<double>[sr.left, sr.top, sr.right, sr.bottom]);
              } else {
                _appendTexturedQuad(
                  posOut: mirrorPos,
                  uvOut: mirrorUv,
                  idxOut: mirrorIdx,
                  dstX: destX + dxOffsets[q],
                  dstY: destY + dyOffsets[q],
                  dstW: halfDestW,
                  dstH: halfDestH,
                  src: sr,
                  flipH: false,
                  flipV: false,
                  quarterTurns: 0,
                );
              }
            }
          }
          continue;
        }

        // Standard single tile (with optional flipH / flipV / quarterTurns):
        final src = tileset.sourceRectForTileId(gid.tileId);
        final isReflected = gid.flipH != gid.flipV;

        if (!isReflected && uniformScale) {
          // Pure rotation (including flipH && flipV == +2 quarterTurns!):
          final turns = (gid.quarterTurns + (gid.flipH ? 2 : 0)) & 0x3;
          final (
            double scos,
            double ssin,
            double tx,
            double ty,
          ) = switch (turns) {
            0 => (scaleX, 0.0, destX, destY),
            1 => (0.0, scaleX, destX + tileDestWidth, destY),
            2 => (-scaleX, 0.0, destX + tileDestWidth, destY + tileDestHeight),
            _ => (0.0, -scaleX, destX, destY + tileDestHeight),
          };
          staticTx.addAll(<double>[scos, ssin, tx, ty]);
          staticRx.addAll(<double>[src.left, src.top, src.right, src.bottom]);
        } else {
          _appendTexturedQuad(
            posOut: mirrorPos,
            uvOut: mirrorUv,
            idxOut: mirrorIdx,
            dstX: destX,
            dstY: destY,
            dstW: tileDestWidth,
            dstH: tileDestHeight,
            src: src,
            flipH: gid.flipH,
            flipV: gid.flipV,
            quarterTurns: gid.quarterTurns,
          );
        }
      }
    }

    chunk.staticQuadCount = staticTx.length ~/ 4;
    chunk.staticTransforms = staticTx.isEmpty
        ? Float32List(0)
        : Float32List.fromList(staticTx);
    chunk.staticRects = staticRx.isEmpty
        ? Float32List(0)
        : Float32List.fromList(staticRx);

    if (mirrorPos.isNotEmpty) {
      chunk.mirroredVertexCount = mirrorPos.length ~/ 2;
      chunk.mirroredVertices = ui.Vertices.raw(
        ui.VertexMode.triangles,
        Float32List.fromList(mirrorPos),
        textureCoordinates: Float32List.fromList(mirrorUv),
        indices: Uint16List.fromList(mirrorIdx),
      );
    } else {
      chunk.mirroredVertexCount = 0;
      chunk.mirroredVertices = null;
    }

    if (animEntries.isEmpty) {
      chunk.animQuadCount = 0;
      chunk.animCycleLength = 1;
      chunk.animTransforms = Float32List(0);
      chunk.animRectBanks = const <Float32List>[];
    } else {
      final totalSubQuads = animEntries.length * 4;
      final txBuf = Float32List(totalSubQuads * 4);
      var ti = 0;
      for (var i = 0; i < animEntries.length; i++) {
        final e = animEntries[i];
        final xs = <double>[
          e.destX,
          e.destX + halfDestW,
          e.destX,
          e.destX + halfDestW,
        ];
        final ys = <double>[
          e.destY,
          e.destY,
          e.destY + halfDestH,
          e.destY + halfDestH,
        ];
        for (var q = 0; q < 4; q++) {
          txBuf[ti++] = scaleX;
          txBuf[ti++] = 0.0;
          txBuf[ti++] = xs[q];
          txBuf[ti++] = ys[q];
        }
      }

      final banks = List<Float32List>.generate(lcmCycle, (phase) {
        final rxBuf = Float32List(totalSubQuads * 4);
        var ri = 0;
        for (var i = 0; i < animEntries.length; i++) {
          final e = animEntries[i];
          final frame = e.def.resolveAtlasFrame(phase);
          final ox = e.def.blockOriginPxX + frame * e.def.frameStridePxX;
          final oy = e.def.blockOriginPxY + frame * e.def.frameStridePxY;
          e.quad.writeSourceRects(
            originPxX: ox,
            originPxY: oy,
            halfTilePxW: halfSrcW,
            halfTilePxH: halfSrcH,
            out4: _quadRectScratch,
          );
          for (var q = 0; q < 4; q++) {
            final sr = _quadRectScratch[q];
            rxBuf[ri++] = sr.left;
            rxBuf[ri++] = sr.top;
            rxBuf[ri++] = sr.right;
            rxBuf[ri++] = sr.bottom;
          }
        }
        return rxBuf;
      }, growable: false);

      chunk.animQuadCount = totalSubQuads;
      chunk.animCycleLength = lcmCycle;
      chunk.animTransforms = txBuf;
      chunk.animRectBanks = banks;
    }
  }

  static void _appendTexturedQuad({
    required List<double> posOut,
    required List<double> uvOut,
    required List<int> idxOut,
    required double dstX,
    required double dstY,
    required double dstW,
    required double dstH,
    required ui.Rect src,
    required bool flipH,
    required bool flipV,
    required int quarterTurns,
  }) {
    final baseVert = posOut.length ~/ 2;
    posOut.addAll(<double>[
      dstX,
      dstY,
      dstX + dstW,
      dstY,
      dstX + dstW,
      dstY + dstH,
      dstX,
      dstY + dstH,
    ]);

    final u0 = flipH ? src.right : src.left;
    final u1 = flipH ? src.left : src.right;
    final v0 = flipV ? src.bottom : src.top;
    final v1 = flipV ? src.top : src.bottom;

    // Corner UVs [TL, TR, BR, BL] before clockwise rotation:
    final corners = <(double, double)>[
      (u0, v0),
      (u1, v0),
      (u1, v1),
      (u0, v1),
    ];
    final shift = (4 - (quarterTurns & 0x3)) & 0x3;
    for (var i = 0; i < 4; i++) {
      final (u, v) = corners[(i + shift) & 0x3];
      uvOut
        ..add(u)
        ..add(v);
    }

    idxOut.addAll(<int>[
      baseVert,
      baseVert + 1,
      baseVert + 2,
      baseVert,
      baseVert + 2,
      baseVert + 3,
    ]);
  }

  static int _gcd(int a, int b) {
    var x = a;
    var y = b;
    while (y != 0) {
      final t = x % y;
      x = y;
      y = t;
    }
    return x;
  }

  static int _lcm(int a, int b) => (a ~/ _gcd(a, b)) * b;
}

/// Container that renders its [PositionComponent] children sorted dynamically
/// by foot baseline (`position.y + ySortBaselineOffset`), breaking ties stably
/// by `position.x`, so actors walk seamlessly in front of and behind trees,
/// pillars, fences, and NPCs without mutating `Component.priority` every frame.
class YSortLayerComponent({
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.priority,
  super.sortKey,
  super.cameraMask,
  super.key,
}) extends PositionComponent with HasVisibility {
  final List<Component> _drawOrder = <Component>[];

  /// Optional baseline offset map for children whose visual foot is offset from
  /// `position.y`.
  final Map<Component, double> baselineOffsets = <Component, double>{};

  double _sortY(Component c) {
    if (c is PositionComponent) {
      return c.position.y + (baselineOffsets[c] ?? 0.0);
    }
    return baselineOffsets[c] ?? 0.0;
  }

  double _sortX(Component c) => c is PositionComponent ? c.position.x : 0.0;

  @override
  void renderTree(ui.Canvas canvas) {
    if (!isVisible) {
      return;
    }
    decorator.applyChain(
      (c) {
        render(c);
        _drawOrder
          ..clear()
          ..addAll(children);
        _drawOrder.sort((a, b) {
          final dy = _sortY(a).compareTo(_sortY(b));
          if (dy != 0) {
            return dy;
          }
          return _sortX(a).compareTo(_sortX(b));
        });
        for (var i = 0; i < _drawOrder.length; i++) {
          _drawOrder[i].renderTree(c);
        }
      },
      canvas,
    );
  }
}
