import 'dart:math';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ignores events while [ignoreEvents] is set.
class _Ignoring({super.position, super.size, super.children})
    extends PositionComponent
    with IgnoreEvents;

/// Overrides [componentsAtLocation] the way users do: with a generator that
/// adds itself in front of what the default implementation finds.
class _Overriding({super.position, super.size, super.children})
    extends PositionComponent {
  @override
  Iterable<Component> componentsAtLocation<T>(
    T locationContext,
    List<T>? nestedContexts,
    T? Function(CoordinateTransform, T) transformContext,
    bool Function(Component, T) checkContains,
  ) sync* {
    yield this;
    yield* super.componentsAtLocation(
      locationContext,
      nestedContexts,
      transformContext,
      checkContains,
    );
  }
}

/// Throws from its hit check once [armed].
class _Throwing({super.size}) extends PositionComponent {
  bool armed = false;

  @override
  bool containsLocalPoint(Vector2 point) {
    if (armed) {
      throw StateError('hit check');
    }
    return super.containsLocalPoint(point);
  }
}

/// The default `componentsAtLocation` as it was written before: a recursive
/// generator. Components that override the method are asked themselves.
Iterable<Component> _reference<T>(
  Component component,
  T locationContext,
  List<T>? nestedContexts,
  T? Function(CoordinateTransform, T) transformContext,
  bool Function(Component, T) checkContains,
) sync* {
  if (!component.isActiveForCurrentGraphicsTier) {
    return;
  }
  final activeCamera = CameraComponent.currentCamera;
  if (activeCamera != null &&
      (component.cameraMask & activeCamera.cameraMask) == 0) {
    return;
  }
  nestedContexts?.add(locationContext);
  if (component is ClipComponent &&
      locationContext is Vector2 &&
      !component.clipShapeContains(locationContext)) {
    nestedContexts?.removeLast();
    return;
  }
  if (component.hasChildren) {
    for (final child in component.children.reversed) {
      if (child is IgnoreEvents && child.ignoreEvents) {
        continue;
      }
      T? childPoint = locationContext;
      if (child is CoordinateTransform) {
        childPoint = transformContext(
          child as CoordinateTransform,
          locationContext,
        );
      }
      if (childPoint != null) {
        yield* child is _Overriding
            ? child.componentsAtLocation(
                childPoint,
                nestedContexts,
                transformContext,
                checkContains,
              )
            : _reference(
                child,
                childPoint,
                nestedContexts,
                transformContext,
                checkContains,
              );
      }
    }
  }
  final shouldIgnoreEvents =
      component is IgnoreEvents && component.ignoreEvents;
  if (checkContains(component, locationContext) && !shouldIgnoreEvents) {
    yield component;
  }
  nestedContexts?.removeLast();
}

Iterable<Component> _referenceAtPoint(
  Component root,
  Vector2 point,
  List<Vector2>? nested,
) {
  Vector2? transform(CoordinateTransform transform, Vector2 point) =>
      transform.parentToLocal(point);
  bool contains(Component component, Vector2 point) =>
      component.containsLocalPoint(point);
  return root is _Overriding
      ? root.componentsAtLocation(point, nested, transform, contains)
      : _reference<Vector2>(root, point, nested, transform, contains);
}

extension on ClipComponent {
  /// What `ClipComponent.containsClipPoint`, which is protected, answers.
  bool clipShapeContains(Vector2 point) => containsClipPoint(point);
}

/// What a consumer sees for each component: the component and the contexts
/// that are pushed while it is handled.
List<(Component, List<Vector2>)> _walk(
  Iterable<Component> found,
  List<Vector2> nested, {
  int? limit,
}) {
  final seen = <(Component, List<Vector2>)>[];
  for (final component in found) {
    seen.add((component, [for (final v in nested) v.clone()]));
    if (limit != null && seen.length >= limit) {
      break;
    }
  }
  return seen;
}

/// A random tree of components of every kind that hit-testing treats in a
/// particular way.
Component _randomTree(Random random) {
  Component node(int depth) {
    final children = depth >= 4
        ? <Component>[]
        : [for (var i = random.nextInt(4); i > 0; i--) node(depth + 1)];
    final position = Vector2(
      random.nextDouble() * 200 - 50,
      random.nextDouble() * 200 - 50,
    );
    final size = Vector2(
      random.nextDouble() * 150 + 1,
      random.nextDouble() * 150 + 1,
    );
    final kind = random.nextInt(9);
    final Component component;
    switch (kind) {
      case 0:
        component = Component(children: children);
      case 1:
        component = _Ignoring(
          position: position,
          size: size,
          children: children,
        )..ignoreEvents = random.nextBool();
      case 2:
        component = ClipComponent.rectangle(
          position: position,
          size: size,
          children: children,
        );
      case 3:
        component = _Overriding(
          position: position,
          size: size,
          children: children,
        );
      default:
        component = PositionComponent(
          position: position,
          size: size,
          angle: random.nextDouble() < 0.3 ? random.nextDouble() : 0,
          scale: random.nextDouble() < 0.3
              ? Vector2(random.nextDouble() + 0.5, -random.nextDouble() - 0.5)
              : null,
          priority: random.nextInt(3),
          children: children,
        );
    }
    return component;
  }

  return node(0);
}

