import 'dart:math' as math;

import 'package:flame/extensions.dart';
import 'package:flame/src/math/simplex_noise_2d.dart';

/// Base class for spatial force fields and colliders applied to a
/// `ParticleBuffer` during simulation.
sealed class const ParticleForceField();

/// Accelerates live particles toward a target point (or dynamic target
/// provider) and optionally absorbs them once they enter [arrivalRadius].
///
/// Ideal for coin/mana/gem streams, energy homing orbs, and collectible
/// pickups that burst outward before curving smoothly into a target character
/// or HUD counter.
///
/// The target is [position], or the point returned by [positionProvider]
/// when one is given; the provider is called once per simulation step. Both
/// are in the emitter's local simulation space.
///
/// [strength] is the acceleration toward the target and [swirl] a tangential
/// acceleration around it, both in local units per second squared.
///
/// A particle arrives when it enters [arrivalRadius]. With
/// [consumeOnArrival] it is removed at that moment; otherwise it lives on,
/// and counts as a new arrival only after it has left the radius and entered
/// it again. [onParticlesArrived] is called at most once per simulation
/// step, after the step, with the number of particles that arrived in it.
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

/// Applies divergence-free 2D curl-noise turbulence (`∇ × ψ`) so fire, smoke,
/// embers, snow, and mist swirl organically without clumping into sinkholes.
class ParticleCurlNoiseField({
  SimplexNoise2D? noise,
  int seed = 1337,
  var double spatialScale = 0.012,
  var double strength = 140.0,
  var double scrollSpeedX = 0.35,
  var double scrollSpeedY = -0.55,
  var double fadeInByProgress = 0.0,
  final double epsilon = 0.002,
}) extends ParticleForceField {
  this
    : assert(spatialScale > 0, 'spatialScale must be positive'),
      assert(epsilon > 1e-5, 'epsilon must be > 1e-5'),
      assert(
        fadeInByProgress >= 0 && fadeInByProgress <= 1,
        'fadeInByProgress must be between 0 and 1',
      );

  /// Underlying seeded 2D Simplex scalar streamfunction `ψ(x, y)`.
  final SimplexNoise2D noise = noise ?? SimplexNoise2D(seed: seed);

  /// Samples the divergence-free curl acceleration `(ax, ay)` at `(x, y)` and
  /// simulation [time], modulated by particle life [progress] (`0..1`).
  (double, double) sampleAcceleration(
    double x,
    double y,
    double time,
    double progress,
  ) {
    final sx = x * spatialScale + time * scrollSpeedX;
    final sy = y * spatialScale + time * scrollSpeedY;
    final inv2Eps = 0.5 / epsilon;
    final dPsiDy =
        (noise.sample(sx, sy + epsilon) - noise.sample(sx, sy - epsilon)) *
        inv2Eps;
    final dPsiDx =
        (noise.sample(sx + epsilon, sy) - noise.sample(sx - epsilon, sy)) *
        inv2Eps;
    final ramp = fadeInByProgress <= 1e-6
        ? 1.0
        : (progress / fadeInByProgress).clamp(0.0, 1.0);
    final scale = strength * ramp;
    return (dPsiDy * scale, -dPsiDx * scale);
  }
}

/// Applies thermal convective buoyancy that lifts hot gases strongly at birth
/// and decays smoothly as particles cool over their normalized lifetime.
class ParticleBuoyancyField({
  var double liftAcceleration = -220.0,
  var double coolingPower = 1.4,
  var double ambientDriftX = 0.0,
  var double swayAmplitude = 18.0,
  var double swayFrequency = 4.5,
}) extends ParticleForceField {
  this : assert(coolingPower >= 0, 'coolingPower must be non-negative');

  /// Evaluates thermal acceleration `(ax, ay)` for a particle with normalized
  /// life [progress] (`0..1`), simulation [time], and deterministic [phase].
  (double, double) sampleAcceleration(
    double progress,
    double time,
    double phase,
  ) {
    final heat = (1.0 - progress).clamp(0.0, 1.0);
    final double factor;
    if (coolingPower == 1.0) {
      factor = heat;
    } else if (coolingPower == 2.0) {
      factor = heat * heat;
    } else if (coolingPower == 0.0) {
      factor = 1.0;
    } else {
      factor = math.pow(heat, coolingPower).toDouble();
    }
    final sway = swayAmplitude == 0.0
        ? 0.0
        : math.sin(time * swayFrequency + phase) * swayAmplitude * (1.0 - heat);
    return (ambientDriftX + sway, liftAcceleration * factor);
  }
}

