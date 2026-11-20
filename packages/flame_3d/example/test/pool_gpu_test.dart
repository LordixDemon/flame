import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d_example/pool/pool_game.dart';
import 'package:flame_3d_example/pool/pool_scene.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pixels of a frame, RGBA.
typedef _Pixels = ({int width, int height, Uint8List rgba});

void main() {
  final gpuAvailable = GpuBackend.isAvailable;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (gpuAvailable) {
      await GpuBackend.initialize();
    }
  });

  testWidgets(
    'the pool renders its water in one draw, at noon and at dusk, with '
    'slabs rising out of it',
    (tester) async {
      tester.view
        ..physicalSize = const ui.Size(844, 390)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final game = PoolGame(autoPlay: false);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: GameWidget(game: game),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));

      Future<_Pixels> frame() async {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        return (await tester.runAsync(() async {
          final image = await boundary.toImage();
          final data = await image.toByteData();
          final pixels = (
            width: image.width,
            height: image.height,
            rgba: data!.buffer.asUint8List(),
          );
          image.dispose();
          return pixels;
        }))!;
      }

      int differing(_Pixels a, _Pixels b) {
        var count = 0;
        for (var i = 0; i < a.rgba.length; i += 4) {
          if ((a.rgba[i] - b.rgba[i]).abs() > 8 ||
              (a.rgba[i + 1] - b.rgba[i + 1]).abs() > 8 ||
              (a.rgba[i + 2] - b.rgba[i + 2]).abs() > 8) {
            count++;
          }
        }
        return count;
      }

      /// The pixels where blue clearly dominates red: water.
      int water(_Pixels p) {
        var count = 0;
        for (var i = 0; i < p.rgba.length; i += 4) {
          if (p.rgba[i + 2] > p.rgba[i] + 40) {
            count++;
          }
        }
        return count;
      }

      game.setTime(1.2);
      final noon = await frame();
      final draws = game.layer.renderStats.drawCalls;
      game.scene.surface.visible = false;
      await frame();
      expect(draws - game.layer.renderStats.drawCalls, 1);
      game.scene.surface.visible = true;

      // The pool covers a good part of the picture, and its water moves.
      expect(water(noon), greaterThan(844 * 390 ~/ 9));
      game.setTime(2.2);
      expect(differing(noon, await frame()), greaterThan(2000));

      // The slabs rise out of the water: the pool shows less water.
      game.scene.slabLift = 1;
      game.setTime(2.3);
      final raised = await frame();
      expect(water(raised), lessThan(water(noon) * 0.85));

      // A pebble lands: a splash, and the drops that fall back raise rings
      // of their own besides the pebble's.
      game.scene
        ..slabLift = 0
        ..dropPebble(0.6, -0.5, 3);
      var rings = 0;
      for (var i = 0; i < 45; i++) {
        final time = 3 + i / 30;
        game.setTime(time);
        await tester.pump(const Duration(milliseconds: 33));
        rings = math.max(rings, game.scene.ripples.aliveAt(time));
      }
      expect(rings, greaterThanOrEqualTo(3));

      // Dusk: another light on the same scene.
      game.scene
        ..slabLift = 0
        ..lighting = PoolLighting.dusk;
      game.setTime(1.2);
      final dusk = await frame();
      expect(differing(noon, dusk), greaterThan(844 * 390 ~/ 2));
    },
    skip: !gpuAvailable,
  );
}
