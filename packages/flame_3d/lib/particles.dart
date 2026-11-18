/// GPU particles for `flame_3d`: [ParticleSystem3D] simulates particles on
/// the CPU (struct of arrays, no allocations per frame) and draws them with
/// one instanced draw per system and material, depth tested against the
/// scene: camera-facing quads with [ParticleMaterial], or small meshes drawn
/// with any instanced material.
///
/// The curves over a particle's life ([ParticleCurve], [ColorRamp]), the
/// value ranges ([ParticleRange]) and the bursts ([EmitterBurst]) are those
/// of Flame's 2D particles.
library;

import 'package:flame_3d/particles.dart';

export 'package:flame/particles.dart'
    show
        ColorRamp,
        EmitterBurst,
        ParticleCurve,
        ParticleRange,
        ParticleRangeExtension;

export 'src/particles/emitter_shape_3d.dart';
export 'src/particles/particle_buffer_3d.dart';
export 'src/particles/particle_emitter_3d.dart';
export 'src/particles/particle_forces_3d.dart';
export 'src/particles/particle_material.dart';
export 'src/particles/particle_presets_3d.dart';
export 'src/particles/particle_system_3d.dart';
