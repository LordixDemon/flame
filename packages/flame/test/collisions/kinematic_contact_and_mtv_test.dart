import 'dart:ui' show Rect;

import 'package:flame/collisions.dart';
import 'package:flame/components.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The top of the floor is at y = 10.
  const floor = Rect.fromLTWH(-100, 10, 200, 10);

  /// A 10x10 body whose bottom edge is exactly on the floor, with no gap.
  KinematicBodyComponent bodyOnFloor(Vector2 velocity) {
    return KinematicBodyComponent(
      position: Vector2(0, 0),
      size: Vector2.all(10),
      velocity: velocity,
    );
  }

  group('KinematicBodyComponent in exact contact with an obstacle', () {
    test('walks along the floor it stands on', () {
      final body = bodyOnFloor(Vector2(60, 0));
      final contacts = body.moveAndSlide(1 / 60, explicitObstacles: [floor]);
      expect(contacts, 0);
      expect(body.position.x, closeTo(1.0, 1e-9));
      expect(body.position.y, 0);
    });

    test('moves away from the floor it stands on', () {
      final body = bodyOnFloor(Vector2(0, -60));
      body.moveAndSlide(1 / 60, explicitObstacles: [floor]);
      expect(body.position.y, closeTo(-1.0, 1e-9));
    });

    test('pressing into the floor is a floor contact with a unit normal', () {
      final body = bodyOnFloor(Vector2(0, 60));
      final hit = body.moveAndCollide(1 / 60, explicitObstacles: [floor]);
      expect(hit, isNotNull);
      expect(hit!.toi, 0);
      expect(hit.normal, Vector2(0, -1));
      expect(body.isOnFloor, isTrue);
      expect(body.isOnWall, isFalse);
    });

    test('gravity on a resting body slides it and cancels the fall', () {
      final body = bodyOnFloor(Vector2(60, 0))..gravity.setValues(0, 980);
      for (var i = 0; i < 60; i++) {
        body
          ..integrateForces(1 / 60)
          ..moveAndSlide(1 / 60, explicitObstacles: [floor]);
        expect(body.isOnFloor, isTrue, reason: 'tick $i');
      }
      expect(body.position.x, closeTo(60, 1e-6));
      // It rests a skin width above the floor instead of sinking into it.
      expect(body.position.y, closeTo(-body.skinWidth, 1e-6));
      expect(body.velocity.y, closeTo(0, 1e-6));
    });

    test('slides along a wall it touches with its side', () {
      const wall = Rect.fromLTWH(10, -100, 10, 200);
      final body = bodyOnFloor(Vector2(0, -60));
      body.moveAndSlide(1 / 60, explicitObstacles: [wall]);
      expect(body.position.y, closeTo(-1.0, 1e-9));
      expect(body.position.x, 0);
    });
  });

  group('KinematicBodyComponent that starts inside an obstacle', () {
    test('is pushed out and keeps moving', () {
      // 4 units deep in the floor.
      final body = KinematicBodyComponent(
        position: Vector2(0, 4),
        size: Vector2.all(10),
        velocity: Vector2(60, 0),
      );
      body.moveAndSlide(1 / 60, explicitObstacles: [floor]);
      expect(body.position.y, closeTo(-body.skinWidth, 1e-9));
      expect(body.position.x, closeTo(1.0, 1e-9));
      expect(
        body.computeWorldBounds().overlaps(floor),
        isFalse,
      );
    });

    test('the hit reports how deep it was', () {
      final hit = ShapeCastHit2D();
      expect(
        ShapeCast2D.sweepRectVsRect(
          movingRect: const Rect.fromLTWH(0, 4, 10, 10),
          delta: Vector2(5, 0),
          obstacleRect: floor,
          out: hit,
        ),
        isTrue,
      );
      expect(hit.toi, 0);
      expect(hit.normal, Vector2(0, -1));
      expect(hit.penetration, closeTo(4, 1e-9));

      // A later cast that does not start in overlap resets it.
      expect(
        ShapeCast2D.sweepRectVsRect(
          movingRect: const Rect.fromLTWH(0, -20, 10, 10),
          delta: Vector2(0, 40),
          obstacleRect: floor,
          out: hit,
        ),
        isTrue,
      );
      expect(hit.toi, closeTo(0.5, 1e-9));
      expect(hit.penetration, 0);
    });
  });

  group('ShapeCast2D with shapes that only touch', () {
    const moving = Rect.fromLTWH(0, 0, 10, 10);

    bool sweepRect(Vector2 delta, ShapeCastHit2D out) {
      return ShapeCast2D.sweepRectVsRect(
        movingRect: moving,
        delta: delta,
        obstacleRect: floor,
        out: out,
      );
    }

    test('rect: moving away or along the surface is not an impact', () {
      final out = ShapeCastHit2D();
      expect(sweepRect(Vector2(0, -5), out), isFalse);
      expect(sweepRect(Vector2(5, 0), out), isFalse);
      expect(sweepRect(Vector2(-5, -5), out), isFalse);
    });

    test('rect: moving into the surface is an impact at time 0', () {
      final out = ShapeCastHit2D();
      expect(sweepRect(Vector2(3, 5), out), isTrue);
      expect(out.toi, 0);
      expect(out.normal, Vector2(0, -1));
    });

    test('rect: passing a corner that it only touches is not an impact', () {
      final out = ShapeCastHit2D();
      // Touches the top left corner of the obstacle with its bottom right
      // corner and moves along the diagonal that leads past it.
      expect(
        ShapeCast2D.sweepRectVsRect(
          movingRect: const Rect.fromLTWH(-110, 0, 10, 10),
          delta: Vector2(5, -5),
          obstacleRect: floor,
          out: out,
        ),
        isFalse,
      );
    });

    test('rect: ending the move in contact is reported at time 1', () {
      final out = ShapeCastHit2D();
      expect(
        ShapeCast2D.sweepRectVsRect(
          movingRect: const Rect.fromLTWH(0, -5, 10, 10),
          delta: Vector2(0, 5),
          obstacleRect: floor,
          out: out,
        ),
        isTrue,
      );
      expect(out.toi, 1);
    });

    bool sweepCircle(Vector2 center, Vector2 delta, ShapeCastHit2D out) {
      return ShapeCast2D.sweepCircleVsRect(
        startCenter: center,
        radius: 5,
        delta: delta,
        obstacleRect: floor,
        out: out,
      );
    }

    test('circle on a face: only moving into it is an impact', () {
      final out = ShapeCastHit2D();
      final center = Vector2(0, 5);
      expect(sweepCircle(center, Vector2(0, -4), out), isFalse);
      expect(sweepCircle(center, Vector2(4, 0), out), isFalse);
      expect(sweepCircle(center, Vector2(1, 4), out), isTrue);
      expect(out.toi, 0);
      expect(out.normal, Vector2(0, -1));
      expect(out.penetration, 0);
    });

    test('circle on a corner: only moving into it is an impact', () {
      final out = ShapeCastHit2D();
      // 3-4-5 triangle away from the top left corner (-100, 10).
      final center = Vector2(-103, 6);
      expect(sweepCircle(center, Vector2(-3, -4), out), isFalse);
      // Along the tangent of the corner.
      expect(sweepCircle(center, Vector2(4, -3), out), isFalse);
      expect(sweepCircle(center, Vector2(3, 4), out), isTrue);
      expect(out.toi, 0);
      expect(out.normal.x, closeTo(-0.6, 1e-6));
      expect(out.normal.y, closeTo(-0.8, 1e-6));
    });
  });

  group('CollisionManifold2D', () {
    Rect resolved(Rect rect, CollisionManifold2D m) =>
        rect.translate(m.normal.x * m.depth, m.normal.y * m.depth);

    test('rectVsRect: a thin wall inside the span of a wide body', () {
      const body = Rect.fromLTWH(100, 0, 32, 32);
      const wall = Rect.fromLTWH(110, -100, 8, 200);
      final m = CollisionManifold2D();
      expect(
        CollisionManifold2D.rectVsRect(rectA: body, rectB: wall, out: m),
        isTrue,
      );
      // The wall is nearer to the left side of the body, so the body leaves
      // to the right: 118 - 100.
      expect(m.normal, Vector2(1, 0));
      expect(m.depth, 18);
      expect(resolved(body, m).overlaps(wall), isFalse);
    });

    test('rectVsRect: a small body deep inside a large obstacle', () {
      const body = Rect.fromLTWH(10, 40, 20, 20);
      const obstacle = Rect.fromLTWH(0, 0, 100, 100);
      final m = CollisionManifold2D();
      CollisionManifold2D.rectVsRect(rectA: body, rectB: obstacle, out: m);
      expect(m.normal, Vector2(-1, 0));
      expect(m.depth, 30);
      expect(m.contactPoint, Vector2(0, 50));
      expect(resolved(body, m).overlaps(obstacle), isFalse);
    });

    test('rectVsRect: a partial overlap keeps its plain result', () {
      const body = Rect.fromLTWH(0, 0, 10, 10);
      const obstacle = Rect.fromLTWH(8, 3, 10, 10);
      final m = CollisionManifold2D();
      CollisionManifold2D.rectVsRect(rectA: body, rectB: obstacle, out: m);
      expect(m.normal, Vector2(-1, 0));
      expect(m.depth, 2);
      expect(resolved(body, m).overlaps(obstacle), isFalse);
    });

    test('rectVsRect: the move always separates the rectangles', () {
      const obstacle = Rect.fromLTWH(0, 0, 40, 24);
      final m = CollisionManifold2D();
      for (var x = -30.0; x <= 45; x += 2.5) {
        for (var y = -30.0; y <= 30; y += 2.5) {
          for (final size in const [3.0, 17.0, 60.0]) {
            final body = Rect.fromLTWH(x, y, size, size * 0.7);
            final overlaps = body.overlaps(obstacle);
            expect(
              CollisionManifold2D.rectVsRect(
                rectA: body,
                rectB: obstacle,
                out: m,
              ),
              overlaps,
            );
            if (overlaps) {
              // Separated, and by no more than needed: half the depth is not
              // enough.
              expect(resolved(body, m).overlaps(obstacle), isFalse);
              final half = body.translate(
                m.normal.x * m.depth * 0.5,
                m.normal.y * m.depth * 0.5,
              );
              expect(half.overlaps(obstacle), isTrue);
            }
          }
        }
      }
    });

    test('touching shapes do not overlap, for all three shape pairs', () {
      final m = CollisionManifold2D();
      expect(
        CollisionManifold2D.rectVsRect(
          rectA: const Rect.fromLTWH(0, 0, 10, 10),
          rectB: floor,
          out: m,
        ),
        isFalse,
      );
      expect(
        CollisionManifold2D.circleVsRect(
          circleCenter: Vector2(0, 5),
          radius: 5,
          rectB: floor,
          out: m,
        ),
        isFalse,
      );
      expect(
        CollisionManifold2D.circleVsCircle(
          centerA: Vector2(0, 0),
          radiusA: 5,
          centerB: Vector2(8, 0),
          radiusB: 3,
          out: m,
        ),
        isFalse,
      );
      // A circle whose center is on the edge is half inside.
      expect(
        CollisionManifold2D.circleVsRect(
          circleCenter: Vector2(0, 10),
          radius: 5,
          rectB: floor,
          out: m,
        ),
        isTrue,
      );
      expect(m.depth, 5);
      expect(m.normal, Vector2(0, -1));
    });
  });
}
