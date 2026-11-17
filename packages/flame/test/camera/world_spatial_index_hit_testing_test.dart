import 'package:flame/camera.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _TappablePanel({super.position, super.size, super.children})
    extends PositionComponent
    with TapCallbacks;

/// A plain container type of the application, which may or may not have a
/// hit area of its own.
class _CatchAllLayer({super.children}) extends Component with TapCallbacks {
  @override
  bool containsLocalPoint(Vector2 point) => true;
}

class _Leaf({super.position, super.size}) extends PositionComponent;

void main() {
  Future<FlameGame> makeGame(
    List<Component> worldChildren, {
    required bool spatialIndex,
  }) async {
    final world = World(spatialIndexEnabled: spatialIndex);
    final game = FlameGame(
      world: world,
      camera: CameraComponent(
        world: world,
        viewport: FixedSizeViewport(400, 300),
      ),
    )..onGameResize(Vector2(400, 300));
    await game.start();
    world.addAll(worldChildren);
    await game.ready();
    return game;
  }

  // Canvas (250, 200) is world (50, 50).
  final tap = Vector2(250, 200);

  group('WorldSpatialIndex hit-testing', () {
    for (final spatialIndex in [false, true]) {
      final mode = spatialIndex ? 'with' : 'without';

      test('a container with a hit area of its own is hit away from its '
          'children ($mode the index)', () async {
        // 200x200 tappable panel with one small icon in its corner.
        final panel = _TappablePanel(
          position: Vector2(-100, -100),
          size: Vector2(200, 200),
          children: [_Leaf(position: Vector2(4, 4), size: Vector2(10, 10))],
        );
        final game = await makeGame([panel], spatialIndex: spatialIndex);

        final hits = game.componentsAtPoint(tap).toList();
        expect(hits, contains(panel));
        expect(hits.whereType<_Leaf>(), isEmpty);
      });

      test('a tappable panel nested in a plain layer is hit '
          '($mode the index)', () async {
        final panel = _TappablePanel(
          position: Vector2(-100, -100),
          size: Vector2(200, 200),
          children: [_Leaf(position: Vector2(4, 4), size: Vector2(10, 10))],
        );
        final game = await makeGame(
          [
            Component(children: [panel]),
          ],
          spatialIndex: spatialIndex,
        );

        expect(game.componentsAtPoint(tap), contains(panel));
      });

      test('a container subclass that overrides containsLocalPoint is hit '
          '($mode the index)', () async {
        final layer = _CatchAllLayer(
          children: [
            _Leaf(position: Vector2(-150, -100), size: Vector2.all(10)),
          ],
        );
        final game = await makeGame([layer], spatialIndex: spatialIndex);

        expect(game.componentsAtPoint(tap), contains(layer));
      });

      test('a leaf inside a plain layer is hit on its box only '
          '($mode the index)', () async {
        final leaf = _Leaf(position: Vector2(40, 40), size: Vector2(20, 20));
        final other = _Leaf(
          position: Vector2(-150, -100),
          size: Vector2(20, 20),
        );
        final game = await makeGame(
          [
            Component(children: [leaf, other]),
          ],
          spatialIndex: spatialIndex,
        );

        final hits = game.componentsAtPoint(tap).toList();
        expect(hits, contains(leaf));
        expect(hits, isNot(contains(other)));
        expect(game.componentsAtPoint(Vector2(10, 10)), isNot(contains(leaf)));
      });
    }

    test(
      'plain layers of leaves are still skipped away from their leaves',
      () async {
        final layer = Component(
          children: [
            _Leaf(position: Vector2(-150, -100), size: Vector2.all(10)),
          ],
        );
        final group = SpatialCullGroup(
          children: [
            _Leaf(position: Vector2(-150, 100), size: Vector2.all(10)),
          ],
        );
        final game = await makeGame([layer, group], spatialIndex: true);

        final candidates = <Component>[];
        game.world.spatialIndex
          ..syncWithChildren(game.world.children)
          ..collectCandidatesAtPoint(50, 50, candidates);
        expect(candidates, isEmpty);

        game.world.spatialIndex.collectCandidatesAtPoint(-145, -95, candidates);
        expect(candidates, [layer]);
      },
    );
  });
}
