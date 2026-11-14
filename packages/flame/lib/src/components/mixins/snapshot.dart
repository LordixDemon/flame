import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/extensions.dart';
import 'package:flame/game.dart';
import 'package:meta/meta.dart';

/// Caching strategy used by [Snapshot] when [Snapshot.renderSnapshot] is true.
enum SnapshotCacheMode() {
  /// Replays the recorded [Picture] display list onto the target [Canvas].
  picture,

  /// Rasterizes the snapshot once into a GPU [Image] texture at
  /// [Snapshot.effectiveSnapshotPixelRatio] and blits it via a single textured
  /// quad.
  rasterImage,
}

/// Resolution scaling policy for [SnapshotCacheMode.rasterImage].
enum SnapshotResolutionPolicy() {
  /// Uses the fixed [Snapshot.snapshotPixelRatio] as-is.
  manual,

  /// Multiplies [Snapshot.snapshotPixelRatio] by live `Game.devicePixelRatio`
  /// so cached textures stay Retina-crisp across displays.
  autoHiDpi,

  /// Multiplies [Snapshot.snapshotPixelRatio] by live `Game.devicePixelRatio`
  /// AND quantized camera zoom buckets with hysteresis so zoomed-in views stay
  /// sharp without re-baking on every smooth zoom frame.
  autoHiDpiAndZoom,
}

