import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/camera.dart';
import 'package:flame/game.dart';

/// Zero-allocation frame-time ring buffer, FPS tracker, and GPU draw-call
/// telemetry mixin for [FlameGame], designed for `60Hz` and `120Hz` ProMotion
/// telemetry overlays without per-frame heap allocations.
mixin HasFrameTelemetry<W extends World> on FlameGame<W> {
  static const int _ringCapacity = 60;

  final Float32List _ringMs = Float32List(_ringCapacity);
  final Float32List _sortScratchMs = Float32List(_ringCapacity);
  int _cursor = 0;
  int _filled = 0;
  double _smoothedFrameMs = 16.67;
  double _smoothedUpdateMs = 0.0;
  double _smoothedRenderMs = 0.0;
  bool _telemetryInitialized = false;

  void _ensureDefaultTelemetryEnabled() {
    if (!_telemetryInitialized) {
      _telemetryInitialized = true;
      collectRenderTelemetry = true;
    }
  }

  /// Number of frame-time samples stored in the ring buffer (`0..60`).
  int get telemetrySampleCount => _filled;

  /// Current write cursor inside the 60-sample ring buffer.
  int get telemetryCursor => _cursor;

  /// Exponentially smoothed frame delta in milliseconds.
  double get smoothedFrameMs => _smoothedFrameMs;

  /// Exponentially smoothed framerate in Hz (`FPS`).
  double get smoothedFps => 1000.0 / math.max(1.0, _smoothedFrameMs);

  /// Exponentially smoothed CPU `update` duration in milliseconds.
  double get smoothedUpdateMs => _smoothedUpdateMs;

  /// Exponentially smoothed CPU `render` duration in milliseconds.
  double get smoothedRenderMs => _smoothedRenderMs;

  /// Total canvas `draw*` calls submitted during the last rendered frame.
  int get lastDrawCalls => renderTelemetry.drawCalls;

  /// `drawAtlas` / `drawRawAtlas` calls submitted during the last frame.
  int get lastAtlasCalls => renderTelemetry.atlasCalls;

  /// `drawVertices` 3D/2D mesh calls submitted during the last frame.
  int get lastVerticesCalls => renderTelemetry.verticesCalls;

  /// `saveLayer` calls submitted during the last frame.
  int get lastSaveLayerCalls => renderTelemetry.saveLayerCalls;

  /// Offscreen post-process rasterizations executed during the last frame.
  int get lastOffscreenRasterizations =>
      renderTelemetry.offscreenRasterizations;

  /// CPU wall-clock duration (in microseconds) of the last `update` tick.
  int get lastUpdateMicros => renderTelemetry.updateMicros;

  /// CPU wall-clock duration (in microseconds) of the last `render` pass.
  int get lastRenderMicros => renderTelemetry.renderMicros;

  /// Exponentially smoothed hardware UI/build duration in milliseconds.
  double get smoothedBuildMs => renderTelemetry.smoothedBuildMs;

  /// Exponentially smoothed hardware GPU raster duration in milliseconds.
  double get smoothedRasterMs => renderTelemetry.smoothedRasterMs;

  /// Exponentially smoothed hardware end-to-end frame span in milliseconds.
  double get smoothedTotalSpanMs => renderTelemetry.smoothedTotalSpanMs;

  /// Total hardware frames exceeding `1.5×` target frame budget.
  int get jankFrameCount => renderTelemetry.jankFrameCount;

  /// Whether GPU rasterization currently dominates CPU UI/build work.
  bool get isGpuBound => renderTelemetry.isGpuBound;

  /// 95th-percentile frame duration in milliseconds (uses hardware
  /// `FrameTiming.totalSpan` when available, falling back to loop `dt`).
  double get p95FrameMs => renderTelemetry.platformTimingSampleCount > 0
      ? renderTelemetry.p95TotalSpanMs
      : _ringPercentile(0.95);

  /// 99th-percentile frame duration in milliseconds (uses hardware
  /// `FrameTiming.totalSpan` when available, falling back to loop `dt`).
  double get p99FrameMs => renderTelemetry.platformTimingSampleCount > 0
      ? renderTelemetry.p99TotalSpanMs
      : _ringPercentile(0.99);

  double _ringPercentile(double quantile) {
    if (_filled <= 0) {
      return 0.0;
    }
    for (var i = 0; i < _filled; i++) {
      _sortScratchMs[i] = _ringMs[i];
    }
    for (var i = 1; i < _filled; i++) {
      final v = _sortScratchMs[i];
      var j = i - 1;
      while (j >= 0 && _sortScratchMs[j] > v) {
        _sortScratchMs[j + 1] = _sortScratchMs[j];
        j--;
      }
      _sortScratchMs[j + 1] = v;
    }
    final idx = ((_filled - 1) * quantile.clamp(0.0, 1.0)).round().clamp(
      0,
      _filled - 1,
    );
    return _sortScratchMs[idx];
  }

  /// Worst (largest) frame delta in milliseconds across the last 60 frames.
  double get worstFrameMs {
    var worst = 0.0;
    for (var i = 0; i < _filled; i++) {
      if (_ringMs[i] > worst) {
        worst = _ringMs[i];
      }
    }
    return worst;
  }

  /// Reads the `index`-th oldest sample (`0` = oldest, `telemetrySampleCount-1`
  /// = newest) in milliseconds.
  double telemetrySampleMsAt(int index) {
    if (_filled == 0) {
      return 0.0;
    }
    final clamped = index.clamp(0, _filled - 1);
    final slot = _filled < _ringCapacity
        ? clamped
        : (_cursor + clamped) % _ringCapacity;
    return _ringMs[slot];
  }

  /// Records a raw or effective frame delta [dtSeconds] into the ring buffer.
  void recordTelemetryFrame(double dtSeconds) {
    final ms = (dtSeconds * 1000.0).clamp(0.5, 250.0);
    _ringMs[_cursor] = ms;
    _cursor = (_cursor + 1) % _ringCapacity;
    if (_filled < _ringCapacity) {
      _filled++;
    }
    _smoothedFrameMs = _smoothedFrameMs * 0.90 + ms * 0.10;
  }

  @override
  void onMount() {
    _ensureDefaultTelemetryEnabled();
    super.onMount();
  }

  @override
  void update(double dt) {
    _ensureDefaultTelemetryEnabled();
    super.update(dt);
    if (collectRenderTelemetry) {
      final upMs = renderTelemetry.updateMicros / 1000.0;
      _smoothedUpdateMs = _smoothedUpdateMs * 0.85 + upMs * 0.15;
    }
  }

  @override
  void render(Canvas canvas) {
    _ensureDefaultTelemetryEnabled();
    super.render(canvas);
    if (collectRenderTelemetry) {
      final rnMs = renderTelemetry.renderMicros / 1000.0;
      _smoothedRenderMs = _smoothedRenderMs * 0.85 + rnMs * 0.15;
    }
  }

  @override
  void updateSubtree(double dt) {
    super.updateSubtree(dt);
    recordTelemetryFrame(lastEffectiveDt);
  }
}
