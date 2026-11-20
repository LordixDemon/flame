import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/game.dart';
import 'package:flame_3d/src/resources/material/water_material.dart';
import 'package:meta/meta.dart';

/// {@template water_foam_sources}
/// A small, fixed set of foam sources on a body of water: the collars of foam
/// around the things that stand in the water, rise out of it, sink into it or
/// move through it, which the foam mask of a surface, fixed when the surface
/// is built, cannot follow.
///
/// Give the same [WaterFoamSources] to the [WaterMaterial]s of one body of
/// water (`WaterMaterial(foamSources: ...)`): each of them draws the collars
/// where its surfaces are. A collar has the look of the foam of the foam mask
/// (a band that laps in and out, broken up into patches of
/// [WaterMaterial.edgeFoamScale], with loose flecks in front of it), moves
/// as fast as it does ([WaterMaterial.edgeFoamMotion]) and is lit as it is
/// ([WaterMaterial.foamLightTint]).
///
/// ```dart
/// final collars = WaterFoamSources();
/// final water = WaterMaterial(foamSources: collars, depthRange: 0.6);
///
/// // A slab that rises out of the water, 0.95 units square:
/// final slot = collars.addRectangle(
///   slab.position,
///   halfLength: 0.475,
///   halfWidth: 0.475,
///   cornerRadius: 0.04,
///   strength: 0,
/// );
///
/// // Every frame, as it crosses the surface:
/// collars
///   ..move(slot, slab.position)
///   ..setStrength(slot, wetness);
/// ```
///
/// Each source is a rectangle with rounded corners, or a circle (see
/// [addCircle]), lying in the plane of the water: its center is projected
/// onto the plane of each material (along its up axis). Its foam mask is its
/// `strength` inside and against its outline, falling to `0` at its `width`
/// from it (`1 - smoothstep(0, width, distance)`), and the surfaces draw the
/// largest of the masks of their vertices and of the sources: at strength
/// `1` the foam is solid against the outline, its band reaches about a third
/// of the width out and its flecks the whole width; below about `0.7` only
/// flecks are left, so fade a collar in and out with [setStrength].
///
/// It holds at most [capacity] sources, in slots that keep their source until
/// it is removed: adding one when every slot is taken throws. Adding, moving,
/// changing and drawing allocate nothing, and moving a source does not
/// rebuild any surface. Only the sources whose strength is above `0` are sent
/// to the shaders, packed first, so the cost per pixel follows their number.
/// {@endtemplate}
class WaterFoamSources() {
  /// The number of sources a set holds.
  static const int capacity = 16;

  // Per source: x, y, z (its center), ax, ay, az (the direction of its
  // length), half length, half width, corner radius, width, strength and an
  // unused value.
  static const int _stride = 12;

  final Float64List _sources = Float64List(capacity * _stride);

  // Whether each slot holds a source.
  final List<bool> _used = List.filled(capacity, false);

  /// The number of slots that hold a source.
  int get length {
    var count = 0;
    for (final used in _used) {
      if (used) {
        count++;
      }
    }
    return count;
  }

  /// Changes every time a source is added, changed, moved or removed, so
  /// that a cached picture can tell it is out of date.
  int get version => _version;
  int _version = 0;

  /// Whether [slot] holds a source.
  bool isUsed(int slot) {
    RangeError.checkValueInInterval(slot, 0, capacity - 1, 'slot');
    return _used[slot];
  }

  /// Adds a circle of [radius] world units around the world point [center]
  /// (`0` for a point) and returns its slot, from `0` to [capacity] `- 1`.
  ///
  /// [width] is how far from its outline its foam reaches, in world units,
  /// and [strength] how solid that foam is, `1` for a band against the
  /// outline (see [WaterFoamSources]). Throws a [StateError] when every slot
  /// holds a source.
  int addCircle(
    Vector3 center, {
    required double radius,
    double width = 0.3,
    double strength = 1,
  }) {
    final slot = _freeSlot();
    setCircle(slot, center, radius: radius, width: width, strength: strength);
    return slot;
  }

  /// Adds a rectangle with rounded corners around the world point [center]
  /// and returns its slot, from `0` to [capacity] `- 1`.
  ///
  /// [halfLength] is half its length along [axis] and [halfWidth] half its
  /// width across it, corners included, in world units; [cornerRadius] the
  /// radius of its corners (at most the smaller of the two halves). [axis] is
  /// a world direction, projected onto the plane of each material: world `x`
  /// by default, or the first axis of the plane when it is along the up axis
  /// of the water. [width] and [strength] are those of [addCircle]. Throws a
  /// [StateError] when every slot holds a source.
  int addRectangle(
    Vector3 center, {
    required double halfLength,
    required double halfWidth,
    double cornerRadius = 0,
    Vector3? axis,
    double width = 0.3,
    double strength = 1,
  }) {
    final slot = _freeSlot();
    setRectangle(
      slot,
      center,
      halfLength: halfLength,
      halfWidth: halfWidth,
      cornerRadius: cornerRadius,
      axis: axis,
      width: width,
      strength: strength,
    );
    return slot;
  }

  /// Puts a circle in [slot], whether it held a source or not, see
  /// [addCircle].
  void setCircle(
    int slot,
    Vector3 center, {
    required double radius,
    double width = 0.3,
    double strength = 1,
  }) {
    _checkExtent(radius, 'radius');
    _set(slot, center, radius, radius, radius, null, width, strength);
  }

