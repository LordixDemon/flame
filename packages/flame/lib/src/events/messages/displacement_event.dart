import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/src/game/game.dart';
import 'package:flutter/gestures.dart';
import 'package:meta/meta.dart';

/// Location context for the Displacement Event.
///
/// This represents a user event that has a start and end locations, as the
/// ones that are represented by a [DisplacementEvent].
typedef DisplacementContext = ({Vector2 start, Vector2 end});

extension DisplacementContextDelta on DisplacementContext {
  /// Displacement delta
  Vector2 get delta => end - start;
}

/// Base class for events that contain two points on the screen, representing
/// some sort of movement (from a "start" to and "end") and having a "delta".
/// These include: drag events and (in the future) pointer move events.
///
/// This class includes properties that describe both positions where the event
/// has occurred (start and end) and the delta (i.e. displacement) represented
/// by the event.
abstract class DisplacementEvent<R>(
  final Game _game, {
  required super.raw,

  /// Event start position in the coordinate space of the device -- either the
  /// phone, or the browser window, or the app.
  ///
  /// If the game runs in a full-screen mode, then this would be equal to the
  /// [canvasStartPosition]. Otherwise, the [deviceStartPosition] is the
  /// Flutter-level global position.
  required final Vector2 deviceStartPosition,

  /// Event end position in the coordinate space of the device -- either the
  /// phone, or the browser window, or the app.
  ///
  /// If the game runs in a full-screen mode, then this would be equal to the
  /// [canvasEndPosition]. Otherwise, the [deviceEndPosition] is the
  /// Flutter-level global position.
  required final Vector2 deviceEndPosition,
}) extends LocationContextEvent<DisplacementContext, R> {
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

  /// Bitmask of currently pressed mouse / stylus buttons.
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

  /// Event start position in the coordinate space of the game widget, i.e.
  /// relative to the game canvas.
  ///
  /// This could be considered the Flame-level global position.
  late final Vector2 canvasStartPosition = _game.convertGlobalToLocalCoordinate(
    deviceStartPosition,
  );

  /// Event start position in the local coordinate space of the current
  /// component.
  ///
  /// This property is only accessible when the event is being propagated to
  /// the components via [deliverAtPoint]. It is an error to try to read this
  /// property at other times.
  Vector2 get localStartPosition => renderingTrace.last.start;

  /// Event end position in the coordinate space of the game widget, i.e.
  /// relative to the game canvas.
  ///
  /// This could be considered the Flame-level global position.
  late final Vector2 canvasEndPosition = _game.convertGlobalToLocalCoordinate(
    deviceEndPosition,
  );

  /// Event end position in the local coordinate space of the current
  /// component.
  ///
  /// This property is only accessible when the event is being propagated to
  /// the components via [deliverAtPoint]. It is an error to try to read this
  /// property at other times.
  Vector2 get localEndPosition => renderingTrace.last.end;

  /// Event delta in the coordinate space of the device -- either the
  /// phone, or the browser window, or the app.
  ///
  /// If the game runs in a full-screen mode, then this would be equal to the
  /// [canvasDelta]. Otherwise, the [deviceDelta] is the
  /// Flutter-level global position.
  late final Vector2 deviceDelta = deviceEndPosition - deviceStartPosition;

  /// Event delta in the coordinate space of the game widget, i.e.
  /// relative to the game canvas.
  ///
  /// This could be considered the Flame-level global position.
  late final Vector2 canvasDelta = canvasEndPosition - canvasStartPosition;

  /// Event delta in the local coordinate space of the current component.
  ///
  /// This property is only accessible when the event is being propagated to
  /// the components via [deliverAtPoint]. It is an error to try to read this
  /// property at other times.
  Vector2 get localDelta => localEndPosition - localStartPosition;

  @override
  @internal
  Vector2? get eventCanvasPosition => canvasEndPosition;

  @override
  Iterable<Component> collectApplicableChildren({
    required Component rootComponent,
  }) {
    return rootComponent.componentsAtLocation(
      (
        start: canvasStartPosition,
        end: canvasEndPosition,
      ),
      renderingTrace,
      (transform, context) {
        final start = context.start;
        final transformedStart = transform.parentToLocal(start);

        final end = context.end;
        final transformedEnd = transform.parentToLocal(end);

        if (transformedStart == null || transformedEnd == null) {
          return null;
        }
        return (
          start: transformedStart,
          end: transformedEnd,
        );
      },
      // we only trigger the drag start if the component check passes, but
      // as the user drags the cursor it could end up outside the component
      // bounds; we don't want the event to be lost, so we bypass the check.
      (component, context) => true,
    );
  }
}
