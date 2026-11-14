import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/src/canvas3d/spatial_hit_testing_3d.dart';
import 'package:meta/meta.dart';

/// This mixin can be added to a [Component] allowing it to receive hover
/// events.
///
/// In addition to adding this mixin, the component must implement either
/// [containsLocalPoint] or [SpatialHitbox3D] -- the component will be
/// considered "hovered" if the pointer intersects its 2D bounds or its 3D
/// spatial hitbox ray.
///
/// This mixin is the replacement of the Hoverable mixin.
///
/// This callback uses [MouseMoveDispatcher] to route events.
mixin HoverCallbacks on Component implements MouseMoveCallbacks {
  bool _isHovered = false;

  /// When `true`, hovering this component stops propagation of [MouseMoveEvent]
  /// to components behind it, preventing occluded background tiles or 3D
  /// objects from entering a hovered state simultaneously.
  bool stopHoverPropagation = false;

  /// Returns true while the component is being hovered.
  bool get isHovered => _isHovered;

  void onHoverEnter() {}

  void onHoverExit() {}

  /// Called when a hover is interrupted because a pointer button was pressed
  /// while the component was hovered.
  ///
  /// Flutter does not emit `PointerHoverEvent`s while a button is held, so the
  /// hover state ends as soon as the press starts. Override this to react to
  /// that transition (e.g. clear a hover-driven highlight). After a cancel,
  /// [onHoverEnter] will fire again only when a fresh button-free hover
  /// re-enters the area.
  void onHoverCancel() {}

  void _doHoverEnter() {
    _isHovered = true;
    onHoverEnter();
  }

  void _doHoverExit() {
    _isHovered = false;
    onHoverExit();
  }

  /// Called by [MouseMoveDispatcher] when a pointer button is pressed while
  /// this component is hovered. Not intended to be called by user code.
  @internal
  void cancelHover() {
    if (_isHovered) {
      _isHovered = false;
      onHoverCancel();
    }
  }

  @override
  void onMouseMove(MouseMoveEvent event) {
    final hit3d =
        this is SpatialHitbox3D &&
        (this as SpatialHitbox3D).spatialHitEnabled &&
        (this as SpatialHitbox3D).isActiveSpatialRayHit;
    if (hit3d || containsLocalPoint(event.localPosition)) {
      if (!_isHovered) {
        _doHoverEnter();
      }
      if (stopHoverPropagation) {
        event.continuePropagation = false;
      }
    } else {
      if (_isHovered) {
        _doHoverExit();
      }
    }
  }

  @override
  void onMouseMoveStop(MouseMoveEvent event) {
    if (_isHovered) {
      _doHoverExit();
    }
  }

  @override
  @mustCallSuper
  void onMount() {
    super.onMount();
    MouseMoveDispatcher.addDispatcher(this);
  }
}
