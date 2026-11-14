import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

/// Mutable hardware telemetry snapshot captured per active pointer by
/// `GameRenderBox.handleEvent` so gesture recognizer details (`TapDownDetails`,
/// `DragUpdateDetails`, etc.) retain full stylus/touch/mouse hardware state.
class PointerHardwareSample({
  var int pointerId = 0,
  var PointerDeviceKind deviceKind = PointerDeviceKind.touch,
  var double pressure = 1.0,
  var double pressureMin = 0.0,
  var double pressureMax = 1.0,
  var double tilt = 0.0,
  var double orientation = 0.0,
  var int buttons = 0,
  var double radiusMajor = 0.0,
}) {
  void updateFromPointerEvent(PointerEvent event) {
    pointerId = event.pointer;
    deviceKind = event.kind;
    // Preserve last contact pressure, tilt, orientation, and buttons across
    // `PointerUpEvent` / `PointerCancelEvent` so quick-tap `TapDownEvent`,
    // `TapUpEvent`, and `DragEndEvent` callbacks resolved by `GestureArena` on
    // pointer lift still observe the contact hardware state.
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      return;
    }
    pressure = event.pressure;
    pressureMin = event.pressureMin;
    pressureMax = event.pressureMax;
    tilt = event.tilt;
    orientation = event.orientation;
    buttons = event.buttons;
    radiusMajor = event.radiusMajor;
  }

  /// Normalized `[0.0 .. 1.0]` pressure relative to
  /// `[pressureMin..pressureMax]`.
  double get normalizedPressure {
    final span = pressureMax - pressureMin;
    if (span <= 1e-6) {
      return pressure.clamp(0.0, 1.0);
    }
    return ((pressure - pressureMin) / span).clamp(0.0, 1.0);
  }
}

/// Zero-allocation utility extracting hardware pointer telemetry and keyboard
/// modifier state across Flutter `PointerEvent` and gesture `*Details` types.
abstract final class PointerTelemetryExtractor._() {
  static PointerDeviceKind resolveDeviceKind(
    Object? raw,
    PointerHardwareSample? fallback,
  ) {
    if (raw is PointerEvent) {
      return raw.kind;
    }
    if (raw is TapDownDetails && raw.kind != null) {
      return raw.kind!;
    }
    if (raw is TapUpDetails) {
      return raw.kind;
    }
    if (raw is DragStartDetails && raw.kind != null) {
      return raw.kind!;
    }
    if (raw is ScaleStartDetails && raw.kind != null) {
      return raw.kind!;
    }
    if (fallback != null) {
      return fallback.deviceKind;
    }
    return PointerDeviceKind.unknown;
  }

  static double resolvePressure(Object? raw, PointerHardwareSample? fallback) {
    if (raw is PointerEvent) {
      return raw.pressure;
    }
    return fallback?.pressure ?? 1.0;
  }

  static double resolveTilt(Object? raw, PointerHardwareSample? fallback) {
    if (raw is PointerEvent) {
      return raw.tilt;
    }
    return fallback?.tilt ?? 0.0;
  }

  static double resolveOrientation(
    Object? raw,
    PointerHardwareSample? fallback,
  ) {
    if (raw is PointerEvent) {
      return raw.orientation;
    }
    return fallback?.orientation ?? 0.0;
  }

  static int resolveButtons(Object? raw, PointerHardwareSample? fallback) {
    if (raw is PointerEvent) {
      return raw.buttons;
    }
    return fallback?.buttons ?? 0;
  }

  static bool get isShiftPressed {
    try {
      return HardwareKeyboard.instance.isShiftPressed;
    } on Object {
      return false;
    }
  }

  static bool get isControlPressed {
    try {
      return HardwareKeyboard.instance.isControlPressed;
    } on Object {
      return false;
    }
  }

  static bool get isAltPressed {
    try {
      return HardwareKeyboard.instance.isAltPressed;
    } on Object {
      return false;
    }
  }

  static bool get isMetaPressed {
    try {
      return HardwareKeyboard.instance.isMetaPressed;
    } on Object {
      return false;
    }
  }
}
