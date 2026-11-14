import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/src/game/graphics_settings.dart';

/// Pre-filtered GPU mip pyramid (`1x`, `0.5x`, `0.25x`, ...) eliminating severe
/// minification aliasing/shimmering when `Canvas.drawRawAtlas` or `SpriteBatch`
/// renders high-resolution atlases at zoomed-out camera scales.
class MipChainImage._(this._levels, this._scales) {
  /// Builds a progressive 2x box-filtered mip chain down to [minDimension]
  /// (at most [maxLevels] levels including level `0` = [baseImage]).
  ///
  /// When [ownsBaseImage] is `false` (default), [dispose] disposes only the
  /// generated downsampled mip textures and leaves [baseImage] intact.
  factory MipChainImage.generateSync(
    Image baseImage, {
    int maxLevels = 4,
    int minDimension = 16,
    bool ownsBaseImage = false,
  }) {
    final levels = <Image>[baseImage];
    final scales = <double>[1.0];
    final filterPaint = Paint()
      ..filterQuality = FilterQuality.medium
      ..isAntiAlias = true;

    var prev = baseImage;
    var scale = 1.0;
    for (var level = 1; level < maxLevels; level++) {
      final nextW = prev.width ~/ 2;
      final nextH = prev.height ~/ 2;
      if (nextW < minDimension || nextH < minDimension) {
        break;
      }
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImageRect(
        prev,
        Rect.fromLTWH(0, 0, prev.width.toDouble(), prev.height.toDouble()),
        Rect.fromLTWH(0, 0, nextW.toDouble(), nextH.toDouble()),
        filterPaint,
      );
      final pic = recorder.endRecording();
      try {
        prev = pic.toImageSync(nextW, nextH);
      } finally {
        pic.dispose();
      }
      scale *= 0.5;
      levels.add(prev);
      scales.add(scale);
    }
    return MipChainImage._(levels, scales).._ownsBaseImage = ownsBaseImage;
  }

  final List<Image> _levels;
  final List<double> _scales;
  bool _ownsBaseImage = false;
  bool _isDisposed = false;

  /// Number of available mip levels (`>= 1`).
  int get levelCount => _levels.length;

  /// Whether [dispose] has been called.
  bool get isDisposed => _isDisposed;

  /// Returns the [Image] at explicit mip [level] (`0` = full resolution).
  Image imageAtLevel(int level) => _levels[level.clamp(0, _levels.length - 1)];

  /// Returns the UV coordinate multiplier (`1.0`, `0.5`, `0.25`, ...) for
  /// [level].
  double scaleAtLevel(int level) => _scales[level.clamp(0, _scales.length - 1)];

  /// Selects the crispest anti-shimmer mip level index for a given
  /// `effectivePixelScale = cameraZoom * devicePixelRatio * worldRenderScale`.
  int selectLevelForScale(double effectivePixelScale, {double mipBias = 0.0}) {
    if (_levels.length <= 1 || effectivePixelScale >= 1.0) {
      return 0;
    }
    final safeScale = math.max(1e-4, effectivePixelScale);
    // log2(1 / scale): scale=0.5 -> level 1, scale=0.25 -> level 2.
    final rawLod = (math.log(1.0 / safeScale) / math.ln2) + mipBias;
    return rawLod.floor().clamp(0, _levels.length - 1);
  }

  /// Disposes generated mip GPU textures (and level `0` if `ownsBaseImage` was
  /// `true`).
  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    final startIdx = _ownsBaseImage ? 0 : 1;
    for (var i = startIdx; i < _levels.length; i++) {
      _levels[i].dispose();
    }
  }
}

/// Resolves quality-appropriate asset paths (`@0.5x`, `@1x`, `@2x`, `@3x` or
/// directory prefixes) from [GraphicsQualityTier] and live `devicePixelRatio`.
class const ResolutionVariantResolver({
  this.availableScales = const <double>[1.0, 2.0, 3.0],
}) {
  /// Sorted positive asset scale factors bundled with the game.
  final List<double> availableScales;

  /// Chooses the best target scale factor for [tier] and [devicePixelRatio].
  double selectScale({
    required GraphicsQualityTier tier,
    required double devicePixelRatio,
  }) {
    if (availableScales.isEmpty) {
      return 1.0;
    }
    final tierCap = switch (tier) {
      GraphicsQualityTier.low => 1.0,
      GraphicsQualityTier.medium => 2.0,
      GraphicsQualityTier.high => 2.5,
      GraphicsQualityTier.ultra => 4.0,
      GraphicsQualityTier.custom => 3.0,
    };
    final desired = math.min(devicePixelRatio, tierCap);
    var best = availableScales.first;
    var bestDiff = (best - desired).abs();
    for (var i = 1; i < availableScales.length; i++) {
      final candidate = availableScales[i];
      final diff = (candidate - desired).abs();
      if (diff < bestDiff) {
        best = candidate;
        bestDiff = diff;
      }
    }
    return best;
  }

  /// Rewrites `sprites/hero.png` into `sprites/2.0x/hero.png` (standard Flutter
  /// resolution-aware asset layout) when the selected scale differs from `1.0`.
  String resolveAssetPath(
    String logicalPath, {
    required GraphicsQualityTier tier,
    required double devicePixelRatio,
  }) {
    final scale = selectScale(tier: tier, devicePixelRatio: devicePixelRatio);
    if ((scale - 1.0).abs() < 1e-3) {
      return logicalPath;
    }
    final scaleFolder = scale == scale.roundToDouble()
        ? '${scale.toInt()}.0x'
        : '${scale}x';
    final slashIdx = logicalPath.lastIndexOf('/');
    if (slashIdx < 0) {
      return '$scaleFolder/$logicalPath';
    }
    final dir = logicalPath.substring(0, slashIdx);
    final file = logicalPath.substring(slashIdx + 1);
    return '$dir/$scaleFolder/$file';
  }
}
