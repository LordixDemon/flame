import 'dart:ui' show Color;

import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';

/// {@template directional_light}
/// A light infinitely far away, whose rays are parallel, like the sun.
///
/// It lights a surface by `max(0, n·l) * intensity * color`, where `l` points
/// towards the light, whatever the surface's position.
///
/// The direction the light travels in is [direction] when it is set,
/// otherwise the way the [Light] holding it faces (see [Light.direction]):
/// for a `LightComponent`, the -Z axis of its world rotation.
///
/// At most `RenderContext3D.maxDirectionalLights` directional lights are used
/// per scene.
///
/// With [shadows], it casts shadows: see [ShadowSettings]. Only the first
/// directional light of a scene with shadows casts them.
/// {@endtemplate}
class DirectionalLight({
  super.color = const Color(0xFFFFFFFF),
  super.intensity = 1.0,

  Vector3? direction,
  double specular = 1.0,
  ShadowSettings? shadows,
}) extends LightSource {
  /// The direction the light travels in, in world space (for a sun high in
  /// the sky, pointing down). It need not be normalized. When `null`, the
  /// light's transform orients it.
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

  /// How strongly the light makes specular highlights, from `0` (none) to `1`
  /// (fully).
  double get specular => _specular;
  set specular(double value) {
    if (value == _specular) {
      return;
    }
    _specular = value;
    markChanged(shadows: false);
  }

  double _specular = specular;

  /// How the light casts shadows, or `null` (the default) when it casts none.
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
