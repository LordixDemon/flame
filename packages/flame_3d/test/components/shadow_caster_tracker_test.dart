// The tracker is internal: it is what ShadowSettings.cacheStillCasters
// relies on to tell still casters from moving ones.

import 'package:flame/game.dart' show FlameGame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _Box() extends Object3D {
  @override
  Aabb3? computeLocalAabb() =>
      Aabb3.minMax(Vector3.all(-0.5), Vector3.all(0.5));

  @override
  void draw(RenderContext context) {}
}

class _Group({super.children}) extends Component3D;

FlameGame _game() => FlameGame(world: World3D());

void main() {
  group('ShadowCasterTracker', () {
    late World3D world;
    late ShadowCasterTracker casters;

    /// One render of the shadows, keeping casters still after 3 renders.
    void render() {
      casters
        ..prepare(3)
        ..advance();
    }

    Future<List<_Box>> mount(FlameGame game, int count) async {
      world = game.world as World3D;
      casters = world.shadowCasters;
      final boxes = [for (var i = 0; i < count; i++) _Box()];
      await world.ensureAddAll(boxes);
      return boxes;
    }

    testWithGame(
      'new casters move; they join the still ones once none '
      'changed for stillCasterFrames renders',
      _game,
      (game) async {
        final [a, b] = await mount(game, 2);
        render();
        expect(casters.isStill(a), isFalse);
        final version = casters.version;
        render();
        render();
        expect(casters.version, version);
        render();
        expect(casters.version, version + 1);
        expect(casters.isStill(a), isTrue);
        expect(casters.isStill(b), isTrue);
      },
    );

    testWithGame(
      'a still caster that moves, hides or leaves renders the '
      'layer again; a moving one does not',
      _game,
      (game) async {
        final [a, b, c, d] = await mount(game, 4);
        for (var i = 0; i < 4; i++) {
          render();
        }
        expect(casters.isStill(a), isTrue);

        var version = casters.version;
        a.position.x = 1;
        expect(casters.version, version + 1);
        expect(casters.isStill(a), isFalse);
        expect(casters.isStill(b), isTrue);

        // A moving caster moves again, or leaves: the layer stays.
        version = casters.version;
        a.position.x = 2;
        a.removeFromParent();
        await game.ready();
        expect(casters.version, version);

        b.visible = false;
        expect(casters.version, version + 1);
        b.visible = true;
        expect(casters.isStill(b), isFalse);
        expect(casters.version, version + 1);

        c.removeFromParent();
        await game.ready();
        expect(casters.version, version + 2);

        d.castsShadows = false;
        expect(casters.version, version + 3);
        expect(casters.isStill(d), isFalse);
      },
    );

    testWithGame('a group that moves moves the casters in it', _game, (
      game,
    ) async {
      world = game.world as World3D;
      casters = world.shadowCasters;
      final inside = _Box();
      final group = _Group(children: [inside]);
      final outside = _Box();
      await world.ensureAddAll([group, outside]);
      await game.ready();
      for (var i = 0; i < 4; i++) {
        render();
      }
      expect(casters.isStill(inside), isTrue);
      group.position.y = 1;
      expect(casters.isStill(inside), isFalse);
      expect(casters.isStill(outside), isTrue);
    });

    testWithGame(
      'changes reported with markDrawDirty: an object moves; '
      'other components and the world render the layer again',
      _game,
      (
        game,
      ) async {
        final [a, b] = await mount(game, 2);
        final group = _Group();
        await world.ensureAdd(group);
        for (var i = 0; i < 4; i++) {
          render();
        }
        var version = casters.version;
        a.markDrawDirty(shadows: false);
        expect(casters.version, version);
        expect(casters.isStill(a), isTrue);
        a.markDrawDirty();
        expect(casters.version, version + 1);
        expect(casters.isStill(a), isFalse);

        version = casters.version;
        group.markDrawDirty();
        expect(casters.version, version + 1);
        world.markSceneDirty(shadows: false);
        expect(casters.version, version + 1);
        world.markShadowsDirty();
        expect(casters.version, version + 2);
        expect(casters.isStill(b), isTrue);
      },
    );

    testWithGame(
      'casters drawn as moving ones that stopped join the still '
      'ones while others keep moving',
      _game,
      (game) async {
        final [a, b, c] = await mount(game, 3);
        for (var i = 0; i < 4; i++) {
          render();
        }
        a.position.x = 1;
        b.position.x = 1;
        render();
        for (var i = 0; i < 3; i++) {
          b.position.x += 1;
          casters.drawnMoving(a);
          casters.drawnMoving(b);
          render();
        }
        final version = casters.version;
        casters.drawnMoving(a);
        render();
        expect(casters.version, version + 1);
        expect(casters.isStill(a), isTrue);
        expect(casters.isStill(b), isFalse);
        expect(casters.isStill(c), isTrue);
      },
    );

    testWithGame('Object3D.shadowMotion overrides the tracking', _game, (
      game,
    ) async {
      final [a, b] = await mount(game, 2);
      render();
      var version = casters.version;
      a.shadowMotion = ShadowCasterMotion.still;
      expect(casters.version, version + 1);
      expect(casters.isStill(a), isTrue);
      version = casters.version;
      a.position.z = 1;
      expect(casters.isStill(a), isTrue);
      expect(casters.version, version + 1);

      b.shadowMotion = ShadowCasterMotion.moving;
      expect(casters.alwaysMoving, 1);
      for (var i = 0; i < 5; i++) {
        render();
      }
      expect(casters.isStill(b), isFalse);
      b.removeFromParent();
      await game.ready();
      expect(casters.alwaysMoving, 0);

      final mesh = MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)))
        ..shadowMotion = ShadowCasterMotion.moving;
      final copy = mesh.clone() as MeshComponent;
      expect(copy.shadowMotion, ShadowCasterMotion.moving);
    });

    test('ShadowSettings.stillCasterFrames is at least 1', () {
      expect(ShadowSettings().stillCasterFrames, 30);
      expect(ShadowSettings().cacheStillCasters, isFalse);
      expect(
        () => ShadowSettings(stillCasterFrames: 0),
        throwsArgumentError,
      );
    });
  });
}
