import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/cache.dart';
import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame/math.dart';
import 'package:flutter_test/flutter_test.dart';

int _isolatedFibonacciSum(int n) {
  var a = 0;
  var b = 1;
  var sum = 0;
  for (var i = 0; i < n; i++) {
    sum = (sum + b) & 0x3FFFFFFF;
    final next = (a + b) & 0x3FFFFFFF;
    a = b;
    b = next;
  }
  return sum;
}

class _FocusableTile({
  required this.tileId,
  required Vector2 position,
  required int order,
}) extends PositionComponent with FocusableComponent {
  this : super(position: position, size: Vector2.all(24)) {
    focusOrder = order;
  }

  final int tileId;
  int gainCount = 0;
  int lostCount = 0;
  int activateCount = 0;

  @override
  void onFocusGain() => gainCount++;

  @override
  void onFocusLost() => lostCount++;

  @override
  void onFocusActivate() => activateCount++;
}

class _InterpolatedSpinner()
    extends PositionComponent
    with HasFixedUpdate, FixedTransformInterpolation {
  double angularVelocity = 0.0;
  Vector2 linearVelocity = Vector2.zero();

  @override
  void fixedUpdate(double dt) {
    position.addScaled(linearVelocity, dt);
    angle += angularVelocity * dt;
  }
}

