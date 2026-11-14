import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame/src/canvas3d/spatial_hit_testing_3d.dart';
import 'package:flame/src/events/tagged_component.dart';
import 'package:flame/src/game/game_render_box.dart';
import 'package:flutter/gestures.dart';
import 'package:meta/meta.dart';

class const MultiDragScaleDispatcherKey() implements ComponentKey {
  @override
  int get hashCode => 91604875; // 'MultiDragScaleDispatcherKey' as hashCode

  @override
  bool operator ==(Object other) =>
      other is MultiDragScaleDispatcherKey && other.hashCode == hashCode;
}

/// Dispatches both drag and scale events to [DragCallbacks] and
/// [ScaleCallbacks] components. Attached to the [FlameGame] automatically
/// when either callback type is first mounted.
///
/// Use [enableDrag] and [enableScale] (called via [addDispatcher]) to control
/// which event types are forwarded to the underlying
/// [MultiDragScaleGestureRecognizer].
class MultiDragScaleDispatcher() extends Dispatcher<FlameGame> {
  /// The record of all components currently being touched.
  final Set<TaggedComponent<DragCallbacks>> _records = {};

  /// Last observed canvas coordinate per active drag pointerId.
  final Map<int, Vector2> _lastCanvasPosByPointer = {};

  /// Active hovered [DropTargetCallbacks] per dragged `(pointerId, component)`.
  final Map<TaggedComponent<DragCallbacks>, DropTargetCallbacks>
  _hoveredDropTargets = {};
  final List<Vector2> _dropHitTraceScratch = <Vector2>[];

  // Reference counts rather than booleans so that enableDrag/enableScale can
  // be called before onMount (when _recognizer is null). onMount uses these
  // counts to initialize the recognizer flags.
  int _dragCount = 0;
  int _scaleCount = 0;
  MultiDragScaleGestureRecognizer? _recognizer;

  /// The minimum scale factor change required before a scale gesture is
  /// recognized. Must be greater than 1.0. The default value is 1.05, meaning
  /// the fingers must spread or pinch by at least 5% before scale events start
  /// firing.
  double get scaleThreshold => _scaleThreshold;
  double _scaleThreshold = 1.05;
  set scaleThreshold(double value) {
    _scaleThreshold = value;
    _recognizer?.scaleThreshold = value;
  }

  /// Minimum rotation angle (in radians) required to start a pure rotation
  /// gesture.
  double get rotationThreshold => _rotationThreshold;
  double _rotationThreshold = 0.05;
  set rotationThreshold(double value) {
    _rotationThreshold = value;
    _recognizer?.rotationThreshold = value;
  }

  /// Whether desktop/macOS trackpad `PointerPanZoom` gestures bypass the
  /// 5% scale and pan-slop deadzones and begin immediately on the first
  /// non-zero pan, pinch, or rotation delta.
  bool get zeroTrackpadDeadzone => _zeroTrackpadDeadzone;
  bool _zeroTrackpadDeadzone = false;
  set zeroTrackpadDeadzone(bool value) {
    _zeroTrackpadDeadzone = value;
    _recognizer?.zeroTrackpadDeadzone = value;
  }

  @visibleForTesting
  bool get hasDrag => _dragCount > 0;

  @visibleForTesting
  bool get hasScale => _scaleCount > 0;

  /// Enables drag forwarding on the underlying recognizer.
  ///
  /// Safe to call before or after [onMount].
  void enableDrag() {
    _dragCount++;
    _recognizer?.hasDrag = true;
  }

  /// Enables scale forwarding on the underlying recognizer.
  ///
  /// Safe to call before or after [onMount].
  void enableScale() {
    _scaleCount++;
    _recognizer?.hasScale = true;
  }

  void _disableDrag() {
    assert(_dragCount > 0, '_disableDrag called more times than enableDrag');
    _dragCount--;
    if (_dragCount == 0) {
      _recognizer?.hasDrag = false;
    }
  }

  void _disableScale() {
    assert(_scaleCount > 0, '_disableScale called more times than enableScale');
    _scaleCount--;
    if (_scaleCount == 0) {
      _recognizer?.hasScale = false;
    }
  }

