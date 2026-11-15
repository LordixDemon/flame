import 'dart:collection';
import 'dart:ui' as ui;

/// Single visual equipment or body layer fed into [PaperDollCompositor].
class PaperDollLayer({
  required this.id,
  required this.image,
  this.zOrder = 0,
  this.tintColor = const ui.Color(0xFFFFFFFF),
  this.sourceRect,
  this.offsetX = 0.0,
  this.offsetY = 0.0,
}) {
  /// Stable layer identifier (e.g. `'body_light'`, `'armor_iron'`,
  /// `'hair_short'`).
  final String id;

  /// Layer sprite sheet image.
  final ui.Image image;

  /// Ascending layer draw order (`body < pants < armor < cloak < hair < hat`).
  final int zOrder;

  /// Optional multiplicative color dye/tint applied to this layer when baking
  /// (e.g. hair color or armor dye).
  final ui.Color tintColor;

  /// Optional sub-rectangle within [image] if multiple outfits share an atlas.
  final ui.Rect? sourceRect;

  /// Pixel X offset within the target composited sheet.
  final double offsetX;

  /// Pixel Y offset within the target composited sheet.
  final double offsetY;
}

class _CachedPaperDollSheet(
  this.signature,
  this.image,
) {
  final String signature;
  final ui.Image image;
  bool disposed = false;

  void dispose() {
    if (!disposed) {
      disposed = true;
      image.dispose();
    }
  }
}

/// Bakes multi-layer character paper-doll sheets (`body + eyes + armor + hair +
/// helmet`) into a single cached GPU [ui.Image] keyed by canonical outfit
/// signature.
///
/// Compositing layers once when equipment changes eliminates both `N`-times
/// sprite draw amplification and translucent `saveLayer` alpha-stacking
/// artifacts when characters fade under roofs or wade into deep grass.
class PaperDollCompositor({
  this.maxCachedSheets = 32,
}) {
  this : assert(maxCachedSheets >= 1, 'maxCachedSheets must be >= 1.');

  /// Maximum number of baked character outfit sheets retained in the LRU cache.
  final int maxCachedSheets;

  final LinkedHashMap<String, _CachedPaperDollSheet> _lru =
      LinkedHashMap<String, _CachedPaperDollSheet>();

  int _cacheHitCount = 0;
  int _cacheMissCount = 0;
  int _evictedImageCount = 0;
  int _disposedImageCount = 0;
  bool _isDisposed = false;

  /// Number of currently cached GPU sheets.
  int get cachedSheetCount => _lru.length;

  /// Total cache hits served without re-baking.
  int get cacheHitCount => _cacheHitCount;

  /// Total cache misses that baked a new GPU [ui.Image].
  int get cacheMissCount => _cacheMissCount;

  /// Total sheets evicted and disposed due to [maxCachedSheets] pressure.
  int get evictedImageCount => _evictedImageCount;

  /// Total GPU images deterministically disposed by this compositor.
  int get disposedImageCount => _disposedImageCount;

  /// Whether [dispose] has been called.
  bool get isDisposed => _isDisposed;

  /// Computes the canonical deterministic cache key for [layers] at target
  /// pixel size `(sheetWidth, sheetHeight)`.
  String computeSignature(
    List<PaperDollLayer> layers, {
    required int sheetWidth,
    required int sheetHeight,
  }) {
    final sorted = List<PaperDollLayer>.of(layers)
      ..sort((a, b) => a.zOrder.compareTo(b.zOrder));
    final sb = StringBuffer('${sheetWidth}x$sheetHeight');
    for (final l in sorted) {
      final r = l.sourceRect;
      sb
        ..write('|')
        ..write(l.zOrder)
        ..write(':')
        ..write(l.id)
        ..write('@')
        ..write(identityHashCode(l.image))
        ..write('#')
        ..write(l.tintColor.toARGB32().toRadixString(16))
        ..write('+')
        ..write(l.offsetX.toStringAsFixed(2))
        ..write(',')
        ..write(l.offsetY.toStringAsFixed(2));
      if (r != null) {
        sb
          ..write('[')
          ..write(r.left.toStringAsFixed(1))
          ..write(',')
          ..write(r.top.toStringAsFixed(1))
          ..write(',')
          ..write(r.width.toStringAsFixed(1))
          ..write(',')
          ..write(r.height.toStringAsFixed(1))
          ..write(']');
      }
    }
    return sb.toString();
  }

  /// Returns a cached or newly baked single-sheet [ui.Image] combining [layers]
  /// in ascending [PaperDollLayer.zOrder].
  ui.Image composeSync(
    List<PaperDollLayer> layers, {
    required int sheetWidth,
    required int sheetHeight,
  }) {
    assert(!_isDisposed, 'Cannot compose on a disposed PaperDollCompositor.');
    assert(
      sheetWidth > 0 && sheetHeight > 0,
      'Sheet dimensions must be > 0.',
    );

    final signature = computeSignature(
      layers,
      sheetWidth: sheetWidth,
      sheetHeight: sheetHeight,
    );

    final existing = _lru.remove(signature);
    if (existing != null && !existing.disposed) {
      _lru[signature] = existing;
      _cacheHitCount++;
      return existing.image;
    }

    _cacheMissCount++;
    final sorted = List<PaperDollLayer>.of(layers)
      ..sort((a, b) => a.zOrder.compareTo(b.zOrder));

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
      recorder,
      ui.Rect.fromLTWH(0, 0, sheetWidth.toDouble(), sheetHeight.toDouble()),
    );
    final paint = ui.Paint()
      ..filterQuality = ui.FilterQuality.none
      ..isAntiAlias = false;

    for (final layer in sorted) {
      final src =
          layer.sourceRect ??
          ui.Rect.fromLTWH(
            0,
            0,
            layer.image.width.toDouble(),
            layer.image.height.toDouble(),
          );
      final dst = ui.Rect.fromLTWH(
        layer.offsetX,
        layer.offsetY,
        src.width,
        src.height,
      );
      final tintArgb = layer.tintColor.toARGB32();
      if (tintArgb != 0xFFFFFFFF) {
        paint.colorFilter = ui.ColorFilter.mode(
          layer.tintColor,
          ui.BlendMode.modulate,
        );
      } else {
        paint.colorFilter = null;
      }
      canvas.drawImageRect(layer.image, src, dst, paint);
    }

    final picture = recorder.endRecording();
    final baked = picture.toImageSync(sheetWidth, sheetHeight);
    picture.dispose();

    while (_lru.length >= maxCachedSheets) {
      final oldestKey = _lru.keys.first;
      final victim = _lru.remove(oldestKey);
      if (victim != null) {
        victim.dispose();
        _evictedImageCount++;
        _disposedImageCount++;
      }
    }

    _lru[signature] = _CachedPaperDollSheet(signature, baked);
    return baked;
  }

  /// Evicts and disposes a specific cached outfit by [signature], if present.
  bool evict(String signature) {
    final removed = _lru.remove(signature);
    if (removed != null) {
      removed.dispose();
      _disposedImageCount++;
      return true;
    }
    return false;
  }

  /// Clears and disposes all cached GPU images while keeping this compositor
  /// reusable.
  void clearCache() {
    for (final entry in _lru.values) {
      entry.dispose();
      _disposedImageCount++;
    }
    _lru.clear();
  }

  /// Permanently disposes all cached GPU images.
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    clearCache();
  }
}
