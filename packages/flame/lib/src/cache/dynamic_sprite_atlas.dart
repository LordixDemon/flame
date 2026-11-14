import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/extensions.dart';
import 'package:flame/src/sprite.dart';

/// 2D integer rectangle placed inside a [MaxRectsBinPacker] page.
class const PackedAtlasRect({
  required this.x,
  required this.y,
  required this.width,
  required this.height,
}) {
  /// Left coordinate in pixels.
  final int x;

  /// Top coordinate in pixels.
  final int y;

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Converts this integer placement into a floating-point `dart:ui` [Rect].
  Rect toRect() => Rect.fromLTWH(
    x.toDouble(),
    y.toDouble(),
    width.toDouble(),
    height.toDouble(),
  );
}

/// Deterministic Maximal-Rectangles (Best Short-Side Fit) 2D bin packer for
/// packing heterogeneous sprite images into a single GPU atlas texture.
class MaxRectsBinPacker({
  required this.binWidth,
  required this.binHeight,
}) {
  /// Atlas width in pixels.
  final int binWidth;

  /// Atlas height in pixels.
  final int binHeight;

  final List<PackedAtlasRect> _freeRects = <PackedAtlasRect>[
    PackedAtlasRect(x: 0, y: 0, width: binWidth, height: binHeight),
  ];
  int _usedArea = 0;

  /// Ratio (`0.0 .. 1.0`) of bin pixel area currently occupied.
  double get occupancy =>
      (binWidth > 0 && binHeight > 0) ? _usedArea / (binWidth * binHeight) : 0;

  /// Inserts a rectangle of `(width, height)` using Best Short-Side Fit, or
  /// returns `null` if the bin cannot fit it.
  PackedAtlasRect? insert(int width, int height) {
    if (width <= 0 || height <= 0 || width > binWidth || height > binHeight) {
      return null;
    }

    var bestShortSide = 0x7FFFFFFF;
    var bestLongSide = 0x7FFFFFFF;
    PackedAtlasRect? bestNode;

    for (var i = 0; i < _freeRects.length; i++) {
      final free = _freeRects[i];
      if (free.width >= width && free.height >= height) {
        final leftoverHoriz = free.width - width;
        final leftoverVert = free.height - height;
        final shortSide = math.min(leftoverHoriz, leftoverVert);
        final longSide = math.max(leftoverHoriz, leftoverVert);
        if (shortSide < bestShortSide ||
            (shortSide == bestShortSide && longSide < bestLongSide)) {
          bestNode = PackedAtlasRect(
            x: free.x,
            y: free.y,
            width: width,
            height: height,
          );
          bestShortSide = shortSide;
          bestLongSide = longSide;
        }
      }
    }

    if (bestNode == null) {
      return null;
    }

    for (var i = _freeRects.length - 1; i >= 0; i--) {
      if (_splitFreeNode(_freeRects[i], bestNode)) {
        _freeRects.removeAt(i);
      }
    }
    _pruneFreeList();
    _usedArea += width * height;
    return bestNode;
  }

  bool _splitFreeNode(PackedAtlasRect free, PackedAtlasRect used) {
    if (used.x >= free.x + free.width ||
        used.x + used.width <= free.x ||
        used.y >= free.y + free.height ||
        used.y + used.height <= free.y) {
      return false;
    }

    if (used.x < free.x + free.width && used.x + used.width > free.x) {
      if (used.y > free.y && used.y < free.y + free.height) {
        _freeRects.add(
          PackedAtlasRect(
            x: free.x,
            y: free.y,
            width: free.width,
            height: used.y - free.y,
          ),
        );
      }
      if (used.y + used.height < free.y + free.height) {
        _freeRects.add(
          PackedAtlasRect(
            x: free.x,
            y: used.y + used.height,
            width: free.width,
            height: free.y + free.height - (used.y + used.height),
          ),
        );
      }
    }

    if (used.y < free.y + free.height && used.y + used.height > free.y) {
      if (used.x > free.x && used.x < free.x + free.width) {
        _freeRects.add(
          PackedAtlasRect(
            x: free.x,
            y: free.y,
            width: used.x - free.x,
            height: free.height,
          ),
        );
      }
      if (used.x + used.width < free.x + free.width) {
        _freeRects.add(
          PackedAtlasRect(
            x: used.x + used.width,
            y: free.y,
            width: free.x + free.width - (used.x + used.width),
            height: free.height,
          ),
        );
      }
    }
    return true;
  }

  void _pruneFreeList() {
    for (var i = 0; i < _freeRects.length; i++) {
      for (var j = i + 1; j < _freeRects.length; j++) {
        if (_isContainedIn(_freeRects[i], _freeRects[j])) {
          _freeRects.removeAt(i);
          i--;
          break;
        }
        if (_isContainedIn(_freeRects[j], _freeRects[i])) {
          _freeRects.removeAt(j);
          j--;
        }
      }
    }
  }

  static bool _isContainedIn(PackedAtlasRect a, PackedAtlasRect b) {
    return a.x >= b.x &&
        a.y >= b.y &&
        a.x + a.width <= b.x + b.width &&
        a.y + a.height <= b.y + b.height;
  }
}

