import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// Material.translucentOrder: translucent draws are drawn in increasing order
// of it, back to front within one order, so a surface can be drawn under the
// translucent things of a scene whatever their distance.

void main() {
  setUpGpu();

  group('Material.translucentOrder', () {
    testGpuEngine(
      'draws lower orders first, back to front within one',
      () async {
        UnlitMaterial translucent(Color color, int order) =>
            UnlitMaterial(albedoColor: color)
              ..renderState = RenderState.alphaBlend
              ..translucentOrder = order;

        /// The color where a red square near the camera and a blue one behind
        /// it overlap.
        Future<(int, int, int, int)> overlap({
          required int near,
          required int far,
        }) async {
          final red = quad(translucent(const Color(0x99FF0000), near));
          final blue = quad(translucent(const Color(0x990000FF), far));
          final frame = await renderFrame(
            draw: (context) => context
              ..drawSurface(red, transform: Matrix4.translationValues(0, 0, -2))
              ..drawSurface(
                blue,
                transform: Matrix4.translationValues(0.2, 0, -6),
              ),
          );
          final (x, y) = pixelAt(0.1, 0);
          return frame.pixels.at(x, y);
        }

        // By default, back to front: the red one, nearer, is blended last.
        final sorted = await overlap(near: 0, far: 0);
        expect(sorted.$1, greaterThan(sorted.$3));
        // The blue one in a higher order is drawn after it, nearer or not.
        final after = await overlap(near: 0, far: 1);
        expect(after.$3, greaterThan(after.$1));
        // As is the red one in a lower order.
        final before = await overlap(near: -1, far: 0);
        expect(before, after);
        // Within one order, back to front again.
        expect(await overlap(near: 2, far: 2), sorted);
      },
    );
  });
}
