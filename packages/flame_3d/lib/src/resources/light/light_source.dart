import 'dart:ui' show Color;

import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

/// {@template light_source}
/// Describes the properties of a light source: its [color] and [intensity].
///
/// The kinds of light sources are [AmbientLight], [HemisphereLight],
/// [DirectionalLight], [PointLight] and [SpotLight]. Their values may be
/// changed at any time: the lights of a scene are read once per render pass.
///
/// Assigning a field marks the worlds the light shines in dirty (see
/// `World3D.sceneVersion`), so that retained layers, a cached static shadow
/// map and on-demand idle rendering pick the change up. A change made in
/// place, such as `sun.direction!.setValues(...)` or a field of its
/// [ShadowSettings], cannot be seen: call [markChanged] after it.
/// {@endtemplate}
abstract class LightSource({
  /// The color of the light. Its alpha is ignored.
  required Color color,

  /// The strength of the light, multiplying its [color].
  required double intensity,
}) {
  /// The color of the light. Its alpha is ignored.
  Color get color => _color;
  set color(Color value) {
    if (value == _color) {
      return;
    }
    _color = value;
    markChanged(shadows: false);
  }

  Color _color = color;

  /// The strength of the light, multiplying its [color].
  double get intensity => _intensity;
  set intensity(double value) {
    if (value == _intensity) {
      return;
    }
    _intensity = value;
    markChanged(shadows: false);
  }

  double _intensity = intensity;

  final List<void Function({required bool shadows})> _changeListeners = [];

  /// Reports that this light changed in a way its setters cannot see (a
  /// vector or a [ShadowSettings] changed in place), marking the worlds it
  /// shines in dirty.
  ///
  /// Pass `shadows: false` when the change cannot move a shadow (a color or
  /// a strength): the cached static shadow maps are then kept.
  void markChanged({bool shadows = true}) {
    final listeners = _changeListeners;
    for (var i = 0; i < listeners.length; i++) {
      listeners[i](shadows: shadows);
    }
  }

  /// Registers [listener] to be called by [markChanged], used by the
  /// components that hold this light.
  @internal
  void addChangeListener(void Function({required bool shadows}) listener) {
    _changeListeners.add(listener);
  }

  /// Unregisters a [listener] added with [addChangeListener].
  @internal
  void removeChangeListener(void Function({required bool shadows}) listener) {
    _changeListeners.remove(listener);
  }
}
