import 'dart:ui' as ui;

import 'package:flame/grid.dart';
import 'package:flame/navigation.dart';
import 'package:flame/rpg.dart';
import 'package:flame/tilemap.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart';

Future<ui.Image> _solidSheet(int w, int h, ui.Color color) async {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawRect(
    ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
    ui.Paint()..color = color,
  );
  final pic = rec.endRecording();
  final img = await pic.toImage(w, h);
  pic.dispose();
  return img;
}

void main() {
  group(
    'GridCharacterMotor tileLocked, freeSubTile doorway slide & MoveRoute',
    () {
      test(
        'preserves continuous stridePhase across chained tileLocked steps and '
        'locks ladder facing North',
        () {
          final grid = TilePassageGrid(width: 8, height: 8);
          // Place walkable ladder on (2, 2):
          grid.setFlags(
            2,
            2,
            TilePassageFlags.passAll4 | TilePassageFlags.ladder,
          );

          final motor = GridCharacterMotor(
            passageGrid: grid,
            speedPixelsPerSecond: 64, // 0.5s per tile
            strideCyclesPerTile: 0.7,
            initialCell: const GridCell(1, 2),
          );

          // Step east into (2, 2) over 0.3s (60% of first tile):
          motor.update(0.3, inputX: 1.0);
          expect(motor.cell, const GridCell(2, 2));
          final phaseMidFirstTile = motor.stridePhase;
          expect(phaseMidFirstTile, closeTo(0.6 * 0.7, 1e-4));

          // Cross tile seam (0.3s more -> 1.2 tiles total, chaining into (3, 2)
          // while input held!):
          // Because (2, 2) has ladder flag, facing locks North when stepping
          // off (2, 2)!
          motor.update(0.3, inputX: 1.0);
          expect(motor.cell, const GridCell(3, 2));
          expect(motor.facing, GridCardinalDirection.north);
          // Stride phase did NOT reset to 0 at the seam (0.42 + 0.42 = 0.84):
          expect(motor.stridePhase, closeTo(0.84, 1e-3));
        },
      );

      test(
        'slides smoothly around open doorway corners in freeSubTile mode '
        'while refusing solid walls',
        () {
          final grid = TilePassageGrid(width: 6, height: 6);
          // Vertical wall at col = 2 EXCEPT open doorway at (2, 2) (y =
          // [64..96]):
          for (var r = 0; r < 6; r++) {
            if (r != 2) {
              grid.setFlags(2, r, 0);
            }
          }

          final motor = GridCharacterMotor(
            passageGrid: grid,
            mode: GridLocomotionMode.freeSubTile,
            hitboxHalfWidth: 10,
            cornerSlideTolerance: 12,
            speedPixelsPerSecond: 120,
            initialCell: const GridCell(1, 2),
          );

          // Offset slightly north so top edge clips wall (2, 1) at y=64 by 6px
          // (within 12px tolerance):
          // Center y = 68 -> top = 58 < 64 (clips wall row 1!), while doorway
          // (2, 2) needs y >= 74:
          motor.worldPosition.setValues(54, 68);
          for (var i = 0; i < 15; i++) {
            motor.update(0.02, inputX: 1.0);
          }
          // Corner slide nudged Y down to >= 74 and let the character pass X >
          // 70 through the doorway!
          expect(motor.worldPosition.y, greaterThanOrEqualTo(73.9));
          expect(motor.worldPosition.x, greaterThan(72.0));

          // Now close the doorway too (solid wall everywhere on col = 4) and
          // verify 0 false sliding:
          for (var r = 0; r < 6; r++) {
            grid.setFlags(4, r, 0);
          }
          motor.worldPosition.setValues(
            118,
            68,
          ); // pressing into solid col=4 wall
          final initialY = motor.worldPosition.y;
          for (var i = 0; i < 10; i++) {
            motor.update(0.02, inputX: 1.0);
          }
          expect(motor.worldPosition.y, closeTo(initialY, 1e-5));
          expect(motor.worldPosition.x, lessThanOrEqualTo(118.1));
        },
      );

      test('executes scripted MoveRoute jump arcs and skipIfBlocked', () {
        final grid = TilePassageGrid(width: 6, height: 6)..setFlags(1, 0, 0);
        final motor =
            GridCharacterMotor(
              passageGrid: grid,
            )..startMoveRoute(
              MoveRoute(
                commands: <MoveRouteCommand>[
                  MoveRouteCommand.step(
                    GridCardinalDirection.east,
                  ), // blocked by (1,0) -> skipped!
                  MoveRouteCommand.jump(
                    dCol: 2,
                    dRow: 1,
                    arcHeightPx: 24,
                    duration: 0.4,
                  ),
                  MoveRouteCommand.turn(GridCardinalDirection.west),
                ],
              ),
            );

        motor.update(0.01); // skips blocked step, starts jump to (2, 1)
        expect(motor.isJumping, isTrue);
        expect(motor.cell, const GridCell(2, 1));

        motor.update(
          0.19,
        ); // t = 0.5 -> apex of parabolic jump (elevation == 24.0)!
        expect(motor.jumpElevationPx, closeTo(24.0, 0.5));

        motor.update(0.25); // lands jump
        motor.update(0.01); // executes trailing turn(west) and finishes route
        expect(motor.isJumping, isFalse);
        expect(motor.jumpElevationPx, 0.0);
        expect(motor.facing, GridCardinalDirection.west);
        expect(motor.hasActiveMoveRoute, isFalse);
      });
    },
  );

  group('PartyCaterpillarChain & PaperDollCompositor', () {
    test(
      'follows leader path distance, reproduces jump elevation, and collapses '
      'on gatherToLeader',
      () {
        final chain = PartyCaterpillarChain(
          followerCount: 2,
        )..resetAt(16, 16, facing: GridCardinalDirection.east);

        // Walk 64px East, then 32px South (L-shaped corner):
        for (var x = 20.0; x <= 80.0; x += 4.0) {
          chain.recordLeader(
            x: x,
            y: 16,
            facing: GridCardinalDirection.east,
            jumpElevationPx: x == 48.0 ? 18.0 : 0.0,
            leaderIsMoving: true,
          );
        }
        for (var y = 20.0; y <= 48.0; y += 4.0) {
          chain.recordLeader(
            x: 80,
            y: y,
            facing: GridCardinalDirection.south,
            leaderIsMoving: true,
          );
        }

        // Leader traveled 64 + 32 = 96px:
        // Follower 0 (at 96 - 32 = 64px) should be right at the corner (80,
        // 16)!
        // Follower 1 (at 96 - 64 = 32px) should be at (48, 16) with the 18px
        // jump apex!
        expect(chain.followers[0].position.x, closeTo(80, 0.5));
        expect(chain.followers[0].position.y, closeTo(16, 0.5));
        expect(chain.followers[1].position.x, closeTo(48, 0.5));
        expect(chain.followers[1].position.y, closeTo(16, 0.5));
        expect(chain.followers[1].jumpElevationPx, closeTo(18.0, 0.5));

        // Gather party into leader at (80, 48):
        var gathered = false;
        for (var i = 0; i < 20 && !gathered; i++) {
          gathered = chain.gatherToLeader(0.05, gatherSpeedPxPerSec: 240);
        }
        expect(gathered, isTrue);
        expect(chain.followers[0].position, Vector2(80, 48));
        expect(chain.followers[1].position, Vector2(80, 48));
      },
    );

    test(
      'CharacterSpriteSheet 0-1-2-1 stride + PaperDollCompositor LRU caching '
      '& deterministic disposal',
      () async {
        final sheet = CharacterSpriteSheet(frameWidth: 32, frameHeight: 48)
          ..setWeaponSocketOffset(CharacterFacing8.east, 2, Vector2(26, 28));

        expect(
          <int>[
            sheet.resolveColumn(isMoving: false, stridePhase: 0.7),
            sheet.resolveColumn(isMoving: true, stridePhase: 0.05),
            sheet.resolveColumn(isMoving: true, stridePhase: 0.30),
            sheet.resolveColumn(isMoving: true, stridePhase: 0.55),
            sheet.resolveColumn(isMoving: true, stridePhase: 0.85),
          ],
          const <int>[1, 0, 1, 2, 1],
        );

        final sock = Vector2.zero();
        sheet.getWeaponSocketOffset(CharacterFacing8.east, 2, sock);
        expect(sock, Vector2(26, 28));
        expect(CharacterFacing8.north.weaponBehindBody, isTrue);
        expect(CharacterFacing8.south.weaponBehindBody, isFalse);

        final bodyImg = await _solidSheet(96, 192, const ui.Color(0xFFFFFFFF));
        final capeImg = await _solidSheet(96, 192, const ui.Color(0xFFFFFFFF));
        addTearDown(bodyImg.dispose);
        addTearDown(capeImg.dispose);

        final compositor = PaperDollCompositor(maxCachedSheets: 2);
        addTearDown(compositor.dispose);

        final outfitRed = <PaperDollLayer>[
          PaperDollLayer(
            id: 'cape',
            image: capeImg,
            zOrder: 10,
            tintColor: const ui.Color(0xFFFF2244),
          ),
          PaperDollLayer(id: 'body', image: bodyImg),
        ];
        final outfitBlue = <PaperDollLayer>[
          PaperDollLayer(id: 'body', image: bodyImg),
          PaperDollLayer(
            id: 'cape',
            image: capeImg,
            zOrder: 10,
            tintColor: const ui.Color(0xFF2266FF),
          ),
        ];
        final outfitGold = <PaperDollLayer>[
          PaperDollLayer(id: 'body', image: bodyImg),
          PaperDollLayer(
            id: 'cape',
            image: capeImg,
            zOrder: 10,
            tintColor: const ui.Color(0xFFFFCC00),
          ),
        ];

        final imgRed1 = compositor.composeSync(
          outfitRed,
          sheetWidth: 96,
          sheetHeight: 192,
        );
        // Reversed input order with identical zOrder produces a cache HIT:
        final imgRed2 = compositor.composeSync(
          outfitRed.reversed.toList(),
          sheetWidth: 96,
          sheetHeight: 192,
        );
        expect(identical(imgRed1, imgRed2), isTrue);
        expect(compositor.cacheHitCount, 1);
        expect(compositor.cacheMissCount, 1);

        compositor.composeSync(outfitBlue, sheetWidth: 96, sheetHeight: 192);
        // Touch outfitRed so outfitBlue becomes LRU victim when outfitGold is
        // baked:
        compositor.composeSync(outfitRed, sheetWidth: 96, sheetHeight: 192);
        compositor.composeSync(outfitGold, sheetWidth: 96, sheetHeight: 192);

        expect(compositor.cachedSheetCount, 2);
        expect(compositor.evictedImageCount, 1);
        expect(compositor.disposedImageCount, 1);

        compositor.dispose();
        expect(compositor.disposedImageCount, 3);
      },
    );
  });

  group(
    'ShadowcastFogOfWar exhaustive all-pairs symmetry & 3-state shroud',
    () {
      test(
        'guarantees 100% floor-to-floor mathematical symmetry sees(A,B) == '
        'sees(B,A) across pillars & slits',
        () async {
          const mapAscii = <String>[
            '############',
            '#....#.....#',
            '#.##.#.###.#',
            '#.#..#...#.#',
            '#...##.#...#',
            '###....#.#.#',
            '#...#.##...#',
            '#.#.#....#.#',
            '#...####...#',
            '#..........#',
            '############',
          ];
          final h = mapAscii.length;
          final w = mapAscii.first.length;
          final fog = ShadowcastFogOfWar(width: w, height: h);

          final floors = <(int, int)>[];
          for (var r = 0; r < h; r++) {
            for (var c = 0; c < w; c++) {
              final isWall = mapAscii[r][c] == '#';
              fog.setOpaque(c, r, opaque: isWall);
              if (!isWall) {
                floors.add((c, r));
              }
            }
          }

          // Exhaustive all-pairs symmetry proof across EVERY floor tile pair!
          const sightRadius = 7.5;
          for (var i = 0; i < floors.length; i++) {
            final (ax, ay) = floors[i];
            for (var j = i + 1; j < floors.length; j++) {
              final (bx, by) = floors[j];
              final ab = fog.hasLineOfSight(
                ax,
                ay,
                bx,
                by,
                radius: sightRadius,
              );
              final ba = fog.hasLineOfSight(
                bx,
                by,
                ax,
                ay,
                radius: sightRadius,
              );
              expect(
                ab,
                ba,
                reason: 'Asymmetric LOS between ($ax,$ay) and ($bx,$by)',
              );
            }
          }

          // Verify 3-state transitions (unexplored -> visible ->
          // exploredShroud) & GPU mask:
          expect(fog.stateAt(1, 1), FogCellState.unexplored);
          fog.revealFrom(1, 1, radius: 3.5);
          expect(fog.stateAt(1, 1), FogCellState.visible);
          expect(fog.stateAt(10, 9), FogCellState.unexplored);

          fog
            ..clearVisibleToShroud()
            ..revealFrom(10, 9, radius: 2.5);
          expect(fog.stateAt(1, 1), FogCellState.exploredShroud);
          expect(fog.stateAt(10, 9), FogCellState.visible);
          expect(fog.stateAt(6, 1), FogCellState.unexplored);

          final mask = fog.bakeMaskImageSync();
          addTearDown(mask.dispose);
          final rgba = (await mask.toByteData())!;
          int alphaAtTile(int col, int row) {
            final px = col * 4 + 2;
            final py = row * 4 + 2;
            return rgba.getUint8((py * mask.width + px) * 4 + 3);
          }

          // Visible = alpha 0, Shroud = medium alpha (~150), Unexplored =
          // near-opaque (~240):
          expect(alphaAtTile(10, 9), 0);
          expect(alphaAtTile(1, 1), inInclusiveRange(120, 180));
          expect(alphaAtTile(6, 1), greaterThan(220));
        },
      );
    },
  );
}
