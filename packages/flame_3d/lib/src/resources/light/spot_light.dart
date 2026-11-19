import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';

/// {@template spot_light}
/// A cone-shaped light source that shines from its position along [direction]
/// (or along the `-Z` axis of its component's world transform when [direction]
/// is `null`).
///
/// Surfaces inside [innerConeAngle] (half-angle, in radians) receive full
/// angular intensity; intensity falls off smoothly to zero at [outerConeAngle].
/// Distance attenuation matches [PointLight]: smooth `(1 - d / range)²` when
/// [range] is positive, or inverse-square `1 / d²` otherwise.
///
/// Up to `RenderContext3D.maxSpotLights` (`4`) spot lights are shaded per pass;
/// when a scene contains more, the active ones nearest to the camera are
/// selected automatically.
/// {@endtemplate}
class SpotLight({
  super.color = const Color(0xFFFFFFFF),
  super.intensity = 1.0,

  Vector3? direction,
  double innerConeAngle = math.pi / 8,
  double outerConeAngle = math.pi / 4,
  double? range,
  double specular = 1.0,
  ShadowSettings? shadows,
}) extends LightSource {
  /// Optional world-space direction the cone points towards (need not be
  /// normalized). When `null`, the `-Z` axis of the light's transform is used.
  ///
  /// After changing the vector in place, call [markChanged].
  Vector3? get direction => _direction;
  set direction(Vector3? value) {
    if (identical(value, _direction)) {
      return;
    }
    _direction = value;
    markChanged(shadows: _shadows != null);
  }

  Vector3? _direction = direction;

  /// Inner half-angle of the cone, in radians, within which angular falloff is
  /// `1.0`.
  double get innerConeAngle => _innerConeAngle;
  set innerConeAngle(double value) {
    if (value == _innerConeAngle) {
      return;
    }
    _innerConeAngle = value;
    markChanged(shadows: false);
  }

  double _innerConeAngle = innerConeAngle;

  /// Outer half-angle of the cone, in radians, at which light reaches `0.0`.
  double get outerConeAngle => _outerConeAngle;
  set outerConeAngle(double value) {
    if (value == _outerConeAngle) {
      return;
    }
    _outerConeAngle = value;
    markChanged(shadows: _shadows != null);
  }

  double _outerConeAngle = outerConeAngle;

  /// Maximum reach of the light, or `null` (or `<= 0`) for inverse-square
  /// falloff.
  double? get range => _range;
  set range(double? value) {
    if (value == _range) {
      return;
    }
    _range = value;
    markChanged(shadows: _shadows != null);
  }

  double? _range = range;

  /// Specular highlight multiplier (`0` = diffuse only, `1` = full specular).
  double get specular => _specular;
  set specular(double value) {
    if (value == _specular) {
      return;
    }
    _specular = value;
    markChanged(shadows: false);
  }

  double _specular = specular;

  /// Optional perspective shadow-map settings for this spotlight cone.
  ///
  /// After changing the settings in place, call [markChanged].
  ShadowSettings? get shadows => _shadows;
  set shadows(ShadowSettings? value) {
    if (identical(value, _shadows)) {
      return;
    }
    _shadows = value;
    markChanged();
  }

  ShadowSettings? _shadows = shadows;
}