  /// Ensures a [MultiDragScaleDispatcher] is registered on the game that owns
  /// [component], then enables drag and/or scale as requested.
  ///
  /// For a component that mixes both [DragCallbacks] and [ScaleCallbacks],
  /// this method is called twice from their separate [onMount] chains, once
  /// with [hasDrag]=true and once with [hasScale]=true. The second call finds
  /// the existing dispatcher and simply enables the remaining flag.
  static void addDispatcher(
    Component component, {
    required bool hasDrag,
    required bool hasScale,
  }) {
    final game = component.findRootGame()!;
    var dispatcher = game.findByKey(
      const MultiDragScaleDispatcherKey(),
    ) as MultiDragScaleDispatcher?;
    if (dispatcher == null) {
      dispatcher = MultiDragScaleDispatcher()
        ..zeroTrackpadDeadzone = game.trackpadImmediateScale;
      game.registerKey(const MultiDragScaleDispatcherKey(), dispatcher);
      game.add(dispatcher);
    }
    if (hasDrag) {
      dispatcher.enableDrag();
    }
    if (hasScale) {
      dispatcher.enableScale();
    }
  }

  /// Decrements the reference counts for [component]'s event types and
  /// disables the corresponding recognizer flags when the count reaches zero.
  static void removeDispatcher(
    Component component, {
    required bool hasDrag,
    required bool hasScale,
  }) {
    final game = component.findRootGame();
    if (game == null) {
      return;
    }
    final dispatcher = game.findByKey(
      const MultiDragScaleDispatcherKey(),
    ) as MultiDragScaleDispatcher?;
    if (dispatcher == null) {
      return;
    }
    if (hasDrag) {
      dispatcher._disableDrag();
    }
    if (hasScale) {
      dispatcher._disableScale();
    }
  }

  static bool _isSelfOrDescendantOf(Component candidate, Component root) {
    Component? cur = candidate;
    while (cur != null) {
      if (identical(cur, root)) {
        return true;
      }
      cur = cur.parent;
    }
    return false;
  }

  (DropTargetCallbacks, DragDropEvent)? _resolveDropTarget({
    required int pointerId,
    required Component dragged,
    required Vector2 canvasPos,
    Vector2? velocity,
  }) {
    _dropHitTraceScratch.clear();
    (DropTargetCallbacks, DragDropEvent)? resolved;
    for (final candidate in gameRef.componentsAtPoint(
      canvasPos,
      _dropHitTraceScratch,
    )) {
      if (candidate is! DropTargetCallbacks || !candidate.dropTargetEnabled) {
        continue;
      }
      if (_isSelfOrDescendantOf(candidate, dragged)) {
        continue;
      }
      if (!gameRef.allowsInputHit(candidate, canvasPos)) {
        continue;
      }
      final localPos = _dropHitTraceScratch.isNotEmpty
          ? _dropHitTraceScratch.last.clone()
          : canvasPos.clone();
      final spatial = (candidate as Component) is SpatialHitbox3D
          ? (candidate as Component) as SpatialHitbox3D
          : null;
      final hit3D = (spatial != null && spatial.isActiveSpatialRayHit)
          ? spatial.lastHitPoint3D
          : null;
      final dist3D = (spatial != null && spatial.isActiveSpatialRayHit)
          ? spatial.lastHitDistance3D
          : null;
      final dropEvent = DragDropEvent(
        pointerId: pointerId,
        draggedComponent: dragged,
        canvasPosition: canvasPos.clone(),
        localPosition: localPos,
        hitPoint3D: hit3D,
        hitDistance3D: dist3D,
        velocity: velocity,
      );
      if (!candidate.canAcceptDrop(dragged, dropEvent)) {
        continue;
      }
      resolved = (candidate, dropEvent);
      CameraComponent.currentCameras.clear();
      break;
    }
    _dropHitTraceScratch.clear();
    return resolved;
  }

