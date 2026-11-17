import 'package:flame/events.dart';
import 'package:flutter/gestures.dart';

class DragCancelEvent(
  /// The id of the event that has been cancelled. This id corresponds to the
  /// id of the previous [DragStartEvent].
  final int pointerId,
) extends Event<void> {
  this : super(raw: null);

  /// Converts this cancellation into a [DragEndEvent] with zero velocity,
  /// [DragEndEvent.wasCancelled] set and no drop target.
  DragEndEvent toDragEnd() =>
      DragEndEvent(pointerId, DragEndDetails(), wasCancelled: true);

  @override
  String toString() => 'DragCancelEvent(pointerId: $pointerId)';
}
