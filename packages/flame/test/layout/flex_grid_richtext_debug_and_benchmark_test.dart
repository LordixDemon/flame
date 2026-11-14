import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/debug.dart';
import 'package:flame/game.dart';
import 'package:flame/layout.dart';
import 'package:flame/text.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

ui.Image _makeIconImageSync() {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawCircle(
    const Offset(8, 8),
    7,
    Paint()..color = const Color(0xFFFFD54F),
  );
  final pic = rec.endRecording();
  try {
    return pic.toImageSync(16, 16);
  } finally {
    pic.dispose();
  }
}

void main() {
  group(
    'Row/Column/Grid/NineSlice Layout, RichBatchedText, DebugHUD & Benchmark',
    () {
      test(
        'RowLayoutComponent, ColumnLayoutComponent, GridLayoutComponent & '
        'NineSlicePanelComponent layout and render cleanly (#28)',
        () {
          final a = PositionComponent(size: Vector2(30, 20));
          final b = PositionComponent(size: Vector2(40, 10));
          final row = RowLayoutComponent(
            spacing: 8,
            padding: const EdgePadding.symmetric(horizontal: 10, vertical: 4),
            children: <Component>[a, b],
          )..performLayout();

          expect(row.size, Vector2(30 + 40 + 8 + 20, 20 + 8));
          expect(a.position, Vector2(10, 4));
          expect(b.position, Vector2(48, 9)); // vertically centered in 20px!

          final c1 = PositionComponent(size: Vector2(20, 16));
          final c2 = PositionComponent(size: Vector2(20, 16));
          final col = ColumnLayoutComponent(
            spacing: 6,
            crossAxisAlignment: FlexCrossAxisAlignment.stretch,
            shrinkWrap: false,
            size: Vector2(100, 80),
            children: <Component>[c1, c2],
          )..performLayout();
          expect(c1.size.x, 100);
          expect(c2.position.y, 22);
          expect(col.size.x, 100);

          final cells = List<PositionComponent>.generate(
            5,
            (_) => PositionComponent(size: Vector2(16, 16)),
          );
          final grid = GridLayoutComponent(
            columns: 3,
            cellWidth: 24,
            cellHeight: 24,
            horizontalSpacing: 4,
            verticalSpacing: 4,
            children: cells,
          )..performLayout();
          expect(grid.size, Vector2(3 * 24 + 2 * 4, 2 * 24 + 1 * 4));
          expect(cells[4].position, Vector2(28 + 4, 28 + 4));

          final iconImg = _makeIconImageSync();
          try {
            final panelTex = NineSlicePanelComponent(
              image: iconImg,
              size: Vector2(120, 60),
            );
            final panelFallback = NineSlicePanelComponent(
              size: Vector2(120, 60),
            );
            final rec = ui.PictureRecorder();
            final canvas = ui.Canvas(rec);
            panelTex.render(canvas);
            panelFallback.render(canvas);
            rec.endRecording().dispose();
          } finally {
            iconImg.dispose();
          }
        },
      );

      test(
        'RichBatchedTextComponent parses color/wave/shake/scale/icon tags and '
        'runs typewriter reveal (#29)',
        () {
          final fontAtlas = RasterFontAtlas.bake(
            style: const TextStyle(fontSize: 14, color: Color(0xFFFFFFFF)),
          );
          final coinImg = _makeIconImageSync();
          try {
            final rich = RichBatchedTextComponent(
              atlas: fontAtlas,
              markup:
                  'Gold <color=#FFD54F><scale=1.2>+500</scale></color> '
                  '[icon:coin] <wave><shake>WIN!</shake></wave>',
              icons: <String, RichTextIconSpan>{
                'coin': RichTextIconSpan(
                  image: coinImg,
                  srcRect: const Rect.fromLTWH(0, 0, 16, 16),
                  logicalWidth: 14,
                  logicalHeight: 14,
                ),
              },
            );

            // "Gold " (5) + "+500" (4) + " " (1) + icon (1) + " " (1) +
            // "WIN!" (4) = 16 tokens!
            expect(rich.tokenCount, 16);
            expect(rich.size.x, greaterThan(40));

            rich.startTypewriter(tokensPerSecond: 20.0);
            expect(rich.visibleTokenLimit, 0);
            rich.update(0.25); // reveals 5 tokens
            expect(rich.visibleTokenLimit, 5);

            final rec = ui.PictureRecorder();
            rich.render(ui.Canvas(rec));
            rec.endRecording().dispose();

            rich.update(1.0);
            expect(rich.visibleTokenLimit, 16);
          } finally {
            fontAtlas.dispose();
            coinImg.dispose();
          }
        },
      );

      test(
        'EngineDebugOverlay renders live telemetry & SceneBenchmarkRunner '
        'enforces SceneBenchmarkBudget (#31, #32)',
        () async {
          final world = World(spatialIndexEnabled: true);
          final game = FlameGame(world: world)..onGameResize(Vector2(640, 360));
          final targetBox = RectangleComponent(
            position: Vector2(20, 20),
            size: Vector2(50, 50),
            paint: Paint()..color = const Color(0xFF42A5F5),
          );
          world.add(targetBox);

          final hud = EngineDebugOverlay();
          game.camera.viewport.add(hud);

          final report = await SceneBenchmarkRunner.run(
            game,
            warmupFrames: 4,
            measuredFrames: 12,
            viewportSize: Vector2(640, 360),
          );
          expect(report.measuredFrames, 12);
          expect(report.peakDrawCalls, greaterThan(0));
          expect(hud.recordedSampleCount, greaterThanOrEqualTo(16));
          expect(hud.summaryText, contains('FPS'));

          final hits = hud.inspectWorldPoint(Vector2(35, 35));
          expect(hits, isNotEmpty);
          expect(hits.first, contains('RectangleComponent'));

          const passingBudget = SceneBenchmarkBudget(
            maxPeakDrawCalls: 500,
            maxPeakSaveLayerCalls: 20,
          );
          expect(report.evaluateBudget(passingBudget), isEmpty);

          const strictBudget = SceneBenchmarkBudget(maxPeakDrawCalls: 0);
          expect(report.evaluateBudget(strictBudget), isNotEmpty);
        },
      );
    },
  );
}
