import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flame/collisions.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/geometry.dart';
import 'package:flame/grid.dart';
import 'package:flame/math.dart';
import 'package:flame/navigation.dart';
import 'package:flutter_test/flutter_test.dart';

class _BoxColliderEntity({
  required this.id,
  required super.position,
  required super.size,
  required final CollisionType type,
  required final int layer,
  required final int mask,
}) extends PositionComponent with CollisionCallbacks {
  final int id;
  final Set<int> activeContacts = <int>{};
  late final RectangleHitbox hitbox;

  this {
    hitbox =
        RectangleHitbox(
            collisionType: type,
            isSolid: true,
          )
          ..collisionLayer = layer
          ..collisionMask = mask;
  }

  @override
  Future<void> onLoad() async {
    add(hitbox);
  }

  @override
  void onCollisionStart(
    List<Vector2> intersectionPoints,
    PositionComponent other,
  ) {
    super.onCollisionStart(intersectionPoints, other);
    if (other is _BoxColliderEntity) {
      activeContacts.add(other.id);
    }
  }

  @override
  void onCollisionEnd(PositionComponent other) {
    super.onCollisionEnd(other);
    if (other is _BoxColliderEntity) {
      activeContacts.remove(other.id);
    }
  }
}

class _SweepGame({super.world}) extends FlameGame with HasCollisionDetection;

class _QuadGame({super.world})
    extends FlameGame
    with HasQuadTreeCollisionDetection;

/// Exact analytical ray vs axis-aligned rectangle `[left..right]x[top..bottom]`
/// entry distance `t` in `[0..maxDistance]`, or `null` on miss.
double? _rayRectEntryT(Ray2 ray, Rect r, double maxDistance) {
  var tMin = 0.0;
  var tMax = maxDistance;

  if (ray.direction.x.abs() < 1e-12) {
    if (ray.origin.x < r.left || ray.origin.x > r.right) {
      return null;
    }
  } else {
    final inv = 1.0 / ray.direction.x;
    var t1 = (r.left - ray.origin.x) * inv;
    var t2 = (r.right - ray.origin.x) * inv;
    if (t1 > t2) {
      final tmp = t1;
      t1 = t2;
      t2 = tmp;
    }
    if (t1 > tMin) {
      tMin = t1;
    }
    if (t2 < tMax) {
      tMax = t2;
    }
    if (tMin > tMax) {
      return null;
    }
  }

  if (ray.direction.y.abs() < 1e-12) {
    if (ray.origin.y < r.top || ray.origin.y > r.bottom) {
      return null;
    }
  } else {
    final inv = 1.0 / ray.direction.y;
    var t1 = (r.top - ray.origin.y) * inv;
    var t2 = (r.bottom - ray.origin.y) * inv;
    if (t1 > t2) {
      final tmp = t1;
      t1 = t2;
      t2 = tmp;
    }
    if (t1 > tMin) {
      tMin = t1;
    }
    if (t2 < tMax) {
      tMax = t2;
    }
    if (tMin > tMax) {
      return null;
    }
  }
  return tMin;
}

