import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

void main() {
  setUpGpu();

  // Uploaded directly where the device has BC1, decoded on the CPU elsewhere:
  // either way the blocks are sampled as sRGB.
  testGpu('an sRGB BC1 texture samples like the same sRGB RGBA8 texture', (
    tester,
  ) async {
    final rgba = Uint8List(8 * 8 * 4);
    for (var i = 0; i < 64; i++) {
      rgba
        ..[i * 4] = 128
        ..[i * 4 + 1] = 128
        ..[i * 4 + 2] = 128
        ..[i * 4 + 3] = 255;
    }
    final bc1 = Ktx2TextureLoader.load(
      Ktx2TextureLoader.encodeBc1(rgba, width: 8, height: 8, srgb: true),
      sampler: TextureSampler.nearest,
    );
    final rgba8 = Ktx2TextureLoader.load(
      Ktx2TextureLoader.encodeUncompressedRgba8(
        rgba,
        width: 8,
        height: 8,
        srgb: true,
      ),
      sampler: TextureSampler.nearest,
    );

    final pixels = (await tester.runAsync(() async {
      final frame = await renderFrame(
        width: 128,
        height: 128,
        draw: (context) {
          context
            ..drawSurface(
              quad(
                UnlitMaterial(albedoTexture: bc1)
                  ..renderState = RenderState.opaque,
                halfSize: 0.42,
              ),
              transform: Matrix4.translationValues(-0.5, 0, 0),
            )
            ..drawSurface(
              quad(
                UnlitMaterial(albedoTexture: rgba8)
                  ..renderState = RenderState.opaque,
                halfSize: 0.42,
              ),
              transform: Matrix4.translationValues(0.5, 0, 0),
            );
        },
      );
      return frame.pixels;
    }))!;

    final (bcRed, _, _, _) = pixels.at(32, 64);
    final (rgbaRed, _, _, _) = pixels.at(96, 64);
    // Both decode sRGB 128 to linear light (0.216, about 55 of 255).
    expect(rgbaRed, lessThan(80));
    // BC1 stores 128 as 132 (5 bits of red).
    expect(bcRed, closeTo(rgbaRed, 6));
  });
}