  void _updateDropTargetForRecord(
    TaggedComponent<DragCallbacks> record,
    Vector2 canvasPos,
  ) {
    final dragged = record.component;
    final prevTarget = _hoveredDropTargets[record];
    final hit = _resolveDropTarget(
      pointerId: record.pointerId,
      dragged: dragged,
      canvasPos: canvasPos,
    );
    final nextTarget = hit?.$1;

    if (!identical(prevTarget, nextTarget)) {
      if (prevTarget != null) {
        _hoveredDropTargets.remove(record);
        if (prevTarget.isMounted && !prevTarget.isRemoving) {
          prevTarget.onDragTargetLeave(
            DragDropEvent(
              pointerId: record.pointerId,
              draggedComponent: dragged,
              canvasPosition: canvasPos.clone(),
              localPosition: canvasPos.clone(),
            ),
          );
        }
      }
      if (nextTarget != null && hit != null) {
        _hoveredDropTargets[record] = nextTarget;
        nextTarget.onDragTargetEnter(hit.$2);
      }
    } else if (nextTarget != null && hit != null) {
      nextTarget.onDragTargetMove(hit.$2);
    }
  }

  void _completeDropForRecord(
    TaggedComponent<DragCallbacks> record,
    Vector2? canvasPos,
    Vector2 velocity,
  ) {
    final prevTarget = _hoveredDropTargets.remove(record);
    if (canvasPos == null) {
      if (prevTarget != null &&
          prevTarget.isMounted &&
          !prevTarget.isRemoving) {
        prevTarget.onDragTargetCancel(
          DragDropEvent(
            pointerId: record.pointerId,
            draggedComponent: record.component,
            canvasPosition: Vector2.zero(),
            localPosition: Vector2.zero(),
          ),
        );
      }
      return;
    }
    final hit = _resolveDropTarget(
      pointerId: record.pointerId,
      dragged: record.component,
      canvasPos: canvasPos,
      velocity: velocity,
    );
    final finalTarget = hit?.$1;
    if (prevTarget != null &&
        !identical(prevTarget, finalTarget) &&
        prevTarget.isMounted &&
        !prevTarget.isRemoving) {
      prevTarget.onDragTargetLeave(
        DragDropEvent(
          pointerId: record.pointerId,
          draggedComponent: record.component,
          canvasPosition: canvasPos.clone(),
          localPosition: canvasPos.clone(),
        ),
      );
    }
    if (finalTarget != null && hit != null) {
      if (!identical(prevTarget, finalTarget)) {
        finalTarget.onDragTargetEnter(hit.$2);
      }
      finalTarget.onDrop(hit.$2);
    }
  }

  void _cancelDropForRecord(
    TaggedComponent<DragCallbacks> record,
    Vector2? canvasPos,
  ) {
    final prevTarget = _hoveredDropTargets.remove(record);
    if (prevTarget != null && prevTarget.isMounted && !prevTarget.isRemoving) {
      final pos = canvasPos?.clone() ?? Vector2.zero();
      prevTarget.onDragTargetCancel(
        DragDropEvent(
          pointerId: record.pointerId,
          draggedComponent: record.component,
          canvasPosition: pos,
          localPosition: pos.clone(),
        ),
      );
    }
  }

  @mustCallSuper
  void onDragStart(DragStartEvent event) {
    _lastCanvasPosByPointer[event.pointerId] = event.canvasPosition.clone();
    final startedRecords = <TaggedComponent<DragCallbacks>>[];
    event.deliverAtPoint(
      rootComponent: gameRef,
      eventHandler: (DragCallbacks component) {
        if (!component.allowsMultiPointerDrag && _isDragging(component)) {
          event.continuePropagation = true;
          return;
        }
        final record = TaggedComponent(event.pointerId, component);
        _records.add(record);
        startedRecords.add(record);
        component.onDragStart(event);
      },
    );
    for (var i = 0; i < startedRecords.length; i++) {
      final rec = startedRecords[i];
      if (rec.component.isMounted && !rec.component.isRemoving) {
        _updateDropTargetForRecord(rec, event.canvasPosition);
      }
    }
  }

  bool _isDragging(DragCallbacks component) {
    return _records.any((record) => record.component == component);
  }

