import 'dart:math';
import 'dart:ui' show Offset, Rect;

import 'package:flame/collisions.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/geometry.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

// Randomized comparisons of the broadphases and the shape casts against a
// brute-force reference, with fixed seeds.

/// A hitbox that is only a box on the x axis, for driving a broadphase
/// without a game.
class _Fake(
  final int id,
  var CollisionType type,
  double x,
  double w,
  var int layer,
  var int mask,
) extends Hitbox<_Fake> {
  @override
  Aabb2 aabb = Aabb2.minMax(Vector2(x, 0), Vector2(x + w, 10));

  @override
  CollisionType get collisionType => type;
  @override
  int get collisionLayer => layer;
  @override
  int get collisionMask => mask;
  @override
  bool get isSolid => false;
  @override
  bool containsPoint(Vector2 point) => false;
  @override
  List<Vector2> intersections(_Fake other) => const [];
  @override
  bool possiblyIntersects(_Fake other) => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

String _key(int a, int b) => a < b ? '$a-$b' : '$b-$a';

class _SweepGame() extends FlameGame with HasCollisionDetection;

class _QuadGame() extends FlameGame with HasQuadTreeCollisionDetection;

void main() {
  test('Sweep prospects match a brute-force pair search while hitboxes '
      'move, change type and mask, and come and go', () {
    final rng = Random(7);
    for (var round = 0; round < 300; round++) {
      final sweep = Sweep<_Fake>();
      final n = 2 + rng.nextInt(30);
      final all = <_Fake>[];
      for (var i = 0; i < n; i++) {
        final f = _Fake(
          i,
          CollisionType.values[rng.nextInt(3)],
          rng.nextInt(60) - 30.0,
          rng.nextInt(12).toDouble(),
          1 << rng.nextInt(2),
          rng.nextInt(4),
        );
        all.add(f);
        sweep.add(f);
      }
      for (var tick = 0; tick < 8; tick++) {
        // mutate
        for (final f in all) {
          final r = rng.nextInt(10);
          if (r < 3) {
            final x = rng.nextInt(60) - 30.0;
            final w = rng.nextInt(12).toDouble();
            f.aabb = Aabb2.minMax(Vector2(x, 0), Vector2(x + w, 10));
          } else if (r == 3) {
            f.type = CollisionType.values[rng.nextInt(3)];
          } else if (r == 4) {
            f.mask = rng.nextInt(4);
          }
        }
        if (rng.nextInt(4) == 0 && sweep.items.length > 2) {
          final victim = sweep.items[rng.nextInt(sweep.items.length)];
          sweep.remove(victim);
          all.remove(victim);
        }
        if (rng.nextInt(4) == 0) {
          final f = _Fake(
            1000 + round * 10 + tick,
            CollisionType.values[rng.nextInt(3)],
            rng.nextInt(60) - 30.0,
            rng.nextInt(12).toDouble(),
            1,
            3,
          );
          all.add(f);
          sweep.add(f);
        }
        sweep.update();
        final got = <String>{};
        for (final p in sweep.query()) {
          expect(got.add(_key(p.a.id, p.b.id)), isTrue, reason: 'dup pair');
        }
        final want = <String>{};
        for (var i = 0; i < all.length; i++) {
          for (var j = i + 1; j < all.length; j++) {
            final a = all[i];
            final b = all[j];
            if (a.type == CollisionType.inactive ||
                b.type == CollisionType.inactive) {
              continue;
            }
            if (a.type != CollisionType.active &&
                b.type != CollisionType.active) {
              continue;
            }
            if ((a.layer & b.mask) == 0 || (b.layer & a.mask) == 0) {
              continue;
            }
            if (a.aabb.min.x <= b.aabb.max.x && b.aabb.min.x <= a.aabb.max.x) {
              want.add(_key(a.id, b.id));
            }
          }
        }
        expect(got, want, reason: 'round $round tick $tick');
      }
    }
  });

  Future<void> rayFuzz(
    FlameGame game,
    CollisionDetection<ShapeHitbox, Broadphase<ShapeHitbox>> cd,
    int seed,
  ) async {
    final rng = Random(seed);
    final holders = <PositionComponent>[];
    final boxes = <ShapeHitbox>[];
    for (var i = 0; i < 120; i++) {
      final box = rng.nextBool()
          ? RectangleHitbox(
              size: Vector2(
                5 + rng.nextDouble() * 60,
                5 + rng.nextDouble() * 60,
              ),
            )
          : CircleHitbox(radius: 3 + rng.nextDouble() * 30);
      box.collisionType = CollisionType.values[rng.nextInt(3)];
      final holder = PositionComponent(
        position: Vector2(
          rng.nextDouble() * 1400 - 200,
          rng.nextDouble() * 1400 - 200,
        ),
        children: [box],
      );
      holders.add(holder);
      boxes.add(box);
      game.world.add(holder);
    }
    await game.ready();
    game.update(0.016);

    var mismatches = 0;
    var hits = 0;
    String? first;
    for (var q = 0; q < 1500; q++) {
      // move a few holders WITHOUT ticking the game (mid-frame query)
      for (var m = 0; m < 3; m++) {
        final h = holders[rng.nextInt(holders.length)];
        h.position.setValues(
          rng.nextDouble() * 1400 - 200,
          rng.nextDouble() * 1400 - 200,
        );
      }
      if (q % 50 == 0) {
        game.update(0.016);
      }
      final angle = rng.nextInt(16) == 0
          ? (rng.nextInt(4) * pi / 2)
          : rng.nextDouble() * tau;
      final ray = Ray2(
        origin: Vector2(
          rng.nextDouble() * 1400 - 200,
          rng.nextDouble() * 1400 - 200,
        ),
        direction: Vector2(cos(angle), sin(angle))..normalize(),
      );
      final maxDistance = rng.nextInt(3) == 0 ? null : rng.nextDouble() * 900;
      final got = cd.raycast(ray, maxDistance: maxDistance);
      // brute force
      double? bestD;
      for (final b in boxes) {
        final r = b.rayIntersection(ray);
        if (r == null || !r.isActive) {
          continue;
        }
        final d = r.distance!;
        if (maxDistance != null && d > maxDistance) {
          continue;
        }
        if (bestD == null || d < bestD) {
          bestD = d;
        }
      }
      final gotD = got?.distance;
      if (bestD != null) {
        hits++;
      }
      final same =
          (gotD == null && bestD == null) ||
          (gotD != null && bestD != null && (gotD - bestD).abs() < 1e-6);
      if (!same) {
        mismatches++;
        first ??= 'q=$q ray=$ray max=$maxDistance got=$gotD brute=$bestD';
      }
    }
    // The comparison only means something when rays do hit.
    expect(hits, greaterThan(300));
    expect(mismatches, 0, reason: first);
  }

  testWithGame<_SweepGame>(
    'Sweep raycast matches a brute-force raycast',
    _SweepGame.new,
    (game) async {
      await rayFuzz(game, game.collisionDetection, 11);
    },
  );

  testWithGame<_QuadGame>(
    'QuadTree raycast matches a brute-force raycast',
    () {
      final g = _QuadGame();
      g.initializeCollisionDetection(
        mapDimensions: const Rect.fromLTWH(0, 0, 1000, 1000),
        maxObjects: 4,
      );
      return g;
    },
    (game) async {
      await rayFuzz(game, game.collisionDetection, 12);
    },
  );

  testWithGame<_QuadGame>(
    'QuadTree raycast matches a brute-force raycast on a map around the '
    'origin',
    () {
      final g = _QuadGame();
      g.initializeCollisionDetection(
        mapDimensions: const Rect.fromLTWH(-200, -200, 1400, 1400),
        maxObjects: 4,
      );
      return g;
    },
    (game) async {
      await rayFuzz(game, game.collisionDetection, 13);
    },
  );

  test('ShapeCast2D sweeps match fine time stepping', () {
    final rng = Random(21);
    var circleMismatch = 0;
    var rectMismatch = 0;
    String? firstC;
    String? firstR;
    double distToRect(double x, double y, Rect r) {
      final cx = x.clamp(r.left, r.right);
      final cy = y.clamp(r.top, r.bottom);
      return sqrt((x - cx) * (x - cx) + (y - cy) * (y - cy));
    }

    for (var i = 0; i < 4000; i++) {
      final rect = Rect.fromLTWH(
        rng.nextDouble() * 40 - 20,
        rng.nextDouble() * 40 - 20,
        1 + rng.nextDouble() * 30,
        1 + rng.nextDouble() * 30,
      );
      final start = Vector2(
        rng.nextDouble() * 160 - 80,
        rng.nextDouble() * 160 - 80,
      );
      final delta = Vector2(
        rng.nextDouble() * 200 - 100,
        rng.nextDouble() * 200 - 100,
      );
      final radius = 0.5 + rng.nextDouble() * 10;
      // circle
      {
        final out = ShapeCastHit2D();
        final hit = ShapeCast2D.sweepCircleVsRect(
          startCenter: start,
          radius: radius,
          delta: delta,
          obstacleRect: rect,
          out: out,
        );
        double? brute;
        const n = 20000;
        for (var k = 0; k <= n; k++) {
          final t = k / n;
          if (distToRect(start.x + delta.x * t, start.y + delta.y * t, rect) <=
              radius) {
            brute = t;
            break;
          }
        }
        final ok =
            (hit && brute != null && (out.toi - brute).abs() < 2e-3) ||
            (!hit && brute == null) ||
            // grazing tolerance: brute found a hit that only barely touches
            (!hit &&
                brute != null &&
                () {
                  var minD = double.infinity;
                  for (var k = 0; k <= n; k++) {
                    final t = k / n;
                    minD = min(
                      minD,
                      distToRect(
                        start.x + delta.x * t,
                        start.y + delta.y * t,
                        rect,
                      ),
                    );
                  }
                  return radius - minD < 1e-3;
                }()) ||
            (hit &&
                brute == null &&
                () {
                  var minD = double.infinity;
                  for (var k = 0; k <= n; k++) {
                    final t = k / n;
                    minD = min(
                      minD,
                      distToRect(
                        start.x + delta.x * t,
                        start.y + delta.y * t,
                        rect,
                      ),
                    );
                  }
                  return minD - radius < 1e-2;
                }());
        if (!ok) {
          circleMismatch++;
          firstC ??=
              'rect=$rect start=$start delta=$delta r=$radius '
              'hit=$hit toi=${out.toi} brute=$brute';
        }
      }
      // rect
      {
        final w = 1 + rng.nextDouble() * 20;
        final h = 1 + rng.nextDouble() * 20;
        final moving = Rect.fromCenter(
          center: Offset(start.x, start.y),
          width: w,
          height: h,
        );
        final out = ShapeCastHit2D();
        final hit = ShapeCast2D.sweepRectVsRect(
          movingRect: moving,
          delta: delta,
          obstacleRect: rect,
          out: out,
        );
        double? brute;
        const n = 20000;
        for (var k = 0; k <= n; k++) {
          final t = k / n;
          if (moving.translate(delta.x * t, delta.y * t).overlaps(rect)) {
            brute = t;
            break;
          }
        }
        final ok =
            (hit && brute != null && (out.toi - brute).abs() < 2e-3) ||
            (!hit && brute == null);
        if (!ok) {
          rectMismatch++;
          firstR ??=
              'rect=$rect moving=$moving delta=$delta '
              'hit=$hit toi=${out.toi} brute=$brute';
        }
      }
    }
    expect(circleMismatch, 0, reason: firstC);
    expect(rectMismatch, 0, reason: firstR);
  });
}
