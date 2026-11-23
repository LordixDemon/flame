import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame_3d/core.dart';

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
/// says how much of the color of the light that foam takes,
/// [waterlineLightFloor] the least light it takes and [waterlineMotion] how
/// fast it moves.
///
/// The shadow pass and the depth-normal prepass ignore it; it costs no pass,
/// a few instructions per pixel of the surfaces above it, and the caustics
/// on the pixels below it. `SpatialMaterial`, `WaterMaterial` and the other
/// materials do not read it.
///
/// Its setters, and changes of [up] in place, report their changes
/// ([version]), so that the retained layers of the worlds that use it render
/// again; a change of [bounds] in place is reported with [markChanged].
/// {@endtemplate}
class WaterVolumeSettings({
  var double _level = 0,

  /// The up axis the [level] is measured along (normalized; `(0, 1, 0)` by
  /// default).
  Vector3? up,

  var Color _shallowColor = const Color(0xFFC8F2EA),
  var Color _deepColor = const Color(0xFF155E75),
  var double _absorption = 0.8,
  var double _causticStrength = 0,
  var double _causticScale = 0.6,
  var Color _causticColor = const Color(0xFFFFFFFF),
  var double _animationPeriod = 8,
  var double _time = 0,
  var double _waterlineWidth = 0,
  var Color _waterlineColor = const Color(0xE6FFFFFF),
  var double _waterlineLightTint = 1,
  var double _waterlineLightFloor = 0,
  var double _waterlineMotion = 1,
  var Aabb3? _bounds,
}) with Versioned {
  /// {@macro water_volume_settings}
  this {
    _up.addListener(markChanged);
  }

  /// The height of the water's surface along [up], in world units.
  double get level => _level;
  set level(double value) => _level = noteChange(_level, value);

  /// The color submerged surfaces are filtered by just below the surface
  /// (it multiplies their color, fully from a quarter of a unit deep).
  Color get shallowColor => _shallowColor;
  set shallowColor(Color value) =>
      _shallowColor = noteChange(_shallowColor, value);

  /// The color of the water the deep surfaces fade into.
  Color get deepColor => _deepColor;
  set deepColor(Color value) => _deepColor = noteChange(_deepColor, value);

  /// How fast the surfaces fade into [deepColor] with their depth, per world
  /// unit: `1 - exp(-absorption * depth)` of the way.
  double get absorption => _absorption;
  set absorption(double value) => _absorption = noteChange(_absorption, value);

  /// The strength of the caustic network on the submerged surfaces: `0`
  /// (the default) turns it off, `1` adds [causticColor] times the direct
  /// sunlight on the lines.
  double get causticStrength => _causticStrength;
  set causticStrength(double value) =>
      _causticStrength = noteChange(_causticStrength, value);

  /// The size of the caustic network, in world units (see
  /// `WaterMaterial.causticScale`).
  double get causticScale => _causticScale;
  set causticScale(double value) =>
      _causticScale = noteChange(_causticScale, value);

  /// The color of the caustic network, times the direct sunlight.
  Color get causticColor => _causticColor;
  set causticColor(Color value) =>
      _causticColor = noteChange(_causticColor, value);

  /// The period over which the caustics and the waterline foam loop, in
  /// seconds of [time] (see `WaterMaterial.animationPeriod`).
  double get animationPeriod => _animationPeriod;
  set animationPeriod(double value) =>
      _animationPeriod = noteChange(_animationPeriod, value);

  /// The time of the caustics and the waterline foam, to advance every
  /// frame, in seconds (keep it equal to the water's `WaterMaterial.time`).
  double get time => _time;
  set time(double value) => _time = noteChange(_time, value);

  /// The width of the band of foam around the level on the surfaces that
  /// cross it, in world units: `0` (the default) turns it off.
  double get waterlineWidth => _waterlineWidth;
  set waterlineWidth(double value) =>
      _waterlineWidth = noteChange(_waterlineWidth, value);

  /// The color of the waterline foam, lit like the surface; its alpha is
  /// how much it covers the surface.
  Color get waterlineColor => _waterlineColor;
  set waterlineColor(Color value) =>
      _waterlineColor = noteChange(_waterlineColor, value);

  /// How much of the color of the light the waterline foam takes, from `0`
  /// to `1`: `1` (the default) takes the color of the light on the surface
  /// as it is, `0` only its brightness (its luminance), so the foam keeps
  /// [waterlineColor] under a colored light. About `0.25` suits a low, warm
  /// sun (see `WaterMaterial.foamLightTint`, its match on the water).
  double get waterlineLightTint => _waterlineLightTint;
  set waterlineLightTint(double value) =>
      _waterlineLightTint = noteChange(_waterlineLightTint, value);

  /// The least light the waterline foam takes, as a multiple of
  /// [waterlineColor], `0` or more: the light on the surface is clamped
  /// between it and `1.25` (or it, when it is above). `0` (the default) lets
  /// the foam darken with the light, grey and weak in low light; at dusk
  /// about `0.7` keeps a white waterline bright (see
  /// `WaterMaterial.foamLightFloor`, its match on the water).
  double get waterlineLightFloor => _waterlineLightFloor;
  set waterlineLightFloor(double value) =>
      _waterlineLightFloor = noteChange(_waterlineLightFloor, value);

  /// How fast the waterline foam laps and drifts, as a multiple of its own
  /// pace, `0` or more: `1` (the default) moves with the caustics, `0` holds
  /// the band still (rime, a crust of salt or ice where the water meets the
  /// stones), still broken up but not moving. Its phase is [phase] of
  /// `time * waterlineMotion`, so a slower band still loops without a jump
  /// (see `WaterMaterial.edgeFoamMotion`, its match on the water). The
  /// caustics keep their pace.
  double get waterlineMotion => _waterlineMotion;
  set waterlineMotion(double value) =>
      _waterlineMotion = noteChange(_waterlineMotion, value);

  /// The box the water fills, in world space: surfaces outside of it are
  /// not submerged, whatever their height. `null` (the default) fills the
  /// whole world below the level.
  Aabb3? get bounds => _bounds;
  set bounds(Aabb3? value) => _bounds = noteChange(_bounds, value);

  /// The up axis the [level] is measured along, which may be changed in
  /// place.
  Vector3 get up => _up;
  final NotifyingVector3 _up = NotifyingVector3.copy(up ?? Vector3(0, 1, 0));

  /// Whether the volume changes anything: it has an [absorption], caustics
  /// or a waterline.
  bool get isActive =>
      absorption > 0 || causticStrength > 0 || waterlineWidth > 0;

  /// The phase of [time] in the loop of [animationPeriod], from `0` to `2π`
  /// (see `WaterMaterial.patternPhase`).
  double get phase => _phaseAt(time);

  /// The phase of the waterline foam: [phase] of `time * waterlineMotion`
  /// (with [waterlineMotion] at least `0`), `0` (still) when
  /// [waterlineMotion] is `0`, and [phase] itself when it is `1` (see
  /// `WaterMaterial.edgeFoamPhase`).
  double get waterlinePhase {
    final motion = waterlineMotion;
    if (!(motion > 0)) {
      return 0;
    }
    return _phaseAt(time * motion);
  }

  double _phaseAt(double time) {
    final period = animationPeriod;
    if (!(period > 0) || !time.isFinite) {
      return 0;
    }
    final turns = time / period;
    return (turns - turns.floorToDouble()) * 2 * math.pi;
  }
}