  /// Called continuously during the drag as the user moves their finger.
  ///
  /// The default handler propagates this event to those components who received
  /// the initial [onDragStart] event. If the position of the pointer is outside
  /// of the bounds of the component, then this event will nevertheless be
  /// delivered, with local coordinates that fall outside those bounds. A
  /// component that hit testing no longer reaches at all -- because an ancestor
  /// started ignoring events, say -- is delivered to from [_records] instead,
  /// with an empty rendering trace, so its local coordinates are unavailable.
  @mustCallSuper
  void onDragUpdate(DragUpdateEvent event) {
    final prevPos = _lastCanvasPosByPointer[event.pointerId];
    final currentCanvasPos =
        (prevPos != null &&
            !event.canvasDelta.isZero() &&
            prevPos.distanceToSquared(event.canvasStartPosition) <= 1e-6)
        ? event.canvasEndPosition
        : event.canvasStartPosition;
    _lastCanvasPosByPointer[event.pointerId] = currentCanvasPos.clone();
    final updated = <TaggedComponent<DragCallbacks>>{};
    final stale = <TaggedComponent<DragCallbacks>>{};
    final activeForPointer = <TaggedComponent<DragCallbacks>>[];
    event.deliverAtPoint(
      rootComponent: gameRef,
      deliverToAll: true,
      eventHandler: (DragCallbacks component) {
        final record = TaggedComponent(event.pointerId, component);
        if (_records.contains(record)) {
          if (!component.isMounted || component.isRemoving) {
            stale.add(record);
          } else {
            component.onDragUpdate(event);
            updated.add(record);
            activeForPointer.add(record);
          }
        }
      },
    );
    for (final record in _records) {
      if (record.pointerId != event.pointerId) {
        continue;
      }
      final component = record.component;
      if (!component.isMounted || component.isRemoving) {
        stale.add(record);
        continue;
      }
      if (!updated.contains(record)) {
        component.onDragUpdate(event);
        activeForPointer.add(record);
      }
    }
    for (var i = 0; i < activeForPointer.length; i++) {
      final rec = activeForPointer[i];
      if (rec.component.isMounted && !rec.component.isRemoving) {
        _updateDropTargetForRecord(rec, currentCanvasPos);
      }
    }
    if (stale.isNotEmpty) {
      final cancelEvent = DragCancelEvent(event.pointerId);
      for (final record in stale) {
        _cancelDropForRecord(record, currentCanvasPos);
        record.component.onDragCancel(cancelEvent);
      }
      _records.removeAll(stale);
    }
  }

  /// Called when the drag gesture finishes.
  ///
  /// The default handler will deliver this event to all components who has
  /// previously received the corresponding [onDragStart] event and
  /// [onDragUpdate]s.
  @mustCallSuper
  void onDragEnd(DragEndEvent event) {
    final lastPos = _lastCanvasPosByPointer.remove(event.pointerId);
    final endedRecords = <TaggedComponent<DragCallbacks>>[];
    _records.removeWhere((record) {
      if (record.pointerId == event.pointerId) {
        endedRecords.add(record);
        record.component.onDragEnd(event);
        return true;
      }
      return false;
    });
    for (var i = 0; i < endedRecords.length; i++) {
      _completeDropForRecord(endedRecords[i], lastPos, event.velocity);
    }
  }

  @mustCallSuper
  void onDragCancel(DragCancelEvent event) {
    final lastPos = _lastCanvasPosByPointer.remove(event.pointerId);
    final cancelledRecords = <TaggedComponent<DragCallbacks>>[];
    _records.removeWhere((record) {
      if (record.pointerId == event.pointerId) {
        cancelledRecords.add(record);
        record.component.onDragCancel(event);
        return true;
      }
      return false;
    });
    for (var i = 0; i < cancelledRecords.length; i++) {
      _cancelDropForRecord(cancelledRecords[i], lastPos);
    }
  }

