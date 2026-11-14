import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/extensions.dart';
import 'package:meta/meta.dart';

/// Caching strategy used by [Snapshot] when [Snapshot.renderSnapshot] is true.
enum SnapshotCacheMode() {
  /// Replays the recorded [Picture] display list onto the target [Canvas].
  picture,

  /// Rasterizes the snapshot once into a GPU [Image] texture at
  /// [Snapshot.snapshotPixelRatio] and blits it via a single textured quad.
  rasterImage,
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

  bool _renderSnapshot = true;
  SnapshotCacheMode _snapshotCacheMode = SnapshotCacheMode.picture;
  double _snapshotPixelRatio = 1.0;
  Rect? _snapshotRegion;

  Picture? _picture;
  Image? _rasterImage;
  Rect _rasterSrcRect = Rect.zero;
  Rect _rasterDstRect = Rect.zero;
  int _snapshotDisposalCount = 0;

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

  void _disposeRasterImage() {
    final image = _rasterImage;
    if (image != null) {
      image.dispose();
      _rasterImage = null;
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

  void _ensureRasterImage() {
    if (_rasterImage != null) {
      return;
    }
    if (_picture == null) {
      takeSnapshot();
    }
    final region = _snapshotRegion ?? Rect.fromLTWH(0.0, 0.0, size.x, size.y);
    final dpr = _snapshotPixelRatio;
    final pixelW = (region.width * dpr).ceil();
    final pixelH = (region.height * dpr).ceil();
    if (pixelW <= 0 || pixelH <= 0) {
      return;
    }

    final recorder = PictureRecorder();
    final innerCanvas = Canvas(recorder);
    if (dpr != 1.0) {
      innerCanvas.scale(dpr, dpr);
    }
    if (region.left != 0.0 || region.top != 0.0) {
      innerCanvas.translate(-region.left, -region.top);
    }
    innerCanvas.drawPicture(_picture!);
    final scaledPicture = recorder.endRecording();
    try {
      _rasterImage = scaledPicture.toImageSync(pixelW, pixelH);
      _rasterSrcRect = Rect.fromLTWH(
        0.0,
        0.0,
        pixelW.toDouble(),
        pixelH.toDouble(),
      );
      _rasterDstRect = region;
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
