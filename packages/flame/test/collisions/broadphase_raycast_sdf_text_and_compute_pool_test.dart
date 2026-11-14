import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/collisions.dart';
import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/geometry.dart';
import 'package:flame/text.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

int _isolateSumTask(int n) {
  var sum = 0;
  for (var i = 1; i <= n; i++) {
    sum += i;
  }
  return sum;
}

Future<String> _delayedLabelTask((int ms, String tag) input) async {
  final (ms, tag) = input;
  await Future<void>.delayed(Duration(milliseconds: ms));
  return tag;
}

TransferableTypedData _doubleFloat32InIsolate(TransferableTypedData packed) {
  final values = EngineComputePool.unpackFloat32(packed);
  final out = Float32List(values.length);
  for (var i = 0; i < values.length; i++) {
    out[i] = values[i] * 2.5;
  }
  return EngineComputePool.packFloat32(out);
}

class _QuadTreeTestGame() extends FlameGame with HasQuadTreeCollisionDetection;

void main() {
  group('Static-Sleeping Sweep & Broadphase '
      'Raycasting, SdfFontAtlas / SdfTextComponent & EngineComputePool', () {
    test(
      'Static-sleeping Sweep skips passive re-sorts on calm '
      'frames and accelerates 2D raycast / raycastAll / raytrace with '
      'collisionMask in both Sweep and QuadTreeBroadphase',
      () async {
        // 1. Sweep static-sleeping + sub-linear raycast pruning + collisionMask
        final game = FlameGame();
        final detection = StandardCollisionDetection<Sweep<ShapeHitbox>>();
        final world = World();
        game.world = world;
        game.onGameResize(Vector2(1000, 1000));
        await game.start();
        addTearDown(() {
          if (game.isMounted) {
            game.onRemove();
          }
        });

        const layerWall = 0x01;
        const layerGhost = 0x02;

        // Add 400 static passive wall hitboxes across x = 0..20,000.
        final walls = <RectangleHitbox>[];
        for (var i = 0; i < 400; i++) {
          final box = RectangleHitbox(
            position: Vector2(i * 50.0, 100),
            size: Vector2(20, 20),
            collisionType: CollisionType.passive,
          )..collisionLayer = layerWall;
          walls.add(box);
          final holder = PositionComponent(children: [box]);
          world.add(holder);
          detection.add(box);
        }

        // Add 1 ghost hitbox in front of wall[2] on layerGhost.
        final ghost = RectangleHitbox(
          position: Vector2(80, 100),
          size: Vector2(20, 20),
          collisionType: CollisionType.passive,
        )..collisionLayer = layerGhost;
        world.add(PositionComponent(children: [ghost]));
        detection.add(ghost);

        await game.ready();

        // First run builds and sorts passive bucket once.
        detection.run();
        final initialPassiveSorts = detection.broadphase.passiveSortCount;
        expect(initialPassiveSorts, 1);

        // 20 calm simulation ticks with 400 stationary passive walls -> ZERO
        // additional passive sorts and O(1) empty-active query!
        for (var t = 0; t < 20; t++) {
          detection.run();
        }
        expect(detection.broadphase.passiveSortCount, initialPassiveSorts);

        // Cast a short ray from (72, 110) rightwards with maxDistance = 120:
        // Sweep X-interval pruning stops early -> tests << 400 hitboxes!
        final shortRay = Ray2(
          origin: Vector2(72, 110),
          direction: Vector2(1, 0),
        );
        final hitAny = detection.raycast(shortRay, maxDistance: 120);
        expect(hitAny, isNotNull);
        expect(hitAny!.hitbox, same(ghost));
        expect(detection.lastRaycastCandidatesTested, lessThan(15));

        // Filter out layerGhost via collisionMask: ray passes straight through
        // ghost at x=80 and hits wall[2] at x=100!
        final hitWallOnly = detection.raycast(
          shortRay,
          maxDistance: 120,
          collisionMask: layerWall,
        );
        expect(hitWallOnly, isNotNull);
        expect(hitWallOnly!.hitbox, same(walls[2]));

        // Verify raycastAll and raytrace also honor collisionMask!
        final burstHits = detection.raycastAll(
          Vector2(72, 110),
          numberOfRays: 8,
          maxDistance: 60,
          collisionMask: layerWall,
        );
        expect(burstHits.any((r) => r.hitbox == ghost), isFalse);

        final traceHits = detection
            .raytrace(shortRay, maxDepth: 2, collisionMask: layerWall)
            .toList();
        expect(traceHits, isNotEmpty);
        expect(traceHits.first.hitbox, same(walls[2]));

        // 2. QuadTreeBroadphase spatial ray pruning + collisionMask!
        game.onRemove();
        final qtGame = _QuadTreeTestGame();
        qtGame.initializeCollisionDetection(
          mapDimensions: const ui.Rect.fromLTWH(0, 0, 2000, 2000),
          maxObjects: 4,
        );
        qtGame.onGameResize(Vector2(2000, 2000));
        await qtGame.start();
        addTearDown(qtGame.onRemove);
        for (var gy = 0; gy < 15; gy++) {
          for (var gx = 0; gx < 15; gx++) {
            final hb = RectangleHitbox(
              size: Vector2(20, 20),
              collisionType: CollisionType.passive,
            )..collisionLayer = (gx == 1 && gy == 1) ? layerGhost : layerWall;
            qtGame.world.add(
              PositionComponent(
                position: Vector2(gx * 120.0 + 40, gy * 120.0 + 40),
                size: Vector2(20, 20),
                children: [hb],
              ),
            );
          }
        }
        await qtGame.ready();
        qtGame.update(1 / 60);

        final qtDetection = qtGame.collisionDetection;
        final qtRay = Ray2(
          origin: Vector2(70, 170),
          direction: Vector2(1, 0),
        );
        // Hits ghost at (160, 160) when mask includes layerGhost, and skips
        // ghost to hit wall at (280, 160) when mask == layerWall!
        final qtHitAll = qtDetection.raycast(qtRay, maxDistance: 350);
        expect(qtHitAll, isNotNull);
        expect(qtHitAll!.distance, closeTo(90.0, 1e-3));
        expect(
          qtDetection.lastRaycastCandidatesTested,
          lessThan(40), // Pruned out of 225 hitboxes!
        );

        final qtHitWall = qtDetection.raycast(
          qtRay,
          maxDistance: 350,
          collisionMask: layerWall,
        );
        expect(qtHitWall, isNotNull);
        expect(qtHitWall!.distance, closeTo(210.0, 1e-3));
      },
    );

    test(
      'SdfFontAtlas Felzenszwalb-Huttenlocher 2D EDT distance '
      'accuracy, async GPU atlas bake & SdfTextComponent multi-pass rendering',
      () async {
        // 1. Exact mathematical verification of 2D Euclidean Distance Transform
        // on a 32x32 mask containing an interior filled square [8..23]x[8..23].
        const w = 32;
        const h = 32;
        final mask = Uint8List(w * h);
        for (var y = 8; y < 24; y++) {
          for (var x = 8; x < 24; x++) {
            mask[y * w + x] = 255;
          }
        }
        final sdf = SdfFontAtlas.computeSignedDistanceField(
          mask,
          w,
          h,
        );

        // Deep center (16, 16) is 8.5px inside -> clamped to 255!
        expect(sdf[16 * w + 16], greaterThanOrEqualTo(245));
        // Far corner (0, 0) is > 8px outside -> clamped to 0!
        expect(sdf[0], 0);
        // Inside boundary pixel (8, 16) is +0.5px inside -> strictly > 128!
        final insideEdge = sdf[16 * w + 8];
        // Outside boundary pixel (7, 16) is -0.5px outside -> strictly < 128!
        final outsideEdge = sdf[16 * w + 7];
        expect(insideEdge, greaterThan(128));
        expect(outsideEdge, lessThan(128));
        // Symmetric around 128!
        expect((insideEdge - 128) - (128 - outsideEdge), closeTo(0, 2));

        // 2. Bake full GPU SdfFontAtlas and render SdfTextComponent with
        // outline, glow, and drop shadow at 4x camera zoom!
        final sdfAtlas = await SdfFontAtlas.bake(
          style: const TextStyle(fontSize: 28),
          charset: 'SDF 123!',
          spreadPx: 6.0,
        );
        expect(sdfAtlas.isDisposed, isFalse);
        expect(sdfAtlas.glyphCount, greaterThanOrEqualTo(8));
        expect(sdfAtlas.measureLineWidth('SDF 123!'), greaterThan(20.0));

        final game = FlameGame();
        game.onGameResize(Vector2(400, 300));
        await game.start();
        addTearDown(game.onRemove);
        game.camera.viewfinder.zoom = 4.0;

        final sdfLabel = SdfTextComponent(
          atlas: sdfAtlas,
          text: 'SDF 123!\n123',
          textAlign: TextAlign.center,
          style: const SdfTextStyle(
            color: ui.Color(0xFFFFEE55),
            outlineWidth: 2.0,
            outlineColor: ui.Color(0xFF1A1026),
            glowRadius: 3.0,
            glowColor: ui.Color(0x88FF8800),
            shadowOffset: ui.Offset(2, 3),
            shadowColor: ui.Color(0xAA000000),
          ),
        );
        game.world.add(sdfLabel);
        await game.ready();
        expect(sdfLabel.size.x, greaterThan(20.0));
        expect(sdfLabel.size.y, greaterThan(30.0));

        final rec = ui.PictureRecorder();
        game.render(ui.Canvas(rec, const ui.Rect.fromLTWH(0, 0, 400, 300)));
        rec.endRecording().dispose();
        // Shadow + glow + outline + fill = 4 batched drawRawAtlas calls!
        expect(sdfLabel.lastDrawCalls, 4);

        sdfAtlas.dispose();
        expect(sdfAtlas.isDisposed, isTrue);
      },
    );

    test(
      'EngineComputePool multi-isolate execution, priority '
      'scheduling, cancellation, inline fallback & TransferableTypedData',
      () async {
        // 1. Multi-worker background Isolate pool (workerCount: 2) + zero-copy
        // TransferableTypedData roundtrip.
        final pool = EngineComputePool();
        await pool.warmUp();

        final sums = await Future.wait([
          pool.schedule(_isolateSumTask, 100),
          pool.schedule(_isolateSumTask, 1000),
          pool.schedule(_isolateSumTask, 5000),
        ]);
        expect(sums, [5050, 500500, 12502500]);
        expect(pool.completedTaskCount, 3);

        final srcFloats = Float32List.fromList([1.0, 2.0, 4.0, 8.0]);
        final replyPacked = await pool.schedule(
          _doubleFloat32InIsolate,
          EngineComputePool.packFloat32(srcFloats),
          priority: ComputePriority.high,
        );
        final outFloats = EngineComputePool.unpackFloat32(replyPacked);
        expect(outFloats, [2.5, 5.0, 10.0, 20.0]);

        await pool.dispose();
        expect(pool.isDisposed, isTrue);

        // 2. Deterministic priority ordering & instant queued cancellation on a
        // 1-worker inline pool (workerCount: 0).
        final inlinePool = EngineComputePool(workerCount: 0);
        final completionOrder = <String>[];

        // First task occupies the runner for 30ms; while occupied, enqueue
        // low, cancelled-normal, and high -> high MUST run before low, and
        // cancelled-normal MUST throw ComputeCancelledException!
        final first = inlinePool
            .schedule(_delayedLabelTask, (30, 'first'))
            .then(completionOrder.add);
        final low = inlinePool
            .schedule(
              _delayedLabelTask,
              (1, 'low'),
              priority: ComputePriority.low,
            )
            .then(completionOrder.add);

        final cancelToken = ComputeCancellationToken();
        final cancelledFuture = inlinePool.schedule(
          _delayedLabelTask,
          (1, 'cancelled'),
          cancelToken: cancelToken,
        );
        final high = inlinePool
            .schedule(
              _delayedLabelTask,
              (1, 'high'),
              priority: ComputePriority.high,
            )
            .then(completionOrder.add);

        // Cancel the queued normal task immediately before 'first' finishes!
        cancelToken.cancel();
        await expectLater(
          cancelledFuture,
          throwsA(isA<ComputeCancelledException>()),
        );

        await Future.wait([first, low, high]);
        expect(completionOrder, ['first', 'high', 'low']);

        await inlinePool.dispose();
      },
    );
  });
}
