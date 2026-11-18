import 'dart:math';
import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

/// A leaf that writes its name into [log] when it is drawn.
class _Leaf({
  required this.name,
  required this.log,
  super.position,
  super.priority,
}) extends PositionComponent {
  this : super(size: Vector2(20, 20));

  final String name;
  final List<String> log;

  @override
  void render(Canvas canvas) => log.add(name);
}

void main() {
  Future<FlameGame> makeGame({bool spatialIndex = true}) async {
    final world = World(spatialIndexEnabled: spatialIndex);
    final game = FlameGame(
      world: world,
      camera: CameraComponent(
        world: world,
        viewport: FixedSizeViewport(400, 300),
      ),
    )..onGameResize(Vector2(400, 300));
    await game.start();
    await game.ready();
    return game;
  }

  void renderOnce(FlameGame game) {
    final recorder = PictureRecorder();
    game.camera.renderTree(
      Canvas(recorder, const Rect.fromLTWH(0, 0, 400, 300)),
    );
    recorder.endRecording().dispose();
  }

  /// The names that a frame draws, with and without the spatial index, for
  /// the same scene and camera, so that the index can be checked against
  /// the plain traversal (which draws everything).
  Future<void> expectSameAsWithoutIndex(
    void Function(FlameGame game, List<String> log) build,
    List<void Function(FlameGame game)> steps,
  ) async {
    final indexed = await makeGame();
    final plain = await makeGame(spatialIndex: false);
    final indexedLog = <String>[];
    final plainLog = <String>[];
    build(indexed, indexedLog);
    build(plain, plainLog);
    await indexed.ready();
    await plain.ready();
    for (final step in [(FlameGame _) {}, ...steps]) {
      step(indexed);
      step(plain);
      await indexed.ready();
      await plain.ready();
      indexedLog.clear();
      plainLog.clear();
      renderOnce(indexed);
      renderOnce(plain);
      final visible = indexed.camera.cullWorldRect;
      final expected = [
        for (final name in plainLog)
          if (_touches(_boundsOf(indexed, name), visible)) name,
      ];
      expect(indexedLog, expected);
    }
  }

  group('WorldSpatialIndex entries', () {
    test(
      'a container draws only its visible children, in order, while they '
      'move in and out of view',
      () async {
        await expectSameAsWithoutIndex(
          (game, log) {
            game.world.add(
              Component(
                children: [
                  for (var i = 0; i < 16; i++)
                    _Leaf(
                      name: 'leaf$i',
                      log: log,
                      // Reverse priorities, so that the order of the grid is
                      // not the order of drawing.
                      priority: 16 - i,
                      position: Vector2(-600.0 + i * 80, -10),
                    ),
                ],
              ),
            );
          },
          [
            // Many visible, then few, then many again: the visible children
            // are kept in a list that is reused from frame to frame.
            for (final x in <double>[0, 300, 900, 1500, 600, 0, -400, -1500, 0])
              (game) => game.camera.viewfinder.position = Vector2(x, 0),
          ],
        );
      },
    );

    test('nested pure containers list each container once', () async {
      await expectSameAsWithoutIndex(
        (game, log) {
          game.world.add(
            Component(
              priority: 1,
              children: [
                for (var g = 0; g < 4; g++)
                  Component(
                    priority: 4 - g,
                    children: [
                      for (var i = 0; i < 5; i++)
                        _Leaf(
                          name: 'g${g}i$i',
                          log: log,
                          priority: i % 2,
                          position: Vector2(-500.0 + g * 250 + i * 30, i * 9),
                        ),
                    ],
                  ),
              ],
            ),
          );
        },
        [
          for (final x in <double>[0, 400, -400, 50])
            (game) => game.camera.viewfinder.position = Vector2(x, 0),
        ],
      );
    });

    test('a leaf that stays indexed across a membership change keeps being '
        'culled by its current bounds', () async {
      final game = await makeGame();
      final log = <String>[];
      final leaf = _Leaf(name: 'leaf', log: log, position: Vector2(-10, -10));
      final container = Component(children: [leaf]);
      game.world.add(container);
      await game.ready();
      renderOnce(game);
      final index = game.world.spatialIndex;
      expect(index.containsIndexed(leaf), isTrue);

      // An unrelated mount sweeps the membership again.
      game.world.add(Component());
      await game.ready();
      leaf.position.setValues(1000, 1000);
      log.clear();
      renderOnce(game);
      expect(log, isEmpty);
      expect(index.containsIndexed(leaf), isTrue);

      leaf.position.setValues(-10, -10);
      game.world.add(Component());
      await game.ready();
      log.clear();
      renderOnce(game);
      expect(log, ['leaf']);
    });

    test('a leaf that gets a child stops being a leaf, and becomes one again '
        'when the child is gone', () async {
      final game = await makeGame();
      final log = <String>[];
      final leaf = _Leaf(name: 'leaf', log: log, position: Vector2(-10, -10));
      game.world.add(Component(children: [leaf]));
      await game.ready();
      renderOnce(game);
      final index = game.world.spatialIndex;
      expect(index.containsIndexed(leaf), isTrue);

      final child = _Leaf(name: 'child', log: log, position: Vector2(2, 2));
      leaf.add(child);
      await game.ready();
      log.clear();
      renderOnce(game);
      expect(index.containsIndexed(leaf), isFalse);
      expect(index.containsIndexed(child), isTrue);
      expect(log, ['leaf', 'child']);

      child.removeFromParent();
      await game.ready();
      log.clear();
      renderOnce(game);
      expect(index.containsIndexed(leaf), isTrue);
      expect(index.containsIndexed(child), isFalse);
      expect(child.spatialIndexEntry, isNull);
      expect(log, ['leaf']);
    });

    test('a removed leaf leaves the index and the grid', () async {
      final game = await makeGame();
      final log = <String>[];
      final leaf = _Leaf(name: 'leaf', log: log, position: Vector2(-10, -10));
      game.world.add(Component(children: [leaf]));
      await game.ready();
      renderOnce(game);
      final index = game.world.spatialIndex;
      expect(index.indexedCount, 1);

      leaf.removeFromParent();
      await game.ready();
      renderOnce(game);
      expect(index.containsIndexed(leaf), isFalse);
      expect(index.indexedCount, 0);
      expect(leaf.spatialIndexEntry, isNull);
      final found = <PositionComponent>[];
      expect(
        index.queryRect(const Rect.fromLTWH(-50, -50, 100, 100), found),
        0,
      );
    });

    test('a leaf moved from a container to the world is measured where it is '
        'now', () async {
      final game = await makeGame();
      final log = <String>[];
      final leaf = _Leaf(name: 'leaf', log: log, position: Vector2(-10, -10));
      // The container is far away, so the leaf in it is off screen.
      final container = PositionComponent(
        position: Vector2(5000, 5000),
        children: [leaf],
      );
      game.world.add(container);
      await game.ready();
      renderOnce(game);
      expect(log, isEmpty);

      leaf.parent = game.world;
      await game.ready();
      log.clear();
      renderOnce(game);
      expect(log, ['leaf']);
      expect(game.world.spatialIndex.containsIndexed(leaf), isTrue);
    });

    test(
      'a leaf moved to the world of another game is indexed there',
      () async {
        final first = await makeGame();
        final log = <String>[];
        final leaf = _Leaf(name: 'leaf', log: log, position: Vector2(-10, -10));
        first.world.add(Component(children: [leaf]));
        await first.ready();
        renderOnce(first);

        final second = await makeGame();
        leaf.removeFromParent();
        await first.ready();
        second.world.add(Component(children: [leaf]));
        await second.ready();
        renderOnce(first);
        log.clear();
        renderOnce(second);
        expect(log, ['leaf']);
        expect(first.world.spatialIndex.containsIndexed(leaf), isFalse);
        expect(second.world.spatialIndex.containsIndexed(leaf), isTrue);
      },
    );

    test('mounts and removals that cannot change the membership leave it '
        'as a full sweep would find it', () async {
      final game = await makeGame();
      final log = <String>[];
      final random = Random(7);
      final index = game.world.spatialIndex;
      final containers = <Component>[];
      var names = 0;
      for (var i = 0; i < 4; i++) {
        final container = PositionComponent(position: Vector2(i * 40.0, 0));
        for (var j = 0; j < 3; j++) {
          container.add(
            _Leaf(
              name: 'leaf${names++}',
              log: log,
              position: Vector2(j * 25.0 - 150, i * 20.0 - 100),
            ),
          );
        }
        containers.add(container);
      }
      game.world.addAll(containers);
      await game.ready();
      renderOnce(game);

      List<Object> snapshot() {
        log.clear();
        renderOnce(game);
        return [
          ...log,
          for (final c in game.world.descendants())
            if (c is PositionComponent) index.containsIndexed(c),
        ];
      }

      final added = <Component>[];
      var skipped = 0;
      for (var step = 0; step < 120; step++) {
        final roll = random.nextInt(6);
        final pool = [
          for (final c in game.world.descendants())
            if (c is! World) c,
        ];
        final parent = pool[random.nextInt(pool.length)];
        if (roll == 0 && added.isNotEmpty) {
          added.removeAt(random.nextInt(added.length)).removeFromParent();
        } else if (roll == 1) {
          // A leaf, so a real change of the membership.
          final leaf = _Leaf(
            name: 'leaf${names++}',
            log: log,
            position: Vector2(random.nextDouble() * 300 - 150, 0),
          );
          parent.add(leaf);
          added.add(leaf);
        } else {
          // What effects and particle bursts look like to the index.
          final inert = roll.isEven
              ? Component()
              : PositionComponent(position: Vector2(3, 3));
          parent.add(inert);
          added.add(inert);
        }
        final sweeps = index.membershipSweepCount;
        await game.ready();
        final incremental = snapshot();
        if (index.membershipSweepCount == sweeps) {
          skipped++;
        }
        index.markMembershipDirty();
        final swept = snapshot();
        expect(incremental, swept, reason: 'step $step');
      }
      // Many of the steps did not sweep the membership.
      expect(skipped, greaterThan(20));
    });

    test('an effect on a container that is not pure needs no sweep, and an '
        'effect on a leaf does', () async {
      final game = await makeGame();
      final leaf = _Leaf(name: 'leaf', log: [], position: Vector2(-10, -10));
      final impure = PositionComponent(children: [Component()]);
      game.world.addAll([
        Component(children: [leaf]),
        impure,
      ]);
      await game.ready();
      renderOnce(game);
      final index = game.world.spatialIndex;
      final sweeps = index.membershipSweepCount;

      final onImpure = Component();
      impure.add(onImpure);
      await game.ready();
      renderOnce(game);
      expect(index.membershipSweepCount, sweeps);
      onImpure.removeFromParent();
      await game.ready();
      renderOnce(game);
      expect(index.membershipSweepCount, sweeps);

      leaf.add(Component());
      await game.ready();
      renderOnce(game);
      expect(index.membershipSweepCount, sweeps + 1);
      expect(index.containsIndexed(leaf), isFalse);
    });

    test('removing the child that kept a container from being pure makes it '
        'pure again', () async {
      final game = await makeGame();
      final log = <String>[];
      final inert = Component();
      final container = Component(
        children: [
          _Leaf(name: 'leaf', log: log, position: Vector2(-10, -10)),
          inert,
        ],
      );
      game.world.add(container);
      await game.ready();
      renderOnce(game);
      expect(container.spatialIndexEntry, isNull);

      inert.removeFromParent();
      await game.ready();
      log.clear();
      renderOnce(game);
      expect(container.spatialIndexEntry, isNotNull);
      expect(log, ['leaf']);
    });

    test('clearing the index takes its entries off the components', () async {
      final game = await makeGame();
      final leaf = _Leaf(name: 'leaf', log: [], position: Vector2(-10, -10));
      final container = Component(children: [leaf]);
      game.world.add(container);
      await game.ready();
      renderOnce(game);
      expect(leaf.spatialIndexEntry, isNotNull);
      expect(container.spatialIndexEntry, isNotNull);

      game.world.spatialIndexEnabled = false;
      expect(leaf.spatialIndexEntry, isNull);
      expect(container.spatialIndexEntry, isNull);
    });
  });
}

/// Whether [a] and [b] overlap or touch, which is how the grid of the index
/// compares bounds.
bool _touches(Rect a, Rect b) =>
    a.right >= b.left &&
    a.left <= b.right &&
    a.bottom >= b.top &&
    a.top <= b.bottom;

/// The world bounds of the leaf called [name].
Rect _boundsOf(FlameGame game, String name) {
  final leaf = game.world.descendants().whereType<_Leaf>().firstWhere(
    (leaf) => leaf.name == name,
  );
  return leaf.toAbsoluteRect();
}
