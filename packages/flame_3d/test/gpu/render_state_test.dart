import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

void main() {
  setUpGpu();

  group('per-material render state', () {
    Future<(int, int, int, int)> renderOne(
      Color color,
      RenderState state,
    ) async {
      final surface = quad(
        UnlitMaterial(albedoColor: color)..renderState = state,
      );
      final frame = await renderFrame(
        draw: (context) => context.drawSurface(
          surface,
          transform: Matrix4.translationValues(0, 0, -5),
        ),
      );
      final (x, y) = pixelAt(0, 0);
      return frame.pixels.at(x, y);
    }

    testGpuEngine('blends straight alpha', () async {
      final (r, g, b, a) = await renderOne(
        const Color(0x80CC0000),
        RenderState.alphaBlend,
      );
      // .8 * .5 over the transparent target.
      expect(r, closeTo(102, 2));
      expect((g, b), (0, 0));
      expect(a, closeTo(128, 1));
    });

    testGpuEngine('blends premultiplied alpha', () async {
      final (r, g, b, a) = await renderOne(
        const Color(0x80CC0000),
        RenderState.premultipliedAlphaBlend,
      );
      expect(r, closeTo(204, 1));
      expect((g, b), (0, 0));
      expect(a, closeTo(128, 1));
    });

    testGpuEngine('does not blend opaque draws', () async {
      final (r, g, b, a) = await renderOne(
        const Color(0x80CC0000),
        RenderState.opaque,
      );
      expect(r, closeTo(204, 1));
      expect((g, b), (0, 0));
      expect(a, closeTo(128, 1));
    });

    testGpuEngine('adds additive draws', () async {
      final red = quad(
        UnlitMaterial(albedoColor: const Color(0x80800000))
          ..renderState = RenderState.additive,
      );
      final green = quad(
        UnlitMaterial(albedoColor: const Color(0x80008000))
          ..renderState = RenderState.additive,
      );
      final frame = await renderFrame(
        draw: (context) => context
          ..drawSurface(red, transform: Matrix4.translationValues(0, 0, -4))
          ..drawSurface(green, transform: Matrix4.translationValues(0, 0, -6)),
      );
      final (x, y) = pixelAt(0, 0);
      final (r, g, b, a) = frame.pixels.at(x, y);
      expect(r, closeTo(128, 1));
      expect(g, closeTo(128, 1));
      expect(b, 0);
      expect(a, closeTo(255, 1));
    });

    testGpuEngine('applies a different state to each draw of a pass', () async {
      final opaque = quad(opaqueUnlit(const Color(0xFF0000FF)), halfSize: .2);
      final alpha = quad(
        UnlitMaterial(albedoColor: const Color(0x80FF0000))
          ..renderState = RenderState.alphaBlend,
        halfSize: .2,
      );
      final additive = quad(
        UnlitMaterial(albedoColor: const Color(0x8000FF00))
          ..renderState = RenderState.additive,
        halfSize: .2,
      );
      final frame = await renderFrame(
        draw: (context) => context
          ..drawSurface(alpha, transform: Matrix4.translationValues(0, .5, -5))
          ..drawSurface(
            additive,
            transform: Matrix4.translationValues(.5, -.5, -5),
          )
          ..drawSurface(
            opaque,
            transform: Matrix4.translationValues(-.5, -.5, -5),
          ),
      );
      final (ax, ay) = pixelAt(0, .5);
      final (dx, dy) = pixelAt(.5, -.5);
      final (ox, oy) = pixelAt(-.5, -.5);
      expect(frame.pixels.at(ax, ay).$1, closeTo(128, 1));
      expect(frame.pixels.at(dx, dy).$2, 255);
      expect(frame.pixels.at(ox, oy), (0, 0, 255, 255));
    });

    testGpuEngine('draws over nearer surfaces without depth test', () async {
      final wall = quad(opaqueUnlit(const Color(0xFF0000FF)), halfSize: .6);
      final overlay = quad(
        UnlitMaterial(albedoColor: const Color(0xFFFF0000))
          ..renderState = const RenderState(
            depthTest: false,
            translucent: true,
          ),
        halfSize: .3,
      );
      final hidden = quad(
        UnlitMaterial(albedoColor: const Color(0xFF00FF00))
          ..renderState = const RenderState(translucent: true),
        halfSize: .3,
      );
      final frame = await renderFrame(
        draw: (context) => context
          ..drawSurface(wall, transform: Matrix4.translationValues(0, 0, -4))
          ..drawSurface(
            overlay,
            transform: Matrix4.translationValues(-.3, 0, -6),
          )
          ..drawSurface(
            hidden,
            transform: Matrix4.translationValues(.3, 0, -6),
          ),
      );
      final (lx, ly) = pixelAt(-.3, 0);
      final (rx, ry) = pixelAt(.3, 0);
      expect(frame.pixels.at(lx, ly), (255, 0, 0, 255));
      expect(frame.pixels.at(rx, ry), (0, 0, 255, 255));
    });

    testGpuEngine(
      'lets farther surfaces through without depth writes',
      () async {
        // Both opaque; the near one is drawn first (lower material id) but does
        // not write depth, so the far one covers it.
        final near = quad(
          UnlitMaterial(albedoColor: const Color(0xFFFF0000))
            ..renderState = const RenderState(depthWrite: false),
          halfSize: .3,
        );
        final far = quad(opaqueUnlit(const Color(0xFF0000FF)), halfSize: .6);
        final frame = await renderFrame(
          draw: (context) => context
            ..drawSurface(near, transform: Matrix4.translationValues(0, 0, -4))
            ..drawSurface(far, transform: Matrix4.translationValues(0, 0, -6)),
        );
        final (x, y) = pixelAt(0, 0);
        expect(frame.pixels.at(x, y), (0, 0, 255, 255));
      },
    );

    testGpuEngine('passes the depth test with the material compare', () async {
      final far = quad(opaqueUnlit(const Color(0xFF0000FF)), halfSize: .6);
      final near = quad(opaqueUnlit(const Color(0xFFFF0000)), halfSize: .3);
      // Drawn last, behind the others, but its compare passes when farther.
      final behind = quad(
        UnlitMaterial(albedoColor: const Color(0xFF00FF00))
          ..renderState = const RenderState(
            depthCompare: CompareFunction.greaterEqual,
            depthWrite: false,
            translucent: true,
          ),
        halfSize: .9,
      );
      final frame = await renderFrame(
        draw: (context) => context
          ..drawSurface(far, transform: Matrix4.translationValues(0, 0, -6))
          ..drawSurface(near, transform: Matrix4.translationValues(0, 0, -4))
          ..drawSurface(behind, transform: Matrix4.translationValues(0, 0, -8)),
      );
      final (cx, cy) = pixelAt(0, 0);
      final (ex, ey) = pixelAt(.75, 0);
      // Where something nearer was drawn, the farther quad passes.
      expect(frame.pixels.at(cx, cy), (0, 255, 0, 255));
      // Where only the cleared depth (the far plane) is, it fails.
      expect(frame.pixels.isClear(ex, ey), isTrue);
    });

    for (final (cullMode, visible) in [
      (CullMode.none, true),
      (CullMode.backFace, true),
      (CullMode.frontFace, false),
    ]) {
      testGpuEngine(
        '${visible ? 'keeps' : 'culls'} a front face with ${cullMode.name}',
        () async {
          final (_, _, _, a) = await renderOne(
            const Color(0xFFFFFFFF),
            RenderState(cullMode: cullMode),
          );
          expect(a, visible ? 255 : 0);
        },
      );
    }
  });
}
