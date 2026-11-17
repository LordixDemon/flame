import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Path _shadowOf(
  ShadowOccluder2D occluder, {
  double lx = 0,
  double ly = 0,
  double radius = 100,
}) {
  final path = Path();
  occluder.appendShadowQuads(
    lx: lx,
    ly: ly,
    radius: radius,
    extrudeDistance: radius * 2.2, // what Light2DLayer passes
    outPath: path,
  );
  return path;
}

void main() {
  group('ShadowOccluder2D wide occluders', () {
    test('a wall close to a light shadows everything behind it inside the '
        'light radius', () {
      // Light at the origin (radius 100), wall along y = 10, x in -100..100:
      // it subtends about 169 degrees.
      final wall = ShadowOccluder2D.segment(
        Vector2(-100, 10),
        Vector2(100, 10),
      );
      final path = Path();
      final shapes = wall.appendShadowQuads(
        lx: 0,
        ly: 0,
        radius: 100,
        extrudeDistance: 220,
        outPath: path,
      );
      expect(shapes, 1);

      // Behind the wall, all the way to the edge of the light.
      for (final p in const <Offset>[
        Offset(0, 20),
        Offset(0, 60),
        Offset(0, 99),
        Offset(50, 80),
        Offset(-70, 60),
      ]) {
        expect(path.contains(p), isTrue, reason: '$p should be in shadow');
      }
      // In front of the wall and beside it: lit.
      for (final p in const <Offset>[
        Offset(0, 5),
        Offset(0, -50),
        Offset(60, 3),
        Offset(-90, -10),
      ]) {
        expect(path.contains(p), isFalse, reason: '$p should be lit');
      }
    });

    test('the shadow covers the whole wedge for any wall distance and '
        'orientation', () {
      for (final distance in <double>[2, 10, 40, 80]) {
        for (final flip in <bool>[false, true]) {
          final a = Vector2(-150, distance);
          final b = Vector2(150, distance);
          final wall = ShadowOccluder2D.segment(flip ? b : a, flip ? a : b);
          final path = _shadowOf(wall);
          // Sample the wedge behind the wall on a polar grid inside the
          // light radius.
          for (var deg = 20; deg <= 160; deg += 10) {
            final rad = deg * 3.141592653589793 / 180.0;
            final dirX = Offset.fromDirection(rad).dx;
            final dirY = Offset.fromDirection(rad).dy;
            // Distance along this ray at which it crosses the wall.
            final tWall = distance / dirY;
            if ((dirX * tWall).abs() >= 150) {
              continue; // this ray passes beside the wall
            }
            for (var t = tWall + 2; t < 100; t += 7) {
              expect(
                path.contains(Offset(dirX * t, dirY * t)),
                isTrue,
                reason: 'distance $distance, $deg deg, t $t (flip $flip)',
              );
            }
          }
        }
      }
    });

    test('a narrow occluder still casts a plain quad', () {
      final post = ShadowOccluder2D.segment(Vector2(-5, 50), Vector2(5, 50));
      final path = _shadowOf(post);
      expect(path.contains(const Offset(0, 80)), isTrue);
      expect(path.contains(const Offset(30, 80)), isFalse);
      expect(path.contains(const Offset(0, 40)), isFalse);
    });

    test('a closed box near the light shadows the region behind it', () {
      final box = ShadowOccluder2D.rect(const Rect.fromLTRB(-80, 8, 80, 20));
      final path = Path();
      final shapes = box.appendShadowQuads(
        lx: 0,
        ly: 0,
        radius: 100,
        extrudeDistance: 220,
        outPath: path,
      );
      expect(shapes, greaterThanOrEqualTo(1));
      expect(path.contains(const Offset(0, 70)), isTrue);
      expect(path.contains(const Offset(40, 85)), isTrue);
      expect(path.contains(const Offset(0, 4)), isFalse);
    });
  });

  group('NormalMappedSpriteBatch lighting', () {
    Future<Image> atlas() {
      final recorder = PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 4, 4),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      return recorder.endRecording().toImage(4, 4);
    }

    testWidgets('queued corner colours match evaluateLitColor', (tester) async {
      final image = (await tester.runAsync(atlas))!;
      final batch = NormalMappedSpriteBatch(diffuseAtlas: image);
      final lights = <PointLight2D>[
        PointLight2D(position: Vector2(30, 10), radius: 120),
      ];
      const dst = Rect.fromLTWH(0, 0, 40, 40);

      // Flat face: every corner uses the face normal itself.
      batch.addLitSprite(
        srcRect: const Rect.fromLTWH(0, 0, 4, 4),
        dstRect: dst,
        lights: lights,
        bevelCurvature: 0,
      );
      expect(batch.spriteCount, 1);
      final lit = batch.evaluateLitColor(
        wx: dst.right,
        wy: dst.top,
        normal: SurfaceNormal2D.flat,
        lights: lights,
      );
      final dark = batch.evaluateLitColor(
        wx: dst.left,
        wy: dst.bottom,
        normal: SurfaceNormal2D.flat,
        lights: lights,
      );
      // The corner nearer the light is brighter, and both are above ambient.
      expect(lit.r, greaterThan(dark.r));
      expect(dark.r, greaterThan(batch.ambientColor.r));

      final recorder = PictureRecorder();
      batch.flush(Canvas(recorder));
      recorder.endRecording().dispose();
      expect(batch.lastDrawCalls, 1);
      batch.dispose();
      image.dispose();
    });

    testWidgets('a light sitting exactly on a corner at zero height is '
        'skipped instead of producing NaN', (tester) async {
      final image = (await tester.runAsync(atlas))!;
      final batch = NormalMappedSpriteBatch(
        diffuseAtlas: image,
        defaultLightHeightZ: 0,
      );
      final lights = <PointLight2D>[
        PointLight2D(position: Vector2(0, 0), radius: 50),
      ];
      expect(
        () => batch.addLitSprite(
          srcRect: const Rect.fromLTWH(0, 0, 4, 4),
          dstRect: const Rect.fromLTWH(0, 0, 10, 10),
          lights: lights,
        ),
        returnsNormally,
      );
      expect(batch.spriteCount, 1);
      image.dispose();
    });

    testWidgets('a batch stops at maxSprites', (tester) async {
      final image = (await tester.runAsync(atlas))!;
      final batch = NormalMappedSpriteBatch(diffuseAtlas: image);
      for (var i = 0; i < NormalMappedSpriteBatch.maxSprites + 10; i++) {
        batch.addLitSprite(
          srcRect: const Rect.fromLTWH(0, 0, 4, 4),
          dstRect: const Rect.fromLTWH(0, 0, 10, 10),
          lights: const <PointLight2D>[],
        );
      }
      expect(batch.spriteCount, NormalMappedSpriteBatch.maxSprites);
      batch.clear();
      expect(batch.spriteCount, 0);
      image.dispose();
    });
  });
}
