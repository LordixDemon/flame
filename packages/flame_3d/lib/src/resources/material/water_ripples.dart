import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

/// {@template water_ripples}
/// A small, fixed set of ripple sources on a body of water: the expanding
/// rings that something landing on, rising out of, sinking into or moving
/// through the water raises.
///
/// Give the same [WaterRipples] to the [WaterMaterial]s of one body of water
/// (`WaterMaterial(ripples: ...)`): each of them draws the rings where its
/// surfaces are, so a ring crosses from one surface to the next. A ripple
/// starts at a time of the materials' clock ([WaterMaterial.time]), so the
/// materials that share ripples should share their time.
///
/// ```dart
/// final ripples = WaterRipples();
/// final water = WaterMaterial(ripples: ripples, depthRange: 0.6);
///
/// // A stone lands at `point`:
/// ripples.add(point, time: water.time, strength: 0.8);
/// ```
///
/// It holds at most [capacity] ripples. Adding one when every slot is taken
/// replaces the weakest at the time it starts: a ripple that is over (or not
/// started yet), else the one whose waves are the lowest now (its strength
/// times the square of the fraction of its life left), the one that started
/// first among equals. Faint, short rings (the drops of a splash) then take
/// each other's places rather than those of the large rings of the things
/// that made the splash. Adding, clearing and drawing allocate nothing.
///
/// Each ripple is a packet of a few waves that leaves its center at [add]'s
/// `speed`: its front is `radius + speed * age` from the center. The waves are
/// `wavelength` apart, trail over `trail` wavelengths behind the front, and
/// fade out with the square of the fraction of `lifetime` left; a ripple is
/// gone after its `lifetime`.
///
/// Adding, removing and clearing ripples raise its [version] (clearing an
/// empty set does not), which counts as a change of the materials that
/// draw it (`WaterMaterial.version`), so that their retained layers render
/// again; the rings then spread with the time of those materials.
/// {@endtemplate}
class WaterRipples() with Versioned {
  /// The number of ripples a set holds.
  static const int capacity = 8;

  // Per ripple: x, y, z, start, strength, speed, wavelength, lifetime, trail,
  // radius.
  static const int _stride = 10;

  final Float64List _ripples = Float64List(capacity * _stride);

  // Whether each slot holds a ripple.
  final List<bool> _used = List.filled(capacity, false);

  /// The number of slots that hold a ripple, alive or not yet removed.
  ///
  /// Ripples older than their lifetime still count until their slot is
  /// reused or [clear] is called; [aliveAt] counts the living ones.
  int get length {
    var count = 0;
    for (final used in _used) {
      if (used) {
        count++;
      }
    }
    return count;
  }

  /// Starts a ripple at the world point [position] at [time] (of the clock
  /// of the materials that draw it, [WaterMaterial.time]) and returns its
  /// slot, from `0` to [capacity] `- 1`.
  ///
  /// [strength] scales the height of its waves, `1` for a stone thrown in;
  /// [speed] is how fast its front travels, in world units per second;
  /// [wavelength] the distance between its waves, in world units; [trail]
  /// how many wavelengths its waves trail behind the front; [lifetime] how
  /// long it lasts, in seconds; [radius] where its front starts, in world
  /// units: `0` for a point (a pebble), the size of an object that rises out
  /// of the water or lands flat on it. The position is projected onto the
  /// plane of each material's surface (along its up axis).
  int add(
    Vector3 position, {
    required double time,
    double strength = 1,
    double speed = 0.9,
    double wavelength = 0.22,
    double trail = 3,
    double lifetime = 2.4,
    double radius = 0,
  }) {
    if (!(speed > 0) || !(wavelength > 0) || !(lifetime > 0)) {
      throw ArgumentError(
        'speed ($speed), wavelength ($wavelength) and lifetime ($lifetime) '
        'must be positive',
      );
    }
    if (!(trail > 0)) {
      throw ArgumentError.value(trail, 'trail', 'Must be positive');
    }
    if (!(radius >= 0)) {
      throw ArgumentError.value(radius, 'radius', 'Must not be negative');
    }
    var slot = -1;
    var weakest = double.infinity;
    var oldest = double.infinity;
    for (var i = 0; i < capacity; i++) {
      if (!_used[i]) {
        slot = i;
        break;
      }
      final o = i * _stride;
      final start = _ripples[o + 3];
      final left = 1 - (time - start) / _ripples[o + 7];
      // Over, or not started yet: nothing to lose.
      final height = left <= 0 || left > 1
          ? 0.0
          : _ripples[o + 4].abs() * left * left;
      if (height < weakest || (height == weakest && start < oldest)) {
        weakest = height;
        oldest = start;
        slot = i;
      }
    }
    final o = slot * _stride;
    _ripples
      ..[o] = position.x
      ..[o + 1] = position.y
      ..[o + 2] = position.z
      ..[o + 3] = time
      ..[o + 4] = strength
      ..[o + 5] = speed
      ..[o + 6] = wavelength
      ..[o + 7] = lifetime
      ..[o + 8] = trail
      ..[o + 9] = radius;
    _used[slot] = true;
    markChanged();
    return slot;
  }

