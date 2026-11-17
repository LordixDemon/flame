import 'package:flame/components.dart';
import 'package:flame/src/events/callbacks/drag_callbacks.dart';
import 'package:flame/src/events/callbacks/pointer_input_callbacks.dart';
import 'package:flame/src/events/dispatchers/multi_drag_scale_dispatcher.dart';
import 'package:flame/src/events/messages/drag_end_event.dart';
import 'package:flame/src/game/flame_game.dart';
import 'package:meta/meta.dart';

/// Predicate filtering which [Component] candidates are allowed to receive
/// pointer, hover, tap, drag, scroll, and drop-target hit-testing at
/// [canvasPosition].
///
/// [canvasPosition] is the position of the pointer on the game canvas. For
/// drag and scale updates this is the point the gesture is currently at.
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
///
/// Drop targets are only looked for while at least one of them is mounted and
/// the dragged component has [DragCallbacks.isDropPayload] set; a drag in a
/// game without drop targets costs nothing extra.
///
/// When the pointer is lifted over an accepting target, the order of calls is:
/// [onDragTargetLeave] on a previously hovered other target, then
/// [onDragTargetEnter] (if the target was not hovered yet) and [onDrop] on the
/// accepting target, and only then [DragCallbacks.onDragEnd] on the dragged
/// component, whose [DragEndEvent.dropTarget] names the accepting target.
mixin DropTargetCallbacks on Component implements PointerInputCallbacks {
  /// Whether this component currently participates in drop-target hit-testing.
  bool dropTargetEnabled = true;

  FlameGame? _dropTargetGame;

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
  /// target. Runs before the dragged component's [DragCallbacks.onDragEnd].
  void onDrop(DragDropEvent event) {}

  /// Fired if the active drag gesture is cancelled while hovering this target.
  void onDragTargetCancel(DragDropEvent event) {}

  @override
  @mustCallSuper
  void onMount() {
    super.onMount();
    if (_dropTargetGame == null) {
      final game = findRootGame();
      if (game != null) {
        _dropTargetGame = game;
        MultiDragScaleDispatcher.registerDropTarget(game);
      }
    }
  }

  @override
  @mustCallSuper
  void onRemove() {
    final game = _dropTargetGame;
    if (game != null) {
      _dropTargetGame = null;
      MultiDragScaleDispatcher.unregisterDropTarget(game);
    }
    super.onRemove();
  }
}
