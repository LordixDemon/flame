import 'package:flame/extensions.dart';

/// Base class for spatial force fields applied to a `ParticleBuffer` during
/// simulation.
sealed class const ParticleForceField();

/// Accelerates live particles toward a target point (or dynamic target
/// provider) and optionally absorbs them once they enter [arrivalRadius].
///
/// Ideal for coin/mana/gem streams, energy homing orbs, and collectible
/// pickups that burst outward before curving smoothly into a target character
/// or HUD counter.
class ParticleAttractor({
  Vector2? position,
  final Vector2 Function()? positionProvider,
  var double strength = 320.0,
  var double arrivalRadius = 8.0,
  var double swirl = 0.0,
  var bool consumeOnArrival = true,
  var void Function(int arrivedCount)? onParticlesArrived,
}) extends ParticleForceField {
  this : assert(arrivalRadius >= 0, 'arrivalRadius must be non-negative');

  /// Static or mutable target position in the emitter's simulation space
  /// (used when [positionProvider] is null).
  final Vector2 position = position ?? Vector2.zero();

  /// Resolves the current target coordinates into [out].
  void resolveTarget(Vector2 out) {
    final provider = positionProvider;
    if (provider != null) {
      out.setFrom(provider());
    } else {
      out.setFrom(position);
    }
  }
}

/// Applies orbital tangential swirl and optional radial pull/push around a
/// center point within [radius].
class ParticleVortex({
  Vector2? center,
  final Vector2 Function()? centerProvider,
  var double angularAcceleration = 220.0,
  var double radialPull = 30.0,
  var double radius = 240.0,
}) extends ParticleForceField {
  this : assert(radius > 0, 'radius must be positive');

  /// Static or mutable vortex center in the emitter's simulation space.
  final Vector2 center = center ?? Vector2.zero();

  /// Resolves the current vortex center into [out].
  void resolveCenter(Vector2 out) {
    final provider = centerProvider;
    if (provider != null) {
      out.setFrom(provider());
    } else {
      out.setFrom(center);
    }
  }
}
