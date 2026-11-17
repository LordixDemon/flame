import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _Unit(final String name, double y) extends PositionComponent {
  this : super(position: Vector2(0, y), sortKey: y);

  int updates = 0;
  int paints = 0;

  /// Walk "down" the screen in the next update and keep the draw order in
  /// sync with the new position (y-sort).
  bool walksInUpdate = false;

  /// Same, but from inside `render`.
  bool walksInRender = false;

  /// Iterate over the siblings (a neighbour lookup) after updating/painting.
  bool looksAtSiblings = false;

  void _walk() {
    position.y += 100;
    sortKey = position.y;
  }

  void _lookAtSiblings() {
    var seen = 0;
    for (final other in parent!.children) {
      if (!identical(other, this)) {
        seen++;
      }
    }
    expect(seen, parent!.children.length - 1);
  }

  @override
  void update(double dt) {
    updates++;
    if (walksInUpdate) {
      _walk();
    }
    if (looksAtSiblings) {
      _lookAtSiblings();
    }
  }

  @override
  void render(Canvas canvas) {
    paints++;
    if (walksInRender) {
      walksInRender = false;
      _walk();
    }
    if (looksAtSiblings) {
      _lookAtSiblings();
    }
  }

  @override
  String toString() => name;
}

class _SlowMotionLayer() extends Component with CustomTraversal, HasTimeScale;

void _render(Component component) {
  final recorder = PictureRecorder();
  component.renderTree(Canvas(recorder));
  recorder.endRecording().dispose();
}

void main() {
  group('Component.sortKey changed while the parent is being traversed', () {
    testWithFlameGame(
      'every child of a CustomTraversal layer is updated exactly once',
      (game) async {
        final layer = _SlowMotionLayer();
        final a = _Unit('a', 0);
        final b = _Unit('b', 10);
        final c = _Unit('c', 20);
        layer.addAll([a, b, c]);
        game.world.add(layer);
        await game.ready();
        game.update(1 / 60);
        expect([a.updates, b.updates, c.updates], [1, 1, 1]);

        a.updates = b.updates = c.updates = 0;
        a.walksInUpdate = true; // a moves behind c
        b.looksAtSiblings = true; // b reads parent.children afterwards
        game.update(1 / 60);

        expect(
          {'a': a.updates, 'b': b.updates, 'c': c.updates},
          {'a': 1, 'b': 1, 'c': 1},
        );
        // The pending reorder is applied by the first read after the pass.
        expect(layer.children.toList(), [b, c, a]);
      },
    );

    testWithFlameGame(
      'every child is updated exactly once through the flat update list',
      (game) async {
        final a = _Unit('a', 0);
        final b = _Unit('b', 10);
        final c = _Unit('c', 20);
        game.world.addAll([a, b, c]);
        await game.ready();
        game.update(1 / 60);

        a.updates = b.updates = c.updates = 0;
        a.walksInUpdate = true;
        b.looksAtSiblings = true;
        game.update(1 / 60);

        expect([a.updates, b.updates, c.updates], [1, 1, 1]);
        expect(game.world.children.whereType<_Unit>().toList(), [b, c, a]);
      },
    );

    testWithFlameGame('every child is painted exactly once', (game) async {
      final group = Component();
      final a = _Unit('a', 0);
      final b = _Unit('b', 10);
      final c = _Unit('c', 20);
      group.addAll([a, b, c]);
      game.world.add(group);
      await game.ready();

      a.walksInRender = true;
      b.looksAtSiblings = true;
      _render(group);

      expect(
        {'a': a.paints, 'b': b.paints, 'c': c.paints},
        {'a': 1, 'b': 1, 'c': 1},
      );
      expect(group.children.toList(), [b, c, a]);

      // The next frame draws in the new order.
      final order = <String>[];
      for (final unit in [a, b, c]) {
        unit
          ..paints = 0
          ..looksAtSiblings = false;
      }
      _render(group);
      for (final child in group.children) {
        order.add(child.toString());
      }
      expect(order, ['b', 'c', 'a']);
      expect([a.paints, b.paints, c.paints], [1, 1, 1]);
    });

    testWithFlameGame(
      'the traversal guard is released when an update throws',
      (game) async {
        final layer = _SlowMotionLayer();
        final a = _Unit('a', 0);
        final b = _Unit('b', 10);
        final thrower = _ThrowingOnce();
        layer.addAll([a, b, thrower]);
        game.world.add(layer);
        await game.ready();

        expect(() => game.update(1 / 60), throwsStateError);

        a.sortKey = 50;
        expect(layer.children.toList(), [b, a, thrower]);
      },
    );
  });
}

class _ThrowingOnce() extends Component {
  this : super(priority: 5);

  bool _thrown = false;

  @override
  void update(double dt) {
    if (!_thrown) {
      _thrown = true;
      throw StateError('update failed');
    }
  }
}
