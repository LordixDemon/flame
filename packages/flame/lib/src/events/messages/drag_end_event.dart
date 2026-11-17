import 'package:flame/events.dart';
import 'package:flame/extensions.dart';
import 'package:flutter/gestures.dart';
import 'package:meta/meta.dart';

class DragEndEvent(
  final int pointerId,
  DragEndDetails details, {

  /// Whether this event was synthesized from a cancelled drag (see
  /// [DragCancelEvent.toDragEnd]) rather than produced by the pointer being
  /// lifted. A cancelled drag never drops anything.
  final bool wasCancelled = false,
}) extends Event<DragEndDetails> {
  this : super(raw: details);

  final Vector2 velocity = details.velocity.pixelsPerSecond.toVector2();

  DropTargetCallbacks? _dropTarget;
  DragDropEvent? _dropEvent;

  /// The [DropTargetCallbacks] component that accepted the component receiving
  /// this event, or `null` if it was released over nothing that accepts it (or
  /// the drag [wasCancelled]).
  ///
  /// The target's [DropTargetCallbacks.onDrop] has already run by the time
  /// [DragCallbacks.onDragEnd] receives this event, so the dragged component
  /// can decide between "dropped" and "missed" right in `onDragEnd`.
  ///
  /// When several components are dragged by the same pointer, the value
  /// describes the component currently receiving the event.
  DropTargetCallbacks? get dropTarget => _dropTarget;

  /// The payload delivered to [dropTarget]'s [DropTargetCallbacks.onDrop], or
  /// `null` when nothing was dropped.
  DragDropEvent? get dropEvent => _dropEvent;

  /// Whether a drop target accepted the component receiving this event.
  bool get dropAccepted => _dropTarget != null;

  /// Records the outcome of drop-target resolution for the component that is
  /// about to receive this event.
  @internal
  void setDropResult(DropTargetCallbacks? target, DragDropEvent? dropEvent) {
    _dropTarget = target;
    _dropEvent = dropEvent;
  }

  @override
  String toString() =>
      'DragEndEvent(pointerId: $pointerId, velocity: $velocity)';
}