/// A mixin that enables caching a component and all its children. If
/// [renderSnapshot] is set to `true`, the component and its children will be
/// rendered to a cache. Subsequent renders use the cache, dramatically
/// improving performance for complex static vector or sprite subtrees.
///
/// Native [Picture] and [Image] GPU resources are deterministically disposed
/// whenever the snapshot is invalidated, replaced, or unmounted.
mixin Snapshot on PositionComponent {
  static final Matrix4 _inverseScratch = Matrix4.identity();
  static final Paint _rasterPaint = Paint()..filterQuality = FilterQuality.low;

  static const List<double> defaultZoomBuckets = <double>[
    0.5,
    1.0,
    1.5,
    2.0,
    3.0,
    4.0,
  ];

  bool _renderSnapshot = true;
  SnapshotCacheMode _snapshotCacheMode = SnapshotCacheMode.picture;
  SnapshotResolutionPolicy _snapshotResolutionPolicy =
      SnapshotResolutionPolicy.manual;
  double _snapshotPixelRatio = 1.0;
  double _activeZoomBucket = 1.0;
  double _bakedEffectiveRatio = 1.0;
  int _rasterBakeCount = 0;

  /// Hysteresis band (`0.0 .. 0.45`) preventing rapid raster re-bakes when
  /// camera zoom oscillates near a bucket boundary.
  double zoomBucketHysteresis = 0.12;

  /// Quantized zoom levels evaluated when [snapshotResolutionPolicy] is
  /// [SnapshotResolutionPolicy.autoHiDpiAndZoom].
  List<double> snapshotZoomBuckets = defaultZoomBuckets;

  /// Maximum allowed width or height (in physical pixels) of a rasterized
  /// snapshot texture so large world backdrops never exceed GPU texture limits.
  int maxSnapshotTextureDimension = 4096;

  Rect? _snapshotRegion;

  Picture? _picture;
  Image? _rasterImage;
  Rect _rasterSrcRect = Rect.zero;
  Rect _rasterDstRect = Rect.zero;
  int _snapshotDisposalCount = 0;
  int _estimatedGpuBytes = 0;

  /// Resolution policy applied when [snapshotCacheMode] is
  /// [SnapshotCacheMode.rasterImage].
  SnapshotResolutionPolicy get snapshotResolutionPolicy =>
      _snapshotResolutionPolicy;
  set snapshotResolutionPolicy(SnapshotResolutionPolicy policy) {
    if (_snapshotResolutionPolicy != policy) {
      _snapshotResolutionPolicy = policy;
      _disposeRasterImage();
    }
  }

  /// Currently selected quantized camera zoom bucket (`1.0` in non-zoom modes).
  double get activeZoomBucket => _activeZoomBucket;

  /// Most recently baked effective raster pixel ratio.
  double get effectiveSnapshotPixelRatio => _bakedEffectiveRatio;

  /// Estimated RGBA8 GPU byte usage of the active [cachedSnapshotImage].
  int get estimatedSnapshotGpuBytes => _estimatedGpuBytes;

  /// Number of times [cachedSnapshotImage] was rasterized.
  @visibleForTesting
  int get snapshotRasterBakeCount => _rasterBakeCount;

  /// Caching backend used when [renderSnapshot] is `true`.
  SnapshotCacheMode get snapshotCacheMode => _snapshotCacheMode;
  set snapshotCacheMode(SnapshotCacheMode mode) {
    if (_snapshotCacheMode != mode) {
      _snapshotCacheMode = mode;
      if (mode != SnapshotCacheMode.rasterImage) {
        _disposeRasterImage();
      }
    }
  }

  /// Device pixel ratio multiplier applied when [snapshotCacheMode] is
  /// [SnapshotCacheMode.rasterImage].
  double get snapshotPixelRatio => _snapshotPixelRatio;
  set snapshotPixelRatio(double value) {
    final clamped = value.clamp(0.25, 4.0);
    if (_snapshotPixelRatio != clamped) {
      _snapshotPixelRatio = clamped;
      _disposeRasterImage();
    }
  }

  /// Optional local-space bounding region rasterized in
  /// [SnapshotCacheMode.rasterImage]. When `null`, `Offset.zero & size` is
  /// used.
  Rect? get snapshotRegion => _snapshotRegion;
  set snapshotRegion(Rect? region) {
    if (_snapshotRegion != region) {
      _snapshotRegion = region;
      _disposeRasterImage();
    }
  }

  /// Cached GPU [Image] texture when [snapshotCacheMode] is
  /// [SnapshotCacheMode.rasterImage] and a frame has been rendered.
  Image? get cachedSnapshotImage => _rasterImage;

  /// Number of native GPU resources (`Picture` or `Image`) deterministically
  /// disposed by this component.
  @visibleForTesting
  int get snapshotDisposalCount => _snapshotDisposalCount;

  /// If [renderSnapshot] is `true` then this component and all its children
  /// will be rendered once and cached. If [renderSnapshot] is `false`
  /// then this component will render normally.
  bool get renderSnapshot => _renderSnapshot;
  set renderSnapshot(bool value) {
    if (_renderSnapshot != value) {
      _renderSnapshot = value;
      _disposeSnapshotResources();
    }
  }

  /// Check if a snapshot exists.
  bool get hasSnapshot => _picture != null;

  /// Grab the current snapshot. Check it exists first using [hasSnapshot].
  Picture get snapshot {
    assert(_picture != null, 'No snapshot has been taken');
    return _picture!;
  }

  void _onBudgetEvicted() {
    final image = _rasterImage;
    if (image != null) {
      image.dispose();
      _rasterImage = null;
      _estimatedGpuBytes = 0;
      _snapshotDisposalCount++;
    }
  }

  void _disposeRasterImage() {
    final game = findGame();
    if (game is FlameGame) {
      game.resourceBudget.unregisterSurface(this);
    }
    final image = _rasterImage;
    if (image != null) {
      image.dispose();
      _rasterImage = null;
      _estimatedGpuBytes = 0;
      _snapshotDisposalCount++;
    }
  }

  void _disposeSnapshotResources() {
    final picture = _picture;
    if (picture != null) {
      picture.dispose();
      _picture = null;
      _snapshotDisposalCount++;
    }
    _disposeRasterImage();
  }

  /// Convert the snapshot to an image with the given [width] and [height].
  /// Use [transform] to position the snapshot in the image, or to apply other
  /// transforms before the image is generated.
  Image snapshotAsImage(int width, int height, {Matrix4? transform}) {
    assert(_picture != null, 'No snapshot has been taken');
    if (transform == null) {
      return _picture!.toImageSync(width, height);
    } else {
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.transform32(transform.storage);
      canvas.drawPicture(_picture!);
      final picture = recorder.endRecording();
      try {
        return picture.toImageSync(width, height);
      } finally {
        picture.dispose();
        _snapshotDisposalCount++;
      }
    }
  }

  /// Immediately take a snapshot and return it. If [renderSnapshot] is true
  /// then the snapshot is also used for rendering. A snapshot is always taken
  /// with no transformations (i.e. as if the Snapshot component is at position
  /// (0, 0) and has no scale or rotation applied).
  Picture takeSnapshot() {
    _disposeSnapshotResources();
    final recorder = PictureRecorder();
    final canvas = Canvas(recorder);
    _inverseScratch.setFrom(transformMatrix);
    _inverseScratch.invert();
    canvas.transform32(_inverseScratch.storage);
    super.renderTree(canvas);
    _picture = recorder.endRecording();
    return _picture!;
  }

  double _resolveTargetPixelRatio() {
    if (_snapshotResolutionPolicy == SnapshotResolutionPolicy.manual) {
      _activeZoomBucket = 1.0;
      return _snapshotPixelRatio;
    }
    final game = findGame();
    final dpr = game?.devicePixelRatio ?? 1.0;
    if (_snapshotResolutionPolicy == SnapshotResolutionPolicy.autoHiDpi) {
      _activeZoomBucket = 1.0;
      return (_snapshotPixelRatio * dpr).clamp(0.25, 8.0);
    }

    // SnapshotResolutionPolicy.autoHiDpiAndZoom with hysteresis
    final camZoom =
        CameraComponent.currentCamera?.viewfinder.zoom ??
        (game is FlameGame ? game.camera.viewfinder.zoom : 1.0);
    final buckets = snapshotZoomBuckets.isEmpty
        ? defaultZoomBuckets
        : snapshotZoomBuckets;
    final h = zoomBucketHysteresis.clamp(0.0, 0.45);
    var nextBucket = buckets.first;
    for (var i = 0; i < buckets.length; i++) {
      final candidate = buckets[i];
      final threshold = candidate <= _activeZoomBucket
          ? candidate * (1.0 - h)
          : candidate * (1.0 + h);
      if (camZoom >= threshold) {
        nextBucket = candidate;
      }
    }
    // Always snap upward immediately if zoom exceeds the highest bucket.
    if (camZoom >= buckets.last) {
      nextBucket = buckets.last;
    }
    _activeZoomBucket = nextBucket;
    return (_snapshotPixelRatio * dpr * nextBucket).clamp(0.25, 8.0);
  }

  void _ensureRasterImage() {
    final desiredRatio = _resolveTargetPixelRatio();
    if (_rasterImage != null &&
        (desiredRatio - _bakedEffectiveRatio).abs() <= 1e-3) {
      final game = findGame();
      if (game is FlameGame) {
        game.resourceBudget.touchSurface(this);
      }
      return;
    }
    if (_rasterImage != null) {
      _disposeRasterImage();
    }
    if (_picture == null) {
      takeSnapshot();
    }
    final region = _snapshotRegion ?? Rect.fromLTWH(0.0, 0.0, size.x, size.y);
    if (region.width <= 0.0 || region.height <= 0.0) {
      return;
    }
    final maxDim = math.max(16, maxSnapshotTextureDimension);
    final maxAllowedScale = math.min(
      maxDim / region.width,
      maxDim / region.height,
    );
    final dpr = math.min(desiredRatio, maxAllowedScale);
    final pixelW = math.min(maxDim, math.max(1, (region.width * dpr).ceil()));
    final pixelH = math.min(maxDim, math.max(1, (region.height * dpr).ceil()));

    final scaleX = pixelW / region.width;
    final scaleY = pixelH / region.height;

    final recorder = PictureRecorder();
    final innerCanvas = Canvas(recorder);
    if (scaleX != 1.0 || scaleY != 1.0) {
      innerCanvas.scale(scaleX, scaleY);
    }
    if (region.left != 0.0 || region.top != 0.0) {
      innerCanvas.translate(-region.left, -region.top);
    }
    innerCanvas.drawPicture(_picture!);
    final scaledPicture = recorder.endRecording();
    try {
      _rasterImage = scaledPicture.toImageSync(pixelW, pixelH);
      _bakedEffectiveRatio = desiredRatio;
      _rasterBakeCount++;
      _estimatedGpuBytes = SceneResourceBudget.estimateRgbaBytes(
        pixelW,
        pixelH,
      );
      _rasterSrcRect = Rect.fromLTWH(
        0.0,
        0.0,
        pixelW.toDouble(),
        pixelH.toDouble(),
      );
      _rasterDstRect = region;
      final game = findGame();
      if (game is FlameGame) {
        game.resourceBudget.registerSurface(
          this,
          bytes: _estimatedGpuBytes,
          onEvict: _onBudgetEvicted,
        );
      }
    } finally {
      scaledPicture.dispose();
    }
  }

  /// Clears the current snapshot and disposes its native GPU resources,
  /// triggering creation of a fresh snapshot next time [renderTree] runs.
  void clearSnapshot() {
    _disposeSnapshotResources();
  }

  @mustCallSuper
  @override
  void onRemove() {
    _disposeSnapshotResources();
    super.onRemove();
  }

  @override
  void renderTree(Canvas canvas) {
    if (renderSnapshot) {
      if (_picture == null) {
        takeSnapshot();
      }
      if (_snapshotCacheMode == SnapshotCacheMode.rasterImage) {
        _ensureRasterImage();
        final image = _rasterImage;
        if (image != null) {
          canvas.save();
          canvas.transform32(transformMatrix.storage);
          canvas.drawImageRect(
            image,
            _rasterSrcRect,
            _rasterDstRect,
            _rasterPaint,
          );
          canvas.restore();
          return;
        }
      }
      canvas.save();
      canvas.transform32(transformMatrix.storage);
      canvas.drawPicture(_picture!);
      canvas.restore();
    } else {
      super.renderTree(canvas);
    }
  }
}
