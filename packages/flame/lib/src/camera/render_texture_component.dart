import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/src/camera/camera_component.dart';
import 'package:flame/src/camera/render_pass.dart';
import 'package:flame/src/components/mixins/has_paint.dart';
import 'package:flame/src/components/mixins/has_visibility.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/game/game.dart';

/// Live offscreen render-target component that rasterizes a [sourceCamera] into
/// a retained GPU [ui.Image] texture and displays it inside any viewport HUD or
/// world container (ideal for live minimaps, 3D character portraits, security
/// monitors, mirrors, and portals).
///
/// Combine with `CameraComponent.cameraMask` and `Component.cameraMask` so
/// minimap-only markers or main-camera-only VFX stay strictly isolated per
/// camera. Supports optional [refreshFps] throttling (`null` = every frame) and
/// deterministic native `ui.Image.dispose()` cleanup on unmount.
///
/// Whenever a capture becomes due the component marks its subtree dirty, so it
/// keeps refreshing inside a `CameraLayerCacheMode.splitRetained` layer: with a
/// throttled [refreshFps] the layer is re-recorded at that rate, with
/// `refreshFps == null` on every frame.
class RenderTextureComponent({
  required var CameraComponent sourceCamera,
  var double pixelRatio = 1.0,
  var double? refreshFps,
  var bool autoRefresh = true,
  var bool includePostProcess = false,
  var bool includeBackdrop = true,
  var bool includeViewport = false,
  var List<RenderPass>? passes,
  var ui.Color? backgroundColor,
  var ui.FilterQuality filterQuality = ui.FilterQuality.low,
  var double cornerRadius = 0.0,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.sortKey,
  super.key,
}) extends PositionComponent with HasPaint, HasVisibility {
  ui.Image? _texture;
  double _accumulator = 0.0;
  bool _forceCapture = true;
  bool _isCapturing = false;
  int _captureCount = 0;

  /// Retained GPU texture captured on the latest refresh (`null` before first
  /// capture or after unmount).
  ui.Image? get texture => _texture;

  /// Total number of offscreen rasterizations executed by this component.
  int get captureCount => _captureCount;

  /// Requests an immediate offscreen capture on the next [update] or [render].
  void markDirty() {
    _forceCapture = true;
    Game.notifyVisualMutation();
    markSubtreeDirty();
  }

  /// Synchronously captures [sourceCamera] into [texture] immediately,
  /// disposing the previous [ui.Image] handle.
  void refreshNow() {
    if (_capture()) {
      // The picture of this component changed outside of its own `render`:
      // retained layers and on-demand rendering have to pick it up.
      Game.notifyVisualMutation();
      markSubtreeDirty();
    }
  }

  /// Captures [sourceCamera] into [texture] and returns whether a new image
  /// was produced. Does not dirty the tree: [render] calls it right before it
  /// draws the fresh texture, so the frame being recorded is already current.
  bool _capture() {
    if (_isCapturing || size.x <= 0 || size.y <= 0) {
      return false;
    }
    final world = sourceCamera.world;
    if (world == null || !world.isMounted) {
      return false;
    }
    final pr = pixelRatio.clamp(0.125, 4.0);
    final w = math.max(1, (size.x * pr).round());
    final h = math.max(1, (size.y * pr).round());
    _isCapturing = true;
    final ui.Image nextImage;
    try {
      nextImage = sourceCamera.renderToImageSync(
        width: w,
        height: h,
        includePostProcess: includePostProcess,
        includeBackdrop: includeBackdrop,
        includeViewport: includeViewport,
        passes: passes,
        backgroundColor: backgroundColor,
      );
    } finally {
      _isCapturing = false;
    }
    _texture?.dispose();
    _texture = nextImage;
    _forceCapture = false;
    _captureCount++;
    return true;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!isVisible || !autoRefresh) {
      return;
    }
    final fps = refreshFps;
    if (fps == null) {
      // A capture is due on every rendered frame. Marking the subtree dirty
      // makes a retained camera layer that contains this component re-record
      // (and thereby call `render`); without it the layer would replay its
      // old picture and the texture would never be captured again.
      _forceCapture = true;
      markSubtreeDirty();
      return;
    }
    if (fps <= 0.0) {
      return;
    }
    _accumulator += dt;
    final interval = 1.0 / fps;
    if (_accumulator >= interval) {
      _accumulator %= interval;
      _forceCapture = true;
      markSubtreeDirty();
      Game.notifyVisualMutation();
    }
  }

  @override
  void render(ui.Canvas canvas) {
    if (_isCapturing || size.x <= 0 || size.y <= 0) {
      return;
    }
    if (_forceCapture) {
      _capture();
    }
    final img = _texture;
    if (img == null) {
      return;
    }
    paint.filterQuality = filterQuality;
    final src = ui.Rect.fromLTWH(
      0,
      0,
      img.width.toDouble(),
      img.height.toDouble(),
    );
    final dst = ui.Rect.fromLTWH(0, 0, size.x, size.y);
    if (cornerRadius > 0.0) {
      canvas.save();
      canvas.clipRRect(
        ui.RRect.fromRectAndRadius(dst, ui.Radius.circular(cornerRadius)),
      );
      canvas.drawImageRect(img, src, dst, paint);
      canvas.restore();
    } else {
      canvas.drawImageRect(img, src, dst, paint);
    }
  }

  void _disposeTexture() {
    _texture?.dispose();
    _texture = null;
  }

  @override
  void onRemove() {
    _disposeTexture();
    super.onRemove();
  }
}
