import 'dart:ui' show Color;

import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';

/// {@template fog_settings}
/// Atmospheric distance and height fog applied to a `World3D` scene.
///
/// Assign [FogSettings] to `World3D.fog` to blend distant or low-lying
/// geometry smoothly towards [color]:
///
/// ```dart
/// world.fog = FogSettings(
///   color: const Color(0xFFC8D8E8),
///   start: 12,
///   end: 48,
///   heightFalloff: 0.15,
///   baseHeight: 0,
/// );
/// ```
///
/// When [density] is `0` (the default), distance fog grows linearly from `0`
/// at [start] units from the camera to `1` at [end] units. When [density] is
/// positive, distance fog follows an exponential curve
/// `1 - exp(-density * max(0, distance - start))`.
///
/// When [heightFalloff] is positive, fog is modulated by elevation along [up]
/// above [baseHeight] (`exp(-heightFalloff * max(0, elevation - baseHeight))`),
/// keeping higher peaks clear while valleys and water stay misty. The final
/// blend factor is clamped to [maxOpacity].
///
/// Its setters, and changes of [up] in place, report their changes
/// ([version]), so that the retained layers of the worlds that use it render
/// again.
/// {@endtemplate}
class FogSettings({
  var Color _color = const Color(0xFFB8C8DC),
  var double _start = 10.0,
  var double _end = 60.0,
  var double _density = 0.0,
  var double _heightFalloff = 0.0,
  var double _baseHeight = 0.0,
  var double _maxOpacity = 1.0,

  /// World-space up direction used for height fog (defaults to `(0, 1, 0)`).
  Vector3? up,
}) with Versioned {
  /// {@macro fog_settings}
  this {
    _up.addListener(markChanged);
  }

  /// The color that fogged surfaces blend towards.
  Color get color => _color;
  set color(Color value) => _color = noteChange(_color, value);

  /// Distance from the camera where fog begins (`>= 0`).
  double get start => _start;
  set start(double value) => _start = noteChange(_start, value);

  /// Distance from the camera where linear fog reaches full strength
  /// (used when [density] is `0`).
  double get end => _end;
  set end(double value) => _end = noteChange(_end, value);

  /// Exponential fog density (`0` uses linear fog between [start] and [end]).
  double get density => _density;
  set density(double value) => _density = noteChange(_density, value);

  /// Exponential falloff rate along [up] above [baseHeight] (`0` disables
  /// height attenuation).
  double get heightFalloff => _heightFalloff;
  set heightFalloff(double value) =>
      _heightFalloff = noteChange(_heightFalloff, value);

  /// World-space elevation along [up] below which height fog is at full
  /// strength.
  double get baseHeight => _baseHeight;
  set baseHeight(double value) => _baseHeight = noteChange(_baseHeight, value);

  /// Maximum fog opacity in `[0, 1]`. Values below `1` keep distant
  /// silhouettes subtly visible.
  double get maxOpacity => _maxOpacity;
  set maxOpacity(double value) => _maxOpacity = noteChange(_maxOpacity, value);

  /// World-space up axis for height fog, which may be changed in place.
  Vector3 get up => _up;
  final NotifyingVector3 _up = NotifyingVector3.copy(up ?? Vector3(0, 1, 0));
}
