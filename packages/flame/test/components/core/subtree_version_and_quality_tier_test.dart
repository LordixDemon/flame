import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _Panel(
  final String name,
  final List<String> order, {
  super.minQualityTier,
}) extends PositionComponent {
  this : super(position: Vector2(10, 10), size: Vector2(40, 40));

  int updates = 0;

  @override
  void update(double dt) => updates++;

  @override
  void render(ui.Canvas canvas) => order.add(name);
}

void _pumpRender(FlameGame game) {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder, const ui.Rect.fromLTWH(0, 0, 400, 300));
  game.render(canvas);
  game.onFrameRendered();
  recorder.endRecording().dispose();
}

Future<(FlameGame, CameraComponent)> _retainedGame() async {
  final world = World();
  final camera = CameraComponent.withFixedResolution(
    width: 400,
    height: 300,
    world: world,
    layerCacheMode: CameraLayerCacheMode.splitRetained,
  );
  final game = FlameGame(world: world, camera: camera);
  game.onGameResize(Vector2(400, 300));
  await game.start();
  addTearDown(game.onRemove);
  return (game, camera);
}

void main() {
  group('Component.subtreeVersion', () {
    test('a sortKey change re-records the retained HUD layer', () async {
      final (game, camera) = await _retainedGame();
      final order = <String>[];
      final a = _Panel('a', order);
      final b = _Panel('b', order);
      camera.viewport.addAll([a, b]);
      await game.ready();
      game.update(1 / 60);
      _pumpRender(game);
      expect(order, ['a', 'b']);

      order.clear();
      a.sortKey = 5;
      game.update(1 / 60);
      _pumpRender(game);

      expect(order, ['b', 'a']);
    });

    test('a priority change re-records the retained HUD layer', () async {
      final (game, camera) = await _retainedGame();
      final order = <String>[];
      final a = _Panel('a', order);
      final b = _Panel('b', order);
      camera.viewport.addAll([a, b]);
      await game.ready();
      game.update(1 / 60);
      _pumpRender(game);
      expect(order, ['a', 'b']);
      final versionBefore = camera.viewport.subtreeVersion;

      order.clear();
      a.priority = 5; // bring "a" to the front
      game.update(1 / 60);
      expect(camera.viewport.children.toList(), [b, a]);
      _pumpRender(game);

      expect(order, ['b', 'a']);
      expect(camera.viewport.subtreeVersion, greaterThan(versionBefore));
    });

    test('a priority change that keeps the order is not a mutation', () async {
      final (game, camera) = await _retainedGame();
      final order = <String>[];
      final a = _Panel('a', order);
      final b = _Panel('b', order);
      camera.viewport.addAll([a, b]);
      await game.ready();
      game.update(1 / 60);
      _pumpRender(game);
      final versionBefore = camera.viewport.subtreeVersion;

      b.priority = 3; // b already draws last
      game.update(1 / 60);

      expect(camera.viewport.children.toList(), [a, b]);
      expect(camera.viewport.subtreeVersion, versionBefore);
    });

    test('a minQualityTier change re-records the retained HUD layer', () async {
      final (game, camera) = await _retainedGame();
      final order = <String>[];
      final a = _Panel('a', order);
      camera.viewport.add(a);
      await game.ready();
      game.update(1 / 60);
      _pumpRender(game);
      expect(order, ['a']);

      order.clear();
      a.minQualityTier = GraphicsQualityTier.ultra;
      game.update(1 / 60);
      _pumpRender(game);
      expect(order, isEmpty, reason: 'gated out and the layer was re-recorded');

      a.minQualityTier = null;
      game.update(1 / 60);
      _pumpRender(game);
      expect(order, ['a']);
    });
  });

  group('Component.minQualityTier', () {
    testWithFlameGame(
      'a component gated out by the graphics tier is not hit-testable',
      (game) async {
        expect(game.graphics.tier, GraphicsQualityTier.high);
        final order = <String>[];
        final fancy = _Panel(
          'fancy',
          order,
          minQualityTier: GraphicsQualityTier.ultra,
        );
        final plain = _Panel('plain', order);
        game.camera.viewport.addAll([plain, fancy]);
        await game.ready();

        game.update(1 / 60);
        _pumpRender(game);
        expect(fancy.updates, 0);
        expect(order, ['plain']);

        final hits = game.componentsAtPoint(Vector2(30, 30)).toList();
        expect(hits, isNot(contains(fancy)));
        expect(hits, contains(plain));
      },
    );

    testWithFlameGame(
      'the subtree of a gated component is not hit-testable either',
      (game) async {
        final order = <String>[];
        final gate = Component(minQualityTier: GraphicsQualityTier.ultra);
        final inner = _Panel('inner', order);
        gate.add(inner);
        game.camera.viewport.add(gate);
        await game.ready();

        expect(
          game.componentsAtPoint(Vector2(30, 30)),
          isNot(contains(inner)),
        );
      },
    );

    testWithFlameGame(
      'a component whose tier is met is hit-testable',
      (game) async {
        final order = <String>[];
        final medium = _Panel(
          'medium',
          order,
          minQualityTier: GraphicsQualityTier.medium,
        );
        game.camera.viewport.add(medium);
        await game.ready();

        expect(game.componentsAtPoint(Vector2(30, 30)), contains(medium));
      },
    );
  });
}
