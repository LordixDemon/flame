import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Standard framerate pacing presets for [FpsPolicy].
enum FpsPreset() {
  /// Battery-saving 30 Hz cap (harmonic `1/2` on 60 Hz, `1/3` on 90 Hz, `1/4`
  /// on 120 Hz).
  powerSave30,

  /// Standard 60 Hz cap (harmonic `1/1` on 60 Hz, `1/2` on 120 Hz, `1/3` on
  /// 180 Hz, `1/4` on 240 Hz).
  locked60,

  /// Half of the display's native refresh rate (`72 Hz` on `144 Hz`, `60 Hz` on
  /// `120 Hz`, `82.5 Hz` on `165 Hz`), staying at native `60 Hz` when half
  /// would drop below `minHarmonicHz`.
  harmonicHalf,

  /// Runs locked `1:1` with the active monitor's VSync refresh rate
  /// (`60 / 90 / 120 / 144 / 240 Hz`).
  nativeDisplay,

  /// Runs every Ticker callback without interval or divisor throttling.
  uncapped,

  /// User-defined target Hz with automatic harmonic divisor detection when
  /// [FpsPolicy.preferHarmonicDivisor] is `true`.
  custom,
}

/// Controls whether `GameRenderBox` schedules GPU repaints on visually clean
/// frames.
enum IdleRenderMode() {
  /// Repaints on every executed game-loop frame (classic Flame behavior).
  always,

  /// Repaints every frame while active, switching to dirty-only repaints once
  /// `Game.isIdleThrottled` engages.
  onDemandWhenIdle,

  /// Skips `markNeedsPaint()` whenever the scene has not been marked dirty
  /// (`Game.isSceneDirty == false`), while keeping `update(dt)` running.
  onDemand,
}

/// Display-aware framerate policy supporting exact integer harmonic VSync
/// divisors to eliminate non-harmonic judder on `90 / 120 / 144 / 165 / 240 Hz`
/// screens.
@immutable
class const FpsPolicy._({
  required this.preset,
  this.customHz,
  this.minHarmonicHz = 60.0,
  this.preferHarmonicDivisor = true,
}) {
  /// Battery-saving `30 Hz` framerate cap.
  const FpsPolicy.powerSave30()
    : this._(preset: FpsPreset.powerSave30, customHz: 30.0);

  /// Standard `60 Hz` framerate cap using exact integer VSync division on
  /// `60 / 120 / 180 / 240 Hz` displays.
  const FpsPolicy.locked60()
    : this._(preset: FpsPreset.locked60, customHz: 60.0);

  /// Harmonic `1/2` refresh rate (`72 FPS` on `144 Hz`, `60 FPS` on `120 Hz`),
  /// clamping to `1/1` when `displayHz / 2 < minHz` (e.g. stays `60 FPS` on a
  /// `60 Hz` panel).
  const FpsPolicy.harmonicHalf({double minHz = 60.0})
    : this._(preset: FpsPreset.harmonicHalf, minHarmonicHz: minHz);

  /// Native `1:1` display VSync rate.
  const FpsPolicy.nativeDisplay() : this._(preset: FpsPreset.nativeDisplay);

  /// Uncapped ticker execution.
  const FpsPolicy.uncapped()
    : this._(preset: FpsPreset.uncapped, preferHarmonicDivisor: false);

  /// Custom target framerate in Hz (`<= 0` suspends frames).
  const FpsPolicy.custom(
    double targetHz, {
    bool preferHarmonicDivisor = true,
  }) : this._(
         preset: FpsPreset.custom,
         customHz: targetHz,
         preferHarmonicDivisor: preferHarmonicDivisor,
       );

  /// Selected policy preset.
  final FpsPreset preset;

  /// Explicit target framerate in Hz for `powerSave30`, `locked60`, or
  /// `custom`.
  final double? customHz;

  /// Minimum acceptable framerate for [FpsPreset.harmonicHalf] before falling
  /// back to `1:1` native VSync.
  final double minHarmonicHz;

  /// Whether integer VSync beat division (`1/N`) is preferred whenever
  /// `displayHz / targetHz` is within `6%` of a positive integer.
  final bool preferHarmonicDivisor;

  /// Resolves the effective target framerate in Hz for a display running at
  /// [displayHz], or `null` when running uncapped / `1:1` native VSync.
  double? resolveTargetFps(double displayHz) {
    final safeDisplayHz = displayHz > 0.0 ? displayHz : 60.0;
    return switch (preset) {
      FpsPreset.powerSave30 => 30.0,
      FpsPreset.locked60 => 60.0,
      FpsPreset.harmonicHalf =>
        safeDisplayHz * 0.5 >= minHarmonicHz * 0.95
            ? safeDisplayHz * 0.5
            : safeDisplayHz,
      FpsPreset.nativeDisplay => null,
      FpsPreset.uncapped => null,
      FpsPreset.custom => customHz,
    };
  }

  /// Resolves an exact integer VSync frame divisor (`>= 1`) for [displayHz], or
  /// `null` when non-harmonic accumulator pacing (`1 / targetFps`) should be
  /// used instead (for example `60 FPS` requested on a `144 Hz` panel).
  int? resolveVsyncDivisor(double displayHz) {
    final safeDisplayHz = displayHz > 0.0 ? displayHz : 60.0;
    switch (preset) {
      case FpsPreset.uncapped:
        return null;
      case FpsPreset.nativeDisplay:
        return 1;
      case FpsPreset.harmonicHalf:
        return safeDisplayHz * 0.5 >= minHarmonicHz * 0.95 ? 2 : 1;
      case FpsPreset.powerSave30:
      case FpsPreset.locked60:
      case FpsPreset.custom:
        final target = customHz;
        if (!preferHarmonicDivisor || target == null || target <= 0.0) {
          return null;
        }
        if (target >= safeDisplayHz * 0.97) {
          return 1;
        }
        final ratio = safeDisplayHz / target;
        final nearest = math.max(1, ratio.round());
        if ((ratio - nearest).abs() / nearest <= 0.06) {
          return nearest;
        }
        return null;
    }
  }

  @override
  bool operator ==(Object other) {
    return other is FpsPolicy &&
        other.preset == preset &&
        other.customHz == customHz &&
        other.minHarmonicHz == minHarmonicHz &&
        other.preferHarmonicDivisor == preferHarmonicDivisor;
  }

  @override
  int get hashCode =>
      Object.hash(preset, customHz, minHarmonicHz, preferHarmonicDivisor);
}