  /// Cancels all active in-flight drag, drop-target, and scale gestures (for
  /// example when the app window loses OS focus mid-drag).
  void cancelAllActiveGestures() {
    if (_records.isNotEmpty) {
      final activeDrags = _records.toList(growable: false);
      _records.clear();
      for (var i = 0; i < activeDrags.length; i++) {
        final rec = activeDrags[i];
        final lastPos = _lastCanvasPosByPointer[rec.pointerId];
        if (rec.component.isMounted && !rec.component.isRemoving) {
          rec.component.onDragCancel(DragCancelEvent(rec.pointerId));
        }
        _cancelDropForRecord(rec, lastPos);
      }
    }
    _lastCanvasPosByPointer.clear();
    _hoveredDropTargets.clear();
    if (_scaleRecords.isNotEmpty) {
      final activeScales = _scaleRecords.toList(growable: false);
      _scaleRecords.clear();
      for (var i = 0; i < activeScales.length; i++) {
        final rec = activeScales[i];
        if (rec.component.isMounted && !rec.component.isRemoving) {
          rec.component.onScaleEnd(
            ScaleEndEvent(rec.pointerId, ScaleEndDetails()),
          );
        }
      }
    }
  }

  //#region MultiDragScaleGestureRecognizer drag API

  /// The beginning of a drag operation.
  ///
  /// This does not fire as soon as the pointer touches the screen: the
  /// recognizer waits until the movement exceeds the platform's touch slop, so
  /// that a tap with a slightly wobbling finger stays a tap. The movement
  /// accumulated up to that point is delivered in the first
  /// [handleDragUpdate].
  @internal
  void handleDragStart(int pointerId, DragStartDetails details) {
    final event = DragStartEvent(pointerId, gameRef, details);
    onDragStart(event);
  }

  /// The pointer that was touching the screen has moved.
  ///
  /// This occurs frequently during the drag, and only when the point of touch
  /// actually moves, not when it stays still.
  @internal
  void handleDragUpdate(int pointerId, DragUpdateDetails details) {
    final event = DragUpdateEvent(pointerId, gameRef, details);
    onDragUpdate(event);
  }

  /// Marks the end of a drag operation.
  ///
  /// Fires when the pointer stops touching the screen, even if the pointer is
  /// outside of the game widget at the time.
  @internal
  void handleDragEnd(int pointerId, DragEndDetails details) {
    final event = DragEndEvent(pointerId, details);
    onDragEnd(event);
  }

  /// The drag operation is cancelled.
  ///
  /// For example, this may happen if the drag was interrupted by a
  /// system-modal dialog appearing during the drag.
  @internal
  void handleDragCancel(int pointerId) {
    final event = DragCancelEvent(pointerId);
    onDragCancel(event);
  }

  //#endregion

  final Set<TaggedComponent<ScaleCallbacks>> _scaleRecords = {};

  /// Called when the user starts a scale gesture.
  @mustCallSuper
  void onScaleStart(ScaleStartEvent event) {
    event.deliverAtPoint(
      rootComponent: gameRef,
      eventHandler: (ScaleCallbacks component) {
        _scaleRecords.add(TaggedComponent(event.pointerId, component));
        component.onScaleStart(event);
      },
    );
  }

  /// Called continuously as the user updates the scale gesture.
  @mustCallSuper
  void onScaleUpdate(ScaleUpdateEvent event) {
    final updated = <TaggedComponent<ScaleCallbacks>>{};
    final stale = <TaggedComponent<ScaleCallbacks>>{};

    // Deliver to components under the pointer
    event.deliverAtPoint(
      rootComponent: gameRef,
      deliverToAll: true,
      eventHandler: (ScaleCallbacks component) {
        final record = TaggedComponent(event.pointerId, component);
        if (_scaleRecords.contains(record)) {
          if (!component.isMounted || component.isRemoving) {
            stale.add(record);
          } else {
            component.onScaleUpdate(event);
            updated.add(record);
          }
        }
      },
    );

    // Also deliver to components that started the scale but weren't under
    // the pointer this frame
    // Currently, the id passed to the scale
    // events is always 0, so maybe it's not relevant.
    for (final record in _scaleRecords) {
      if (record.pointerId != event.pointerId) {
        continue;
      }
      final component = record.component;
      if (!component.isMounted || component.isRemoving) {
        stale.add(record);
        continue;
      }
      if (!updated.contains(record)) {
        record.component.onScaleUpdate(event);
      }
    }

    if (stale.isNotEmpty) {
      final endEvent = ScaleEndEvent(event.pointerId, ScaleEndDetails());
      for (final record in stale) {
        record.component.onScaleEnd(endEvent);
      }
      _scaleRecords.removeAll(stale);
    }
  }

