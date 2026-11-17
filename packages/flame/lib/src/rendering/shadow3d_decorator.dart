import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/extensions.dart';
import 'package:flame/game.dart';
import 'package:flame/src/palette.dart';
import 'package:flame/src/rendering/decorator.dart';
import 'package:meta/meta.dart';
// TODO(spydon): Remove this import when flutter version is updated to 3.35.0
// ignore: unnecessary_import
import 'package:vector_math/vector_math.dart';

/// [Shadow3DDecorator] casts a realistic-looking shadow from the component
/// onto the ground.
///
/// This decorator is suitable for games that use an isometric projection.
///
/// The shadows are very flexible, allowing for different positions of sun in
/// the sky, and even supporting airborne objects.
///
/// Still, these are not real 3D shadows cast by real 3D objects on a real 3D
/// terrain, so many limitations apply. For example, the shadow must fall on
/// the flat ground, having the sun too high in the sky is undesirable as it
/// would betray the fact that the component is really flat, etc.
class Shadow3DDecorator({
  Vector2? base,
  double? ascent,
  double? angle,
  double? xShift,
  double? yScale,
  double? blur,
  double? opacity,
  Color? baseColor,
}) extends Decorator {
  /// Coordinates of the point where the component "touches the ground". If the
  /// component is airborne (i.e. [ascent] is non-zero), then this should be the
  /// coordinate of the point where the component would have touched the ground
  /// if it landed.
  ///
  /// This point is in the parent's coordinate space.
  Vector2 get base => _base;
  final Vector2 _base = base?.clone() ?? Vector2.zero();
  set base(Vector2 value) {
    _base.setFrom(value);
    _invalidateTransform();
  }

  /// How high is the component above the ground.
  double get ascent => _ascent;
  double _ascent = ascent ?? 0;
  set ascent(double value) {
    _ascent = value;
    _invalidateTransform();
  }

  /// The amount of skew the shadow is experiencing. The value of 0 corresponds
  /// to the shadow being right behind (or in front of) the object. Positive
  /// shift skews the shadow to the right if it's behind the object, or to the
  /// left if the shadow is in front of the object. Negative shift skews in the
  /// opposite direction.
  ///
  /// This property should be determined by the meridian position of the sun.
  double get xShift => _shift;
  double _shift = xShift ?? 100.0;
  set xShift(double value) {
    _shift = value;
    _invalidateTransform();
  }

  /// The length of the shadow relative to the height of the object. If the sun
  /// is 45º above the horizon, this scale will be 1. When the sun is higher in
  /// the sky, the scale factor should be less than 1, and when the sun is
  /// lower, the scale factor ought to be greater than 1.
  double get yScale => _scale;
  double _scale = yScale ?? 1.0;
  set yScale(double value) {
    _scale = value;
    _paint = null;
    _invalidateTransform();
  }

  /// Visual angle between a vertically standing component and the ground. This
  /// angle is determined by your isometric projection. Use negative values
  /// smaller than τ/4 (1.57) in magnitude to create shadows that are behind the
  /// objects. Use positive angles that are slightly above τ/4 to make shadows
  /// that are in front of the objects.
  double get angle => _angle;
  double _angle = angle ?? -1.4;
  set angle(double value) {
    _angle = value;
    _invalidateTransform();
  }

  /// The amount of blur to apply to the shadow. The value of 0 produces crisp
  /// shadows with sharp edges, whereas positive [blur] produces softer-looking
  /// shadows.
  ///
  /// Strictly speaking, the parts of the object that are closer to the ground
  /// ought to experience less blur than those that are higher up. However, this
  /// is not supported by this decorator. Still, you can try setting the amount
  /// of blur proportional to the height of the object, or dependent on its
  /// ascent above the ground.
  double get blur => _blur;
  double _blur = blur ?? 0;
  set blur(double value) {
    _blur = value;
    _paint = null;
    _hasCachedShadowBounds = false;
  }

  /// Shadow's intensity. The value of 1 will create a hard pitch-black shadow,
  /// which can only happen when there are no ambient sources of light (e.g. in
  /// a cave). Values close to 0 will make the shadow barely visible, such as
  /// on a cloudy day.
  double get opacity => _opacity;
  double _opacity = opacity ?? 0.6;
  set opacity(double value) {
    _opacity = value;
    _paint = null;
  }

  /// Shadow's base color before opacity. This defaults to pitch-black.
  Color get baseColor => _baseColor;
  Color _baseColor = baseColor ?? BasicPalette.black.color;
  set baseColor(Color value) {
    _baseColor = value;
    _paint = null;
  }

  Paint? _paint;
  Paint _makePaint(double opacityScale) {
    final paint = Paint();
    final effectiveAlpha = (opacity * opacityScale).clamp(0.0, 1.0);
    final color = baseColor.withValues(alpha: effectiveAlpha);
    paint.colorFilter = ColorFilter.mode(color, BlendMode.srcIn);
    if (_blur > 0) {
      paint.imageFilter = ImageFilter.blur(
        sigmaX: blur,
        sigmaY: _scale.abs() > 1e-4 ? blur / _scale.abs() : blur,
      );
    }
    return paint;
  }

  /// Shadow projection matrix, rebuilt in place (no allocation) whenever a
  /// property it depends on changes.
  final Matrix4 _transformMatrix = Matrix4.identity();
  bool _transformDirty = true;

  /// Marks the projection, and the layer bounds derived from it, as stale.
  void _invalidateTransform() {
    _transformDirty = true;
    _hasCachedShadowBounds = false;
  }

  void _updateTransform() {
    _transformMatrix
      ..setIdentity()
      ..translateByDouble(0.0, 0.0, _scale * _ascent, 1.0)
      ..setEntry(3, 2, 0.001)
      ..rotateX(_angle)
      ..scaleByDouble(1.0, _scale, 1.0, 1.0)
      ..translateByDouble(
        -base.x - _shift,
        -base.y - _scale * _ascent,
        0.0,
        1.0,
      );
    _transformDirty = false;
  }

  /// Whether [applyChain] bounds should be projected into a tight shadow
  /// `Canvas.saveLayer` rectangle instead of allocating an unbounded layer.
  bool useBoundedSaveLayer = true;

  Rect? _lastInputBounds;
  Rect? _cachedShadowBounds;
  bool _hasCachedShadowBounds = false;
  Rect? _lastSaveLayerBounds;

  /// Most recent bounds passed to [Canvas.saveLayer] (`null` when unbounded).
  @visibleForTesting
  Rect? get lastSaveLayerBounds => _lastSaveLayerBounds;

  Rect? _resolveShadowLayerBounds(Rect bounds) {
    if (_hasCachedShadowBounds && _lastInputBounds == bounds) {
      return _cachedShadowBounds;
    }
    final m = _transformMatrix.storage;
    final tx = base.x + _shift;
    final ty = base.y;

    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;

    for (var i = 0; i < 4; i++) {
      final px = (i & 1) == 0 ? bounds.left : bounds.right;
      final py = (i & 2) == 0 ? bounds.top : bounds.bottom;
      final rw = m[3] * px + m[7] * py + m[15];
      if (rw <= 1e-3) {
        _lastInputBounds = bounds;
        _cachedShadowBounds = null;
        _hasCachedShadowBounds = true;
        return null;
      }
      final invW = 1.0 / rw;
      final sx = tx + (m[0] * px + m[4] * py + m[12]) * invW;
      final sy = ty + (m[1] * px + m[5] * py + m[13]) * invW;
      minX = math.min(minX, sx);
      minY = math.min(minY, sy);
      maxX = math.max(maxX, sx);
      maxY = math.max(maxY, sy);
    }

    final absScale = _scale.abs();
    final sigmaY = (_blur > 0 && absScale > 1e-4) ? _blur / absScale : _blur;
    final padX = _blur > 0 ? 3.0 * _blur + 2.0 : 1.0;
    final padY = _blur > 0 ? 3.0 * sigmaY + 2.0 : 1.0;
    final resolved = Rect.fromLTRB(
      minX - padX,
      minY - padY,
      maxX + padX,
      maxY + padY,
    );
    _lastInputBounds = bounds;
    _cachedShadowBounds = resolved;
    _hasCachedShadowBounds = true;
    return resolved;
  }

  @override
  void apply(void Function(Canvas) draw, Canvas canvas) {
    applyBounded(draw, canvas, null);
  }

  /// Whether [applyBounded] automatically honors `FlameGame.graphics`
  /// `effectiveShadowsEnabled` and `effectiveShadowOpacityScale`.
  bool respectGraphicsShadows = true;

  /// Optional explicit [GraphicsSettingsController] consulted when no camera
  /// context is active.
  GraphicsSettingsController? graphics;

  double _lastAppliedOpacityScale = 1.0;

  @override
  void applyBounded(void Function(Canvas) draw, Canvas canvas, Rect? bounds) {
    var opacityScale = 1.0;
    if (respectGraphicsShadows) {
      final game = CameraComponent.currentCamera?.findGame();
      final ctrl = graphics ?? (game is FlameGame ? game.graphics : null);
      if (ctrl != null) {
        if (!ctrl.effectiveShadowsEnabled) {
          _lastSaveLayerBounds = null;
          draw(canvas);
          return;
        }
        opacityScale = ctrl.effectiveShadowOpacityScale;
      }
    }

    if ((opacityScale - _lastAppliedOpacityScale).abs() > 1e-4) {
      _lastAppliedOpacityScale = opacityScale;
      _paint = null;
    }

    if (_transformDirty) {
      _updateTransform();
    }
    _paint ??= _makePaint(opacityScale);

    final shadowBounds =
        (useBoundedSaveLayer && bounds != null && !bounds.isEmpty)
        ? _resolveShadowLayerBounds(bounds)
        : null;
    _lastSaveLayerBounds = shadowBounds;
    canvas.saveLayer(shadowBounds, _paint!);
    canvas.translate(base.x + _shift, base.y);
    canvas.transform32(_transformMatrix.storage);
    draw(canvas);
    canvas.restore();
    draw(canvas);
  }
}
