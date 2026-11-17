# Drag Events

**Drag events** occur when the user moves their finger across the screen of the device, or when they
move the mouse while holding its button down.

Multiple drag events can occur at the same time, if the user is using multiple fingers. Such cases
will be handled correctly by Flame, and you can even keep track of the events by using their
`pointerId` property.

For those components that you want to respond to drags, add the `DragCallbacks` mixin.

- This mixin adds four overridable methods to your component: `onDragStart`, `onDragUpdate`,
  `onDragEnd`, and `onDragCancel`. By default, these methods do nothing; they need to be overridden
  in order to perform any function.
- In addition, the component must implement the `containsLocalPoint()` method (already implemented
  in `PositionComponent`, so most of the time you don't need to do anything here). This method
  allows Flame to know whether the event occurred within the component or not.

```dart
class MyComponent extends PositionComponent with DragCallbacks {
  MyComponent() : super(size: Vector2(180, 120));

   @override
   void onDragStart(DragStartEvent event) {
     // Do something in response to a drag event
   }
}
```


## Demo

In this example you can use drag gestures to either drag star-like shapes across the screen, or to
draw curves inside the magenta rectangle.

```{flutter-app}
:sources: ../flame/examples
:page: drag_events
:show: widget code
```


## Drag anatomy


### onDragStart

This is the first event that occurs in a drag sequence. Usually, the event will be delivered to the
topmost component at the point of touch with the `DragCallbacks` mixin. However, by setting the flag
`event.continuePropagation` to true, you can allow the event to propagate to the components below.

The `DragStartEvent` object associated with this event will contain the coordinate of the point
where the event has originated. This point is available in multiple coordinate system:
`devicePosition` is given in the coordinate system of the entire device, `canvasPosition` is in the
coordinate system of the game widget, and `localPosition` provides the position in the component's
local coordinate system.

Any component that receives `onDragStart` will later be receiving `onDragUpdate` and `onDragEnd`
events as well.

A drag only starts once the pointer has moved further than the platform's touch slop from the
point where it went down, so a tap with a slightly wobbling finger is still delivered as a tap and
not as a drag. When the drag starts, the movement accumulated before that point is delivered in the
first `onDragUpdate`.


### onDragUpdate

This event is fired continuously as user drags their finger across the screen. It will not fire if
the user is holding their finger still.

The default implementation delivers this event to all the components that received the previous
`onDragStart` with the same pointer id. Moving the finger off the component **does not** stop
the drag, and the local coordinates are still computed (potentially outside the component bounds).

The exception is when hit testing stops reaching the component altogether while it still holds the
drag, for example if an ancestor turns on `IgnoreEvents` mid-gesture. The component still receives
the event, but with an empty `event.renderingTrace` behind it, so reading `localStartPosition`,
`localEndPosition` or `localDelta` throws. `canvasStartPosition`, `canvasEndPosition`,
`deviceStartPosition` and `deviceEndPosition` never depend on the trace and remain valid.

In addition, the `DragUpdateEvent` will contain `delta`, the amount the finger has moved since
the previous `onDragUpdate`, or since the `onDragStart` if this is the first drag-update after
a drag-start.

The `event.timestamp` property measures the time elapsed since the beginning of the drag. It can be
used, for example, to compute the speed of the movement.


### onDragEnd

This event is fired when the user lifts their finger and thus stops the drag gesture. There is no
position associated with this event.

If the component was released over a [drop target](#drop-targets) that accepts it, the target has
already received its `onDrop` when `onDragEnd` runs, and `event.dropTarget` refers to it. Otherwise
`event.dropAccepted` is `false`.


### onDragCancel

This event is fired when the drag gesture is interrupted before it ends naturally, for example when
another gesture recognizer wins the gesture arena or a second pointer triggers a scale takeover.
Unlike `onDragEnd` it carries no velocity information, and nothing is dropped: a drop target that
was hovered receives `onDragTargetCancel` first. The default implementation simply resets the
drag state; override it and call `onDragEnd(event.toDragEnd())` yourself if you want a cancellation
handled like a natural drag end. The converted event has `wasCancelled` set and no drop target.


## Mixins


### DragCallbacks

The `DragCallbacks` mixin can be added to any `Component` in order for that component to start
receiving drag events.

This mixin adds methods `onDragStart`, `onDragUpdate`, `onDragEnd`, and `onDragCancel` to the
component, which by default don't do anything, but can be overridden to implement any real
functionality.

Another crucial detail is that a component will only receive drag events that originate *within*
that component, as judged by the `containsLocalPoint()` function. The commonly-used
`PositionComponent` class provides such an implementation based on its `size` property. Thus, if
your component derives from a `PositionComponent`, then make sure that you set its size correctly.
If, however, your component derives from the bare `Component`, then the `containsLocalPoint()`
method must be implemented manually.

If your component is a part of a larger hierarchy, then it will only receive drag events if its
ancestors have all implemented the `containsLocalPoint` correctly.


### isDragged

The `DragCallbacks` mixin provides an `isDragged` getter that returns `true` while the component is
actively being dragged. This is set to `true` at `onDragStart` and back to `false` at `onDragEnd`.
It can be used, for example, to change the component's visual appearance during a drag.


### allowsMultiPointerDrag

Drags are tracked per pointer, so a component that is already being dragged will start a second,
independent drag when another finger touches it. That is what you want when each drag manipulates
something of its own, but not when they all drive a single piece of state (such as a camera or
a draggable object), where a second finger just fights the first.

Override `allowsMultiPointerDrag` to `false` to accept only one drag at a time:

```dart
class MagnifyingGlass extends PositionComponent with DragCallbacks {
  @override
  bool get allowsMultiPointerDrag => false;

  @override
  void onDragUpdate(DragUpdateEvent event) {
    position = event.canvasEndPosition;
  }
}
```

While a drag is in progress, no other pointer gets an `onDragStart` on this component, and no
`onDragUpdate`, `onDragEnd` or `onDragCancel` follow for it either; the event is offered to the
components below instead. Once the accepted drag ends or is cancelled, the component is free to
accept a new one.

Control is not handed over: if the accepted pointer is lifted while another is still down, the drag
ends rather than continuing on the remaining finger.

This only gates drags. A component that also uses `ScaleCallbacks` keeps receiving scale events
normally, so one-finger drag plus two-finger pinch still works.


## Drop targets

Mix `DropTargetCallbacks` into a component to let dragged components be dropped onto it. While a
`DragCallbacks` component is dragged, the dispatcher looks for the topmost drop target under the
pointer (ignoring the dragged component itself and its children) and calls:

- `canAcceptDrop(dragged, event)` to ask whether the target takes this component; returning `false`
  lets the search continue with the targets underneath;
- `onDragTargetEnter`, `onDragTargetMove` and `onDragTargetLeave` as the pointer enters, moves
  across and leaves the target;
- `onDrop` when the pointer is lifted over the target;
- `onDragTargetCancel` if the drag is cancelled while over the target.

When the pointer is lifted, the drop is delivered **before** the dragged component's `onDragEnd`,
as in HTML drag and drop, so the dragged component can tell a hit from a miss right there:

```dart
class Card extends PositionComponent with DragCallbacks {
  @override
  void onDragEnd(DragEndEvent event) {
    super.onDragEnd(event);
    if (!event.dropAccepted) {
      returnToHand();
    }
  }
}

class Slot extends PositionComponent with DropTargetCallbacks {
  @override
  bool canAcceptDrop(Component dragged, DragDropEvent event) => dragged is Card;

  @override
  void onDrop(DragDropEvent event) {
    place(event.draggedComponent as Card);
  }
}
```

`DragDropEvent` carries the `draggedComponent`, the `canvasPosition` and `localPosition` of the
pointer, the release `velocity` (on `onDrop`), and, for a target picked by a 3D ray
(`SpatialHitbox3D`), `hitPoint3D` and `hitDistance3D`.

Looking for a drop target costs one extra hit test of the component tree per pointer sample. It
only happens while at least one drop target is mounted and the dragged component is a drop payload.
Set `isDropPayload = false` on components whose drags never drop anything (a camera pan surface, a
slider, a virtual joystick) to keep their drags at the plain cost:

```dart
class PanSurface extends PositionComponent with DragCallbacks {
  PanSurface() {
    isDropPayload = false;
  }
}
```


## Combining with ScaleCallbacks

`DragCallbacks` and `ScaleCallbacks` can be used at the same time: single-finger gestures produce
drag events, and two-finger gestures produce both drag and scale events. See
[Combining with DragCallbacks](scale_events.md#combining-with-dragcallbacks) for how to make the two
work together, both on a component and for panning and zooming the camera.
