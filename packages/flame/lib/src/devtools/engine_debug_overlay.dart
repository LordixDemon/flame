import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/src/text/renderers/raster_font_atlas.dart';
import 'package:flutter/painting.dart';

/// Pure-`Canvas`, zero-widget developer HUD component displaying live frame
/// timings, GPU batch counters, VRAM budget usage, and component inspection.
///
/// Can be added to `camera.viewport` so it renders in crisp screen coordinates
/// without triggering Flutter widget tree rebuilds.
class EngineDebugOverlay({
  var RasterFontAtlas? fontAtlas,
  final int sampleHistoryCapacity = 120,
  var double summaryUpdateInterval = 0.25,
  var double targetFrameBudgetMs = 16.67,
  super.position,
  Vector2? size,
  super.priority = 100000,
  super.key,
}) extends PositionComponent with HasGameRef<FlameGame> {
  this
    : assert(sampleHistoryCapacity >= 16, 'sampleHistoryCapacity >= 16'),
      super(size: size ?? Vector2(268, 128));

  final Float32List _frameRingMs = Float32List(sampleHistoryCapacity);
  int _ringCursor = 0;
  int _ringFilled = 0;
  double _textRefreshTimer = 999.0;
  String _cachedSummary = '';

  final GlyphBatchRenderer _glyphRenderer = GlyphBatchRenderer(
    initialGlyphCapacity: 192,
  );
  TextPainter? _fallbackPainter;

  final Paint _bgPaint = Paint()..color = const Color(0xCC0E121D);
  final Paint _borderPaint = Paint()
    ..color = const Color(0xFF3A496B)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.0;
  final Paint _budgetPaint = Paint()
    ..color = const Color(0x884CAF50)
    ..strokeWidth = 1.0;
  final Paint _barOkPaint = Paint()..color = const Color(0xFF4DD0E1);
  final Paint _barWarnPaint = Paint()..color = const Color(0xFFFFB74D);
  final Paint _barJankPaint = Paint()..color = const Color(0xFFEF5350);

  /// Latest formatted summary string displayed in the HUD.
  String get summaryText => _cachedSummary;

  /// Number of frame-time samples recorded so far.
  int get recordedSampleCount => _ringFilled;

  @override
  void onMount() {
    super.onMount();
    gameRef.collectRenderTelemetry = true;
  }

  @override
  void update(double dt) {
    final ms = (dt * 1000.0).clamp(0.2, 200.0);
    _frameRingMs[_ringCursor] = ms;
    _ringCursor = (_ringCursor + 1) % sampleHistoryCapacity;
    if (_ringFilled < sampleHistoryCapacity) {
      _ringFilled++;
    }

    _textRefreshTimer += dt;
    if (_textRefreshTimer >= summaryUpdateInterval) {
      _textRefreshTimer = 0.0;
      _rebuildSummaryString(ms);
    }
  }

  void _rebuildSummaryString(double latestMs) {
    final tel = gameRef.renderTelemetry;
    final fps = latestMs > 0.1 ? (1000.0 / latestMs) : 0.0;
    final upMs = (tel.updateMicros / 1000.0).toStringAsFixed(2);
    final rnMs = (tel.renderMicros / 1000.0).toStringAsFixed(2);
    final vramMb =
        (gameRef.resourceBudget.totalEstimatedBytes / (1024.0 * 1024.0))
            .toStringAsFixed(1);
    final tier = gameRef.graphics.tier.name;

    _cachedSummary =
        'FPS ${fps.toStringAsFixed(0)} | Tier $tier | VRAM ${vramMb}MB\n'
        'CPU upd ${upMs}ms | rnd ${rnMs}ms\n'
        'Draw ${tel.drawCalls} | Atl ${tel.atlasCalls} | '
        'Vtx ${tel.verticesCalls} | Lay ${tel.saveLayerCalls}';

    if (fontAtlas == null) {
      final tp = _fallbackPainter ??= TextPainter(
        textDirection: TextDirection.ltr,
      );
      tp
        ..text = TextSpan(
          text: _cachedSummary,
          style: const TextStyle(
            color: Color(0xFFE6EEF8),
            fontSize: 10.5,
            height: 1.28,
            fontFamily: 'monospace',
          ),
        )
        ..layout(maxWidth: math.max(64.0, size.x - 16.0));
    }
  }

  /// Inspects all world [PositionComponent]s overlapping [worldPoint] and
  /// returns a compact human-readable diagnostic list.
  List<String> inspectWorldPoint(Vector2 worldPoint) {
    final results = <String>[];
    if (gameRef.world.spatialIndexEnabled) {
      final hits = <PositionComponent>[];
      gameRef.world.querySpatialPoint(worldPoint, hits);
      for (var i = 0; i < hits.length; i++) {
        final c = hits[i];
        results.add(
          '${c.runtimeType} pos=(${c.position.x.toStringAsFixed(1)}, '
          '${c.position.y.toStringAsFixed(1)}) prio=${c.priority}',
        );
      }
      return results;
    }

    for (final child in gameRef.world.children) {
      if (child is PositionComponent && child.containsPoint(worldPoint)) {
        results.add(
          '${child.runtimeType} pos=(${child.position.x.toStringAsFixed(1)}, '
          '${child.position.y.toStringAsFixed(1)}) prio=${child.priority}',
        );
      }
    }
    return results;
  }

  @override
  void render(Canvas canvas) {
    final rect = Rect.fromLTWH(0, 0, size.x, size.y);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
    canvas.drawRRect(rrect, _bgPaint);
    canvas.drawRRect(rrect, _borderPaint);

    // Render text summary at top.
    final atlas = fontAtlas;
    if (atlas != null && !atlas.isDisposed && _cachedSummary.isNotEmpty) {
      final lines = _cachedSummary.split('\n');
      _glyphRenderer.begin();
      for (var i = 0; i < lines.length; i++) {
        _glyphRenderer.addText(
          atlas,
          lines[i],
          x: 8,
          y: 6 + i * (atlas.lineHeight + 1),
          scale: 0.85,
          color: const Color(0xFFE6EEF8),
        );
      }
      _glyphRenderer.flush(canvas, atlas);
    } else {
      _fallbackPainter?.paint(canvas, const Offset(8, 6));
    }

    // Render rolling frame-time bar chart at bottom.
    const chartLeft = 8.0;
    final chartRight = size.x - 8.0;
    final chartBottom = size.y - 8.0;
    final chartTop = math.max(58.0, size.y - 46.0);
    final chartHeight = math.max(12.0, chartBottom - chartTop);
    final chartWidth = math.max(16.0, chartRight - chartLeft);

    const maxScaleMs = 33.34;
    final budgetRatio = (targetFrameBudgetMs / maxScaleMs).clamp(0.05, 1.0);
    final budgetY = chartBottom - chartHeight * budgetRatio;
    canvas.drawLine(
      Offset(chartLeft, budgetY),
      Offset(chartRight, budgetY),
      _budgetPaint,
    );

    if (_ringFilled > 0) {
      final barStep = chartWidth / sampleHistoryCapacity;
      final barWidth = math.max(1.0, barStep - 0.5);
      for (var i = 0; i < _ringFilled; i++) {
        final slot = _ringFilled < sampleHistoryCapacity
            ? i
            : (_ringCursor + i) % sampleHistoryCapacity;
        final sampleMs = _frameRingMs[slot];
        final h = (sampleMs / maxScaleMs).clamp(0.03, 1.0) * chartHeight;
        final Paint p;
        if (sampleMs <= targetFrameBudgetMs * 1.08) {
          p = _barOkPaint;
        } else if (sampleMs <= targetFrameBudgetMs * 1.5) {
          p = _barWarnPaint;
        } else {
          p = _barJankPaint;
        }
        final bx = chartLeft + i * barStep;
        canvas.drawRect(Rect.fromLTWH(bx, chartBottom - h, barWidth, h), p);
      }
    }
  }

  @override
  void onRemove() {
    _fallbackPainter?.dispose();
    _fallbackPainter = null;
    super.onRemove();
  }
}
