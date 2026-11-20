import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/animation.dart' show Curves;

/// Ready-made [ParticleSystem3D]s for common effects, to use as they are or
/// as starting points.
///
/// Each preset is a system with one emitter that spawns nothing on its own
/// (unless given a `rate`): call [ParticleSystem3D.burst] to release
/// particles where the effect happens. Their sizes, speeds and accelerations
/// are in meters for a `scale` of `1`: pass the number of scene units per
/// meter otherwise. `up` is the scene's up direction (`+y` by default); the
/// ground of the presets that have one is the plane through the origin
/// perpendicular to it, at `groundHeight` along it.
abstract final class ParticlePresets3D() {
  /// Glowing sparks shooting up and out, stretched along their velocity,
  /// falling and bouncing off the ground: hits, impacts, welding,
  /// fireworks.
  ///
  /// Additive, so they need no sorting and brighten what is behind them.
  static ParticleSystem3D sparks({
    int capacity = 512,
    Color color = const Color(0xFFFFA43A),
    double rate = 0,
    Vector3? up,
    double scale = 1,
    double? groundHeight = 0,
    int seed = 1,
  }) {
    final upAxis = _unit(up);
    return ParticleSystem3D(
      capacity: capacity,
      seed: seed,
      rotation: _orientation(upAxis),
      material: ParticleMaterial(
        billboard: ParticleBillboard.velocity,
        softness: 0.9,
        renderState: RenderState.additive,
      ),
      emitters: [
        ParticleEmitter3D(
          rate: rate,
          shape: const ConeEmitterShape3D(angle: 0.9),
          speed: (2.5 * scale, 6 * scale),
          lifespan: (0.35, 0.8),
          size: (0.04 * scale, 0.07 * scale),
        ),
      ],
      gravity: upAxis * (-9.8 * scale),
      drag: 0.6,
      ground: groundHeight == null
          ? null
          : ParticleGround3D(
              height: groundHeight,
              normal: upAxis,
              restitution: 0.35,
              friction: 0.6,
              restSpeed: 0.3 * scale,
            ),
      velocityStretch: 0.15 / scale,
      maxStretch: 6,
      sizeOverLife: ParticleCurve(1, 0.4),
      colorOverLife: ColorRamp(
        [const Color(0xFFFFFFFF), color, color.withValues(alpha: 0)],
        stops: const [0, 0.3, 1],
      ),
    );
  }

  /// Soft, lumpy smoke that rises, swells, swirls and fades: chimneys,
  /// fires, demolitions.
  ///
  /// Blended with premultiplied alpha and sorted back to front.
  static ParticleSystem3D smoke({
    int capacity = 256,
    Color color = const Color(0xFF8A8F96),
    double rate = 0,
    Vector3? up,
    double scale = 1,
    int seed = 2,
  }) {
    final upAxis = _unit(up);
    return ParticleSystem3D(
      capacity: capacity,
      seed: seed,
      rotation: _orientation(upAxis),
      material: ParticleMaterial(
        sprite: ParticleSprite.softBlob,
        softness: 0.7,
        lumpiness: 0.7,
      ),
      emitters: [
        ParticleEmitter3D(
          rate: rate,
          shape: SphereEmitterShape3D(0.15 * scale, hemisphere: true),
          speed: (0.2 * scale, 0.6 * scale),
          spread: 0.5,
          velocity: upAxis * (0.6 * scale),
          lifespan: (2.2, 3.2),
          size: (0.3 * scale, 0.5 * scale),
          rotation: (0, 2 * math.pi),
          spin: (-0.6, 0.6),
          colors: [color],
        ),
      ],
      gravity: upAxis * (0.4 * scale),
      drag: 0.8,
      turbulence: ParticleTurbulence3D(
        strength: 1.2 * scale,
        frequency: 0.9 / scale,
        speed: 0.8,
      ),
      sizeOverLife: ParticleCurve(0.6, 2.6, curve: Curves.easeOut),
      opacityOverLife: _fadeInOut(0.12, 0.7),
    );
  }

