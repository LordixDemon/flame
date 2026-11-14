import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:meta/meta.dart';

/// Structured world layer supporting camera `layerMask` visibility filtering,
/// camera-relative parallax translation, `minQualityTier` gating, and optional
/// static display-list (`ui.Picture`) caching.
///
/// Typical scene setups mount dedicated layers inside a [World] (for example:
/// `skyBackdrop`, `terrain`, `groundProps`, `mainActors`, `weatherOverlay`),
/// allowing auxiliary cameras (minimaps, reflection passes, clean exports) to
/// selectively toggle layers via `CameraComponent.layerMask`.
class SceneLayerComponent({
  final String? name,
  var int layerBit = 1,
  Vector2? parallaxFactor,
  bool cacheAsPicture = false,
  GraphicsQualityTier? minQualityTier,
  super.children,
  super.priority,
  super.ticksEnabled,
  super.key,
}) extends Component {
  this {
    if (minQualityTier != null) {
      this.minQualityTier = minQualityTier;
    }
  }

  /// Camera translation multiplier `(1.0, 1.0)` = normal 1:1 world space,
  /// `< 1.0` = distant background parallax, `> 1.0` = foreground depth shift.
  final Vector2 parallaxFactor = parallaxFactor?.clone() ?? Vector2.all(1.0);

  bool _cacheAsPicture = cacheAsPicture;
  Picture? _cachedPicture;
  bool _pictureDirty = true;
  int _pictureBakeCount = 0;

  /// Whether this layer records its child subtree into a cached [Picture] and
  /// replays it in a single `Canvas.drawPicture` call until [markLayerDirty].
  bool get cacheAsPicture => _cacheAsPicture;
  set cacheAsPicture(bool value) {
    if (_cacheAsPicture != value) {
      _cacheAsPicture = value;
      _disposeCachedPicture();
      _pictureDirty = true;
    }
  }

  /// Number of times the static [Picture] display list was recorded.
  @visibleForTesting
  int get pictureBakeCount => _pictureBakeCount;

  /// Marks the cached [Picture] display list dirty so it re-records on the next
  /// rendered frame.
  void markLayerDirty() {
    _pictureDirty = true;
    _disposeCachedPicture();
    findGame()?.markSceneDirty();
  }

  void _disposeCachedPicture() {
    _cachedPicture?.dispose();
    _cachedPicture = null;
  }

  @override
  void onChildrenChanged(Component child, ChildrenChangeType type) {
    super.onChildrenChanged(child, type);
    if (_cacheAsPicture) {
      _pictureDirty = true;
      _disposeCachedPicture();
    }
  }

  @override
  void onRemove() {
    _disposeCachedPicture();
    super.onRemove();
  }

  @override
  void renderTree(Canvas canvas) {
    if (!isActiveForCurrentGraphicsTier) {
      return;
    }
    final camera = CameraComponent.currentCamera;
    if (camera != null && (camera.layerMask & layerBit) == 0) {
      return;
    }

    final px = parallaxFactor.x;
    final py = parallaxFactor.y;
    final hasParallax = camera != null && (px != 1.0 || py != 1.0);
    if (hasParallax) {
      final camPos = camera.viewfinder.position;
      canvas.save();
      canvas.translate(
        camPos.x * (1.0 - px),
        camPos.y * (1.0 - py),
      );
    }

    try {
      if (_cacheAsPicture) {
        if (_pictureDirty || _cachedPicture == null) {
          _disposeCachedPicture();
          final recorder = PictureRecorder();
          final recCanvas = Canvas(recorder);
          super.renderTree(recCanvas);
          _cachedPicture = recorder.endRecording();
          _pictureDirty = false;
          _pictureBakeCount++;
        }
        canvas.drawPicture(_cachedPicture!);
      } else {
        super.renderTree(canvas);
      }
    } finally {
      if (hasParallax) {
        canvas.restore();
      }
    }
  }
}
