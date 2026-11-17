import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:meta/meta.dart';

/// Structured world layer supporting camera `layerMask` visibility filtering,
/// camera-relative parallax translation, `minQualityTier` gating, and optional
/// static display-list (`ui.Picture`) caching.
///
/// ## Parallax
///
/// A [parallaxFactor] other than `(1, 1)` shifts the whole subtree on the
/// canvas by `camera.viewfinder.position * (1 - parallaxFactor)`. The shift is
/// applied while rendering only: `CullWhenOffscreen` and `SpatialCullGroup`
/// descendants take it into account when they decide whether they are on
/// screen, the `World` spatial index leaves such a layer alone, and
/// hit-testing still uses the un-shifted positions.
///
/// ## Picture cache
///
/// With [cacheAsPicture] the subtree is recorded once, independently of any
/// camera (nothing is culled, masked by `cameraMask`, or filtered by render
/// pass while recording), and replayed until [markLayerDirty] is called or a
/// direct child is added or removed. The layer's own `layerBit`,
/// `cameraMask`, `minQualityTier` and parallax are applied on every frame.
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
    (this.parallaxFactor as NotifyingVector2).addListener(
      _onParallaxFactorChanged,
    );
  }

  /// Camera translation multiplier `(1.0, 1.0)` = normal 1:1 world space,
  /// `< 1.0` = distant background parallax, `> 1.0` = foreground depth shift.
  ///
  /// The vector can be changed at any time; the layer then repaints and the
  /// `World` spatial index re-evaluates whether it may index the subtree.
  final Vector2 parallaxFactor = NotifyingVector2.copy(
    parallaxFactor ?? Vector2.all(1.0),
  );

  void _onParallaxFactorChanged() {
    if (!isMounted) {
      return;
    }
    final world = enclosingWorld();
    if (world != null && world.spatialIndexEnabled) {
      world.spatialIndex.markMembershipDirty();
    }
    markSubtreeDirty();
    Game.notifyVisualMutation();
  }

  /// Whether this layer currently moves its subtree relative to the world.
  bool get hasParallax => parallaxFactor.x != 1.0 || parallaxFactor.y != 1.0;

  /// Horizontal canvas shift this layer applies to its subtree when it is
  /// rendered through [camera].
  double parallaxShiftX(CameraComponent camera) =>
      camera.viewfinder.position.x * (1.0 - parallaxFactor.x);

  /// Vertical canvas shift this layer applies to its subtree when it is
  /// rendered through [camera].
  double parallaxShiftY(CameraComponent camera) =>
      camera.viewfinder.position.y * (1.0 - parallaxFactor.y);

  /// Returns the [SceneLayerComponent] ancestors of [component] up to its
  /// enclosing `World` (innermost first), or `null` when there are none.
  ///
  /// Cullers keep this list from `onMount` on, so that they can add up the
  /// parallax shifts of the layers they are drawn through.
  @internal
  static List<SceneLayerComponent>? ancestorLayersOf(Component component) {
    List<SceneLayerComponent>? layers;
    var cursor = component.parent;
    while (cursor != null && cursor is! World) {
      if (cursor is SceneLayerComponent) {
        (layers ??= <SceneLayerComponent>[]).add(cursor);
      }
      cursor = cursor.parent;
    }
    return layers;
  }

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
    if (camera != null &&
        ((camera.layerMask & layerBit) == 0 ||
            (camera.cameraMask & cameraMask) == 0)) {
      return;
    }

    final shiftsSubtree = camera != null && hasParallax;
    if (shiftsSubtree) {
      canvas.save();
      canvas.translate(parallaxShiftX(camera), parallaxShiftY(camera));
    }

    try {
      if (_cacheAsPicture) {
        if (_pictureDirty || _cachedPicture == null) {
          _disposeCachedPicture();
          final recorder = PictureRecorder();
          final recCanvas = Canvas(recorder);
          // The picture is replayed for every camera and every camera
          // position, so it is recorded without a camera: a culler or the
          // spatial index would otherwise leave out whatever is off screen
          // right now, for good.
          CameraComponent.beginDetachedRecording();
          try {
            super.renderTree(recCanvas);
          } finally {
            CameraComponent.endDetachedRecording();
          }
          _cachedPicture = recorder.endRecording();
          _pictureDirty = false;
          _pictureBakeCount++;
        }
        canvas.drawPicture(_cachedPicture!);
      } else {
        super.renderTree(canvas);
      }
    } finally {
      if (shiftsSubtree) {
        canvas.restore();
      }
    }
  }
}