  /// A puff of dust thrown sideways along the ground that swells and
  /// settles: footsteps, landings, things dropped on the ground.
  ///
  /// Blended with premultiplied alpha and sorted back to front.
  static ParticleSystem3D dustPuff({
    int capacity = 256,
    Color color = const Color(0xFFC8B48C),
    Vector3? up,
    double scale = 1,
    int seed = 3,
  }) {
    final upAxis = _unit(up);
    return ParticleSystem3D(
      capacity: capacity,
      seed: seed,
      rotation: _orientation(upAxis),
      material: ParticleMaterial(
        sprite: ParticleSprite.softBlob,
        softness: 0.8,
        lumpiness: 0.5,
      ),
      emitters: [
        ParticleEmitter3D(
          shape: DiscEmitterShape3D(0.12 * scale, radial: true),
          speed: (0.6 * scale, 1.4 * scale),
          velocity: upAxis * (0.25 * scale),
          spread: 0.25,
          lifespan: (0.5, 0.9),
          size: (0.18 * scale, 0.3 * scale),
          rotation: (0, 2 * math.pi),
          spin: (-1, 1),
          colors: [color],
        ),
      ],
      gravity: upAxis * (0.15 * scale),
      drag: 4,
      sizeOverLife: ParticleCurve(0.5, 1.8, curve: Curves.easeOut),
      opacityOverLife: ParticleCurve(0.85, 0, curve: Curves.easeIn),
    );
  }

  /// Paper confetti: small flat mesh particles in several colors that shoot
  /// up, flutter down slowly while tumbling, and come to rest lying flat.
  ///
  /// The default [mesh] is a two-sided card drawn with an opaque
  /// `UnlitMaterial`, tinted by each particle's color.
  static ParticleSystem3D confetti({
    int capacity = 512,
    List<Color> colors = const [
      Color(0xFFFF5A5F),
      Color(0xFFFFC145),
      Color(0xFF4ECDC4),
      Color(0xFF5B8DEF),
      Color(0xFFB57BFF),
      Color(0xFFFFFFFF),
    ],
    Mesh? mesh,
    Vector3? up,
    double scale = 1,
    double? groundHeight = 0,
    int seed = 4,
  }) {
    final upAxis = _unit(up);
    return ParticleSystem3D(
      capacity: capacity,
      seed: seed,
      rotation: _orientation(upAxis),
      mesh:
          mesh ??
          PlaneMesh(
            size: Vector2(1, 0.5),
            material: UnlitMaterial()..renderState = RenderState.opaque,
          ),
      emitters: [
        ParticleEmitter3D(
          shape: const ConeEmitterShape3D(angle: 0.6),
          speed: (3.5 * scale, 6 * scale),
          lifespan: (2.5, 3.5),
          size: (0.05 * scale, 0.08 * scale),
          rotation: (0, 2 * math.pi),
          spin: (-14, 14),
          gravityScale: (0.18, 0.3),
          colors: colors,
        ),
      ],
      gravity: upAxis * (-9.8 * scale),
      drag: 2.2,
      turbulence: ParticleTurbulence3D(
        strength: 1.2 * scale,
        frequency: 1.5 / scale,
        speed: 1.5,
      ),
      ground: groundHeight == null
          ? null
          : ParticleGround3D(
              height: groundHeight,
              normal: upAxis,
              restitution: 0.05,
              friction: 0.3,
              slideDrag: 8,
              restSpeed: 0.3 * scale,
              settleRotation: true,
            ),
      sizeOverLife: _shrinkAtEnd(0.85),
    );
  }

  /// Coins that burst up, tumble, bounce on the ground and settle lying
  /// flat: rewards, payouts, treasure.
  ///
  /// The default [mesh] is a gold coin (a flat `CylinderMesh` of radius `1`
  /// drawn with a `SpatialMaterial`, scaled by each particle's size); pass a
  /// mesh of your own (modelled lying flat in its `xz` plane,
  /// of radius about `1`) to match your art.
  static ParticleSystem3D coinBurst({
    int capacity = 128,
    Mesh? mesh,
    Vector3? up,
    double scale = 1,
    double? groundHeight = 0,
    int seed = 5,
  }) {
    final upAxis = _unit(up);
    const thickness = 0.18;
    return ParticleSystem3D(
      capacity: capacity,
      seed: seed,
      rotation: _orientation(upAxis),
      mesh:
          mesh ??
          CylinderMesh(
            radius: 1,
            height: thickness,
            segments: 20,
            material: SpatialMaterial(
              albedoColor: const Color(0xFFFFC83D),
              metallic: 0.3,
              roughness: 0.35,
            ),
          ),
      emitters: [
        ParticleEmitter3D(
          shape: ConeEmitterShape3D(angle: 0.55, radius: 0.05 * scale),
          speed: (3.2 * scale, 5 * scale),
          lifespan: (2.2, 2.8),
          size: (0.1 * scale, 0.12 * scale),
          rotation: (0, 2 * math.pi),
          spin: (-16, 16),
        ),
      ],
      gravity: upAxis * (-9.8 * scale),
      drag: 0.2,
      ground: groundHeight == null
          ? null
          : ParticleGround3D(
              height: groundHeight,
              normal: upAxis,
              restitution: 0.45,
              friction: 0.7,
              slideDrag: 5,
              restSpeed: 0.4 * scale,
              sizeOffset: thickness / 2,
              settleRotation: true,
            ),
      sizeOverLife: _shrinkAtEnd(0.9),
    );
  }

