import 'dart:ui' show Rect;

import 'package:flame/collisions.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _SweepCollisionGame() extends FlameGame with HasCollisionDetection;

class _QuadTreeGame() extends FlameGame with HasQuadTreeCollisionDetection {
  @override
  Future<void> onLoad() async {
    initializeCollisionDetection(
      mapDimensions: const Rect.fromLTWH(-500, -500, 1000, 1000),
    );
  }
}

class _MaskedCollider({
  required super.position,
  required final int layer,
  required final int mask,
}) extends PositionComponent with CollisionCallbacks {
  int startHits = 0;

  this : super(size: Vector2.all(20));

  @override
  Future<void> onLoad() async {
    add(
      RectangleHitbox()
        ..collisionLayer = layer
        ..collisionMask = mask,
    );
  }

  @override
  void onCollisionStart(
    List<Vector2> intersectionPoints,
    PositionComponent other,
  ) {
    super.onCollisionStart(intersectionPoints, other);
    startHits++;
  }
}

void main() {
  group('32-bit Masks, MTV Manifold, ShapeCast2D, KinematicBody & Trigger', () {
    test(
      '32-bit collisionLayer & collisionMask filter pairs in both Sweep and '
      'QuadTree broadphases (#14)',
      () async {
        const layerPlayer = 1 << 0;
        const layerEnemy = 1 << 1;
        const layerTrigger = 1 << 2;

        // 1. Default Sweep broadphase.
        final sweepGame = _SweepCollisionGame()
          ..onGameResize(Vector2(400, 400));
        await sweepGame.start();
        final player = _MaskedCollider(
          position: Vector2(50, 50),
          layer: layerPlayer,
          mask: layerEnemy,
        );
        final enemy = _MaskedCollider(
          position: Vector2(55, 55),
          layer: layerEnemy,
          mask: layerPlayer,
        );
        final allyGhost = _MaskedCollider(
          position: Vector2(52, 52),
          layer: layerTrigger,
          mask: layerTrigger,
        );

        sweepGame.world.addAll(<Component>[player, enemy, allyGhost]);
        await sweepGame.ready();
        sweepGame.update(1.0 / 60.0);

        expect(player.startHits, 1);
        expect(enemy.startHits, 1);
        expect(allyGhost.startHits, 0);

        // 2. QuadTree broadphase.
        final qtGame = _QuadTreeGame()..onGameResize(Vector2(400, 400));
        await qtGame.start();
        final qtA = _MaskedCollider(
          position: Vector2(10, 10),
          layer: layerPlayer,
          mask: layerEnemy,
        );
        final qtIgnored = _MaskedCollider(
          position: Vector2(12, 12),
          layer: layerTrigger,
          mask: layerTrigger,
        );
        final qtMatch = _MaskedCollider(
          position: Vector2(14, 14),
          layer: layerEnemy,
          mask: layerPlayer,
        );
        qtGame.world.addAll(<Component>[qtA, qtIgnored, qtMatch]);
        await qtGame.ready();
        qtGame.update(1.0 / 60.0);

        expect(qtA.startHits, 1);
        expect(qtMatch.startHits, 1);
        expect(qtIgnored.startHits, 0);
      },
    );

    test(
      'CollisionManifold2D computes exact MTV push-out & ShapeCast2D prevents '
      'thin-wall tunneling (#15)',
      () {
        final manifold = CollisionManifold2D();
        expect(
          CollisionManifold2D.circleVsCircle(
            centerA: Vector2(0, 0),
            radiusA: 10,
            centerB: Vector2(15, 0),
            radiusB: 10,
            out: manifold,
          ),
          isTrue,
        );
        expect(manifold.depth, closeTo(5.0, 1e-5));
        expect(manifold.normal.x, closeTo(-1.0, 1e-5));

        // Circle center deeply inside Rect still resolves nearest face!
        expect(
          CollisionManifold2D.circleVsRect(
            circleCenter: Vector2(12, 50),
            radius: 5,
            rectB: const Rect.fromLTWH(10, 0, 100, 100),
            out: manifold,
          ),
          isTrue,
        );
        expect(manifold.normal.x, closeTo(-1.0, 1e-5));
        expect(manifold.depth, closeTo(7.0, 1e-5));

        // Fast projectile sweeping 200px across a 2px-thin wall at x = 100!
        final hit = ShapeCastHit2D();
        final impacted = ShapeCast2D.sweepCircleVsRect(
          startCenter: Vector2(0, 50),
          radius: 4,
          delta: Vector2(200, 0),
          obstacleRect: const Rect.fromLTWH(100, 0, 2, 100),
          out: hit,
          collider: 'thin_wall',
        );
        expect(impacted, isTrue);
        // Center stops at x = 96 => toi = 96 / 200 = 0.48!
        expect(hit.toi, closeTo(0.48, 1e-5));
        expect(hit.normal.x, closeTo(-1.0, 1e-5));
        expect(hit.collider, 'thin_wall');
      },
    );

    test(
      'KinematicBodyComponent slides along walls, detects floors, and bounces '
      '(#16)',
      () {
        final obstacles = <Rect>[
          const Rect.fromLTWH(0, 100, 300, 20), // floor at y=100
          const Rect.fromLTWH(150, 0, 20, 120), // vertical wall at x=150
        ];

        final body = KinematicBodyComponent(
          position: Vector2(100, 70),
          size: Vector2(20, 20),
          velocity: Vector2(200, 200),
          obstacleQuery: (_, out) => out.addAll(obstacles),
        );

        // Step 0.2s: hits floor at y=80 (top-left) AND slides into right wall
        // at x=130!
        final contacts = body.moveAndSlide(0.2);
        expect(contacts, greaterThanOrEqualTo(1));
        expect(body.position.y, lessThanOrEqualTo(80.1));
        expect(body.position.x, lessThanOrEqualTo(130.1));

        // Elastic bounce test against vertical wall.
        final bouncy = KinematicBodyComponent(
          position: Vector2(100, 20),
          size: Vector2(10, 10),
          velocity: Vector2(300, 0),
          bounciness: 1.0,
        );
        bouncy.moveAndSlide(0.2, explicitObstacles: obstacles);
        expect(bouncy.velocity.x, lessThan(0));
        expect(bouncy.isOnWall, isTrue);
      },
    );

    test(
      'TriggerZoneComponent fires Enter -> Stay -> Exit lifecycle hooks (#17)',
      () async {
        final events = <String>[];
        final world = World(spatialIndexEnabled: true);
        final game = FlameGame(world: world)..onGameResize(Vector2(400, 400));
        await game.start();

        final zone = TriggerZoneComponent(
          position: Vector2(100, 100),
          size: Vector2(60, 60),
          anchor: Anchor.center,
          onEntityEntered: (_) => events.add('enter'),
          onEntityStay: (_, _) => events.add('stay'),
          onEntityExited: (_) => events.add('exit'),
        );
        final token = PositionComponent(
          position: Vector2(10, 10),
          size: Vector2(16, 16),
          anchor: Anchor.center,
        );

        world.addAll(<Component>[zone, token]);
        await game.ready();

        game.update(0.016);
        expect(events, isEmpty);

        // Move token inside zone -> enter + stay.
        token.position.setValues(100, 100);
        game.update(0.016);
        expect(events, <String>['enter', 'stay']);
        expect(zone.isOccupied, isTrue);

        // Remain inside -> stay only.
        game.update(0.016);
        expect(events, <String>['enter', 'stay', 'stay']);

        // Move outside -> exit!
        token.position.setValues(300, 300);
        game.update(0.016);
        expect(events, <String>['enter', 'stay', 'stay', 'exit']);
        expect(zone.isOccupied, isFalse);
      },
    );
  });
}