void main() {
  group('Component.componentsAtLocation', () {
    test('finds the same components with the same contexts as a recursive '
        'generator, in random trees', () async {
      final random = Random(20261118);
      var found = 0;
      var withContexts = 0;
      for (var tree = 0; tree < 40; tree++) {
        final game = await initializeGame(FlameGame.new);
        final root = _randomTree(random);
        game.world.add(root);
        await game.ready();
        for (var i = 0; i < 30; i++) {
          final point = Vector2(
            random.nextDouble() * 400 - 100,
            random.nextDouble() * 400 - 100,
          );
          final nested = <Vector2>[];
          final actual = _walk(root.componentsAtPoint(point, nested), nested);
          final referenceNested = <Vector2>[];
          final expected = _walk(
            _referenceAtPoint(root, point, referenceNested),
            referenceNested,
          );
          expect(
            [for (final (c, _) in actual) identityHashCode(c)],
            [for (final (c, _) in expected) identityHashCode(c)],
            reason: 'tree $tree, point $point',
          );
          for (var j = 0; j < actual.length; j++) {
            expect(actual[j].$2, expected[j].$2, reason: 'tree $tree, $j');
            withContexts += actual[j].$2.length > 2 ? 1 : 0;
          }
          found += actual.length;
          expect(nested, isEmpty);

          // A consumer that stops early leaves the same contexts behind.
          final partial = <Vector2>[];
          final referencePartial = <Vector2>[];
          _walk(root.componentsAtPoint(point, partial), partial, limit: 2);
          _walk(
            _referenceAtPoint(root, point, referencePartial),
            referencePartial,
            limit: 2,
          );
          expect(partial, referencePartial);
        }
      }
      // The trees are not trivial: many points hit nested components.
      expect(found, greaterThan(500));
      expect(withContexts, greaterThan(100));
    });

    test('is lazy and can be iterated again', () {
      final inner = PositionComponent(size: Vector2.all(10));
      final outer = PositionComponent(size: Vector2.all(10), children: [inner]);
      final calls = <Component>[];
      final found = outer.componentsAtLocation<Vector2>(
        Vector2(1, 1),
        null,
        (transform, point) => transform.parentToLocal(point),
        (component, point) {
          calls.add(component);
          return true;
        },
      );
      expect(calls, isEmpty);
      final iterator = found.iterator;
      expect(iterator.moveNext(), isTrue);
      expect(iterator.current, inner);
      expect(calls, [inner]);
      expect(iterator.moveNext(), isTrue);
      expect(iterator.current, outer);
      expect(iterator.moveNext(), isFalse);
      expect(found.toList(), [inner, outer]);
      expect(found.toList(), [inner, outer]);
    });

    test('a component that throws ends the iteration', () {
      final throwing = _Throwing(size: Vector2.all(10));
      final root = PositionComponent(
        size: Vector2.all(10),
        children: [
          throwing,
          PositionComponent(size: Vector2.all(10)),
        ],
      );
      throwing.armed = true;
      final iterator = root.componentsAtPoint(Vector2(1, 1)).iterator;
      expect(iterator.moveNext(), isTrue);
      expect(iterator.moveNext, throwsStateError);
      expect(iterator.moveNext(), isFalse);
    });

    test('reordering the children while iterating them is an error, like for '
        'a generator', () async {
      final game = await initializeGame(FlameGame.new);
      final parent = PositionComponent(size: Vector2.all(10));
      final first = PositionComponent(size: Vector2.all(10), priority: 1);
      final second = PositionComponent(size: Vector2.all(10), priority: 2);
      parent.addAll([first, second]);
      game.world.add(parent);
      await game.ready();

      Object? error;
      Object? referenceError;
      for (final (found, record) in [
        (parent.componentsAtPoint(Vector2(1, 1)), (Object e) => error = e),
        (
          _referenceAtPoint(parent, Vector2(1, 1), null),
          (Object e) => referenceError = e,
        ),
      ]) {
        try {
          for (final component in found) {
            if (component == second) {
              // Puts `second` in front of `first`.
              second.priority = 0;
              game.processLifecycleEvents();
            }
          }
        } on Object catch (e) {
          record(e);
        }
        second.priority = 2;
        game.processLifecycleEvents();
      }
      expect(error, isA<ConcurrentModificationError>());
      expect(referenceError, isA<ConcurrentModificationError>());
    });

    test('skips components below the graphics tier, like before', () async {
      final game = await initializeGame(FlameGame.new);
      final gated = PositionComponent(
        size: Vector2.all(10),
        minQualityTier: GraphicsQualityTier.ultra,
      );
      final open = PositionComponent(size: Vector2.all(10));
      final parent = Component(children: [open, gated]);
      game.world.add(parent);
      await game.ready();
      game.graphics.setTier(GraphicsQualityTier.low);
      expect(parent.componentsAtPoint(Vector2(1, 1)).toList(), [open]);
      game.graphics.setTier(GraphicsQualityTier.ultra);
      expect(parent.componentsAtPoint(Vector2(1, 1)).toList(), [gated, open]);
    });
  });
}