  /// A crown of droplets thrown up and out where something breaks the water
  /// surface or lands on it; they fall back and die at the [waterLevel],
  /// each reporting where it fell to [onGroundHit] (to start a ripple, for
  /// instance).
  ///
  /// [size] scales the splash: `1` suits something about 20 cm across.
  /// Distances grow with it and speeds with its square root, so a bigger
  /// splash rises higher and lasts longer. Blended with premultiplied alpha
  /// and sorted back to front. Burst it at the point of the surface where
  /// the splash happens, about `40 * size` particles.
  static ParticleSystem3D splashCrown({
    int capacity = 384,
    double size = 1,
    Color tint = const Color(0xFFEAF6FF),
    Vector3? up,
    double scale = 1,
    double waterLevel = 0,
    void Function(Vector3 position, double speed)? onGroundHit,
    int seed = 6,
  }) {
    final upAxis = _unit(up);
    final length = size * scale;
    final speed = math.sqrt(size) * scale;
    return ParticleSystem3D(
      capacity: capacity,
      seed: seed,
      rotation: _orientation(upAxis),
      material: ParticleMaterial(
        billboard: ParticleBillboard.velocity,
        softness: 0.65,
      ),
      emitters: [
        ParticleEmitter3D(
          shape: DiscEmitterShape3D(
            0.1 * length,
            innerRadius: 0.08 * length,
            tilt: 0.38,
          ),
          offset: Vector3(0, 0.005 * scale, 0),
          speed: (1.75 * speed, 2.35 * speed),
          spread: 0.12,
          lifespan: (1.2, 1.6),
          size: (0.02 * length, 0.042 * length),
          colors: [tint],
        ),
      ],
      gravity: upAxis * (-9.8 * scale),
      drag: 0.4,
      ground: ParticleGround3D(
        height: waterLevel,
        normal: upAxis,
        killOnHit: true,
      ),
      onGroundHit: onGroundHit,
      velocityStretch: 0.35 / scale,
      maxStretch: 3,
      opacityOverLife: ParticleCurve(1, 0.7),
    );
  }

  /// Water running off the edges of a slab that rises out of the water: drops
  /// fall from the outline of a rectangle of [width] by [depth] (along the
  /// scene's x and the other horizontal axis), thinning out over [duration]
  /// seconds, and die at the [waterLevel], each reporting where it fell to
  /// [onGroundHit].
  ///
  /// The system starts with its emitter stopped: call
  /// [ParticleSystem3D.start] when the slab leaves the water, and keep the
  /// system's `position` at the middle of the slab's top as it rises (the
  /// drops stay where they fall from). `rate` is the number of drops per
  /// second at the start. Blended with premultiplied alpha and sorted back to
  /// front.
  static ParticleSystem3D runoffDrips({
    required double width,
    required double depth,
    int capacity = 512,
    double duration = 1.6,
    double rate = 480,
    Color tint = const Color(0xFFE2F2FF),
    Vector3? up,
    double scale = 1,
    double waterLevel = 0,
    void Function(Vector3 position, double speed)? onGroundHit,
    int seed = 7,
  }) {
    assert(duration > 0, 'duration must be positive');
    final upAxis = _unit(up);
    // A burst every 50 ms, fewer and fewer of them.
    const step = 0.05;
    final steps = math.max(1, (duration / step).round());
    final bursts = <EmitterBurst>[];
    var owed = 0.0;
    for (var i = 0; i < steps; i++) {
      final left = 1 - i / steps;
      owed += rate * step * left * left;
      final count = owed.floor();
      if (count > 0) {
        bursts.add(EmitterBurst(i * step, count));
        owed -= count;
      }
    }
    return ParticleSystem3D(
      capacity: capacity,
      seed: seed,
      emitting: false,
      rotation: _orientation(upAxis),
      material: ParticleMaterial(
        billboard: ParticleBillboard.velocity,
        softness: 0.6,
      ),
      emitters: [
        ParticleEmitter3D(
          bursts: bursts,
          shape: RectangleEdgeEmitterShape3D(width, depth, outward: true),
          speed: (0.08 * scale, 0.3 * scale),
          spread: 0.3,
          lifespan: (1.5, 2),
          size: (0.02 * scale, 0.036 * scale),
          aspect: (1.4, 2.2),
          gravityScale: (0.7, 1),
          colors: [tint],
        ),
      ],
      gravity: upAxis * (-9.8 * scale),
      drag: 0.3,
      ground: ParticleGround3D(
        height: waterLevel,
        normal: upAxis,
        killOnHit: true,
      ),
      onGroundHit: onGroundHit,
      velocityStretch: 0.3 / scale,
      maxStretch: 3,
      opacityOverLife: ParticleCurve(1, 0.75),
    );
  }

