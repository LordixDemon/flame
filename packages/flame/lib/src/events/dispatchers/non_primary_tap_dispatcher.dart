import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';

class const NonPrimaryTapDispatcherKey() implements ComponentKey {
  @override
  int get hashCode => 'NonPrimaryTapDispatcherKey'.hashCode;

  @override
  bool operator ==(Object other) =>
      other is NonPrimaryTapDispatcherKey && other.hashCode == hashCode;
}

/// [NonPrimaryTapDispatcher] propagates non-primary tap events (i.e.
/// secondary/right and tertiary/middle mouse clicks) to every component in the
/// component tree that is mixed with [SecondaryTapCallbacks] or
/// [TertiaryTapCallbacks]. This will be attached to the [FlameGame] instance
/// automatically whenever any of those callbacks are mounted into the
/// component tree.
class NonPrimaryTapDispatcher() extends Dispatcher<FlameGame> {
  final _secondaryComponents = <SecondaryTapCallbacks>{};
  final _tertiaryComponents = <TertiaryTapCallbacks>{};

  void _onSecondaryTapDown(SecondaryTapDownEvent event) {
    event.deliverAtPoint(
      rootComponent: gameRef,
      eventHandler: (SecondaryTapCallbacks component) {
        _secondaryComponents.add(component..onSecondaryTapDown(event));
      },
    );
  }

  void _onSecondaryTapUp(SecondaryTapUpEvent event) {
    for (final component in _secondaryComponents) {
      component.onSecondaryTapUp(event);
    }
    _secondaryComponents.clear();
  }

  void _onSecondaryTapCancel(SecondaryTapCancelEvent event) {
    for (final component in _secondaryComponents) {
      component.onSecondaryTapCancel(event);
    }
    _secondaryComponents.clear();
  }

  void _onTertiaryTapDown(TertiaryTapDownEvent event) {
    event.deliverAtPoint(
      rootComponent: gameRef,
      eventHandler: (TertiaryTapCallbacks component) {
        _tertiaryComponents.add(component..onTertiaryTapDown(event));
      },
    );
  }

  void _onTertiaryTapUp(TertiaryTapUpEvent event) {
    for (final component in _tertiaryComponents) {
      component.onTertiaryTapUp(event);
    }
    _tertiaryComponents.clear();
  }

  void _onTertiaryTapCancel(TertiaryTapCancelEvent event) {
    for (final component in _tertiaryComponents) {
      component.onTertiaryTapCancel(event);
    }
    _tertiaryComponents.clear();
  }

  /// Cancels any active secondary or tertiary mouse press gestures, including
  /// those held by components that have been removed from the tree in the
  /// meantime.
  void cancelAllActiveNonPrimaryTaps() {
    if (_secondaryComponents.isNotEmpty) {
      final sec = _secondaryComponents.toList(growable: false);
      _secondaryComponents.clear();
      final ev = SecondaryTapCancelEvent();
      for (var i = 0; i < sec.length; i++) {
        sec[i].onSecondaryTapCancel(ev);
      }
    }
    if (_tertiaryComponents.isNotEmpty) {
      final ter = _tertiaryComponents.toList(growable: false);
      _tertiaryComponents.clear();
      final ev = TertiaryTapCancelEvent();
      for (var i = 0; i < ter.length; i++) {
        ter[i].onTertiaryTapCancel(ev);
      }
    }
  }

  static void addDispatcher(Component component) {
    Dispatcher.addDispatcher(
      component,
      const NonPrimaryTapDispatcherKey(),
      NonPrimaryTapDispatcher.new,
    );
  }

  @override
  void onMount() {
    gameRef.gestureDetectors.register(
      TapGestureRecognizer.new,
      (TapGestureRecognizer instance) {
        instance.onSecondaryTapDown = (details) =>
            _onSecondaryTapDown(SecondaryTapDownEvent(gameRef, details));
        instance.onSecondaryTapCancel = () =>
            _onSecondaryTapCancel(SecondaryTapCancelEvent());
        instance.onSecondaryTapUp = (details) =>
            _onSecondaryTapUp(SecondaryTapUpEvent(gameRef, details));
        instance.onTertiaryTapDown = (details) =>
            _onTertiaryTapDown(TertiaryTapDownEvent(gameRef, details));
        instance.onTertiaryTapCancel = () =>
            _onTertiaryTapCancel(TertiaryTapCancelEvent());
        instance.onTertiaryTapUp = (details) =>
            _onTertiaryTapUp(TertiaryTapUpEvent(gameRef, details));
      },
    );
  }

  @override
  void onRemove() {
    gameRef.gestureDetectors.unregister<TapGestureRecognizer>();
    Dispatcher.removeDispatcher(gameRef, const NonPrimaryTapDispatcherKey());
  }
}
