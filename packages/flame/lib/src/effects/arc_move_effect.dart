import 'dart:math' as math;

import 'package:flame/extensions.dart';
import 'package:flame/src/effects/controllers/effect_controller.dart';
import 'package:flame/src/effects/move_effect.dart';
import 'package:flame/src/effects/provider_interfaces.dart';

/// Interface implemented by 2.5D/isometric/3D components whose ground shadow
/// stays anchored at `position` while their visual body rises above the ground
/// plane.
abstract interface class ElevationTarget() {
  /// Updates the visual height offset above the ground plane (`>= 0` for upward
  /// jumps).
  void setElevation(double elevation);
}

/// Moves a [PositionProvider] to a destination along a zero-allocation
/// parabolic jump arc (`4 * arcHeight * t * (1 - t)`).
///
/// - When [target] implements [ElevationTarget] (or [onElevation] is provided),
///   `target.position` advances cleanly along the ground line while the
///   parabolic height is reported separately so ground shadows stay planted.
/// - Otherwise, the parabolic arc offset is added directly along `arcNormal`
///   (default `Vector2(0, -1)` = upward in 2D screen/world coordinates) with
///   incremental deltas so multiple effects compose cleanly.
class ArcMoveEffect(
  Vector2 destination,
  EffectController controller, {
  final double arcHeight = 28.0,
  Vector2? arcNormal,
  final void Function(double elevation)? onElevation,
  PositionProvider? target,
  super.onComplete,
  super.key,
}) extends MoveEffect {
  this : super(controller, target);

  final Vector2 _destination = destination.clone();
  final Vector2 _arcNormal = (arcNormal?.clone() ?? Vector2(0, -1))
    ..normalize();
  final Vector2 _groundDelta = Vector2.zero();
  final Vector2 _lastApplied = Vector2.zero();

  @override
  void onStart() {
    super.onStart();
    _groundDelta
      ..setFrom(_destination)
      ..sub(target.position);
    _lastApplied.setZero();
    _reportElevationIfSupported(0.0);
  }

  bool get _separatesElevation =>
      onElevation != null || (target as Object) is ElevationTarget;

  void _reportElevationIfSupported(double elevation) {
    final cb = onElevation;
    if (cb != null) {
      cb(elevation);
    }
    final Object tgt = target;
    if (tgt is ElevationTarget) {
      tgt.setElevation(elevation);
    }
  }

  @override
  void apply(double progress) {
    final clamped = progress.clamp(0.0, 1.0);
    final elevation = 4.0 * arcHeight * clamped * (1.0 - clamped);

    var desiredX = _groundDelta.x * progress;
    var desiredY = _groundDelta.y * progress;

    if (_separatesElevation) {
      _reportElevationIfSupported(elevation);
    } else {
      desiredX += _arcNormal.x * elevation;
      desiredY += _arcNormal.y * elevation;
    }

    target.position.x += desiredX - _lastApplied.x;
    target.position.y += desiredY - _lastApplied.y;
    _lastApplied.setValues(desiredX, desiredY);
  }

  @override
  void onFinish() {
    if (_separatesElevation && (controller.progress - 1.0).abs() < 1e-4) {
      _reportElevationIfSupported(0.0);
    }
    super.onFinish();
  }

  @override
  double measure() {
    final chord = _groundDelta.length;
    return math.sqrt(chord * chord + 16.0 * arcHeight * arcHeight * 0.35);
  }
}
