import 'dart:typed_data';
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

    group('premultipliedTexture', () {
      // A texel of half transparent red, premultiplied: (128, 0, 0, 128),
      // what filtering a premultiplied atlas between an opaque red texel and
      // a transparent one gives.
      final texture = Texture(
        ByteData.sublistView(Uint8List.fromList([128, 0, 0, 128])),
        width: 1,
        height: 1,
      );

      Future<(int, int, int, int)> center(
        DecalMaterial material, {
        Color color = const Color(0xFFFFFFFF),
      }) async {
        final decals = DecalBatch3D(material: material)
          ..addFlatDecal(
            center: Vector3(0, 0, -5),
            width: 1.2,
            height: 1.2,
            normal: Vector3(0, 0, 1),
            color: color,
          );
        final frame = await renderFrame(draw: decals.draw);
        final (x, y) = pixelAt(0, 0);
        return frame.pixels.at(x, y);
      }

      testGpuEngine('off, texels are straight colors as before', () async {
        final (r, _, _, a) = await center(DecalMaterial(texture: texture));
        // Multiplied by their alpha once more.
        expect(r, closeTo(64, 1));
        expect(a, closeTo(128, 1));
      });

      testGpuEngine('on, premultiplied texels keep their colors', () async {
        final material = DecalMaterial(
          texture: texture,
          premultipliedTexture: true,
        );
        expect(await center(material), (128, 0, 0, 128));
        // A tint's alpha scales the whole texel.
        final (r, g, b, a) = await center(
          material,
          color: const Color(0x80FFFFFF),
        );
        expect(r, closeTo(64, 1));
        expect((g, b), (0, 0));
        expect(a, closeTo(64, 1));
        // A tint's color multiplies it.
        final (tr, _, _, ta) = await center(
          material,
          color: const Color(0xFF808080),
        );
        expect(tr, closeTo(64, 1));
        expect(ta, 128);
      });
    });

    group('sortByDepth', () {
      // A half transparent red decal at z = -4, in front of a half
      // transparent blue one at z = -5, added in that order: over the clear
      // color, red over blue is (128, 0, 64), blue over red (64, 0, 128).
      DecalBatch3D overlapping({required bool sortByDepth}) {
        return DecalBatch3D(sortByDepth: sortByDepth)
          ..addFlatDecal(
            center: Vector3(0, 0, -4),
            width: 1.2,
            height: 1.2,
            normal: Vector3(0, 0, 1),
            color: const Color(0x80FF0000),
          )
          ..addFlatDecal(
            center: Vector3(0.2, 0, -5),
            width: 1.2,
            height: 1.2,
            normal: Vector3(0, 0, 1),
            color: const Color(0x800000FF),
          );
      }

      (int, int, int) middle(Frame frame) {
        final (x, y) = pixelAt(0.1, 0);
        final (r, g, b, _) = frame.pixels.at(x, y);
        return (r, g, b);
      }

      testGpuEngine(
        'off, decals are drawn in the order they were added',
        () async {
          final frame = await renderFrame(
            draw: overlapping(sortByDepth: false).draw,
          );
          final (r, g, b) = middle(frame);
          expect(r, closeTo(64, 2));
          expect(g, 0);
          expect(b, closeTo(128, 2));
        },
      );

      testGpuEngine('on, decals are drawn back to front', () async {
        final decals = overlapping(sortByDepth: true);
        final frame = await renderFrame(draw: decals.draw);
        final (r, g, b) = middle(frame);
        expect(r, closeTo(128, 2));
        expect(g, 0);
        expect(b, closeTo(64, 2));
        expect(decals.sortCount, 1);

        // The same camera and decals: no new sort.
        await renderFrame(draw: decals.draw);
        expect(decals.sortCount, 1);

        // The red decal moves behind the blue one: sorted again.
        decals.setDecal(
          0,
          transform: Matrix4.translationValues(0, 0, -6)
            ..scaleByDouble(1.2, 1.2, 1, 1),
        );
        final moved = await renderFrame(draw: decals.draw);
        expect(decals.sortCount, 2);
        final (mr, _, mb) = middle(moved);
        expect(mr, closeTo(64, 2));
        expect(mb, closeTo(128, 2));

        // Another camera: sorted again.
        await renderFrame(
          draw: decals.draw,
          view: Matrix4.translationValues(0.1, 0, 0),
        );
        expect(decals.sortCount, 3);
      });
    });
  });
}
