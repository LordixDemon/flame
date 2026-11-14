import 'dart:ui' show Offset, Rect;

import 'package:flame/collisions.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

class _MaskActor({
  required super.position,
  required super.size,
  required int layer,
  required int mask,
}) extends PositionComponent with CollisionCallbacks {
  final Set<PositionComponent> contacts = <PositionComponent>{};
  final RectangleHitbox hitbox = RectangleHitbox(isSolid: true)
    ..collisionLayer = layer
    ..collisionMask = mask;

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
    contacts.add(other);
  }

  @override
  void onCollisionEnd(PositionComponent other) {
    super.onCollisionEnd(other);
    contacts.remove(other);
  }
}

class _CollisionWorldGame({super.world})
    extends FlameGame
    with HasCollisionDetection;

void main() {
  group('32-bit collisionLayer & collisionMask bitmask filtering', () {
    test(
      'asymmetric masks, bit 31 & runtime mask toggling work cleanly',
      () async {
        final world = World();
        final game = _CollisionWorldGame(world: world)
          ..onGameResize(Vector2(400, 300));
        await game.start();
        await game.ready();

        const bitPlayer = 1 << 0;
        const bitProjectile = 1 << 5;
        const bitSensor31 = 1 << 31;

        // Asymmetric mask: projectile wants bitPlayer, while player initially
        // ignores bitProjectile! Mutual `(A.layer & B.mask) != 0 &&
        // (B.layer & A.mask) != 0` requires both sides to opt in.
        final player = _MaskActor(
          position: Vector2(20, 20),
          size: Vector2(30, 30),
          layer: bitPlayer,
          mask: bitSensor31,
        );
        final bullet = _MaskActor(
          position: Vector2(25, 25),
          size: Vector2(12, 12),
          layer: bitProjectile,
          mask: bitPlayer,
        );
        final highBitZone = _MaskActor(
          position: Vector2(22, 22),
          size: Vector2(20, 20),
          layer: bitSensor31,
          mask: bitPlayer,
        );

        world.addAll(<Component>[player, bullet, highBitZone]);
        await game.ready();
        game.update(1 / 60);

        expect(player.contacts, contains(highBitZone));
        expect(player.contacts, isNot(contains(bullet)));

        // Enable bitProjectile on player at runtime -> collision starts!
        player.hitbox.collisionMask |= bitProjectile;
        game.update(1 / 60);
        expect(player.contacts, contains(bullet));

        // Disable bitProjectile again -> collision ends cleanly!
        player.hitbox.collisionMask &= ~bitProjectile;
        game.update(1 / 60);
        expect(player.contacts, isNot(contains(bullet)));
      },
    );
  });

  group('CollisionManifold2D & ShapeCast2D analytical edge cases', () {
    test('coincident circles, deep-interior circleVsRect & rectVsRect MTV', () {
      final m = CollisionManifold2D();
      final mtv = Vector2.zero();

      // Exact coincident centers must not produce NaN!
      expect(
        CollisionManifold2D.circleVsCircle(
          centerA: Vector2(50, 50),
          radiusA: 10,
          centerB: Vector2(50, 50),
          radiusB: 14,
          out: m,
        ),
        isTrue,
      );
      expect(m.normal.length, closeTo(1.0, 1e-6));
      expect(m.depth, closeTo(24.0, 1e-6));

      // Circle center strictly inside rectB pushes out through nearest face!
      const box = Rect.fromLTWH(100, 100, 80, 60);
      expect(
        CollisionManifold2D.circleVsRect(
          circleCenter: Vector2(172, 130), // 8px from right face!
          radius: 10,
          rectB: box,
          out: m,
        ),
        isTrue,
      );
      expect(m.normal, Vector2(1, 0));
      expect(m.depth, closeTo(18.0, 1e-6));

      // Applying rectVsRect MTV resolves overlap completely to false.
      const rA = Rect.fromLTWH(90, 110, 25, 20);
      expect(
        CollisionManifold2D.rectVsRect(rectA: rA, rectB: box, out: m),
        isTrue,
      );
      m.writeMtv(mtv);
      final pushedA = rA.shift(Offset(mtv.x, mtv.y));
      expect(
        CollisionManifold2D.rectVsRect(rectA: pushedA, rectB: box, out: m),
        isFalse,
      );
    });

    test(
      'ShapeCast2D distinguishes rounded Voronoi corner hit vs near-miss',
      () {
        final hit = ShapeCastHit2D();
        const wall = Rect.fromLTWH(100, 100, 40, 40);

        // Grazing pass that clips the inflated square AABB corner `(90, 90)` at
        // `(91, 91)` (`dist = sqrt(81 + 81) = 12.72 > radius 10`) MUST miss the
        // true rounded Minkowski corner!
        expect(
          ShapeCast2D.sweepCircleVsRect(
            startCenter: Vector2(82, 100),
            radius: 10,
            delta: Vector2(18, -18),
            obstacleRect: wall,
            out: hit,
          ),
          isFalse,
        );

        // Direct diagonal sweep into corner `(100, 100)` hits with 45-deg norm.
        expect(
          ShapeCast2D.sweepCircleVsRect(
            startCenter: Vector2(80, 80),
            radius: 10,
            delta: Vector2(30, 30),
            obstacleRect: wall,
            out: hit,
            collider: 'corner_wall',
          ),
          isTrue,
        );
        expect(hit.collider, 'corner_wall');
        expect(hit.toi, inExclusiveRange(0.0, 1.0));
        expect(hit.normal.x, closeTo(-0.7071, 1e-3));
        expect(hit.normal.y, closeTo(-0.7071, 1e-3));

        // Initial overlap returns toi == 0.0; zero delta outside returns false.
        expect(
          ShapeCast2D.sweepRectVsRect(
            movingRect: const Rect.fromLTWH(110, 110, 10, 10),
            delta: Vector2(50, 0),
            obstacleRect: wall,
            out: hit,
          ),
          isTrue,
        );
        expect(hit.toi, 0.0);
        expect(
          ShapeCast2D.sweepRectVsRect(
            movingRect: const Rect.fromLTWH(10, 10, 10, 10),
            delta: Vector2.zero(),
            obstacleRect: wall,
            out: hit,
          ),
          isFalse,
        );
      },
    );
  });

  group('KinematicBodyComponent & TriggerZoneComponent edge cases', () {
    test(
      'KinematicBodyComponent concave corner arrest, ceiling, floor & bounce',
      () {
        const floor = Rect.fromLTWH(0, 200, 400, 40);
        const rightWall = Rect.fromLTWH(200, 0, 40, 240);
        const ceiling = Rect.fromLTWH(0, 0, 400, 20);
        final obstacles = <Rect>[floor, rightWall, ceiling];

        // Moving diagonally into a 90-degree concave corner slides along the
        // first surface and arrests cleanly against the second!
        final actor = KinematicBodyComponent(
          position: Vector2(170, 170),
          size: Vector2(20, 20),
          anchor: Anchor.center,
          velocity: Vector2(300, 300),
          gravity: Vector2(0, 500),
          linearDamping: 1.0,
          obstacleQuery: (bounds, out) => out.addAll(obstacles),
        )..integrateForces(0.05);
        final slides = actor.moveAndSlide(0.2);
        expect(slides, greaterThanOrEqualTo(2));
        expect(actor.isOnFloor, isTrue);
        expect(actor.isOnWall, isTrue);
        final worldBox = actor.computeWorldBounds();
        expect(worldBox.right, lessThanOrEqualTo(200.05));
        expect(worldBox.bottom, lessThanOrEqualTo(200.05));

        // Upward velocity hits ceiling and sets isOnCeiling; elastic bounciness
        // reflects velocity downward!
        final bouncy = KinematicBodyComponent(
          position: Vector2(80, 40),
          size: Vector2(16, 16),
          velocity: Vector2(0, -400),
          bounciness: 0.8,
        )..moveAndSlide(0.1, explicitObstacles: obstacles);
        expect(bouncy.isOnCeiling, isTrue);
        expect(bouncy.velocity.y, closeTo(320.0, 1e-3));
      },
    );

    test(
      'TriggerZoneComponent circle-vs-large-AABB, unmount & spatial parity',
      () async {
        for (final useSpatialIndex in <bool>[false, true]) {
          final world = World(spatialIndexEnabled: useSpatialIndex);
          final game = FlameGame(world: world)..onGameResize(Vector2(400, 300));
          await game.start();
          await game.ready();

          final entered = <PositionComponent>[];
          final stayed = <PositionComponent>[];
          final exited = <PositionComponent>[];

          final circleZone = TriggerZoneComponent(
            position: Vector2(100, 100),
            size: Vector2(40, 40),
            anchor: Anchor.center,
            zoneShape: TriggerZoneShape.circle,
            radius: 20,
            onEntityEntered: entered.add,
            onEntityStay: (e, _) => stayed.add(e),
            onEntityExited: exited.add,
          );

          // Large boss AABB whose center `(155, 100)` is `55px > radius 20`
          // away, yet its left edge `(155 - 45 = 110)` penetrates `120`!
          final largeBoss = PositionComponent(
            position: Vector2(155, 100),
            size: Vector2(90, 90),
            anchor: Anchor.center,
          );

          world.addAll(<Component>[circleZone, largeBoss]);
          await game.ready();
          game.update(1 / 60);

          expect(circleZone.isOccupied, isTrue);
          expect(entered, <PositionComponent>[largeBoss]);
          expect(stayed, <PositionComponent>[largeBoss]);

          // Removing entity while inside zone fires onEntityExited next tick!
          largeBoss.removeFromParent();
          await game.ready();
          game.update(1 / 60);
          expect(circleZone.isOccupied, isFalse);
          expect(exited, <PositionComponent>[largeBoss]);

          // Unmounting the zone clears internal sets cleanly.
          final probe = PositionComponent(
            position: Vector2(100, 100),
            size: Vector2(10, 10),
            anchor: Anchor.center,
          );
          world.add(probe);
          await game.ready();
          game.update(1 / 60);
          expect(circleZone.isOccupied, isTrue);

          circleZone.removeFromParent();
          await game.ready();
          expect(circleZone.isOccupied, isFalse);
        }
      },
    );
  });
}
