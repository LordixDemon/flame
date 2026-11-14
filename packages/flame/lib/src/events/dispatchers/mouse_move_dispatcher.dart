import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/src/events/tagged_component.dart';
import 'package:flame/src/game/flame_game.dart';
import 'package:flutter/gestures.dart' as flutter;
import 'package:meta/meta.dart';

/// **MouseMoveDispatcher** facilitates dispatching of mouse move events to the
/// [MouseMoveCallbacks] components in the component tree. It will be attached
/// to the [FlameGame] instance automatically whenever any
/// [MouseMoveCallbacks] components are mounted into the component tree.
class MouseMoveDispatcher() extends Dispatcher<FlameGame> {
  /// The record of all components currently being hovered.
  final Set<TaggedComponent<MouseMoveCallbacks>> _records = {};
  final Set<TaggedComponent<MouseMoveCallbacks>> _updatedScratch = {};
  final List<TaggedComponent<MouseMoveCallbacks>> _toRemoveScratch = [];
  final Map<int, flutter.PointerHoverEvent> _pendingHoverByPointer = {};

  int _rawHoverEventsReceived = 0;
  int _dispatchCount = 0;

  /// Total number of raw OS `PointerHoverEvent`s received from Flutter.
  int get rawHoverEventsReceived => _rawHoverEventsReceived;

  /// Total number of scene hover raycasts/dispatches actually executed.
  int get dispatchCount => _dispatchCount;

  @mustCallSuper
  void onMouseMove(MouseMoveEvent event) {
    _dispatchCount++;
    _updatedScratch.clear();

    event.deliverAtPoint(
      rootComponent: gameRef,
      deliverToAll: true,
      eventHandler: (MouseMoveCallbacks component) {
        final tagged = TaggedComponent(event.pointerId, component);
        _records.add(tagged);
        _updatedScratch.add(tagged);
        component.onMouseMove(event);
      },
    );

    _toRemoveScratch.clear();
    for (final record in _records) {
      if (record.pointerId == event.pointerId &&
          !_updatedScratch.contains(record)) {
        // one last "exit" event
        record.component.onMouseMoveStop(event);
        _toRemoveScratch.add(record);
      }
    }
    for (var i = 0; i < _toRemoveScratch.length; i++) {
      _records.remove(_toRemoveScratch[i]);
    }
    _toRemoveScratch.clear();
    _updatedScratch.clear();
  }

  /// Flushes any coalesced OS `PointerHoverEvent`s queued since the previous
  /// frame when [FlameGame.coalesceMouseHover] is enabled.
  void flushPendingHover() {
    if (_pendingHoverByPointer.isEmpty) {
      return;
    }
    if (_pendingHoverByPointer.length == 1) {
      final raw = _pendingHoverByPointer.values.first;
      _pendingHoverByPointer.clear();
      onMouseMove(MouseMoveEvent.fromPointerHoverEvent(gameRef, raw));
      return;
    }
    final pending = _pendingHoverByPointer.values.toList(growable: false);
    _pendingHoverByPointer.clear();
    for (final raw in pending) {
      onMouseMove(MouseMoveEvent.fromPointerHoverEvent(gameRef, raw));
    }
  }

  void _handleMouseMove(flutter.PointerHoverEvent event) {
    _rawHoverEventsReceived++;
    if (gameRef.coalesceMouseHover && !gameRef.isPaused) {
      _pendingHoverByPointer[event.pointer] = event;
      gameRef.notifyActivity();
      return;
    }
    onMouseMove(MouseMoveEvent.fromPointerHoverEvent(gameRef, event));
  }

  /// Cancels the hover on every currently-hovered [HoverCallbacks] tracked by
  /// this dispatcher when a pointer button is pressed. Flutter routes such
  /// presses through `Listener.onPointerDown` (not `MouseRegion.onHover`), so
  /// without this hook hovered components would never learn the hover ended.
  /// See issue #2741.
  void _handlePointerPress(flutter.PointerDownEvent event) {
    _pendingHoverByPointer.remove(event.pointer);
    _toRemoveScratch.clear();
    for (final record in _records) {
      final component = record.component;
      if (component is HoverCallbacks && component.isHovered) {
        component.cancelHover();
        _toRemoveScratch.add(record);
      }
    }
    for (var i = 0; i < _toRemoveScratch.length; i++) {
      _records.remove(_toRemoveScratch[i]);
    }
    _toRemoveScratch.clear();
  }

  /// Clears pending coalesced hover events and cancels active hover states.
  void cancelAllActiveHovers() {
    _pendingHoverByPointer.clear();
    if (_records.isEmpty) {
      return;
    }
    final active = _records.toList(growable: false);
    _records.clear();
    for (var i = 0; i < active.length; i++) {
      final comp = active[i].component;
      if (comp is HoverCallbacks && comp.isHovered) {
        comp.cancelHover();
      }
    }
  }

  static void addDispatcher(Component component) {
    Dispatcher.addDispatcher(
      component,
      const MouseMoveDispatcherKey(),
      MouseMoveDispatcher.new,
    );
  }

  @override
  void onMount() {
    gameRef.mouseDetector = _handleMouseMove;
    gameRef.mousePressDetector = _handlePointerPress;
  }

  @override
  void onRemove() {
    gameRef.mouseDetector = null;
    gameRef.mousePressDetector = null;
    Dispatcher.removeDispatcher(gameRef, const MouseMoveDispatcherKey());
  }
}

class const MouseMoveDispatcherKey() implements ComponentKey {
  @override
  int get hashCode => 'MouseMoveDispatcherKey'.hashCode;

  @override
  bool operator ==(Object other) =>
      other is MouseMoveDispatcherKey && other.hashCode == hashCode;
}
