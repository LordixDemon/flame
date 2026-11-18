part of 'component.dart';

/// The result of the default [Component.componentsAtLocation]: the components
/// under a location, front-most first.
///
/// It is the same lazy sequence as this generator, which was the default
/// implementation before:
///
/// ```dart
/// Iterable<Component> componentsAtLocation<T>(...) sync* {
///   if (!isActiveForCurrentGraphicsTier) return;
///   final activeCamera = CameraComponent.currentCamera;
///   if (activeCamera != null &&
///       (_cameraMask & activeCamera.cameraMask) == 0) {
///     return;
///   }
///   nestedContexts?.add(locationContext);
///   if (clipsChildEvents &&
///       locationContext is Vector2 &&
///       !containsClipPoint(locationContext)) {
///     nestedContexts?.removeLast();
///     return;
///   }
///   final children = _children;
///   if (children != null) {
///     for (final child in children.reversed) {
///       if (child is IgnoreEvents && child.ignoreEvents) continue;
///       T? childPoint = locationContext;
///       if (child is CoordinateTransform) {
///         childPoint = transformContext(child, locationContext);
///       }
///       if (childPoint != null) {
///         yield* child.componentsAtLocation(childPoint, ...);
///       }
///     }
///   }
///   final shouldIgnoreEvents = this is IgnoreEvents && ignoreEvents;
///   if (checkContains(this, locationContext) && !shouldIgnoreEvents) {
///     yield this;
///   }
///   nestedContexts?.removeLast();
/// }
/// ```
///
/// Every step happens at the same point as in the generator: the contexts are
/// pushed and popped, the transforms and the hit checks are evaluated, and
/// the children's own [Component.componentsAtLocation] are called, only as
/// the iteration reaches them. But where the generator allocated an iterable
/// and two copies of its frame for every component it visited, the iterator
/// walks the components that use this implementation on a stack of its own,
/// and only hands over to the iterator of a component that overrides
/// [Component.componentsAtLocation].
class _ComponentsAtLocation<T>(
  final Component _root,
  final T _context,
  final List<T>? _nestedContexts,
  final T? Function(CoordinateTransform, T) _transformContext,
  final bool Function(Component, T) _checkContains,
) extends Iterable<Component> {
  @override
  Iterator<Component> get iterator => _ComponentsAtLocationIterator<T>(this);
}

/// One level of the walk of a [_ComponentsAtLocationIterator]: a component
/// whose [_ComponentsAtLocation] is walked in place, or the iterator of a
/// component that overrides [Component.componentsAtLocation].
class _LocationFrame<T>() {
  _ComponentsAtLocation<T>? walk;
  Iterator<Component>? delegate;

  /// Where the walk of [walk] is: one of the `_step*` constants of
  /// [_ComponentsAtLocationIterator].
  int step = 0;

  /// The children being walked, back to front, like the iterator of
  /// `children.reversed`: [index] is the last one that was visited, and
  /// [shiftCount] what the list's count was when the walk started.
  ComponentList? children;
  int shiftCount = 0;
  int index = 0;
}

class _ComponentsAtLocationIterator<T>(_ComponentsAtLocation<T> root)
    implements Iterator<Component> {
  this {
    _pushWalk(root);
  }

  static const int _stepStart = 0;
  static const int _stepChildren = 1;
  static const int _stepSelf = 2;
  static const int _stepEnd = 3;

  /// The frames of the walk, reused from one level to the next; the first
  /// [_depth] of them are in use.
  final List<_LocationFrame<T>> _frames = <_LocationFrame<T>>[];
  int _depth = 0;
  Component? _current;

  @override
  Component get current => _current!;

  _LocationFrame<T> _push() {
    if (_depth == _frames.length) {
      _frames.add(_LocationFrame<T>());
    }
    return _frames[_depth++];
  }

  void _pushWalk(_ComponentsAtLocation<T> walk) {
    _push()
      ..walk = walk
      ..delegate = null
      ..step = _stepStart
      ..children = null;
  }

  void _pushDelegate(Iterator<Component> delegate) {
    _push()
      ..walk = null
      ..delegate = delegate;
  }

  void _pop() {
    _frames[--_depth]
      ..walk = null
      ..delegate = null
      ..children = null;
  }

  @override
  bool moveNext() {
    try {
      return _advance();
    } on Object {
      // Like a generator that threw, the iteration is over.
      while (_depth > 0) {
        _pop();
      }
      _current = null;
      rethrow;
    }
  }

  bool _advance() {
    while (_depth > 0) {
      final frame = _frames[_depth - 1];
      final delegate = frame.delegate;
      if (delegate != null) {
        if (delegate.moveNext()) {
          _current = delegate.current;
          return true;
        }
        _pop();
        continue;
      }
      final walk = frame.walk!;
      final component = walk._root;
      switch (frame.step) {
        case _stepStart:
          if (!component.isActiveForCurrentGraphicsTier) {
            _pop();
            continue;
          }
          final activeCamera = CameraComponent.currentCamera;
          if (activeCamera != null &&
              (component._cameraMask & activeCamera.cameraMask) == 0) {
            _pop();
            continue;
          }
          final context = walk._context;
          walk._nestedContexts?.add(context);
          if (component.clipsChildEvents &&
              context is Vector2 &&
              !component.containsClipPoint(context)) {
            walk._nestedContexts?.removeLast();
            _pop();
            continue;
          }
          final children = component._children;
          if (children != null) {
            // What `children.reversed.iterator` does.
            children._ensureSortKeysOrdered();
            frame
              ..children = children
              ..shiftCount = children._shiftCount
              ..index = children._elements.length;
          }
          frame.step = _stepChildren;
        case _stepChildren:
          final children = frame.children;
          final child = children == null ? null : _nextChild(frame, children);
          if (child == null) {
            frame.step = _stepSelf;
            continue;
          }
          if (child is IgnoreEvents && child.ignoreEvents) {
            continue;
          }
          T? childContext = walk._context;
          if (child is CoordinateTransform) {
            childContext = walk._transformContext(
              child as CoordinateTransform,
              walk._context,
            );
          }
          if (childContext != null) {
            final found = child.componentsAtLocation(
              childContext,
              walk._nestedContexts,
              walk._transformContext,
              walk._checkContains,
            );
            if (found is _ComponentsAtLocation<T>) {
              _pushWalk(found);
            } else {
              _pushDelegate(found.iterator);
            }
          }
        case _stepSelf:
          frame.step = _stepEnd;
          final shouldIgnoreEvents =
              component is IgnoreEvents && component.ignoreEvents;
          if (walk._checkContains(component, walk._context) &&
              !shouldIgnoreEvents) {
            _current = component;
            return true;
          }
        default:
          walk._nestedContexts?.removeLast();
          _pop();
      }
    }
    _current = null;
    return false;
  }

  /// The next child of [children] from the back, or null when there is none:
  /// what the iterator of `children.reversed` returns.
  static Component? _nextChild(
    _LocationFrame<Object?> frame,
    ComponentList children,
  ) {
    if (children._shiftCount != frame.shiftCount) {
      throw ConcurrentModificationError(children);
    }
    final elements = children._elements;
    for (var i = frame.index - 1; i >= 0; i--) {
      final element = elements[i];
      if (element != null) {
        frame.index = i;
        return element;
      }
    }
    frame.index = -1;
    return null;
  }
}