  /// A short burst of foam spreading on the water where something broke the
  /// surface: soft white patches lying flat (perpendicular to `up`, a hair
  /// above the point they are burst at) that spread, swell and fade within a
  /// second.
  ///
  /// [size] scales the patches and how far they spread (`1` for something
  /// about 20 cm across). Blended with premultiplied alpha and sorted back to
  /// front. Burst it at the point of the surface, about `14 * size`
  /// particles.
  static ParticleSystem3D foamBurst({
    int capacity = 256,
    double size = 1,
    Color color = const Color(0xFFF4FAFF),
    Vector3? up,
    double scale = 1,
    int seed = 8,
  }) {
    final upAxis = _unit(up);
    final length = size * scale;
    return ParticleSystem3D(
      capacity: capacity,
      seed: seed,
      rotation: _orientation(upAxis),
      material: ParticleMaterial(
        sprite: ParticleSprite.softBlob,
        billboard: ParticleBillboard.flat,
        axis: upAxis,
        softness: 0.75,
        lumpiness: 0.85,
      ),
      emitters: [
        ParticleEmitter3D(
          shape: DiscEmitterShape3D(0.06 * length, radial: true),
          offset: Vector3(0, 0.008 * scale, 0),
          speed: (0.25 * length, 0.8 * length),
          lifespan: (0.6, 1.1),
          size: (0.07 * length, 0.15 * length),
          rotation: (0, 2 * math.pi),
          spin: (-0.8, 0.8),
          colors: [color],
        ),
      ],
      drag: 3.5,
      sizeOverLife: ParticleCurve(0.6, 2.1, curve: Curves.easeOut),
      opacityOverLife: _fadeInOut(0.08, 0.9),
    );
  }

  /// A puff of fine mist over a splash: faint soft blobs that start a little
  /// above the point they are burst at, swell, drift up and fade within a
  /// second or so.
  ///
  /// [size] scales the puff (`1` for something about 20 cm across). Blended
  /// with premultiplied alpha and sorted back to front. Burst it at the
  /// point of the surface, about `10 * size` particles.
  static ParticleSystem3D mistPuff({
    int capacity = 128,
    double size = 1,
    Color color = const Color(0xFFE8F4FA),
    Vector3? up,
    double scale = 1,
    int seed = 9,
  }) {
    final upAxis = _unit(up);
    final length = size * scale;
    return ParticleSystem3D(
      capacity: capacity,
      seed: seed,
      rotation: _orientation(upAxis),
      material: ParticleMaterial(
        sprite: ParticleSprite.softBlob,
        softness: 0.9,
        lumpiness: 0.5,
      ),
      emitters: [
        ParticleEmitter3D(
          shape: SphereEmitterShape3D(0.08 * length, hemisphere: true),
          offset: Vector3(0, 0.12 * length, 0),
          speed: (0.15 * length, 0.45 * length),
          velocity: upAxis * (0.2 * length),
          lifespan: (0.8, 1.4),
          size: (0.07 * length, 0.14 * length),
          rotation: (0, 2 * math.pi),
          spin: (-0.5, 0.5),
          colors: [color],
        ),
      ],
      drag: 2.5,
      turbulence: ParticleTurbulence3D(
        strength: 0.3 * length,
        frequency: 2 / length,
        speed: 1.2,
      ),
      sizeOverLife: ParticleCurve(0.6, 2.8, curve: Curves.easeOut),
      opacityOverLife: _fadeInOut(0.15, 0.32),
    );
  }

  static Vector3 _unit(Vector3? up) {
    if (up == null || up.length2 == 0) {
      return Vector3(0, 1, 0);
    }
    return up.normalized();
  }

  /// The rotation that turns `+y`, the axis presets are described around,
  /// to [up].
  static Quaternion _orientation(Vector3 up) {
    if (up.y < -0.9999) {
      return Quaternion.axisAngle(Vector3(1, 0, 0), math.pi);
    }
    return Quaternion.fromTwoVectors(Vector3(0, 1, 0), up);
  }

  /// Fades in over the first [fadeIn] of the life, up to [peak], then out.
  static ParticleCurve _fadeInOut(double fadeIn, double peak) {
    return ParticleCurve.custom(
      (t) => t < fadeIn
          ? peak * t / fadeIn
          : peak * (1 - (t - fadeIn) / (1 - fadeIn)),
    );
  }

  /// Full size until [start], then shrinks to nothing at the end of the
  /// life.
  static ParticleCurve _shrinkAtEnd(double start) {
    return ParticleCurve.custom(
      (t) => t < start ? 1 : (1 - t) / (1 - start),
    );
  }
}
