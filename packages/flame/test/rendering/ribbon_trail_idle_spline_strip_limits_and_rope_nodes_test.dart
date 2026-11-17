import 'dart:ui';

import 'package:flame/game.dart';
import 'package:flame/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RibbonTrailComponent visual mutations', () {
    test('a trail following a target that stands still reports none', () {
      final target = Vector2(100, 100);
      final trail = RibbonTrailComponent(targetProvider: () => target);

      // Let the trail settle for one second.
      for (var i = 0; i < 60; i++) {
        trail.update(1 / 60);
      }
      expect(trail.pointCount, lessThan(2), reason: 'nothing is drawn');

      final before = Game.visualMutationCount;
      for (var i = 0; i < 600; i++) {
        trail.update(1 / 60);
      }
      expect(Game.visualMutationCount - before, 0);
    });

    test('a moving trail reports mutations until its last segment has '
        'faded, then goes quiet', () {
      final target = Vector2(0, 0);
      final trail = RibbonTrailComponent(
        lifetime: 0.3,
        targetProvider: () => target,
      );
      var before = Game.visualMutationCount;
      for (var i = 0; i < 30; i++) {
        target.x += 10;
        trail.update(1 / 60);
      }
      expect(trail.pointCount, greaterThanOrEqualTo(2));
      expect(Game.visualMutationCount - before, greaterThanOrEqualTo(29));

      // The target stops: the visible tail keeps fading for `lifetime`.
      before = Game.visualMutationCount;
      for (var i = 0; i < 12; i++) {
        trail.update(1 / 60);
      }
      expect(Game.visualMutationCount - before, 12);

      for (var i = 0; i < 60; i++) {
        trail.update(1 / 60);
      }
      before = Game.visualMutationCount;
      for (var i = 0; i < 120; i++) {
        trail.update(1 / 60);
      }
      expect(Game.visualMutationCount - before, 0);
    });

    test('hand-fed points: the first point is silent, the second one '
        'makes the trail visible', () {
      final trail = RibbonTrailComponent();
      var before = Game.visualMutationCount;
      trail.addPointXY(0, 0);
      expect(Game.visualMutationCount - before, 0);
      trail.addPointXY(20, 0);
      expect(Game.visualMutationCount - before, 1);

      before = Game.visualMutationCount;
      trail.clear();
      expect(Game.visualMutationCount - before, 1);
      expect(trail.pointCount, 0);
    });

    test('render tolerates a lifetime set to zero after construction', () {
      final trail = RibbonTrailComponent()
        ..addPointXY(0, 0)
        ..addPointXY(20, 0)
        ..lifetime = 0;
      final recorder = PictureRecorder();
      expect(() => trail.render(Canvas(recorder)), returnsNormally);
      recorder.endRecording().dispose();
    });
  });

  group('SplineStripMesh2D', () {
    final path = <Vector2>[Vector2(0, 0), Vector2(128, 0), Vector2(256, 0)];

    test('texture size scales the UVs into shader pixels', () {
      final normalised = SplineStripMesh2D.fromCatmullRom(controlPoints: path);
      final textured = SplineStripMesh2D.fromCatmullRom(
        controlPoints: path,
        textureWidth: 32,
        textureHeight: 8,
      );
      // Default: normalised, one repeat every 64 units along the strip.
      final last = (normalised.sampleCount - 1) * 4;
      expect(normalised.uvs[last], closeTo(256 / 64, 1e-4));
      expect(normalised.uvs[1], 0.0);
      expect(normalised.uvs[3], 1.0);
      // Scaled: the same repeats, in pixels of a 32x8 image.
      expect(textured.uvs[last], closeTo(256 / 64 * 32, 1e-3));
      expect(textured.uvs[1], 0.0);
      expect(textured.uvs[3], 8.0);
      // Geometry is not affected.
      expect(textured.positions, normalised.positions);
    });

    test('fewer than two control points give an empty mesh that draws '
        'nothing', () {
      final empty = SplineStripMesh2D.fromCatmullRom(
        controlPoints: <Vector2>[Vector2(1, 1)],
      );
      expect(empty.sampleCount, 0);
      final recorder = PictureRecorder();
      expect(() => empty.render(Canvas(recorder)), returnsNormally);
      recorder.endRecording().dispose();
    });

    test('subdivisions are reduced so vertex indices stay within 16 bits', () {
      final many = List<Vector2>.generate(
        5001,
        (i) => Vector2(i * 4.0, (i % 2) * 3.0),
      );
      final strip = SplineStripMesh2D.fromCatmullRom(
        controlPoints: many,
        subdivisionsPerSegment: 16,
      );
      expect(
        strip.sampleCount,
        lessThanOrEqualTo(SplineStripMesh2D.maxSamples),
      );
      // 5000 spans fit 6 subdivisions each (30001 samples).
      expect(strip.sampleCount, 5000 * 6 + 1);
      final maxIndex = strip.indices.reduce((a, b) => a > b ? a : b);
      expect(maxIndex, strip.sampleCount * 2 - 1);
      // The strip still ends on the last control point.
      final lastVertex = (strip.sampleCount - 1) * 4;
      final midX =
          (strip.positions[lastVertex] + strip.positions[lastVertex + 2]) / 2;
      expect(midX, closeTo(many.last.x, 1e-2));
    });

    test('more control points than a strip can index are rejected', () {
      final tooMany = List<Vector2>.generate(
        SplineStripMesh2D.maxSamples + 1,
        (i) => Vector2(i.toDouble(), 0),
      );
      expect(
        () => SplineStripMesh2D.fromCatmullRom(controlPoints: tooMany),
        throwsArgumentError,
      );
    });
  });

  group('VerletRope2D node counts', () {
    test('a single node is a free point that falls without NaN', () {
      final rope = VerletRope2D(
        nodeCount: 1,
        start: Vector2(5, 7),
        pinStart: false,
      );
      expect(rope.posX[0], 5.0);
      expect(rope.posY[0], 7.0);
      for (var i = 0; i < 30; i++) {
        rope.step(1 / 60);
      }
      expect(rope.posX[0], 5.0);
      expect(rope.posY[0].isFinite, isTrue);
      expect(rope.posY[0], greaterThan(7.0));
    });

    test('a single pinned node stays put', () {
      final rope = VerletRope2D(nodeCount: 1, start: Vector2(5, 7));
      rope.step(1 / 60);
      expect(rope.posX[0], 5.0);
      expect(rope.posY[0], 7.0);
    });

    test('zero nodes are rejected', () {
      expect(
        () => VerletRope2D(nodeCount: 0, start: Vector2.zero()),
        throwsArgumentError,
      );
    });

    test('a NaN time step leaves the rope untouched', () {
      final rope = VerletRope2D(nodeCount: 4, start: Vector2.zero())
        ..step(double.nan);
      expect(rope.posY.every((v) => v.isFinite), isTrue);
    });
  });
}