  /// Puts a rectangle with rounded corners in [slot], whether it held a
  /// source or not, see [addRectangle].
  void setRectangle(
    int slot,
    Vector3 center, {
    required double halfLength,
    required double halfWidth,
    double cornerRadius = 0,
    Vector3? axis,
    double width = 0.3,
    double strength = 1,
  }) {
    _checkExtent(halfLength, 'halfLength');
    _checkExtent(halfWidth, 'halfWidth');
    _checkExtent(cornerRadius, 'cornerRadius');
    _set(
      slot,
      center,
      halfLength,
      halfWidth,
      math.min(cornerRadius, math.min(halfLength, halfWidth)),
      axis,
      width,
      strength,
    );
  }

  /// Moves the source in [slot] to the world point [center] and, with
  /// [axis], turns its length along that world direction.
  void move(int slot, Vector3 center, {Vector3? axis}) {
    final o = _usedOffset(slot);
    var changed = _write(o, center.x, center.y, center.z);
    if (axis != null) {
      changed = _write(o + 3, axis.x, axis.y, axis.z) || changed;
    }
    if (changed) {
      _version++;
    }
  }

  /// Sets the strength of the source in [slot]: `0` hides it without
  /// freeing its slot, `1` draws a band against its outline (see
  /// [WaterFoamSources]).
  void setStrength(int slot, double strength) {
    final o = _usedOffset(slot);
    _checkStrength(strength);
    if (_sources[o + 10] != strength) {
      _sources[o + 10] = strength;
      _version++;
    }
  }

  /// The strength of the source in [slot].
  double strengthOf(int slot) => _sources[_usedOffset(slot) + 10];

  /// Removes the source in [slot], if any.
  void remove(int slot) {
    RangeError.checkValueInInterval(slot, 0, capacity - 1, 'slot');
    if (_used[slot]) {
      _used[slot] = false;
      _version++;
    }
  }

  /// Removes every source.
  void clear() {
    for (var i = 0; i < capacity; i++) {
      _used[i] = false;
    }
    _version++;
  }

  int _freeSlot() {
    for (var i = 0; i < capacity; i++) {
      if (!_used[i]) {
        return i;
      }
    }
    throw StateError(
      'Every one of the $capacity foam sources is in use: remove one first',
    );
  }

  int _usedOffset(int slot) {
    RangeError.checkValueInInterval(slot, 0, capacity - 1, 'slot');
    if (!_used[slot]) {
      throw StateError('Slot $slot holds no foam source');
    }
    return slot * _stride;
  }

  static void _checkExtent(double value, String name) {
    if (!(value >= 0) || value.isInfinite) {
      throw ArgumentError.value(value, name, 'Must not be negative');
    }
  }

  static void _checkStrength(double strength) {
    if (!(strength >= 0) || strength.isInfinite) {
      throw ArgumentError.value(strength, 'strength', 'Must not be negative');
    }
  }

  void _set(
    int slot,
    Vector3 center,
    double halfLength,
    double halfWidth,
    double cornerRadius,
    Vector3? axis,
    double width,
    double strength,
  ) {
    RangeError.checkValueInInterval(slot, 0, capacity - 1, 'slot');
    if (!(width > 0) || width.isInfinite) {
      throw ArgumentError.value(width, 'width', 'Must be positive');
    }
    _checkStrength(strength);
    final o = slot * _stride;
    var changed = !_used[slot];
    changed = _write(o, center.x, center.y, center.z) || changed;
    changed = axis == null
        ? _write(o + 3, 1, 0, 0) || changed
        : _write(o + 3, axis.x, axis.y, axis.z) || changed;
    changed = _write(o + 6, halfLength, halfWidth, cornerRadius) || changed;
    changed = _write(o + 9, width, strength, 0) || changed;
    _used[slot] = true;
    if (changed) {
      _version++;
    }
  }

  // Writes three values at [o]; whether any of them changed.
  bool _write(int o, double x, double y, double z) {
    final changed =
        _sources[o] != x || _sources[o + 1] != y || _sources[o + 2] != z;
    _sources
      ..[o] = x
      ..[o + 1] = y
      ..[o + 2] = z;
    return changed;
  }

  /// Writes the sources whose strength is above `0` into [positions] and
  /// [shapes], one `Vector4` each per source, as `WaterMaterial`'s fragment
  /// shader reads them, in the plane coordinates `(dot(p, uAxis), dot(p,
  /// vAxis))`; returns how many it wrote.
  @internal
  int writeUniforms(
    Vector3 uAxis,
    Vector3 vAxis,
    List<Vector4> positions,
    List<Vector4> shapes,
  ) {
    var count = 0;
    for (var i = 0; i < capacity && count < positions.length; i++) {
      final o = i * _stride;
      final strength = _sources[o + 10];
      if (!_used[i] || !(strength > 0)) {
        continue;
      }
      final x = _sources[o];
      final y = _sources[o + 1];
      final z = _sources[o + 2];
      final ax = _sources[o + 3];
      final ay = _sources[o + 4];
      final az = _sources[o + 5];
      var au = ax * uAxis.x + ay * uAxis.y + az * uAxis.z;
      var av = ax * vAxis.x + ay * vAxis.y + az * vAxis.z;
      var length = math.sqrt(au * au + av * av);
      if (!(length > 1e-9)) {
        // Along the up axis: the first axis of the plane.
        au = 1;
        av = 0;
        length = 1;
      }
      final width = _sources[o + 9];
      final corner = _sources[o + 8];
      final perWidth = 1 / (length * width);
      positions[count].setValues(
        x * uAxis.x + y * uAxis.y + z * uAxis.z,
        x * vAxis.x + y * vAxis.y + z * vAxis.z,
        au * perWidth,
        av * perWidth,
      );
      shapes[count].setValues(
        (_sources[o + 6] - corner) / width,
        (_sources[o + 7] - corner) / width,
        corner / width,
        strength,
      );
      count++;
    }
    return count;
  }
}
