import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d_example/lanterns/lanterns_game.dart';
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
    'the pool at dusk is lit by 64 and by 200 small lights through the light '
    'grid, in the draws of 8',
    (tester) async {
      tester.view
        ..physicalSize = const ui.Size(844, 390)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      Future<(LanternsGame, _Pixels)> render({
        required int lights,
        required bool grid,
      }) async {
        final game = LanternsGame(lights: lights, grid: grid, autoPlay: false);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: GameWidget(game: game),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
        game.setTime(1.3);
        await tester.pump(const Duration(milliseconds: 16));
        await tester.pump(const Duration(milliseconds: 16));
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final pixels = (await tester.runAsync(() async {
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
        return (game, pixels);
      }

      /// The pixels at least 24 levels brighter (summed over the color
      /// channels) in [a] than in [b].
      int brighter(_Pixels a, _Pixels b) {
        var count = 0;
        for (var i = 0; i < a.rgba.length; i += 4) {
          final d =
              a.rgba[i] +
              a.rgba[i + 1] +
              a.rgba[i + 2] -
              b.rgba[i] -
              b.rgba[i + 1] -
              b.rgba[i + 2];
          if (d >= 24) {
            count++;
          }
        }
        return count;
      }

      for (final lights in [64, 200]) {
        final (without, dark) = await render(lights: lights, grid: false);
        final draws = without.layer.renderStats.drawCalls;
        final (game, lit) = await render(lights: lights, grid: true);
        final stats = game.layer.context.lightGridStats;

        // Every small light is in the grid, none is left out, and a cell
        // lists far fewer lights than the scene has.
        expect(game.lanterns.added.length + 2, lights);
        expect(stats.active, isTrue);
        expect(stats.pointLights, lights);
        expect(stats.droppedLights, 0);
        expect(stats.droppedEntries, 0);
        expect(stats.maxPointLightsInCell, lessThan(32));
        expect(stats.averageLightsPerOccupiedCell, lessThan(8));

        // The draws do not change: the lanterns are instanced.
        expect(game.layer.renderStats.drawCalls, draws);
        expect(draws, lessThan(30));

        // Without the grid, 8 lights light the scene; with it, all of them.
        expect(brighter(lit, dark), greaterThan(844 * 390 ~/ 8));
        expect(brighter(dark, lit), lessThan(50));
      }
    },
    skip: !gpuAvailable,
  );
}