class _PendingAtlasItem(
  final String id,
  final int width,
  final int height,
  final void Function(Canvas canvas, Rect dst) drawContent,
  final Image? sourceForExtrusion,
);

/// Packs separate [Image]s or procedural vector icons at runtime into a
/// **single** GPU [Image] atlas with optional border pixel extrusion
/// (`extrudePadding`) so dozens of distinct sprites share `1` `SpriteBatch` /
/// `Canvas.drawRawAtlas` draw call without seam bleeding.
class DynamicSpriteAtlas._(
  final Image atlasImage,
  final Map<String, Rect> _regions,
  final Map<String, Sprite> _sprites,
) {
  bool _isDisposed = false;

  /// Whether [dispose] has been called.
  bool get isDisposed => _isDisposed;

  /// Packed sprite identifiers.
  Iterable<String> get keys => _regions.keys;

  /// Source UV pixel rectangle inside [atlasImage] for [id].
  Rect? regionOf(String id) => _regions[id];

  /// Pre-built [Sprite] referencing [atlasImage] at [id]'s packed sub-rect.
  Sprite spriteOf(String id) {
    final s = _sprites[id];
    if (s == null) {
      throw ArgumentError.value(id, 'id', 'Unknown DynamicSpriteAtlas key');
    }
    return s;
  }

  /// Disposes the underlying GPU [atlasImage] deterministically.
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    atlasImage.dispose();
  }

  /// Creates a builder accumulating images and procedural painters before
  /// baking into a single GPU [DynamicSpriteAtlas].
  static DynamicSpriteAtlasBuilder builder({
    int maxAtlasDimension = 2048,
    int extrudePadding = 2,
  }) => DynamicSpriteAtlasBuilder(
    maxAtlasDimension: maxAtlasDimension,
    extrudePadding: extrudePadding,
  );
}

