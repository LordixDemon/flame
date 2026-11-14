import 'package:flame/canvas3d.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

class _SpatialTower({
  required this.minZ,
  required this.maxZ,
  bool occludeBehind = false,
}) extends PositionComponent with SpatialHitbox3D, HoverCallbacks {
  final double minZ;
  final double maxZ;
  int enterCount = 0;
  int exitCount = 0;

  this : super(size: Vector2.zero()) {
    stopHoverPropagation = occludeBehind;
  }

  @override
  double? intersectRay3D(Ray3D ray) {
    return Raycaster3D.intersectAabbDistance(
      ray,
      minX: -25,
      minY: -25,
      minZ: minZ,
      maxX: 25,
      maxY: 25,
      maxZ: maxZ,
    );
  }

  @override
  void onHoverEnter() {
    enterCount++;
  }

  @override
  void onHoverExit() {
    exitCount++;
  }
}

void main() {
  group('3D Hover Occlusion & Coalesced MouseMoveDispatcher', () {
    test(
      'HoverCallbacks works on zero-size 3D components and foreground '
      'stopHoverPropagation occludes background structures',
      () async {
        final game = FlameGame()..onGameResize(Vector2(800, 600));
        await game.start();

        // Orthographic-like top-down ray along -Z at world (x, y, z=100).
        game.camera.rayProjector3D = (viewportPt, worldPt) => Ray3D(
          ox: worldPt.x,
          oy: worldPt.y,
          oz: 100,
          dx: 0,
          dy: 0,
          dz: -1,
        );

        final frontTower = _SpatialTower(
          minZ: 40,
          maxZ: 80,
          occludeBehind: true,
        );
        final rearTower = _SpatialTower(
          minZ: 0,
          maxZ: 30,
        );
        game.world.addAll([rearTower, frontTower]);
        await game.ready();

        // Screen center (400, 300) maps to world (0, 0) where both AABBs
        // overlap along the ray, with frontTower closer (t = 20 vs t = 70).
        game.mouseDetector!(
          const PointerHoverEvent(position: Offset(400, 300)),
        );

        expect(frontTower.isHovered, isTrue);
        expect(frontTower.enterCount, 1);
        expect(rearTower.isHovered, isFalse);
        expect(rearTower.enterCount, 0);

        // Move off both towers -> frontTower exits cleanly.
        game.mouseDetector!(
          const PointerHoverEvent(position: Offset(100, 100)),
        );
        expect(frontTower.isHovered, isFalse);
        expect(frontTower.exitCount, 1);
      },
    );

    test(
      'coalesceMouseHover collapses bursts of OS hover events into 1 raycast '
      'per game.update tick',
      () async {
        var raycastCalls = 0;
        final game = FlameGame()
          ..coalesceMouseHover = true
          ..onGameResize(Vector2(800, 600));
        await game.start();

        game.camera.rayProjector3D = (viewportPt, worldPt) {
          raycastCalls++;
          return Ray3D(
            ox: worldPt.x,
            oy: worldPt.y,
            oz: 100,
            dx: 0,
            dy: 0,
            dz: -1,
          );
        };

        final tower = _SpatialTower(minZ: 0, maxZ: 40);
        game.world.add(tower);
        await game.ready();

        final dispatcher = game.findByKey<MouseMoveDispatcher>(
          const MouseMoveDispatcherKey(),
        )!;

        // Simulate 25 1000Hz gaming-mouse hover packets arriving between frames
        for (var i = 0; i < 25; i++) {
          game.mouseDetector!(
            PointerHoverEvent(
              position: Offset(388.0 + i * 0.5, 294.0 + i * 0.25),
            ),
          );
        }

        expect(dispatcher.rawHoverEventsReceived, 25);
        expect(dispatcher.dispatchCount, 0);
        expect(raycastCalls, 0);
        expect(tower.isHovered, isFalse);

        // Single frame tick flushes only the latest coalesced hover position.
        game.update(1 / 60);
        expect(dispatcher.dispatchCount, 1);
        expect(raycastCalls, 1);
        expect(tower.isHovered, isTrue);
      },
    );
  });
}
