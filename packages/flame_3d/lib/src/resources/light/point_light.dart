import 'package:flame_3d/resources.dart';

/// {@template point_light}
/// A light that emits light in all directions equally from its position.
///
/// Without a [range], its light falls off with the inverse square of the
/// distance `d`: `intensity / d²`. With a range, it falls off smoothly to
/// nothing at that distance: `intensity * (1 - d / range)²`, and does not
/// reach further.
///
/// When [shadows] is non-null, omnidirectional Dual-Paraboloid (`+Z` and `-Z`
/// hemisphere) shadow tiles are rendered into the unified `ShadowAtlas3D`.
/// {@endtemplate}
class PointLight({
  required super.color,
  required super.intensity,

  /// The distance at which the light fades out, or `null` (or a value that is
  /// not above zero) for an inverse-square falloff.
  var double? range,

  /// Optional omnidirectional Dual-Paraboloid shadow settings.
  var ShadowSettings? shadows,
}) extends LightSource;