/// Accumulator for [DynamicSpriteAtlas] entries.
class DynamicSpriteAtlasBuilder({
  this.maxAtlasDimension = 2048,
  this.extrudePadding = 2,
}) {
  /// Maximum width/height of the baked GPU texture.
  final int maxAtlasDimension;

  /// Border padding around each sprite (replicated from edge texels for
  /// [addImage] entries to eliminate bilinear texture-bleed seams).
  final int extrudePadding;

  final List<_PendingAtlasItem> _items = <_PendingAtlasItem>[];

  /// Adds an existing [Image] under [id].
  void addImage(String id, Image image) {
    _items.add(
      _PendingAtlasItem(
        id,
        image.width,
        image.height,
        (canvas, dst) {
          canvas.drawImageRect(
            image,
            Rect.fromLTWH(
              0,
              0,
              image.width.toDouble(),
              image.height.toDouble(),
            ),
            dst,
            _copyPaint,
          );
        },
        image,
      ),
    );
  }

  /// Adds a procedural `Canvas` icon/shape of `(width, height)` under [id].
  void addProcedural(
    String id, {
    required int width,
    required int height,
    required void Function(Canvas canvas, Size size) painter,
  }) {
    _items.add(
      _PendingAtlasItem(
        id,
        width,
        height,
        (canvas, dst) {
          canvas.save();
          canvas.translate(dst.left, dst.top);
          canvas.clipRect(
            Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
          );
          painter(canvas, Size(width.toDouble(), height.toDouble()));
          canvas.restore();
        },
        null,
      ),
    );
  }

  static final Paint _copyPaint = Paint()
    ..blendMode = BlendMode.src
    ..isAntiAlias = false
    ..filterQuality = FilterQuality.none;

  /// Packs all registered items (auto-sizing power-of-two bin dimensions up to
  /// [maxAtlasDimension]) and rasterizes the single GPU [DynamicSpriteAtlas]
  /// synchronously via `Picture.toImageSync`.
  DynamicSpriteAtlas buildSync() {
    if (_items.isEmpty) {
      throw StateError('DynamicSpriteAtlasBuilder has no items to pack');
    }

    // Sort largest area first for optimal MaxRects packing density.
    final sorted = List<_PendingAtlasItem>.of(_items)
      ..sort((a, b) => (b.width * b.height).compareTo(a.width * a.height));

    final pad = math.max(0, extrudePadding);
    var totalPaddedArea = 0;
    var minReqW = 16;
    var minReqH = 16;
    for (final item in sorted) {
      final pw = item.width + pad * 2;
      final ph = item.height + pad * 2;
      totalPaddedArea += pw * ph;
      minReqW = math.max(minReqW, pw);
      minReqH = math.max(minReqH, ph);
    }

    var atlasW = _nextPow2(
      math.max(minReqW, math.sqrt(totalPaddedArea).ceil()),
    );
    var atlasH = _nextPow2(
      math.max(minReqH, (totalPaddedArea / atlasW).ceil()),
    );

    Map<String, PackedAtlasRect>? placed;
    while (atlasW <= maxAtlasDimension && atlasH <= maxAtlasDimension) {
      final packer = MaxRectsBinPacker(binWidth: atlasW, binHeight: atlasH);
      final attempt = <String, PackedAtlasRect>{};
      var fitsAll = true;
      for (final item in sorted) {
        final rect = packer.insert(item.width + pad * 2, item.height + pad * 2);
        if (rect == null) {
          fitsAll = false;
          break;
        }
        attempt[item.id] = PackedAtlasRect(
          x: rect.x + pad,
          y: rect.y + pad,
          width: item.width,
          height: item.height,
        );
      }
      if (fitsAll) {
        placed = attempt;
        break;
      }
      if (atlasW <= atlasH && atlasW * 2 <= maxAtlasDimension) {
        atlasW *= 2;
      } else if (atlasH * 2 <= maxAtlasDimension) {
        atlasH *= 2;
      } else {
        break;
      }
    }

    if (placed == null) {
      throw StateError(
        'DynamicSpriteAtlas overflowed maxAtlasDimension=$maxAtlasDimension',
      );
    }

    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);

    for (final item in sorted) {
      final inner = placed[item.id]!;
      final dst = inner.toRect();
      item.drawContent(canvas, dst);

      final srcImg = item.sourceForExtrusion;
      if (srcImg != null && pad > 0) {
        _extrudeImageBorders(canvas, srcImg, inner, pad.toDouble());
      }
    }

    final picture = recorder.endRecording();
    final Image baked;
    try {
      baked = picture.toImageSync(atlasW, atlasH);
    } finally {
      picture.dispose();
    }

    final regions = <String, Rect>{};
    final sprites = <String, Sprite>{};
    for (final entry in placed.entries) {
      final r = entry.value.toRect();
      regions[entry.key] = r;
      sprites[entry.key] = Sprite(
        baked,
        srcPosition: Vector2(r.left, r.top),
        srcSize: Vector2(r.width, r.height),
      );
    }
    return DynamicSpriteAtlas._(baked, regions, sprites);
  }

  static void _extrudeImageBorders(
    Canvas canvas,
    Image img,
    PackedAtlasRect inner,
    double pad,
  ) {
    final w = img.width.toDouble();
    final h = img.height.toDouble();
    final ix = inner.x.toDouble();
    final iy = inner.y.toDouble();
    // Top & bottom 1px strips stretched across `pad`.
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, w, 1),
      Rect.fromLTWH(ix, iy - pad, w, pad),
      _copyPaint,
    );
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, h - 1, w, 1),
      Rect.fromLTWH(ix, iy + h, w, pad),
      _copyPaint,
    );
    // Left & right 1px strips stretched across `pad`.
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, 1, h),
      Rect.fromLTWH(ix - pad, iy, pad, h),
      _copyPaint,
    );
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(w - 1, 0, 1, h),
      Rect.fromLTWH(ix + w, iy, pad, h),
      _copyPaint,
    );
  }

  static int _nextPow2(int v) {
    var n = math.max(16, v - 1);
    n |= n >> 1;
    n |= n >> 2;
    n |= n >> 4;
    n |= n >> 8;
    n |= n >> 16;
    return n + 1;
  }
}
