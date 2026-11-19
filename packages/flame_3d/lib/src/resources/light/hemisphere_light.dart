import 'dart:ui' show Color;

import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';

/// {@template hemisphere_light}
/// An ambient light that comes from the sky above and from the ground below.
///
/// Surfaces facing [up] receive the [skyColor], surfaces facing down the
/// [groundColor], and the others a blend of both: with `hemi = 0.5 + 0.5 *
/// dot(n, up)`, `SpatialMaterial` receives
/// `intensity * mix(groundColor, skyColor, hemi)`. `StylizedMaterial` responds
/// to it in its own way, see there.
///
/// The first hemisphere light of a scene is used. It adds to the
/// [AmbientLight], and replaces the default ambient light of scenes that have
/// none.
/// {@endtemplate}
class HemisphereLight({
  /// The color of the light coming from above.
  Color skyColor = const Color(0xFFFFFFFF),

  Color groundColor = const Color(0xFF808080),
  super.intensity = 0.5,

  /// The direction of the sky, in world space. Defaults to +Y.
  Vector3? up,
}) extends LightSource {
  /// {@macro hemisphere_light}
  this : super(color: skyColor);

  /// The color of the light coming from below.
  Color get groundColor => _groundColor;
  set groundColor(Color value) {
    if (value == _groundColor) {
      return;
    }
    _groundColor = value;
    markChanged(shadows: false);
  }

  Color _groundColor = groundColor;

  /// The direction of the sky, in world space. It need not be normalized.
  ///
  /// After changing the vector in place, call [markChanged].
  Vector3 get up => _up;
  set up(Vector3 value) {
    if (identical(value, _up)) {
      return;
    }
    _up = value;
    markChanged(shadows: false);
  }

  Vector3 _up = up ?? Vector3(0, 1, 0);

  /// The color of the light coming from above: the light's [color].
  Color get skyColor => color;
  set skyColor(Color value) => color = value;
}