void main() {
  group('Sweep & QuadTree broadphase pair + 200-ray oracle equivalence', () {
    test(
      'matches contact sets and O(N) raycast oracle across 32-bit layer '
      'masks (including bit 31) in both Sweep and QuadTreeBroadphase',
      () async {
        final worldSweep = World();
        final worldQuad = World();
        final sweepGame = _SweepGame(world: worldSweep)
          ..onGameResize(Vector2(2048, 2048));
        final quadGame = _QuadGame(world: worldQuad)
          ..initializeCollisionDetection(
            mapDimensions: const Rect.fromLTWH(0, 0, 2048, 2048),
          )
          ..onGameResize(Vector2(2048, 2048));

        await sweepGame.start();
        await quadGame.start();
        addTearDown(sweepGame.onRemove);
        addTearDown(quadGame.onRemove);

        const layers = <int>[1 << 0, 1 << 3, 1 << 15, 1 << 31];
        final rng = SeededRng(0xC0111DE5);
        final sweepBoxes = <_BoxColliderEntity>[];
        final quadBoxes = <_BoxColliderEntity>[];

        // 240 passive walls + 60 active movers = 300 hitboxes!
        for (var i = 0; i < 300; i++) {
          final isActive = i >= 240;
          final x = 40.0 + rng.nextDouble() * 1900.0;
          final y = 40.0 + rng.nextDouble() * 1900.0;
          final w = 18.0 + rng.nextInt(32);
          final h = 18.0 + rng.nextInt(32);
          final layer = layers[i % layers.length];
          final mask = layers[(i + 1) % layers.length] | layers[0];
          final type = isActive ? CollisionType.active : CollisionType.passive;

          sweepBoxes.add(
            _BoxColliderEntity(
              id: i,
              position: Vector2(x, y),
              size: Vector2(w, h),
              type: type,
              layer: layer,
              mask: mask,
            ),
          );
          quadBoxes.add(
            _BoxColliderEntity(
              id: i,
              position: Vector2(x, y),
              size: Vector2(w, h),
              type: type,
              layer: layer,
              mask: mask,
            ),
          );
        }

        worldSweep.addAll(sweepBoxes);
        worldQuad.addAll(quadBoxes);
        await sweepGame.ready();
        await quadGame.ready();

        // Step 12 frames moving the 60 active colliders while keeping all 240
        // passive colliders asleep!
        for (var step = 0; step < 12; step++) {
          for (var i = 240; i < 300; i++) {
            final dx = (rng.nextDouble() - 0.5) * 40.0;
            final dy = (rng.nextDouble() - 0.5) * 40.0;
            final nx = (sweepBoxes[i].position.x + dx).clamp(30.0, 1960.0);
            final ny = (sweepBoxes[i].position.y + dy).clamp(30.0, 1960.0);
            sweepBoxes[i].position.setValues(nx, ny);
            quadBoxes[i].position.setValues(nx, ny);
          }
          sweepGame.update(1 / 60);
          quadGame.update(1 / 60);
        }

        // Verify Sweep passive sort slept on all frames after frame 1!
        final sweepBroadphase =
            sweepGame.collisionDetection.broadphase as Sweep<ShapeHitbox>;
        expect(sweepBroadphase.passiveSortCount, 1);

        // Verify active contact sets in Sweep and QuadTree match identically!
        for (var i = 240; i < 300; i++) {
          expect(
            quadBoxes[i].activeContacts,
            sweepBoxes[i].activeContacts,
            reason: 'Sweep vs QuadTree contact mismatch for active entity $i',
          );
        }

        // Fire 200 random masked 2D rays and compare Sweep, QuadTree, and
        // brute-force O(N) analytical slab oracle!
        var rayHitsVerified = 0;
        for (var r = 0; r < 200; r++) {
          final ox = 20.0 + rng.nextDouble() * 2000.0;
          final oy = 20.0 + rng.nextDouble() * 2000.0;
          final ang = rng.nextDouble() * math.pi * 2;
          final ray = Ray2(
            origin: Vector2(ox, oy),
            direction: Vector2(math.cos(ang), math.sin(ang)),
          );
          final mask = layers[r % layers.length];
          const maxDist = 700.0;

          // Skip rays originating strictly inside a matching box so interior vs
          // boundary distance conventions don't create trivial ambiguity.
          var insideAny = false;
          double? bestOracleT;
          for (var i = 0; i < 300; i++) {
            final b = sweepBoxes[i];
            if ((b.hitbox.collisionLayer & mask) == 0) {
              continue;
            }
            final rect = Rect.fromLTWH(
              b.position.x,
              b.position.y,
              b.size.x,
              b.size.y,
            );
            if (rect.inflate(0.5).contains(Offset(ox, oy))) {
              insideAny = true;
              break;
            }
            final t = _rayRectEntryT(ray, rect, maxDist);
            if (t != null && (bestOracleT == null || t < bestOracleT)) {
              bestOracleT = t;
            }
          }
          if (insideAny) {
            continue;
          }

          final hitSweep = sweepGame.collisionDetection.raycast(
            ray,
            maxDistance: maxDist,
            collisionMask: mask,
          );
          final hitQuad = quadGame.collisionDetection.raycast(
            ray,
            maxDistance: maxDist,
            collisionMask: mask,
          );

          if (bestOracleT == null) {
            expect(hitSweep, isNull);
            expect(hitQuad, isNull);
          } else {
            expect(hitSweep, isNotNull);
            expect(hitQuad, isNotNull);
            expect(hitSweep!.distance, closeTo(bestOracleT, 1e-2));
            expect(hitQuad!.distance, closeTo(bestOracleT, 1e-2));
            rayHitsVerified++;
          }
        }
        expect(rayHitsVerified, greaterThan(40));
      },
    );
  });

  group(
    '50k px/s CCD anti-tunneling, Kinematic wedges & 128x128 A* vs Flow',
    () {
      test(
        'prevents 50,000 px/s tunneling across 1px walls, arrests 100 random '
        'high-speed KinematicBodyComponent corner impacts, and proves 128x128 '
        'AStarGridPathfinder == FlowField2D shortest-path parity',
        () {
          final hit = ShapeCastHit2D();
          // 1px paper-thin vertical steel sheet at x = 500!
          const razorWall = Rect.fromLTWH(500.0, 0.0, 1.0, 1000.0);

          for (var i = 0; i < 50; i++) {
            final startY = 100.0 + i * 14.0;
            final vy = (i - 25) * 80.0;
            final didHit = ShapeCast2D.sweepCircleVsRect(
              startCenter: Vector2(10.0, startY),
              radius: 4.0,
              delta: Vector2(50000.0 * (1 / 60), vy * (1 / 60)),
              obstacleRect: razorWall,
              out: hit,
            );
            expect(didHit, isTrue);
            final stopX = 10.0 + (50000.0 / 60.0) * hit.toi;
            expect(stopX, closeTo(496.0, 1e-3));
          }

          // 100 random high-velocity trajectories inside a walled arena with
          // interior pillars: actor MUST NEVER tunnel into any solid obstacle!
          final arenaObstacles = <Rect>[
            const Rect.fromLTWH(0, 0, 400, 20), // top
            const Rect.fromLTWH(0, 380, 400, 20), // bottom
            const Rect.fromLTWH(0, 0, 20, 400), // left
            const Rect.fromLTWH(380, 0, 20, 400), // right
            const Rect.fromLTWH(180, 140, 40, 120), // center pillar
          ];
          final rng = SeededRng(0x778899AA);
          final actor = KinematicBodyComponent(
            position: Vector2(80, 80),
            size: Vector2(16, 16),
            obstacleQuery: (_, out) => out.addAll(arenaObstacles),
          );
          for (var step = 0; step < 100; step++) {
            actor.velocity.setValues(
              (rng.nextDouble() - 0.5) * 3600.0,
              (rng.nextDouble() - 0.5) * 3600.0,
            );
            actor.moveAndSlide(1 / 30);
            final box = actor.computeWorldBounds().deflate(0.05);
            for (final obs in arenaObstacles) {
              expect(
                box.overlaps(obs),
                isFalse,
                reason: 'Kinematic penetration at step $step: $box vs $obs',
              );
            }
          }

          // 128x128 (16,384-cell) maze: 4-way AStarGridPathfinder path length
          // MUST equal FlowField2D integration cost from every sampled start!
          const w = 128;
          const h = 128;
          final astar = AStarGridPathfinder(width: w, height: h);
          final flow = FlowField2D(width: w, height: h);

          for (var r = 0; r < h; r++) {
            for (var c = 0; c < w; c++) {
              // Keep goal (64, 64) clear, scatter ~22% random obstacles.
              final blocked = (c != 64 || r != 64) && rng.nextDouble() < 0.22;
              astar.setBlocked(c, r, blocked: blocked);
              flow.setBlocked(c, r, blocked: blocked);
            }
          }

          const goal = GridCell(64, 64);
          flow.bake(const <GridCell>[goal]);
          final path = <GridCell>[];
          var reachableChecked = 0;

          for (var q = 0; q < 80; q++) {
            final sc = rng.nextInt(w);
            final sr = rng.nextInt(h);
            if (astar.isBlocked(sc, sr)) {
              continue;
            }
            final found = astar.findPath(GridCell(sc, sr), goal, path);
            final flowCost = flow.costAt(sc, sr);
            if (!found) {
              expect(flowCost.isInfinite, isTrue);
            } else {
              expect(path.length - 1, flowCost.round());
              reachableChecked++;
            }
          }
          expect(reachableChecked, greaterThan(30));
        },
      );
    },
  );
}
