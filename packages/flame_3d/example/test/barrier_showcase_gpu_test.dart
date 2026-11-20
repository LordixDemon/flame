import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d_example/barrier/barrier_game.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final gpuAvailable = GpuBackend.isAvailable;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (gpuAvailable) {
      await GpuBackend.initialize();
    }
  });

  testWidgets(
    'BarrierGame raises the barrier, hits it, lowers it and splashes',
    (tester) async {
      // A phone in landscape.
      tester.view
        ..physicalSize = const ui.Size(844, 390)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final game = BarrierGame(showStats: false);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: GameWidget(game: game),
        ),
      );
      await tester.pump();
      expect(game.isLoaded, isTrue);
      final scene = game.scene;

      var time = 0.0;
      Future<void> playUntil(double until) async {
        while (time < until) {
          await tester.pump(const Duration(microseconds: 33333));
          time += 1 / 30;
        }
      }

      Future<Uint8List> pixels() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        return (await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData();
          image.dispose();
          return data!.buffer.asUint8List();
        }))!;
      }

      // The sum of the channels around the far wall, a little above the rim.
      final wallPoint = game.camera.localToGlobal(
        scene.layer.positionOf(
          scene.layer.scenePointToLocal(
            Vector3(-2.7, -2.7, BarrierScene.platformTop + 0.25),
          ),
        ),
      );
      int lightAtWall(Uint8List rgba) {
        var sum = 0;
        for (var dy = -3; dy <= 3; dy++) {
          for (var dx = -3; dx <= 3; dx++) {
            final x = wallPoint.x.round() + dx;
            final y = wallPoint.y.round() + dy;
            final i = (y * 844 + x) * 4;
            sum += rgba[i] + rgba[i + 1] + rgba[i + 2];
          }
        }
        return sum;
      }

      // The platform rises with water running off its edges.
      await playUntil(0.9);
      expect(scene.drips.particleCount, greaterThan(0));
      expect(scene.barrier.appear, 0);
      final before = lightAtWall(await pixels());

      // The barrier is up and has been hit.
      await playUntil(2.45);
      expect(scene.barrier.appear, 1);
      expect(scene.barrier.activeImpactCount, 1);
      final raised = lightAtWall(await pixels());
      expect(raised, greaterThan(before + 49 * 60));

      // Hit twice more, then lowered: nothing of it is drawn.
      await playUntil(3.4);
      expect(scene.barrier.activeImpactCount, greaterThanOrEqualTo(2));
      final drawsUp = scene.layer.renderStats.drawCalls;
      await playUntil(4.8);
      expect(scene.barrier.appear, 0);
      expect(scene.layer.renderStats.drawCalls, drawsUp - 1);
      expect(lightAtWall(await pixels()), closeTo(before, 49 * 6));

      // A block drops into the water: a splash.
      await playUntil(5.6);
      expect(scene.crown.particleCount, greaterThan(0));
      expect(scene.foam.particleCount, greaterThan(0));
      expect(scene.mist.particleCount, greaterThan(0));
      expect(scene.layer.renderStats.particles, greaterThan(0));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
    skip: !gpuAvailable,
  );
}
