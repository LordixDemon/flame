import 'dart:ui';

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

void main() {
  setUpGpu();

  group('DecalBatch3D', () {
    testGpuEngine('sorts among translucent draws at its own depth', () async {
      // Decals far behind (z = -5) a half transparent red square (z = -1):
      // the square must be blended over them, not under them.
      final decals = DecalBatch3D()
        ..addFlatDecal(
          center: Vector3(0, 0, -5),
          width: 1.2,
          height: 1.2,
          normal: Vector3(0, 0, 1),
          color: const Color(0xFF0000FF),
        );
      final glass = quad(UnlitMaterial(albedoColor: const Color(0x80FF0000)));
      final frame = await renderFrame(
        draw: (context) {
          context.drawSurface(
            glass,
            transform: Matrix4.translationValues(0, 0, -1),
          );
          decals.draw(context);
        },
      );
      final (x, y) = pixelAt(0, 0);
      final (r, _, b, _) = frame.pixels.at(x, y);
      expect(r, greaterThan(200), reason: 'the square is in front');
      // Blended over the blue decals, drawn first.
      expect(b, inInclusiveRange(100, 160));
    });
  });
}
