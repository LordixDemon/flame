import 'package:flame/game.dart' show Game;
import 'package:meta/meta.dart';

/// {@template versioned}
/// Values that report their own changes through a [version]: every setter
/// raises it when it writes a value that differs from the one held, so that
/// what keeps pictures of those values (a `Scene3DCacheMode.retained`
/// layer, a game's idle rendering) knows when to draw them again, and
/// writing the value already held costs nothing and raises nothing.
///
/// Materials and the small state objects they and the worlds read (fog,
/// water, bloom and post-processing settings, ripples and foam sources)
/// carry one. A change the setters cannot see, such as a field of an object
/// they hold changed in place, is reported with [markChanged].
/// {@endtemplate}
mixin Versioned {
  /// A number that increases every time a value of this object changes,
  /// and never decreases: compare it with the number kept with a picture to
  /// tell whether that picture is out of date.
  int get version => _version;
  int _version = 0;

  /// Reports a change that the setters cannot see: [version] increases and
  /// idle-throttled game loops wake up (see `Game.notifyVisualMutation`).
  void markChanged() {
    _version++;
    Game.notifyVisualMutation();
  }

  /// Returns [next], having reported a change ([markChanged]) when it
  /// differs from [current], for setters:
  ///
  /// ```dart
  /// set strength(double value) => _strength = noteChange(_strength, value);
  /// ```
  @protected
  T noteChange<T>(T current, T next) {
    if (current != next) {
      markChanged();
    }
    return next;
  }

  /// Reports that an object whose version [version] includes was replaced
  /// by another one, given [before], the [version] before the replacement:
  /// [version] becomes `before + 1`, whatever the version of the new
  /// object, so that it keeps increasing.
  @protected
  void markReplaced(int before) {
    _version += before + 1 - version;
    Game.notifyVisualMutation();
  }
}
