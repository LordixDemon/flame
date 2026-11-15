import 'dart:math' as math;

import 'package:flame/extensions.dart';
import 'package:flame/src/particles/color_ramp.dart';
import 'package:flame/src/particles/emitter_shape.dart';
import 'package:flame/src/particles/particle_curve.dart';
import 'package:flame/src/particles/particle_emitter.dart';
import 'package:flame/src/particles/particle_force_field.dart';

/// Ready-to-use physical [ParticleEmitter] presets for fire, turbulent smoke,
/// embers, pressurized steam, water splashes, and drifting ground mist.
///
/// Every preset is stateless/reusable and compatible with
/// `ParticleEmitterComponent`, `ComponentPool`, and `ParticleBatchGroup`.
abstract final class ElementalParticles() {
  /// Incandescent blackbody flame core (`6000K` white-yellow -> `3200K` amber
  /// -> `1600K` crimson) driven by thermal [ParticleBuoyancyField] lift and
  /// progressive [ParticleCurlNoiseField] vorticity.
  ///
  /// Pair with `CircleParticleRenderer(softness: 0.72, blendMode:
  /// BlendMode.plus)` or `NoiseCloudParticleRenderer(blendMode:
  /// BlendMode.plus)`.
  static ParticleEmitter fireCore({
    double rate = 56.0,
    int maxParticles = 128,
    double baseRadius = 10.0,
    double intensity = 1.0,
    double windX = 0.0,
    int seed = 101,
  }) {
    final s = intensity.clamp(0.25, 3.0);
    return ParticleEmitter(
      maxParticles: maxParticles,
      rate: rate * s,
      lifespan: (0.42, 0.78),
      shape: CircleEmitterShape(baseRadius),
      speed: (18.0 * s, 46.0 * s),
      direction: -math.pi * 0.5,
      spread: 0.55,
      drag: 1.35,
      velocityStretch: 0.008,
      size: (14.0 * s, 24.0 * s),
      scaleOverLife: ParticleCurve(0.85, 0.18),
      opacityOverLife: ParticleCurve(0.95, 0.0),
      colorOverLife: ColorRamp(const <Color>[
        Color(0xFFFFFBE6),
        Color(0xFFFFCA28),
        Color(0xFFFF5722),
        Color(0x008E0000),
      ]),
      fields: <ParticleForceField>[
        ParticleBuoyancyField(
          liftAcceleration: -235.0 * s,
          ambientDriftX: windX,
          swayAmplitude: 24.0 * s,
        ),
        ParticleCurlNoiseField(
          seed: seed,
          spatialScale: 0.018,
          strength: 165.0 * s,
          scrollSpeedY: -0.85,
          fadeInByProgress: 0.35,
        ),
      ],
    );
  }

  /// Rising charcoal smoke plume driven by decaying buoyancy and curl-noise
  /// eddies. Pair with `NoiseCloudParticleRenderer()`.
  static ParticleEmitter fireSmoke({
    double rate = 22.0,
    int maxParticles = 96,
    double baseRadius = 12.0,
    double windX = 18.0,
    int seed = 202,
  }) {
    return ParticleEmitter(
      maxParticles: maxParticles,
      rate: rate,
      lifespan: (1.2, 2.1),
      shape: CircleEmitterShape(baseRadius),
      speed: (14.0, 32.0),
      direction: -math.pi * 0.5,
      spread: 0.65,
      drag: 1.1,
      size: (18.0, 30.0),
      spin: (-0.9, 0.9),
      scaleOverLife: ParticleCurve(0.65, 2.15),
      opacityOverLife: ParticleCurve(0.52, 0.0),
      colorOverLife: ColorRamp(const <Color>[
        Color(0xAA4A3B36),
        Color(0x882B2E36),
        Color(0x001C2026),
      ]),
      fields: <ParticleForceField>[
        ParticleBuoyancyField(
          liftAcceleration: -95.0,
          coolingPower: 0.85,
          ambientDriftX: windX,
          swayAmplitude: 16.0,
          swayFrequency: 2.4,
        ),
        ParticleCurlNoiseField(
          seed: seed,
          spatialScale: 0.011,
          strength: 110.0,
          scrollSpeedX: 0.25,
          scrollSpeedY: -0.45,
          fadeInByProgress: 0.2,
        ),
      ],
    );
  }

