import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/gestures.dart';
import 'package:meta/meta.dart';

/// Base class for events that originate at some point on the screen. These
/// include: tap events, scale events, etc.
///
/// This class includes properties that describe the position where the event
/// has occurred, as well as hardware pointer telemetry (`deviceKind`,
/// `pressure`, `tilt`, `orientation`, `buttons`, and modifier keys).
abstract class PositionEvent<R>(
  final Game _game, {

  /// Event position in the coordinate space of the device -- either the phone,
  /// or the browser window, or the app.
  ///
  /// If the game runs in a full-screen mode, then this would be equal to the
  /// [canvasPosition]. Otherwise, the [devicePosition] is the Flutter-level
  /// global position.
  required final Vector2 devicePosition,
  required super.raw,
}) extends LocationContextEvent<Vector2, R> {
  late final PointerHardwareSample? _telemetryFallback =
      _game.latestPointerTelemetry;

  /// Originating hardware input device (`touch`, `mouse`, `stylus`,
  /// `trackpad`, etc.).
  PointerDeviceKind get deviceKind =>
      PointerTelemetryExtractor.resolveDeviceKind(raw, _telemetryFallback);

  /// Stylus / touch force pressure (`1.0` when unsupported).
  double get pressure =>
      PointerTelemetryExtractor.resolvePressure(raw, _telemetryFallback);

  /// Stylus tilt angle in radians (`0.0 .. pi/2`).
  double get tilt =>
      PointerTelemetryExtractor.resolveTilt(raw, _telemetryFallback);

  /// Stylus azimuth orientation angle in radians (`-pi .. pi`).
  double get orientation =>
      PointerTelemetryExtractor.resolveOrientation(raw, _telemetryFallback);

  /// Bitmask of currently pressed mouse / stylus buttons (`kPrimaryButton`,
  /// `kSecondaryButton`, `kMiddleMouseButton`, etc.).
  int get buttons =>
      PointerTelemetryExtractor.resolveButtons(raw, _telemetryFallback);

  /// Whether [deviceKind] is a stylus (`stylus` or `invertedStylus`).
  bool get isStylus =>
      deviceKind == PointerDeviceKind.stylus ||
      deviceKind == PointerDeviceKind.invertedStylus;

  /// Whether [deviceKind] is direct touch.
  bool get isTouch => deviceKind == PointerDeviceKind.touch;

  /// Whether [deviceKind] is a mouse.
  bool get isMouse => deviceKind == PointerDeviceKind.mouse;

  /// Whether [deviceKind] is a trackpad.
  bool get isTrackpad => deviceKind == PointerDeviceKind.trackpad;

  /// Whether either `Shift` modifier key is currently held.
  bool get isShiftPressed => PointerTelemetryExtractor.isShiftPressed;

  /// Whether either `Control` modifier key is currently held.
  bool get isControlPressed => PointerTelemetryExtractor.isControlPressed;

  /// Whether either `Alt` / `Option` modifier key is currently held.
  bool get isAltPressed => PointerTelemetryExtractor.isAltPressed;

  /// Whether either `Meta` / `Command` / `Windows` key is currently held.
  bool get isMetaPressed => PointerTelemetryExtractor.isMetaPressed;

  /// Event position in the coordinate space of the game widget, i.e. relative
  /// to the game canvas.
  ///
  /// This could be considered the Flame-level global position.
  late final Vector2 canvasPosition = _game.convertGlobalToLocalCoordinate(
    devicePosition,
  );

  /// Event position in the local coordinate space of the current component.
  ///
  /// This property is only accessible when the event is being propagated to
  /// the components via [deliverAtPoint]. It is an error to try to read this
  /// property at other times.
  Vector2 get localPosition => renderingTrace.last;

  @override
  @internal
  Vector2? get eventCanvasPosition => canvasPosition;

  @override
  Iterable<Component> collectApplicableChildren({
    required Component rootComponent,
  }) {
    return rootComponent.componentsAtPoint(canvasPosition, renderingTrace);
  }
}
