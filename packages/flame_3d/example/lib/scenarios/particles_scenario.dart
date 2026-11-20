import 'dart:math' as math;

import 'package:flame/components.dart' show Component;
import 'package:flame/extensions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d_example/example_game_3d.dart';
import 'package:flame_3d_example/scenarios/game_scenario.dart';

/// Particle systems among pillars they pass behind and in front of: a sparks
/// fountain, a smoke column, coin and confetti bursts, a trail of dust
/// behind a moving emitter, and the water splashes: a crown with foam and
/// mist, and drops running off a slab that rises out of the floor as if it
/// were water.
class ParticlesScenario() implements GameScenario {
  @override
  Future<void> onLoad() async {}

  @override
  void setup(ExampleGame3D game) {
    final sparks = ParticlePresets3D.sparks(capacity: 1024, rate: 160)
      ..position = Vector3(0, 0.3, 0);
    final smoke = ParticlePresets3D.smoke(rate: 8)
      ..position = Vector3(-4, 0.2, 0)
      ..prewarm(3);
    final coins = ParticlePresets3D.coinBurst()..position = Vector3(4, 0.3, 0);
    final confetti = ParticlePresets3D.confetti()
      ..position = Vector3(0, 0.3, 4);
    final dust = ParticlePresets3D.dustPuff();
    dust.emitters[0] = ParticleEmitter3D(
      ratePerDistance: 6,
      shape: const DiscEmitterShape3D(0.15, radial: true),
      speed: (0.3, 0.8),
      velocity: Vector3(0, 0.2, 0),
      lifespan: (0.6, 1),
      size: (0.25, 0.4),
      rotation: (0, 2 * math.pi),
      colors: const [Color(0xFFC8B48C)],
    );

    // The splashes, the floor standing for the surface of the water.
    final splashAt = Vector3(-4, 0, -4);
    final crown = ParticlePresets3D.splashCrown(size: 2);
    final foam = ParticlePresets3D.foamBurst(size: 2);
    final mist = ParticlePresets3D.mistPuff(size: 2);
    final slab = MeshComponent(
      position: Vector3(4, -0.3, -4),
      mesh: CuboidMesh(
        size: Vector3(1.2, 0.5, 1.2),
        material: SpatialMaterial(
          albedoColor: const Color(0xFFB8AC98),
          metallic: 0,
          roughness: 0.9,
        ),
      ),
    );
    final drips = ParticlePresets3D.runoffDrips(width: 1.2, depth: 1.2);

    game.world.addAll([
      for (final (x, z) in const [
        (-2.0, -1.5),
        (2.0, -1.5),
        (-2.0, 1.5),
        (2.0, 1.5),
      ])
        MeshComponent(
          position: Vector3(x, 1.5, z),
          mesh: CuboidMesh(
            size: Vector3(0.8, 3, 0.8),
            material: SpatialMaterial(
              albedoColor: const Color(0xFF8C7A6B),
              metallic: 0.1,
              roughness: 0.8,
            ),
          ),
        ),
      sparks,
      smoke,
      coins,
      confetti,
      dust,
      _Every(1.5, () => coins.burst(16)),
      _Every(3, () => confetti.burst(80)),
      _Circling(dust, radius: 5, speed: 0.6),
      crown,
      foam,
      mist,
      _Every(2.5, () {
        crown.burst(70, at: splashAt);
        foam.burst(24, at: splashAt);
        mist.burst(16, at: splashAt);
      }),
      slab,
      drips,
      _RisingSlab(slab, drips),
    ]);
  }
}

/// Raises [slab] out of the floor and lowers it back, every four seconds,
/// with [drips] running off its top edges as it rises.
class _RisingSlab(final MeshComponent slab, final ParticleSystem3D drips)
    extends Component {
  double _time = 0;

  @override
  void update(double dt) {
    final before = _time;
    _time = (_time + dt) % 4;
    // Up in the first second, down in the third.
    final up = _time < 1
        ? 1 - math.pow(1 - _time, 3)
        : (_time < 2 ? 1.0 : math.max(0.0, 1 - (_time - 2)));
    slab.position.y = -0.3 + 0.7 * up;
    drips.position.setValues(slab.position.x, slab.position.y + 0.25, -4);
    if (before < 0.2 && _time >= 0.2) {
      drips.start();
    }
  }
}

/// Calls [action] every [period] seconds.
class _Every(final double period, final void Function() action)
    extends Component {
  double _time = 0;

  @override
  void update(double dt) {
    _time += dt;
    while (_time >= period) {
      _time -= period;
      action();
    }
  }
}

/// Moves [target] along a circle on the ground.
class _Circling(
  final Component3D target, {
  required final double radius,
  required final double speed,
}) extends Component {
  double _angle = 0;

  @override
  void update(double dt) {
    _angle += speed * dt;
    target.position.setValues(
      math.cos(_angle) * radius,
      0.05,
      math.sin(_angle) * radius,
    );
  }
}