void main() {
  group('MaxRectsBinPacker & DynamicSpriteAtlas zero-overlap stress', () {
    test(
      'packs 400 heterogeneous rects with 0 pairwise overlaps and builds '
      '150-sprite extruded DynamicSpriteAtlas cleanly',
      () {
        final rng = SeededRng(0xA71A5);
        final packer = MaxRectsBinPacker(binWidth: 1024, binHeight: 1024);
        final placed = <PackedAtlasRect>[];
        var placedArea = 0;

        for (var i = 0; i < 400; i++) {
          final w = 4 + rng.nextInt(60);
          final h = 4 + rng.nextInt(60);
          final r = packer.insert(w, h);
          if (r != null) {
            expect(r.x, greaterThanOrEqualTo(0));
            expect(r.y, greaterThanOrEqualTo(0));
            expect(r.x + r.width, lessThanOrEqualTo(1024));
            expect(r.y + r.height, lessThanOrEqualTo(1024));
            placed.add(r);
            placedArea += w * h;
          }
        }

        expect(placed.length, greaterThan(350));
        expect(
          packer.occupancy,
          closeTo(placedArea / (1024 * 1024), 1e-9),
        );

        // Pairwise O(N^2) zero-overlap oracle across all packed rects:
        for (var i = 0; i < placed.length; i++) {
          final a = placed[i];
          for (var j = i + 1; j < placed.length; j++) {
            final b = placed[j];
            final separated =
                a.x + a.width <= b.x ||
                b.x + b.width <= a.x ||
                a.y + a.height <= b.y ||
                b.y + b.height <= a.y;
            expect(
              separated,
              isTrue,
              reason: 'Atlas rects $i and $j overlapped!',
            );
          }
        }

        // Reject degenerate and oversized rects deterministically:
        expect(packer.insert(0, 16), isNull);
        expect(packer.insert(16, -4), isNull);
        expect(packer.insert(2048, 16), isNull);

        // DynamicSpriteAtlasBuilder with 150 procedural icons + 2px extrusion:
        final builder = DynamicSpriteAtlas.builder(
          maxAtlasDimension: 1024,
        );
        for (var i = 0; i < 150; i++) {
          final w = 8 + (i % 7) * 4;
          final h = 8 + ((i ~/ 7) % 5) * 4;
          builder.addProcedural(
            'icon_$i',
            width: w,
            height: h,
            painter: (canvas, size) {
              canvas.drawRect(
                ui.Offset.zero & size,
                ui.Paint()
                  ..color = ui.Color(0xFF000000 | ((i * 7919) & 0xFFFFFF)),
              );
            },
          );
        }
        final atlas = builder.buildSync();
        addTearDown(atlas.dispose);

        expect(atlas.keys.length, 150);
        // Verify padded regions never collide inside the baked GPU image:
        final paddedRects = <ui.Rect>[];
        for (var i = 0; i < 150; i++) {
          final reg = atlas.regionOf('icon_$i')!;
          expect(reg.left, greaterThanOrEqualTo(2.0));
          expect(reg.top, greaterThanOrEqualTo(2.0));
          expect(reg.right, lessThanOrEqualTo(atlas.atlasImage.width - 2.0));
          expect(reg.bottom, lessThanOrEqualTo(atlas.atlasImage.height - 2.0));
          paddedRects.add(reg.inflate(2.0));
        }
        for (var i = 0; i < paddedRects.length; i++) {
          for (var j = i + 1; j < paddedRects.length; j++) {
            final inter = paddedRects[i].intersect(paddedRects[j]);
            expect(inter.width <= 0.0 || inter.height <= 0.0, isTrue);
          }
        }
      },
    );
  });

  group('EngineComputePool priority & cancellation stress', () {
    test(
      'executes 120 multi-isolate tasks with priority overtaking and '
      'cancels 40 queued tasks cleanly without deadlocking workers',
      () async {
        final pool = EngineComputePool();
        await pool.warmUp();
        addTearDown(pool.dispose);

        final futures = <Future<int>>[];
        final cancelledFutures = <Future<int>>[];
        final tokens = <ComputeCancellationToken>[];

        for (var i = 0; i < 160; i++) {
          final priority = switch (i % 3) {
            0 => ComputePriority.low,
            1 => ComputePriority.normal,
            _ => ComputePriority.high,
          };
          if (i >= 20 && i < 60) {
            final token = ComputeCancellationToken();
            tokens.add(token);
            cancelledFutures.add(
              pool.schedule(
                _isolatedFibonacciSum,
                250 + i,
                priority: ComputePriority.low,
                cancelToken: token,
              ),
            );
          } else {
            futures.add(
              pool.schedule(
                _isolatedFibonacciSum,
                200 + (i % 50),
                priority: priority,
              ),
            );
          }
        }

        // Cancel the 40 low-priority tasks immediately while workers are busy:
        for (final t in tokens) {
          t.cancel();
        }

        for (final cf in cancelledFutures) {
          await expectLater(cf, throwsA(isA<ComputeCancelledException>()));
        }

        final results = await Future.wait(futures);
        expect(results.length, 120);
        for (var idx = 0; idx < results.length; idx++) {
          final origI = idx < 20 ? idx : idx + 40;
          expect(results[idx], _isolatedFibonacciSum(200 + (origI % 50)));
        }
        expect(pool.pendingTaskCount, 0);
      },
    );
  });

  group('50-deep AffineMatrix2D oracle & FixedTransformInterpolation', () {
    test(
      'matches exact Matrix4 chain product across 50-level nested hierarchy '
      'during 200 random mid-chain transform mutations and wraps shortest-arc '
      'fixed interpolation across -pi/+pi',
      () async {
        final world = World();
        final game = FlameGame(world: world)..onGameResize(Vector2(400, 300));
        game.fixedTimeStep = 1.0 / 60.0;
        await game.start();
        addTearDown(game.onRemove);

        final chain = <PositionComponent>[];
        for (var d = 0; d < 50; d++) {
          final node = PositionComponent(
            position: Vector2(2.0 + (d % 5), -1.5 + (d % 3)),
            angle: (d % 7) * 0.08,
            scale: Vector2(1.01, 0.99),
          );
          if (chain.isEmpty) {
            world.add(node);
          } else {
            chain.last.add(node);
          }
          chain.add(node);
        }

        final spinner = _InterpolatedSpinner()
          ..position = Vector2(10, 20)
          ..angle = math.pi - 0.1
          ..linearVelocity = Vector2(60, -30)
          ..angularVelocity = 12.0; // steps +0.2 rad -> crosses +pi!
        world.add(spinner);
        await game.ready();

        final rng = SeededRng(0x50DEEB);
        final localProbe = Vector2(7.5, -4.25);

        for (var step = 0; step < 200; step++) {
          final idx = rng.nextInt(chain.length);
          chain[idx]
            ..position.setValues(
              rng.rangeDouble(-8.0, 8.0),
              rng.rangeDouble(-8.0, 8.0),
            )
            ..angle = rng.rangeDouble(-0.4, 0.4)
            ..scale.setValues(
              rng.rangeDouble(0.92, 1.08),
              rng.rangeDouble(0.92, 1.08),
            );

          // Brute-force Float64 chain product + Float32 Matrix4 oracle:
          final expectedMat32 = Matrix4.identity();
          final expectedAffine64 = AffineMatrix2D();
          for (var d = 0; d < chain.length; d++) {
            expectedMat32.multiply(chain[d].transformMatrix);
            expectedAffine64.setMultiplyTransform2D(
              expectedAffine64,
              chain[d].transform,
            );
          }
          final expectedWorld32 = expectedMat32.transform3(
            Vector3(localProbe.x, localProbe.y, 0.0),
          );
          final leafAffine = chain.last.worldTransformMatrix;
          final actualX = leafAffine.transformX(localProbe.x, localProbe.y);
          final actualY = leafAffine.transformY(localProbe.x, localProbe.y);

          expect(
            actualX,
            closeTo(
              expectedAffine64.transformX(localProbe.x, localProbe.y),
              1e-10,
            ),
          );
          expect(
            actualY,
            closeTo(
              expectedAffine64.transformY(localProbe.x, localProbe.y),
              1e-10,
            ),
          );
          expect(actualX, closeTo(expectedWorld32.x, 1e-3));
          expect(actualY, closeTo(expectedWorld32.y, 1e-3));
        }

        // FixedTransformInterpolation shortest-arc wrap across +pi/-pi seam:
        spinner.angle = math.pi - 0.1;
        spinner.teleportFixedState();
        spinner.angle =
            -math.pi + 0.1; // shortest delta is +0.2 rad, NOT -6.08!
        final (_, _, midAngle, _, _) = spinner.sampleInterpolatedTransform(0.5);
        // Midpoint along shortest arc is +/-pi (`cos(midAngle) == -1`):
        expect(math.cos(midAngle), closeTo(-1.0, 1e-5));

        // Teleport snaps interpolation delta immediately to zero:
        spinner.position.setValues(999, -999);
        expect(spinner.hasPendingFixedInterpolationDelta, isTrue);
        spinner.teleportFixedState();
        expect(spinner.hasPendingFixedInterpolationDelta, isFalse);
      },
    );
  });

  group('InputContextStack, InputBuffer & 200-node FocusNavigationGroup', () {
    test(
      'maintains strict focus gain/lost conservation across 200 focusables '
      'under random disables, modal InputContext priorities, and TTL buffers',
      () {
        final focusGroup = FocusNavigationGroup();
        final tiles = <_FocusableTile>[];
        for (var r = 0; r < 10; r++) {
          for (var c = 0; c < 20; c++) {
            final id = r * 20 + c;
            final t = _FocusableTile(
              tileId: id,
              position: Vector2(c * 32.0, r * 32.0),
              order: id,
            );
            tiles.add(t);
            focusGroup.register(t);
          }
        }

        final rng = SeededRng(0xF0C05);
        const dirs = FocusDirection.values;
        for (var i = 0; i < 600; i++) {
          final toggle = tiles[rng.nextInt(tiles.length)];
          toggle.canFocus = rng.nextInt(4) != 0; // ~75% enabled
          focusGroup.moveFocus(dirs[rng.nextInt(dirs.length)]);
          focusGroup.activateFocused();

          // Invariant: at most 1 focused tile, and gainCount - lostCount ==
          // (isFocused ? 1 : 0) for EVERY tile!
          var focusedCount = 0;
          for (final t in tiles) {
            if (t.isFocused) {
              focusedCount++;
              expect(t.canFocus, isTrue);
            }
            expect(t.gainCount - t.lostCount, t.isFocused ? 1 : 0);
          }
          expect(focusedCount, lessThanOrEqualTo(1));
        }

        // Modal InputContextStack priority + spotlight target hierarchy:
        final stack = InputContextStack()
          ..push(
            InputContext(
              name: 'gameplay',
              allowedActions: const <String>['move', 'jump', 'pause'],
            ),
          )
          ..push(
            InputContext(
              name: 'tutorial_spotlight',
              priority: 50,
              allowedActions: const <String>['confirm'],
              allowedTargets: <Component>[tiles[42]],
            ),
          );
        expect(stack.isActionAllowed('move'), isFalse);
        expect(stack.isActionAllowed('confirm'), isTrue);
        expect(stack.isTargetAllowed(tiles[42]), isTrue);
        expect(stack.isTargetAllowed(tiles[43]), isFalse);

        stack.pop();
        expect(stack.isActionAllowed('move'), isTrue);

        // InputBuffer TTL expiration & single-shot consume:
        final buffer = InputBuffer()
          ..buffer('jump')
          ..buffer('attack', windowSeconds: 0.05);
        buffer.update(0.08);
        expect(buffer.hasBuffered('attack'), isFalse);
        expect(buffer.consume('jump'), isTrue);
        expect(buffer.consume('jump'), isFalse);
      },
    );
  });
}