  /// Swirling incandescent embers and cinders that dance upward in curl
  /// turbulence and bounce elastically if they strike [floorY].
  static ParticleEmitter risingEmbers({
    double rate = 18.0,
    int maxParticles = 64,
    double baseRadius = 14.0,
    double? floorY,
    void Function(double x, double y, double impactSpeed)? onFloorBounce,
    int seed = 303,
  }) {
    return ParticleEmitter(
      maxParticles: maxParticles,
      rate: rate,
      lifespan: (0.9, 1.7),
      shape: CircleEmitterShape(baseRadius),
      speed: (32.0, 78.0),
      direction: -math.pi * 0.5,
      spread: 0.95,
      drag: 0.9,
      floorY: floorY,
      floorRestitution: 0.58,
      onFloorBounce: onFloorBounce,
      velocityStretch: 0.014,
      size: (2.8, 5.2),
      scaleOverLife: ParticleCurve(1.0, 0.25),
      opacityOverLife: ParticleCurve(1.0, 0.0),
      colorOverLife: ColorRamp(const <Color>[
        Color(0xFFFFF59D),
        Color(0xFFFF9800),
        Color(0xFFD84315),
      ]),
      fields: <ParticleForceField>[
        ParticleBuoyancyField(
          liftAcceleration: -140.0,
          coolingPower: 1.8,
          swayAmplitude: 32.0,
          swayFrequency: 6.0,
        ),
        ParticleCurlNoiseField(
          seed: seed,
          spatialScale: 0.022,
          strength: 210.0,
        ),
      ],
    );
  }

  /// Pressurized directional steam or geyser vapor jet that decelerates under
  /// drag and expands into curling mist puffs.
  static ParticleEmitter steamJet({
    double direction = -math.pi * 0.5,
    double rate = 34.0,
    int maxParticles = 96,
    double jetSpeed = 145.0,
    int seed = 404,
  }) {
    return ParticleEmitter(
      maxParticles: maxParticles,
      rate: rate,
      lifespan: (0.75, 1.35),
      speed: (jetSpeed * 0.78, jetSpeed * 1.15),
      direction: direction,
      spread: 0.26,
      drag: 2.6,
      size: (10.0, 18.0),
      spin: (-1.4, 1.4),
      scaleOverLife: ParticleCurve(0.55, 2.45),
      opacityOverLife: ParticleCurve(0.68, 0.0),
      colorOverLife: ColorRamp(const <Color>[
        Color(0xCCE8F4FC),
        Color(0x88C5DCEB),
        Color(0x00A8C6DC),
      ]),
      fields: <ParticleForceField>[
        ParticleBuoyancyField(
          liftAcceleration: -65.0,
          coolingPower: 1.0,
          swayAmplitude: 10.0,
        ),
        ParticleCurlNoiseField(
          seed: seed,
          spatialScale: 0.015,
          strength: 125.0,
          fadeInByProgress: 0.25,
        ),
      ],
    );
  }

  /// Parabolic burst of water droplets and spray mist that arcs upward and
  /// splashes onto [floorY].
  static ParticleEmitter waterSplash({
    int count = 18,
    double floorY = 0.0,
    Color color = const Color(0xFFD6F3FF),
    void Function(double x, double y, double impactSpeed)? onFloorBounce,
  }) {
    final n = math.max(1, count);
    return ParticleEmitter(
      maxParticles: math.max(24, n),
      bursts: <EmitterBurst>[EmitterBurst(0.0, n)],
      lifespan: (0.38, 0.68),
      shape: const CircleEmitterShape(6.0),
      speed: (65.0, 145.0),
      direction: -math.pi * 0.5,
      spread: 1.15,
      gravity: Vector2(0.0, 340.0),
      drag: 0.65,
      floorY: floorY,
      floorRestitution: 0.32,
      floorFriction: 0.70,
      onFloorBounce: onFloorBounce,
      velocityStretch: 0.012,
      size: (3.4, 6.4),
      scaleOverLife: ParticleCurve(1.0, 0.45),
      opacityOverLife: ParticleCurve(0.92, 0.0),
      colorOverLife: ColorRamp(<Color>[
        const Color(0xFFFFFFFF),
        color,
      ]),
    );
  }

  /// Low-lying atmospheric mist bank drifting horizontally across [width].
  static ParticleEmitter groundMist({
    double width = 320.0,
    double height = 36.0,
    double rate = 14.0,
    int maxParticles = 80,
    double windX = 22.0,
    Color color = const Color(0x88CEDEEB),
    int seed = 505,
  }) {
    return ParticleEmitter(
      maxParticles: maxParticles,
      rate: rate,
      lifespan: (2.4, 4.2),
      shape: RectangleEmitterShape(width, height),
      speed: (4.0, 14.0),
      drag: 0.85,
      size: (44.0, 78.0),
      spin: (-0.35, 0.35),
      scaleOverLife: ParticleCurve(0.82, 1.45),
      opacityOverLife: ParticleCurve(0.55, 0.0),
      colorOverLife: ColorRamp(<Color>[
        color,
        color.withValues(alpha: 0.0),
      ]),
      fields: <ParticleForceField>[
        ParticleWindField(
          baseAcceleration: Vector2(windX, -2.5),
          seed: seed,
          gustStrength: 18.0,
          gustFrequency: 0.65,
        ),
        ParticleCurlNoiseField(
          seed: seed + 17,
          spatialScale: 0.006,
          strength: 28.0,
        ),
      ],
    );
  }
}
