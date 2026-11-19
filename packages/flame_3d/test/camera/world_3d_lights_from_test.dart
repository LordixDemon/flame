import 'dart:ui' show Color;

import 'package:flame/game.dart' show FlameGame, Game;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

/// A game holding two worlds side by side, `lender` and `borrower`.
class _Worlds() extends FlameGame {
  final World3D lender = World3D();
  final World3D borrower = World3D();

  @override
  void onLoad() {
    world.addAll([lender, borrower]);
  }
}

_Worlds _game() => _Worlds();

/// Records the versions of [world] and [Game.visualMutationCount], to tell
/// what a change bumped.
class _Versions(final World3D world) {
  int scene = world.sceneVersion;
  int casters = world.castersVersion;
  int mutations = Game.visualMutationCount;

  ({bool scene, bool casters, bool woke}) take() {
    final result = (
      scene: world.sceneVersion != scene,
      casters: world.castersVersion != casters,
      woke: Game.visualMutationCount != mutations,
    );
    scene = world.sceneVersion;
    casters = world.castersVersion;
    mutations = Game.visualMutationCount;
    return result;
  }
}

const _nothing = (scene: false, casters: false, woke: false);
const _sceneOnly = (scene: true, casters: false, woke: true);
const _sceneAndShadows = (scene: true, casters: true, woke: true);

