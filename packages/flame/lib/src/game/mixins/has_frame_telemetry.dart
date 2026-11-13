import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/game.dart';

/// Zero-allocation frame-time ring buffer & FPS tracker mixin for [FlameGame],
/// designed for `60Hz` and `120Hz` ProMotion telemetry overlays without
/// per-frame heap allocations.
mixin HasFrameTelemetry on FlameGame {
  static const int _ringCapacity = 60;

  final Float32List _ringMs = Float32List(_ringCapacity);
  int _cursor = 0;
  int _filled = 0;
  double _smoothedFrameMs = 16.67;

  /// Number of frame-time samples stored in the ring buffer (`0..60`).
  int get telemetrySampleCount => _filled;

  /// Current write cursor inside the 60-sample ring buffer.
  int get telemetryCursor => _cursor;

  /// Exponentially smoothed frame delta in milliseconds.
  double get smoothedFrameMs => _smoothedFrameMs;

  /// Exponentially smoothed framerate in Hz (`FPS`).
  double get smoothedFps => 1000.0 / math.max(1.0, _smoothedFrameMs);

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
  void updateSubtree(double dt) {
    super.updateSubtree(dt);
    recordTelemetryFrame(lastEffectiveDt);
  }
}
