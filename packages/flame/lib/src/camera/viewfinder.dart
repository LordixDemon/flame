import 'dart:math';

import 'package:flame/components.dart';
import 'package:flame/extensions.dart';
import 'package:flame/src/camera/behaviors/viewport_aware_bounds_behavior.dart';
import 'package:flame/src/camera/viewport.dart';
import 'package:flame/src/camera/viewports/fixed_resolution_viewport.dart';
import 'package:flame/src/effects/provider_interfaces.dart';
import 'package:flame/src/game/game.dart';
import 'package:flame/src/game/notifying_vector2.dart';
import 'package:flame/src/game/transform2d.dart';
import 'package:meta/meta.dart';

/// [Viewfinder] is a part of a [CameraComponent] system that controls which
/// part of the game world is currently visible through a viewport.
///
/// The viewfinder contains the game point that is currently at the
/// "cross-hairs" of the viewport ([position]), the [zoom] level, and the
/// [angle] of rotation of the camera.
///
/// If you add children to the [Viewfinder] they will appear like HUDs i.e.
/// statically in front of the world.
class Viewfinder({
  super.key,
}) extends Component
    implements
        AnchorProvider,
        AngleProvider,
        PositionProvider,
        ScaleProvider,
        CoordinateTransform {
  /// Transform matrix used by the viewfinder.
  final Transform2D transform = Transform2D();

  final NotifyingVector2 _position = NotifyingVector2.zero();

  this {
    _position.addListener(_onPositionChanged);
  }

  /// The game coordinates of a point that is to be positioned at the center
  /// of the viewport.
  @override
  NotifyingVector2 get position => _position;
  @override
  set position(Vector2 value) => _position.setFrom(value);

  /// Updates [position] coordinates in place without allocating a [Vector2].
  void setPositionValues(double x, double y) => _position.setValues(x, y);

  void _onPositionChanged() {
    transform.offset.setValues(-_position.x, -_position.y);
    visibleRect = null;
  }

  /// Zoom level of the game.
  ///
  /// The default zoom value of 1 means that the world coordinates are in 1:1
  /// correspondence with the pixels on the screen. Zoom levels higher than 1
  /// make the world appear closer: each unit of game coordinate systems maps
  /// to [zoom] pixels on the screen. Conversely, when [zoom] is less than 1,
  /// the game world will appear further away and smaller in size.
  ///
  /// See also: [visibleGameSize] for setting the zoom level dynamically.
  double get zoom => transform.scale.x;
  set zoom(double value) {
    assert(value > 0, 'zoom level must be positive: $value');
    transform.scale.setAll(value);
    visibleRect = null;
  }

  /// Rotation angle of the game world, in radians.
  ///
  /// The rotation is around the axis that is perpendicular to the screen.
  @override
  double get angle => -transform.angle;
  @override
  set angle(double value) {
    transform.angle = -value;
    visibleRect = null;
  }

  /// The point within the viewport that is considered the "logical center" of
  /// the camera.
  ///
  /// This anchor is relative to the viewport's bounding rect, and by default
  /// is at the center of the viewport.
  ///
  /// The "logical center" of the camera means the point within the viewport
  /// where the viewfinder's focus is located at. It is at this point within
  /// the viewport that the world's point [position] will be displayed.
  @override
  Anchor get anchor => _anchor;
  Anchor _anchor = Anchor.center;
  @override
  set anchor(Anchor value) {
    _anchor = value;
    onViewportResize();
  }

  /// The [considerViewport] flag is read-only and cannot be set except through
  /// [CameraComponent.setBounds] as an optional parameter.
  ///
  /// If this value is true, a child component [ViewportAwareBoundsBehavior]
  /// exists whose purpose is to keep the viewfinder's visible area in bounds
  /// of the viewport w.r.t. the bounds shape.
  ///
  /// If this value is false, then no child [ViewportAwareBoundsBehavior]
  /// will be present. False is the initial value.
  bool get considerViewport =>
      firstChild<ViewportAwareBoundsBehavior>() != null;

  /// Reference to the parent camera.
  CameraComponent get camera => parent! as CameraComponent;

  /// Convert a point from the global coordinate system to the viewfinder's
  /// coordinate system.
  ///
  /// Use [output] to send in a Vector2 object that will be used to avoid
  /// creating a new Vector2 object in this method.
  ///
  /// Opposite of [localToGlobal].
  Vector2 globalToLocal(Vector2 point, {Vector2? output}) {
    return transform.globalToLocal(point, output: output);
  }

  /// Convert a point from the viewfinder's coordinate system to the global
  /// coordinate system.
  ///
  /// Use [output] to send in a Vector2 object that will be used to avoid
  /// creating a new Vector2 object in this method.
  ///
  /// Opposite of [globalToLocal].
  Vector2 localToGlobal(Vector2 point, {Vector2? output}) {
    return transform.localToGlobal(point, output: output);
  }

  /// How much of a game world ought to be visible through the viewport.
  ///
  /// When this property is non-null, the viewfinder will automatically select
  /// the maximum zoom level such that a rectangle of size [visibleGameSize]
  /// (in game coordinates) is visible through the viewport. If you want a
  /// certain dimension to be unconstrained, set it to zero.
  ///
  /// For example, if `visibleGameSize` is set to `[100.0, 0.0]`, the zoom level
  /// will be chosen such that 100 game units will be visible across the width
  /// of the viewport. Likewise, setting `visibleGameSize` to `[5.0, 10.0]`
  /// will ensure that 5 or more game units are visible across the width of the
  /// viewport, and 10 or more game units across the height.
  ///
  /// This property is an alternative way to set the [zoom] level for the
  /// viewfinder. It is persistent too: if the size of the viewport changes,
  /// the zoom will be recalculated to fit the constraint.
  ///
  /// The zoom is calculated against the viewport's [Viewport.virtualSize], so
  /// when used together with a [FixedResolutionViewport], the given region is
  /// fitted within the viewport's resolution.
  Vector2? get visibleGameSize => _visibleGameSize;
  Vector2? _visibleGameSize;
  set visibleGameSize(Vector2? value) {
    if (value == null || (value.x == 0 && value.y == 0)) {
      _visibleGameSize = null;
    } else {
      assert(
        value.x >= 0 && value.y >= 0,
        'visibleGameSize cannot be negative: $value',
      );
      _visibleGameSize = value;
      _updateZoom();
    }
  }

  final Vector2 _zeroVector = Vector2.zero();
  final Vector2 _topLeft = Vector2.zero();
  final Vector2 _bottomRight = Vector2.zero();
  final Vector2 _topRight = Vector2.zero();
  final Vector2 _bottomLeft = Vector2.zero();

  /// See [CameraComponent.visibleWorldRect].
  @internal
  Rect get visibleWorldRect => visibleRect ??= computeVisibleRect();
  @internal
  Rect? visibleRect;
  @protected
  Rect computeVisibleRect() {
    final viewportSize = camera.viewport.virtualSize;
    final currentTransform = transform;
    currentTransform.globalToLocal(_zeroVector, output: _topLeft);
    currentTransform.globalToLocal(viewportSize, output: _bottomRight);
    var minX = min(_topLeft.x, _bottomRight.x);
    var minY = min(_topLeft.y, _bottomRight.y);
    var maxX = max(_topLeft.x, _bottomRight.x);
    var maxY = max(_topLeft.y, _bottomRight.y);
    if (angle != 0) {
      _topRight.setValues(viewportSize.x, 0);
      _bottomLeft.setValues(0, viewportSize.y);
      currentTransform.globalToLocal(_topRight, output: _topRight);
      currentTransform.globalToLocal(_bottomLeft, output: _bottomLeft);
      minX = min(minX, min(_topRight.x, _bottomLeft.x));
      minY = min(minY, min(_topRight.y, _bottomLeft.y));
      maxX = max(maxX, max(_topRight.x, _bottomLeft.x));
      maxY = max(maxY, max(_topRight.y, _bottomLeft.y));
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// Set [zoom] level based on the [_visibleGameSize].
  void _updateZoom() {
    final visibleGameSize = _visibleGameSize;
    if (visibleGameSize != null) {
      final viewportSize = camera.viewport.virtualSize;
      final zoomX = viewportSize.x / visibleGameSize.x;
      final zoomY = viewportSize.y / visibleGameSize.y;
      final newZoom = min(zoomX, zoomY);
      // The viewport can have an empty size before it has been laid out.
      if (newZoom > 0 && newZoom.isFinite) {
        zoom = newZoom;
      }
    }
  }

  @override
  Vector2 parentToLocal(Vector2 point) {
    return globalToLocal(point);
  }

  @override
  Vector2 localToParent(Vector2 point) {
    return localToGlobal(point);
  }

  /// Called by the viewport when its size changes.
  @internal
  void onViewportResize() {
    if (parent != null) {
      // The zoom has to be updated first, so that the camera's bounds aren't
      // updated for the new size of the viewport with the old zoom.
      _updateZoom();
      final viewportSize = camera.viewport.virtualSize;
      transform.position.x = viewportSize.x * _anchor.x;
      transform.position.y = viewportSize.y * _anchor.y;
      visibleRect = null;
    }
  }

  @mustCallSuper
  @override
  void onLoad() {
    // This has to be done here and on onMount so that it is available for
    // the CameraComponent.visibleWorldRect calculation in onLoad of the game.
    updateTransform();
  }

  @mustCallSuper
  @override
  void onMount() {
    assert(
      parent! is CameraComponent,
      'Viewfinder can only be mounted to a CameraComponent',
    );
    super.onMount();
    updateTransform();
  }

  @internal
  void updateTransform() => onViewportResize();

  // --- Non-Destructive Trauma Camera Shake ---

  double _trauma = 0.0;
  double _shakeTime = 0.0;
  final Vector2 _shakeOffset = Vector2.zero();
  double _shakeRoll = 0.0;

  /// Rate (in trauma units per second) at which [trauma] linearly decays back
  /// to `0.0`.
  double traumaDecay = 1.8;

  /// Maximum translational shake amplitude (in viewport virtual pixels) at
  /// `trauma == 1.0`.
  double maxShakeOffset = 14.0;

  /// Maximum rotational roll shake amplitude (in radians) at `trauma == 1.0`.
  double maxShakeRoll = 0.035;

  /// Angular frequency multiplier driving the multi-harmonic trauma shake.
  double shakeFrequency = 29.0;

  /// Current normalized trauma level in `[0.0 .. 1.0]`.
  ///
  /// Shake amplitude scales quadratically (`trauma * trauma`) for natural
  /// physical impact falloff without mutating [position], [angle], or
  /// [visibleWorldRect].
  double get trauma => _trauma;

  /// Current transient render-only viewport offset produced by [trauma].
  Vector2 get shakeOffset => _shakeOffset;

  /// Current transient render-only roll angle (in radians) produced by
  /// [trauma].
  double get shakeRoll => _shakeRoll;

  /// Whether a non-zero trauma shake offset or roll is currently active.
  @internal
  bool get hasActiveShake =>
      _shakeOffset.x != 0.0 || _shakeOffset.y != 0.0 || _shakeRoll != 0.0;

  /// Adds [amount] (`> 0`) to [trauma], clamped to `[0.0 .. 1.0]`, and wakes
  /// per-frame updates if sleeping.
  void addTrauma(double amount) {
    if (amount <= 0.0) {
      return;
    }
    _trauma = (_trauma + amount).clamp(0.0, 1.0);
    wakeUpdates();
    _recomputeShake();
  }

  /// Immediately resets [trauma], [shakeOffset], and [shakeRoll] to zero.
  ///
  /// If a shake was displacing the picture, a repaint is requested so that
  /// on-demand rendering does not leave the last shaken frame on screen.
  void clearTrauma() {
    final wasShaking = hasActiveShake;
    _trauma = 0.0;
    _shakeTime = 0.0;
    _shakeOffset.setZero();
    _shakeRoll = 0.0;
    if (wasShaking) {
      Game.notifyVisualMutation();
    }
  }

  void _recomputeShake() {
    final intensity = _trauma * _trauma;
    final p = _shakeTime * shakeFrequency;
    final nx = sin(p + 0.7) * 0.65 + cos(p * 1.73 + 1.9) * 0.35;
    final ny = cos(p * 1.31 + 2.3) * 0.65 + sin(p * 2.17 + 0.4) * 0.35;
    final nr = sin(p * 1.13 + 1.1) * 0.70 + cos(p * 2.41 + 0.5) * 0.30;
    _shakeOffset.setValues(
      nx * maxShakeOffset * intensity,
      ny * maxShakeOffset * intensity,
    );
    _shakeRoll = nr * maxShakeRoll * intensity;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (_trauma > 0.0) {
      _shakeTime += dt;
      if (traumaDecay > 0.0 && dt > 0.0) {
        _trauma = max(0.0, _trauma - traumaDecay * dt);
      }
      if (_trauma <= 0.0) {
        // The shake has run out: one more frame has to be painted without it.
        final wasShaking = hasActiveShake;
        _trauma = 0.0;
        _shakeOffset.setZero();
        _shakeRoll = 0.0;
        if (wasShaking) {
          Game.notifyVisualMutation();
        }
      } else {
        _recomputeShake();
      }
    }
  }

  /// [ScaleProvider]'s API.
  @internal
  @override
  Vector2 get scale => transform.scale;
  @internal
  @override
  set scale(Vector2 value) {
    assert(
      value.x == value.y,
      'Non-uniform scale cannot be applied to a Viewfinder: $value',
    );
    assert(value.x > 0, 'Zoom must be positive: ${value.x}');
    transform.scale = value;
    visibleRect = null;
  }
}
