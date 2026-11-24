import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

void main() {
  setUpGpu();

  testGpu(
    'StaticSceneCache3D preserves depth occlusion and moving-caster shadows '
    'matching uncached rendering',
    (tester) async {
      Future<({Pixels pixels, Pixels occludedPixels, int hits})> runScene({
        required bool enableStaticCache,
      }) async {
        final floor = MeshComponent(
          mesh: PlaneMesh(
            size: Vector2(12, 12),
            material: StylizedMaterial(
              albedoColor: const Color(0xFFD8D0C0),
              windAmplitude: 0,
            ),
          ),
          castsShadows: false,
        );
        final wall = MeshComponent(
          position: Vector3(0, 0.8, -1.5),
          mesh: CuboidMesh(
            size: Vector3(2.4, 1.6, 0.4),
            material: StylizedMaterial(
              albedoColor: const Color(0xFF4060A0),
              windAmplitude: 0,
            ),
          ),
        );
        final mover =
            MeshComponent(
                position: Vector3(-2.0, 0.6, 0.5),
                mesh: CuboidMesh(
                  size: Vector3.all(0.9),
                  material: StylizedMaterial(
                    albedoColor: const Color(0xFFD04040),
                    windAmplitude: 0,
                  ),
                ),
              )
              ..sceneCacheMotion = SceneCacheMotion.dynamic
              ..shadowMotion = ShadowCasterMotion.moving;
        final world = World3D(
          staticSceneCache: enableStaticCache
              ? StaticSceneCacheSettings(stillFrames: 1)
              : null,
          children: [
            LightComponent.directional(
              direction: Vector3(0.45, -1.0, 0.35),
              intensity: 1.4,
              shadows: ShadowSettings(
                resolution: 512,
                cacheStillCasters: true,
                stillCasterFrames: 2,
              ),
            ),
            LightComponent.ambient(intensity: 0.35),
            floor,
            wall,
            mover,
          ],
        );
        final camera = CameraComponent3D(
          position: Vector3(0, 3.8, 5.5),
          target: Vector3(0, 0.4, -0.5),
        );
        final game = FlameGame3D(world: world, camera: camera);
        // Frame batch 1: dynamic cube in front of wall casting moving shadow.
        await renderGame(tester, game);
        mover.position.setValues(0.2, 0.6, 0.8);
        final frontPx = await renderGame(tester, game);
        final frontHits = game.device.lastFrameStats.staticCacheHits;
        // Frame batch 2: dynamic cube moved behind the blue wall (occluded).
        mover.position.setValues(0.0, 0.5, -3.2);
        final backPx = await renderGame(tester, game, frames: 2);
        return (
          pixels: frontPx,
          occludedPixels: backPx,
          hits: frontHits + game.device.lastFrameStats.staticCacheHits,
        );
      }

      final uncached = await runScene(enableStaticCache: false);
      final cached = await runScene(enableStaticCache: true);

      expect(cached.hits, greaterThanOrEqualTo(2));
      expect(
        differingPixels(cached.pixels, uncached.pixels, tolerance: 20),
        lessThan(220),
        reason: 'Cached restore + moving shadow diverged too far from uncached',
      );
      expect(
        differingPixels(
          cached.occludedPixels,
          uncached.occludedPixels,
          tolerance: 20,
        ),
        lessThan(220),
        reason: 'Static depth occlusion diverged too far from uncached',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