void main() {
  group('World3D.lightsFrom', () {
    testWithGame(
      'the borrower renders with the lent lights, then its own',
      _game,
      (
        game,
      ) async {
        final sun = LightComponent.directional(direction: Vector3(0, -1, 0));
        final fill = LightComponent.ambient();
        await game.lender.ensureAddAll([sun, fill]);
        final own = LightComponent.point(position: Vector3(1, 2, 3));

        expect(game.borrower.lights, isEmpty);
        game.borrower.lightsFrom = game.lender;
        expect(game.borrower.lightsFrom, same(game.lender));
        expect(game.borrower.lights, [sun.light, fill.light]);

        await game.borrower.ensureAdd(own);
        expect(game.borrower.lights, [sun.light, fill.light, own.light]);
        // The lender keeps its own lights.
        expect(game.lender.lights, [sun.light, fill.light]);

        fill.removeFromParent();
        await game.ready();
        expect(game.borrower.lights, [sun.light, own.light]);

        game.borrower.lightsFrom = null;
        expect(game.borrower.lights, [own.light]);
        expect(
          () => game.borrower.lights.add(sun.light),
          throwsUnsupportedError,
        );
      },
    );

    testWithGame('lent light changes reach the borrower versions', _game, (
      game,
    ) async {
      final sun = LightComponent.directional(
        direction: Vector3(0, -1, 0),
        shadows: ShadowSettings(),
      );
      final lamp = LightComponent.point(position: Vector3(1, 1, 1));
      final holder = MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)));
      final carried = LightComponent.point();
      await game.lender.ensureAddAll([sun, lamp, holder]);
      await holder.ensureAdd(carried);
      game.borrower.lightsFrom = game.lender;
      final versions = _Versions(game.borrower);

      // A sun with shadows moves the shadows; a lamp without does not.
      sun.source.color = const Color(0xFF00FF00);
      expect(versions.take(), _sceneOnly);
      (sun.source as DirectionalLight).direction = Vector3(1, -1, 0);
      expect(versions.take(), _sceneAndShadows);
      lamp.position.x = 4;
      expect(versions.take(), _sceneOnly);
      sun.position.x = 2;
      expect(versions.take(), _sceneAndShadows);
      lamp.lightMask = 0x2;
      expect(versions.take(), _sceneOnly);
      lamp.source.markChanged(shadows: false);
      expect(versions.take(), _sceneOnly);

      // A light carried by a moving component moves with it.
      holder.position.y = 3;
      expect(versions.take().scene, isTrue);

      // Lights joining and leaving.
      final extra = LightComponent.ambient();
      await game.lender.ensureAdd(extra);
      expect(versions.take(), _sceneAndShadows);
      extra.removeFromParent();
      await game.ready();
      expect(versions.take(), _sceneAndShadows);

      // The other changes of the lender stay in the lender.
      final lenderVersions = _Versions(game.lender);
      final mesh = MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)));
      await game.lender.ensureAdd(mesh);
      mesh.position.x = 5;
      mesh.color = const Color(0xFFFF0000);
      game.lender.fog = FogSettings();
      expect(lenderVersions.take().scene, isTrue);
      expect(versions.take(), (scene: false, casters: false, woke: true));

      // A light changed in place is reported on its source, as without
      // borrowing.
      (sun.source as DirectionalLight).direction!.x = 0.5;
      expect(versions.take(), _nothing);
      sun.source.markChanged();
      expect(versions.take(), _sceneAndShadows);
    });

    testWithGame('another lender keeps the versions increasing', _game, (
      game,
    ) async {
      final other = World3D();
      await game.world.ensureAdd(other);
      // Make the two lenders' light versions far apart.
      final busy = LightComponent.point();
      await game.lender.ensureAdd(busy);
      for (var i = 0; i < 20; i++) {
        busy.position.x = i.toDouble();
      }
      expect(game.lender.lightsVersion, greaterThan(other.lightsVersion + 10));

      game.borrower.lightsFrom = game.lender;
      final versions = <int>[game.borrower.sceneVersion];
      final casters = <int>[game.borrower.castersVersion];
      for (final lender in [other, game.lender, null, other]) {
        game.borrower.lightsFrom = lender;
        versions.add(game.borrower.sceneVersion);
        casters.add(game.borrower.castersVersion);
      }
      for (var i = 1; i < versions.length; i++) {
        expect(versions[i], greaterThan(versions[i - 1]));
        expect(casters[i], greaterThan(casters[i - 1]));
      }
    });

    testWithGame(
      'a world borrows from one lender that does not borrow',
      _game,
      (
        game,
      ) async {
        final third = World3D();
        await game.world.ensureAdd(third);
        expect(
          () => game.lender.lightsFrom = game.lender,
          throwsArgumentError,
        );
        game.borrower.lightsFrom = game.lender;
        // Chains are refused both ways.
        expect(() => third.lightsFrom = game.borrower, throwsArgumentError);
        expect(() => game.lender.lightsFrom = third, throwsStateError);
        // Two borrowers of one lender are fine.
        third.lightsFrom = game.lender;
        expect(third.lightsFrom, same(game.lender));
        // Once nobody borrows from it, the lender may borrow.
        game.borrower.lightsFrom = null;
        third.lightsFrom = null;
        game.lender.lightsFrom = third;
        expect(game.lender.lightsFrom, same(third));
      },
    );

    testWithGame(
      'an unmounted lender lends nothing until mounted again',
      _game,
      (
        game,
      ) async {
        final sun = LightComponent.directional(direction: Vector3(0, -1, 0));
        final own = LightComponent.ambient();
        await game.lender.ensureAdd(sun);
        await game.borrower.ensureAdd(own);
        game.borrower.lightsFrom = game.lender;
        final versions = _Versions(game.borrower);

        game.lender.removeFromParent();
        await game.ready();
        expect(game.borrower.lights, [own.light]);
        expect(versions.take(), _sceneAndShadows);
        expect(game.borrower.lightsFrom, same(game.lender));

        await game.world.ensureAdd(game.lender);
        expect(game.borrower.lights, [sun.light, own.light]);
        expect(versions.take(), _sceneAndShadows);
      },
    );

    test('the lights of unmounted worlds are gathered for a snapshot', () {
      // Only the lists: a snapshot gathers the lights of an unmounted world
      // and of its unmounted lender while it renders.
      final lender = World3D(
        children: [LightComponent.directional(direction: Vector3(0, 0, -1))],
      );
      final borrower = World3D(children: [LightComponent.ambient()])
        ..lightsFrom = lender;
      expect(borrower.lights, isEmpty);
      final seen = <int>[];
      borrower.debugGatherLights(() => seen.add(borrower.lights.length));
      expect(seen, [2]);
      expect(borrower.lights, isEmpty);
      expect(lender.lights, isEmpty);
    });
  });
}

extension on World3D {
  /// Runs [body] while the lights are gathered as for a snapshot.
  void debugGatherLights(void Function() body) {
    final backend = FakeGpuBackend();
    final device = GraphicsDevice(backend: backend);
    renderWithHost(device, RenderContext3D(device), body);
  }
}
