import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame_3d/game.dart';

/// {@template water_volume_settings}
/// A body of water in a `World3D`: the surfaces of a `StylizedMaterial`
/// below its [level] look submerged, without a depth buffer.
///
/// Assign it to `World3D.waterVolume`, as `World3D.fog`:
///
/// ```dart
/// world.waterVolume = WaterVolumeSettings(
///   level: 0, // along up, (0, 1, 0) by default
///   deepColor: const Color(0xFF155E75),
///   absorption: 0.9,
///   causticStrength: 0.8,
///   waterlineWidth: 0.05,
/// );
/// ```
///
/// Where a surface is `depth = level - dot(position, up)` below the level
/// (and inside [bounds], when given), its lit color is
///
/// ```text
/// lit      += albedo * sun * causticColor * causticStrength
///             * caustics(the point where its sunlight entered the water)
/// absorbed  = 1 - exp(-absorption * depth)
/// color     = mix(lit * mix(1, shallowColor, min(1, depth * 4)),
///                 deepColor, absorbed)
/// ```
///
/// where `sun` is the direct light the directional lights give it, after
/// their shadows: a submerged surface keeps its shadows, which fade with the
/// rest of its color as it deepens. The caustics are the network
/// `WaterMaterial.causticStrength` draws on a surface: with the same
/// [causticScale], [animationPeriod] and [time] as the water's material
/// (`WaterMaterial.causticScale`, `animationPeriod` and `time`), the floor
/// shows the network of the surface above it, shifted along the refracted
/// sunlight. With [waterlineWidth] above `0`, the surfaces also foam in a
/// band about that wide around the level, broken up and lapping, so an
/// object rising through the water gets its foam ring; [waterlineLightTint]
/// says how much of the color of the light that foam takes and
/// [waterlineLightFloor] the least light it takes.
///
/// The shadow pass and the depth-normal prepass ignore it; it costs no pass,
/// a few instructions per pixel of the surfaces above it, and the caustics
/// on the pixels below it. `SpatialMaterial`, `WaterMaterial` and the other
/// materials do not read it.
/// {@endtemplate}
class WaterVolumeSettings({
  /// The height of the water's surface along [up], in world units.
  var double level = 0,

  /// The up axis the [level] is measured along (normalized; `(0, 1, 0)` by
  /// default).
  Vector3? up,

  /// The color submerged surfaces are filtered by just below the surface
  /// (it multiplies their color, fully from a quarter of a unit deep).
  var Color shallowColor = const Color(0xFFC8F2EA),

  /// The color of the water the deep surfaces fade into.
  var Color deepColor = const Color(0xFF155E75),

  /// How fast the surfaces fade into [deepColor] with their depth, per world
  /// unit: `1 - exp(-absorption * depth)` of the way.
  var double absorption = 0.8,

  /// The strength of the caustic network on the submerged surfaces: `0`
  /// (the default) turns it off, `1` adds [causticColor] times the direct
  /// sunlight on the lines.
  var double causticStrength = 0,

  /// The size of the caustic network, in world units (see
  /// `WaterMaterial.causticScale`).
  var double causticScale = 0.6,

  /// The color of the caustic network, times the direct sunlight.
  var Color causticColor = const Color(0xFFFFFFFF),

  /// The period over which the caustics and the waterline foam loop, in
  /// seconds of [time] (see `WaterMaterial.animationPeriod`).
  var double animationPeriod = 8,

  /// The time of the caustics and the waterline foam, to advance every
  /// frame, in seconds (keep it equal to the water's `WaterMaterial.time`).
  var double time = 0,

  /// The width of the band of foam around the level on the surfaces that
  /// cross it, in world units: `0` (the default) turns it off.
  var double waterlineWidth = 0,

  /// The color of the waterline foam, lit like the surface; its alpha is
  /// how much it covers the surface.
  var Color waterlineColor = const Color(0xE6FFFFFF),

  /// How much of the color of the light the waterline foam takes, from `0`
  /// to `1`: `1` (the default) takes the color of the light on the surface
  /// as it is, `0` only its brightness (its luminance), so the foam keeps
  /// [waterlineColor] under a colored light. About `0.25` suits a low, warm
  /// sun (see `WaterMaterial.foamLightTint`, its match on the water).
  var double waterlineLightTint = 1,

  /// The least light the waterline foam takes, as a multiple of
  /// [waterlineColor], `0` or more: the light on the surface is clamped
  /// between it and `1.25` (or it, when it is above). `0` (the default) lets
  /// the foam darken with the light, grey and weak in low light; at dusk
  /// about `0.7` keeps a white waterline bright (see
  /// `WaterMaterial.foamLightFloor`, its match on the water).
  var double waterlineLightFloor = 0,

  /// The box the water fills, in world space: surfaces outside of it are
  /// not submerged, whatever their height. `null` (the default) fills the
  /// whole world below the level.
  var Aabb3? bounds,
}) {
  /// The up axis the [level] is measured along.
  final Vector3 up = up?.clone() ?? Vector3(0, 1, 0);

  /// Whether the volume changes anything: it has an [absorption], caustics
  /// or a waterline.
  bool get isActive =>
      absorption > 0 || causticStrength > 0 || waterlineWidth > 0;

  /// The phase of [time] in the loop of [animationPeriod], from `0` to `2π`
  /// (see `WaterMaterial.patternPhase`).
  double get phase {
    final period = animationPeriod;
    if (!(period > 0) || !time.isFinite) {
      return 0;
    }
    final turns = time / period;
    return (turns - turns.floorToDouble()) * 2 * math.pi;
  }
}
