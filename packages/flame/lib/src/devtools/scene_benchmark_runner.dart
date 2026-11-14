import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/game.dart';

/// Performance regression budget thresholds evaluated against a
/// [SceneBenchmarkReport].
class const SceneBenchmarkBudget({
  final int? maxP95UpdateMicros,
  final int? maxP95RenderMicros,
  final int? maxPeakDrawCalls,
  final int? maxPeakSaveLayerCalls,
  final int? maxPeakVramBytes,
});

/// Deterministic profiling report produced by [SceneBenchmarkRunner].
class const SceneBenchmarkReport({
  required final int warmupFrames,
  required final int measuredFrames,
  required final double meanUpdateMicros,
  required final int p95UpdateMicros,
  required final int p99UpdateMicros,
  required final double meanRenderMicros,
  required final int p95RenderMicros,
  required final int p99RenderMicros,
  required final int peakDrawCalls,
  required final int peakAtlasCalls,
  required final int peakVerticesCalls,
  required final int peakSaveLayerCalls,
  required final int peakVramBytes,
}) {
  /// Evaluates [budget] against this report and returns all violated constraint
  /// descriptions (empty list when passing).
  List<String> evaluateBudget(SceneBenchmarkBudget budget) {
    final violations = <String>[];
    if (budget.maxP95UpdateMicros != null &&
        p95UpdateMicros > budget.maxP95UpdateMicros!) {
      violations.add(
        'p95UpdateMicros ($p95UpdateMicros) > ${budget.maxP95UpdateMicros}',
      );
    }
    if (budget.maxP95RenderMicros != null &&
        p95RenderMicros > budget.maxP95RenderMicros!) {
      violations.add(
        'p95RenderMicros ($p95RenderMicros) > ${budget.maxP95RenderMicros}',
      );
    }
    if (budget.maxPeakDrawCalls != null &&
        peakDrawCalls > budget.maxPeakDrawCalls!) {
      violations.add(
        'peakDrawCalls ($peakDrawCalls) > ${budget.maxPeakDrawCalls}',
      );
    }
    if (budget.maxPeakSaveLayerCalls != null &&
        peakSaveLayerCalls > budget.maxPeakSaveLayerCalls!) {
      violations.add(
        'peakSaveLayerCalls ($peakSaveLayerCalls) > '
        '${budget.maxPeakSaveLayerCalls}',
      );
    }
    if (budget.maxPeakVramBytes != null &&
        peakVramBytes > budget.maxPeakVramBytes!) {
      violations.add(
        'peakVramBytes ($peakVramBytes) > ${budget.maxPeakVramBytes}',
      );
    }
    return violations;
  }

  /// Exports all metrics as a JSON-serializable map for CI regression logs.
  Map<String, Object> toJson() => <String, Object>{
    'warmupFrames': warmupFrames,
    'measuredFrames': measuredFrames,
    'meanUpdateMicros': meanUpdateMicros,
    'p95UpdateMicros': p95UpdateMicros,
    'p99UpdateMicros': p99UpdateMicros,
    'meanRenderMicros': meanRenderMicros,
    'p95RenderMicros': p95RenderMicros,
    'p99RenderMicros': p99RenderMicros,
    'peakDrawCalls': peakDrawCalls,
    'peakAtlasCalls': peakAtlasCalls,
    'peakVerticesCalls': peakVerticesCalls,
    'peakSaveLayerCalls': peakSaveLayerCalls,
    'peakVramBytes': peakVramBytes,
  };
}

/// Headless deterministic scene benchmark runner for CI regression gates and
/// local profiling.
///
/// Steps a mounted [FlameGame] through `warmupFrames` + `measuredFrames` fixed
/// `stepDt` update/render cycles onto a `PictureRecorder`, capturing exact
/// CPU update/render microseconds, peak GPU draw-call/batch counts, and peak
/// `SceneResourceBudget` VRAM bytes while deterministically disposing every
/// recorded `ui.Picture`.
abstract final class SceneBenchmarkRunner._() {
  /// Starts/mounts [game] if not yet mounted, waits for all queued lifecycle
  /// events (`await game.ready()`), and runs [runMounted].
  static Future<SceneBenchmarkReport> run(
    FlameGame game, {
    int warmupFrames = 15,
    int measuredFrames = 60,
    double stepDt = 1.0 / 60.0,
    Vector2? viewportSize,
  }) async {
    final size = viewportSize ?? Vector2(1280, 720);
    if (!game.hasLayout) {
      game.onGameResize(size);
    }
    if (!game.isMounted) {
      await game.start();
    }
    await game.ready();
    return runMounted(
      game,
      warmupFrames: warmupFrames,
      measuredFrames: measuredFrames,
      stepDt: stepDt,
      viewportSize: size,
    );
  }

