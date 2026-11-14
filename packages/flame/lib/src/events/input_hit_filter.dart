import 'package:flame/components.dart';
import 'package:flame/src/events/callbacks/pointer_input_callbacks.dart';

/// Predicate filtering which [Component] candidates are allowed to receive
/// pointer, hover, tap, drag, scroll, and drop-target hit-testing at
/// [canvasPosition].
///
/// Push modal filters onto `FlameGame.pushInputHitFilter` (for example during a
/// tutorial spotlight or modal confirmation sheet) and pop them via
/// `FlameGame.popInputHitFilter` without mutating individual components'
/// `IgnoreEvents` flags.
typedef InputHitFilter = bool Function(
  Component candidate,
  Vector2? canvasPosition,
);

/// Payload delivered to [DropTargetCallbacks] when a `DragCallbacks` component
/// is dragged across, dropped onto, or cancelled over a target across any
/// coordinate space (HUD/Viewport, 2D `World`, or 3D `SpatialHitbox3D`).
class DragDropEvent({
  required final int pointerId,
  required final Component draggedComponent,
  required final Vector2 canvasPosition,
  required final Vector2 localPosition,
  final (double, double, double)? hitPoint3D,
  final double? hitDistance3D,
  Vector2? velocity,
}) {
  /// Release velocity in logical pixels per second (populated on
  /// [DropTargetCallbacks.onDrop], zero during hover/move/cancel).
  final Vector2 velocity = velocity ?? Vector2.zero();
}

/// Mixin enabling any [Component] (HUD slot, 2D `World` zone, or 3D
/// `SpatialHitbox3D` board tile/prop) to receive cross-layer drag-over and drop
/// events when a `DragCallbacks` component is dragged over it.
///
/// Hit-testing automatically ignores the dragged component itself (and its
/// descendants) and respects `FlameGame.inputHitFilter`.
mixin DropTargetCallbacks on Component implements PointerInputCallbacks {
  /// Whether this component currently participates in drop-target hit-testing.
  bool dropTargetEnabled = true;

  /// Returns `true` if this target accepts [dragged] at [event]. Returning
  /// `false` allows hit-testing to pass through to drop targets underneath.
  bool canAcceptDrop(Component dragged, DragDropEvent event) => true;

  /// Fired when [DragDropEvent.draggedComponent] first enters this target.
  void onDragTargetEnter(DragDropEvent event) {}

  /// Fired while [DragDropEvent.draggedComponent] moves across this target.
  void onDragTargetMove(DragDropEvent event) {}

  /// Fired when [DragDropEvent.draggedComponent] leaves this target without
  /// dropping.
  void onDragTargetLeave(DragDropEvent event) {}

  /// Fired when the user releases [DragDropEvent.draggedComponent] over this
  /// target.
  void onDrop(DragDropEvent event) {}

  /// Fired if the active drag gesture is cancelled while hovering this target.
  void onDragTargetCancel(DragDropEvent event) {}
}