  /// Called when the scale gesture ends.
  @mustCallSuper
  void onScaleEnd(ScaleEndEvent event) {
    _scaleRecords.removeWhere((record) {
      if (record.pointerId == event.pointerId) {
        record.component.onScaleEnd(event);
        return true;
      }
      return false;
    });
  }

  //#region MultiDragScaleGestureRecognizer scale API

  /// The beginning of a scale operation.
  ///
  /// Fires once two or more pointers are touching the screen and their
  /// movement exceeds the recognizer's [scaleThreshold].
  @internal
  void handleScaleStart(ScaleStartDetails details) {
    onScaleStart(ScaleStartEvent(0, gameRef, details));
  }

  /// The pointers taking part in the scale gesture have moved.
  ///
  /// This occurs frequently during the gesture, reporting the current scale
  /// factors, the rotation and the focal point.
  @internal
  void handleScaleUpdate(ScaleUpdateDetails details) {
    onScaleUpdate(ScaleUpdateEvent(0, gameRef, details));
  }

  /// Marks the end of a scale operation.
  ///
  /// Fires once fewer than two pointers are left touching the screen.
  @internal
  void handleScaleEnd(ScaleEndDetails details) {
    onScaleEnd(ScaleEndEvent(0, details));
  }

  //#endregion

  @override
  void onMount() {
    gameRef.gestureDetectors.register<MultiDragScaleGestureRecognizer>(
      () => MultiDragScaleGestureRecognizer(
        scaleThreshold: _scaleThreshold,
        rotationThreshold: _rotationThreshold,
        zeroTrackpadDeadzone: _zeroTrackpadDeadzone,
      ),
      (MultiDragScaleGestureRecognizer instance) {
        _recognizer = instance;
        instance.scaleThreshold = _scaleThreshold;
        instance.rotationThreshold = _rotationThreshold;
        instance.zeroTrackpadDeadzone = _zeroTrackpadDeadzone;
        instance.hasDrag = _dragCount > 0;
        instance.hasScale = _scaleCount > 0;
        instance.onStart = (Offset point) => _FlameDragAdapter(this, point);
        instance.onScaleStart = handleScaleStart;
        instance.onScaleUpdate = handleScaleUpdate;
        instance.onScaleEnd = handleScaleEnd;
      },
    );
  }

  @override
  void onRemove() {
    _recognizer = null;
    gameRef.gestureDetectors.unregister<MultiDragScaleGestureRecognizer>();
    gameRef.unregisterKey(const MultiDragScaleDispatcherKey());
  }

  GameRenderBox get _renderBox => gameRef.renderBox;
}

/// Adapts the drag API expected by [MultiDragScaleGestureRecognizer] into the
/// one expected by [MultiDragScaleDispatcher].
///
/// Flutter identifies a drag by the [Drag] object returned from `onStart`, and
/// its `update`/`end`/`cancel` callbacks carry no pointer id of their own. The
/// dispatcher, in contrast, is shared by the whole game and needs to tell
/// pointers apart, so one of these is created per pointer to hold the id and
/// attach it to every event that follows.
class _FlameDragAdapter(
  final MultiDragScaleDispatcher _dispatcher,
  Offset startPoint,
) implements Drag {
  this {
    _id = _globalIdCounter++;
    _dispatcher.handleDragStart(
      _id,
      DragStartDetails(
        sourceTimeStamp: Duration.zero,
        globalPosition: startPoint,
        localPosition: _dispatcher._renderBox.globalToLocal(startPoint),
      ),
    );
  }

  late final int _id;
  static int _globalIdCounter = 0;

  @override
  void update(DragUpdateDetails event) =>
      _dispatcher.handleDragUpdate(_id, event);

  @override
  void end(DragEndDetails event) => _dispatcher.handleDragEnd(_id, event);

  @override
  void cancel() => _dispatcher.handleDragCancel(_id);
}