  /// Runs a synchronous benchmark on an already-mounted [game].
  static SceneBenchmarkReport runMounted(
    FlameGame game, {
    int warmupFrames = 15,
    int measuredFrames = 60,
    double stepDt = 1.0 / 60.0,
    Vector2? viewportSize,
  }) {
    assert(measuredFrames >= 1, 'measuredFrames must be >= 1');
    final size = viewportSize ?? Vector2(1280, 720);
    if (!game.hasLayout) {
      game.onGameResize(size);
    }
    final prevTelemetry = game.collectRenderTelemetry;
    game.collectRenderTelemetry = true;

    for (var i = 0; i < warmupFrames; i++) {
      game.update(stepDt);
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      game.render(canvas);
      recorder.endRecording().dispose();
    }

    final updateSamples = List<int>.filled(measuredFrames, 0);
    final renderSamples = List<int>.filled(measuredFrames, 0);
    var sumUpdate = 0;
    var sumRender = 0;
    var peakDraws = 0;
    var peakAtlas = 0;
    var peakVertices = 0;
    var peakSaveLayers = 0;
    var peakVram = 0;

    final sw = Stopwatch();
    for (var i = 0; i < measuredFrames; i++) {
      sw
        ..reset()
        ..start();
      game.update(stepDt);
      sw.stop();
      final upUs = math.max(
        sw.elapsedMicroseconds,
        game.renderTelemetry.updateMicros,
      );
      updateSamples[i] = upUs;
      sumUpdate += upUs;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      sw
        ..reset()
        ..start();
      game.render(canvas);
      sw.stop();
      recorder.endRecording().dispose();

      final rnUs = math.max(
        sw.elapsedMicroseconds,
        game.renderTelemetry.renderMicros,
      );
      renderSamples[i] = rnUs;
      sumRender += rnUs;

      final tel = game.renderTelemetry;
      if (tel.drawCalls > peakDraws) {
        peakDraws = tel.drawCalls;
      }
      if (tel.atlasCalls > peakAtlas) {
        peakAtlas = tel.atlasCalls;
      }
      if (tel.verticesCalls > peakVertices) {
        peakVertices = tel.verticesCalls;
      }
      if (tel.saveLayerCalls > peakSaveLayers) {
        peakSaveLayers = tel.saveLayerCalls;
      }
      final vram = game.resourceBudget.totalEstimatedBytes;
      if (vram > peakVram) {
        peakVram = vram;
      }
    }

    game.collectRenderTelemetry = prevTelemetry;

    updateSamples.sort();
    renderSamples.sort();

    int percentile(List<int> sorted, double q) {
      final idx = ((sorted.length - 1) * q).round().clamp(0, sorted.length - 1);
      return sorted[idx];
    }

    return SceneBenchmarkReport(
      warmupFrames: warmupFrames,
      measuredFrames: measuredFrames,
      meanUpdateMicros: sumUpdate / measuredFrames,
      p95UpdateMicros: percentile(updateSamples, 0.95),
      p99UpdateMicros: percentile(updateSamples, 0.99),
      meanRenderMicros: sumRender / measuredFrames,
      p95RenderMicros: percentile(renderSamples, 0.95),
      p99RenderMicros: percentile(renderSamples, 0.99),
      peakDrawCalls: peakDraws,
      peakAtlasCalls: peakAtlas,
      peakVerticesCalls: peakVertices,
      peakSaveLayerCalls: peakSaveLayers,
      peakVramBytes: peakVram,
    );
  }
}