  /// Removes the ripple in [slot], if any.
  void remove(int slot) {
    RangeError.checkValueInInterval(slot, 0, capacity - 1, 'slot');
    if (_used[slot]) {
      _used[slot] = false;
      markChanged();
    }
  }

  /// Removes every ripple.
  void clear() {
    var changed = false;
    for (var i = 0; i < capacity; i++) {
      changed = changed || _used[i];
      _used[i] = false;
    }
    if (changed) {
      markChanged();
    }
  }

  /// The number of ripples alive at [time]: started at or before it, and not
  /// older than their lifetime.
  int aliveAt(double time) {
    var count = 0;
    for (var i = 0; i < capacity; i++) {
      if (_isAlive(i, time)) {
        count++;
      }
    }
    return count;
  }

  /// The radius of the front of the ripple in [slot] at [time], in world
  /// units, or `null` when the slot holds no ripple alive at that time.
  double? frontRadius(int slot, double time) {
    RangeError.checkValueInInterval(slot, 0, capacity - 1, 'slot');
    if (!_isAlive(slot, time)) {
      return null;
    }
    final o = slot * _stride;
    return _ripples[o + 9] + _ripples[o + 5] * (time - _ripples[o + 3]);
  }

  bool _isAlive(int slot, double time) {
    if (!_used[slot]) {
      return false;
    }
    final o = slot * _stride;
    final age = time - _ripples[o + 3];
    return age >= 0 && age < _ripples[o + 7];
  }

  /// Writes the ripples alive at [time] into [positions] and [shapes], one
  /// `Vector4` each per ripple, as `WaterMaterial`'s fragment shader reads
  /// them, with their centers in the plane coordinates `(dot(p, uAxis),
  /// dot(p, vAxis))`; returns how many it wrote.
  @internal
  int writeUniforms(
    double time,
    Vector3 uAxis,
    Vector3 vAxis,
    List<Vector4> positions,
    List<Vector4> shapes,
  ) {
    var count = 0;
    for (var i = 0; i < capacity && count < positions.length; i++) {
      if (!_isAlive(i, time)) {
        continue;
      }
      final o = i * _stride;
      final x = _ripples[o];
      final y = _ripples[o + 1];
      final z = _ripples[o + 2];
      final age = time - _ripples[o + 3];
      final left = 1 - age / _ripples[o + 7];
      positions[count].setValues(
        x * uAxis.x + y * uAxis.y + z * uAxis.z,
        x * vAxis.x + y * vAxis.y + z * vAxis.z,
        age,
        _ripples[o + 4] * left * left,
      );
      shapes[count].setValues(
        _ripples[o + 9] + _ripples[o + 5] * age,
        1 / _ripples[o + 6],
        math.max(_ripples[o + 8], 1e-3),
        0,
      );
      count++;
    }
    return count;
  }
}