/// Applies directional wind acceleration with coherent spatial and temporal
/// gusts driven by [SimplexNoise2D].
class ParticleWindField({
  Vector2? baseAcceleration,
  SimplexNoise2D? noise,
  int seed = 4242,
  var double gustStrength = 85.0,
  var double gustFrequency = 1.4,
  var double spatialScale = 0.004,
}) extends ParticleForceField {
  /// Constant mean wind acceleration `(ax, ay)` in local units/s².
  final Vector2 baseAcceleration = baseAcceleration ?? Vector2(60.0, 0.0);

  /// Seeded Simplex noise used for travelling gusts.
  final SimplexNoise2D noise = noise ?? SimplexNoise2D(seed: seed);

  /// Evaluates total wind + gust acceleration `(ax, ay)` at `(x, y)` and
  /// simulation [time].
  (double, double) sampleAcceleration(double x, double y, double time) {
    if (gustStrength == 0.0) {
      return (baseAcceleration.x, baseAcceleration.y);
    }
    final gx = noise.sample(
      x * spatialScale - time * gustFrequency,
      y * spatialScale + 0.37,
    );
    final gy = noise.sample(
      x * spatialScale + 7.13,
      y * spatialScale - time * gustFrequency * 0.7,
    );
    return (
      baseAcceleration.x + gx * gustStrength,
      baseAcceleration.y + gy * gustStrength * 0.35,
    );
  }
}

/// Pushes particles away from a circular obstacle or shield dome and optionally
/// enforces an elastic [hardBoundary] collision at [radius].
class ParticleRepulsor({
  Vector2? position,
  final Vector2 Function()? positionProvider,
  var double radius = 48.0,
  var double strength = 420.0,
  var bool hardBoundary = false,
  var double restitution = 0.55,
}) extends ParticleForceField {
  this
    : assert(radius > 0, 'radius must be positive'),
      assert(
        restitution >= 0 && restitution <= 1,
        'restitution must be between 0 and 1',
      );

  /// Center of the repulsor when [positionProvider] is null.
  final Vector2 position = position ?? Vector2.zero();

  /// Resolves the current repulsor center into [out].
  void resolveCenter(Vector2 out) {
    final provider = positionProvider;
    if (provider != null) {
      out.setFrom(provider());
    } else {
      out.setFrom(position);
    }
  }
}

/// Arbitrary 2D half-plane collider `n · p >= offset` that reflects particles
/// off slanted roofs, walls, cliffs, or force barriers.
class ParticlePlaneCollider({
  required double normalX,
  required double normalY,
  var double offset = 0.0,
  var double restitution = 0.45,
  var double friction = 0.82,
}) extends ParticleForceField {
  this
    : assert(
        normalX != 0 || normalY != 0,
        'Plane normal must be non-zero',
      ),
      assert(
        restitution >= 0 && restitution <= 1,
        'restitution must be between 0 and 1',
      ),
      assert(
        friction >= 0 && friction <= 1,
        'friction must be between 0 and 1',
      ) {
    final invLen = 1.0 / math.sqrt(normalX * normalX + normalY * normalY);
    this.normalX = normalX * invLen;
    this.normalY = normalY * invLen;
  }

  /// Unit normal X pointing into the allowed half-space.
  late final double normalX;

  /// Unit normal Y pointing into the allowed half-space.
  late final double normalY;
}
