import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

void main() {
  setUpGpu();

  group('instanced batching', () {
    testGpuEngine('draws 300 instances of a mesh with one draw call', () async {
      const columns = 20;
      const rows = 15;
      const width = 200;
      const height = 150;
      final surface = quad(opaqueUnlit(const Color(0xFFFFFFFF)));

      Color colorOf(int column, int row) =>
          Color.from(alpha: 1, red: column / 19, green: row / 14, blue: 0.5);
      (double, double) centerOf(int column, int row) => (
        -1 + (column + 0.5) * 2 / columns,
        -1 + (row + 0.5) * 2 / rows,
      );

      final frame = await renderFrame(
        width: width,
        height: height,
        draw: (context) {
          final transform = Matrix4.identity();
          for (var row = 0; row < rows; row++) {
            for (var column = 0; column < columns; column++) {
              final (x, y) = centerOf(column, row);
              transform
                ..setIdentity()
                ..translateByDouble(x, y, -5, 1)
                ..scaleByDouble(0.06, 0.08, 1, 1);
              context.drawSurface(
                surface,
                transform: transform,
                color: colorOf(column, row),
              );
            }
          }
        },
      );

      expect(frame.stats.drawCalls, 1);
      expect(frame.stats.instances, columns * rows);
      expect(frame.stats.triangles, columns * rows * 2);

      for (var row = 0; row < rows; row++) {
        for (var column = 0; column < columns; column++) {
          final (x, y) = centerOf(column, row);
          final (px, py) = pixelAt(x, y, width: width, height: height);
          final (r, g, b, a) = frame.pixels.at(px, py);
          final color = colorOf(column, row);
          expect(r, closeTo(color.r * 255, 1), reason: 'red of $column,$row');
          expect(g, closeTo(color.g * 255, 1), reason: 'green of $column,$row');
          expect(b, closeTo(color.b * 255, 1), reason: 'blue of $column,$row');
          expect(a, 255);
        }
      }
      // Between instances the target stays clear.
      expect(frame.pixels.isClear(0, 0), isTrue);
    });

    testGpuEngine('groups interleaved draws by material and surface', () async {
      final red = opaqueUnlit(const Color(0xFFFF0000));
      final green = opaqueUnlit(const Color(0xFF00FF00));
      final small = [quad(red, halfSize: 0.1), quad(green, halfSize: 0.1)];

      final frame = await renderFrame(
        draw: (context) {
          for (var i = 0; i < 40; i++) {
            final surface = small[i % 2];
            context.drawSurface(
              surface,
              transform: Matrix4.translationValues(
                -0.9 + (i % 10) * 0.2,
                -0.9 + (i ~/ 10) * 0.2,
                -5,
              ),
            );
          }
        },
      );

      expect(frame.stats.drawCalls, 2);
      expect(frame.stats.instances, 40);
      expect(frame.stats.materialChanges, 2);
      expect(frame.stats.pipelineChanges, 1);
    });

    testGpuEngine('never batches translucent draws', () async {
      final surface = quad(
        UnlitMaterial(albedoColor: const Color(0x80FF0000))
          ..renderState = RenderState.alphaBlend,
        halfSize: 0.05,
      );

      final frame = await renderFrame(
        draw: (context) {
          for (var i = 0; i < 10; i++) {
            context.drawSurface(
              surface,
              transform: Matrix4.translationValues(-0.9 + i * 0.2, 0, -5),
            );
          }
        },
      );

      expect(frame.stats.drawCalls, 10);
      expect(frame.stats.instances, 10);
    });

    testGpuEngine('never batches skinned draws', () async {
      final surface = quad(opaqueUnlit(const Color(0xFFFFFFFF)), halfSize: .1);
      final joints = [Matrix4.identity()];

      final frame = await renderFrame(
        draw: (context) {
          for (var i = 0; i < 3; i++) {
            context
              ..drawSurface(
                surface,
                transform: Matrix4.translationValues(-0.5 + i * 0.5, 0.5, -5),
                jointTransforms: joints,
              )
              ..drawSurface(
                surface,
                transform: Matrix4.translationValues(-0.5 + i * 0.5, -.5, -5),
              );
          }
        },
      );

      // Three skinned draws, and one batch for the three others.
      expect(frame.stats.drawCalls, 4);
      expect(frame.stats.instances, 6);
    });
  });
}
