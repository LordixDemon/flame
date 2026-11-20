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
/// flecks are left, so fade a collar in and out with [setStrength]. The
/// pattern of that foam stays in the world, unless the source carries it
/// (`carryPattern`, [setCarryPattern]): then it moves and turns with the
/// source.
///
/// It holds at most [capacity] sources (8 by default, up to [maxCapacity]),
/// in slots that keep their source until it is removed: adding one when
/// every slot is taken throws. A set of more than 8 (or one whose sources
/// carry their pattern) makes its materials draw with their full fragment
/// stage, 16 uniform vectors larger and a little slower (see
/// `WaterMaterial.foamSources`): give a set the capacity its scene needs.
/// Adding, moving, changing and drawing allocate nothing, and moving a source
/// does not rebuild any surface. The pixels pay for the slots up to the last
/// source whose strength is above `0`, and only where a source may reach
/// them: the vertices of the surface tell the pixels where none does, so the
/// cost follows the area the collars cover (on a surface subdivided finely
/// enough for its waves).
/// {@endtemplate}
class WaterFoamSources({
  /// The number of sources the set holds, from `1` to [maxCapacity]:
  /// [defaultCapacity] by default.
  final int capacity = defaultCapacity,
}) {
  /// {@macro water_foam_sources}
  this {
    RangeError.checkValueInInterval(capacity, 1, maxCapacity, 'capacity');
  }

  /// The number of sources a set holds by default, as many as the fragment
  /// stage of `WaterMaterial` holds without its 16 more uniform vectors.
  static const int defaultCapacity = 8;

  /// The most sources a set can hold.
  static const int maxCapacity = 16;

  // Per source: x, y, z (its center), ax, ay, az (the direction of its
  // length), half length, half width, corner radius, width, strength and 1
  // when it carries its pattern (0 otherwise).
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
  /// outline (see [WaterFoamSources]). With [carryPattern], the pattern of
  /// its foam moves and turns with it instead of staying in the world (see
  /// [setCarryPattern]). Throws a [StateError] when every slot holds a
  /// source.
  int addCircle(
    Vector3 center, {
    required double radius,
    double width = 0.3,
    double strength = 1,
    bool carryPattern = false,
  }) {
    final slot = _freeSlot();
    setCircle(
      slot,
      center,
      radius: radius,
      width: width,
      strength: strength,
      carryPattern: carryPattern,
    );
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
  /// of the water. [width], [strength] and [carryPattern] are those of
  /// [addCircle]. Throws a [StateError] when every slot holds a source.
  int addRectangle(
    Vector3 center, {
    required double halfLength,
    required double halfWidth,
    double cornerRadius = 0,
    Vector3? axis,
    double width = 0.3,
    double strength = 1,
    bool carryPattern = false,
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
      carryPattern: carryPattern,
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
    bool carryPattern = false,
  }) {
    _checkExtent(radius, 'radius');
    _set(
      slot,
      center,
      radius,
      radius,
      radius,
      null,
      width,
      strength,
      carryPattern,
    );
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
    bool carryPattern = false,
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
      carryPattern,
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

  /// Sets whether the source in [slot] carries the pattern of its foam.
  ///
  /// By default (`false`) the pattern of a collar, its patches and holes,
  /// stays in the world, as the foam of the foam mask does: a source that
  /// moves slides through it, its foam seeming to stream through the
  /// collar. A source that carries it draws its foam in its own frame, so
  /// that the collar moves and turns with the source (a crate drifting by, a
  /// boat), still lapping at the pace of `WaterMaterial.edgeFoamMotion`;
  /// each slot starts its pattern at a place of its own, so that collars of
  /// one shape do not show the same foam. Where such a collar meets other
  /// foam, the larger of the two foams shows. While a source of the set
  /// carries its pattern, its materials draw with their full fragment stage
  /// (see `WaterMaterial.foamSources`).
  void setCarryPattern(int slot, {required bool carry}) {
    final o = _usedOffset(slot);
    final value = carry ? 1.0 : 0.0;
    if (_sources[o + 11] != value) {
      _sources[o + 11] = value;
      _version++;
    }
  }

  /// Whether the source in [slot] carries the pattern of its foam (see
  /// [setCarryPattern]).
  bool carriesPattern(int slot) => _sources[_usedOffset(slot) + 11] > 0;

  /// Whether a source of the set carries the pattern of its foam.
  @internal
  bool get carriesAnyPattern {
    for (var i = 0; i < capacity; i++) {
      if (_used[i] && _sources[i * _stride + 11] > 0) {
        return true;
      }
    }
    return false;
  }

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
    bool carryPattern,
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
    changed = _write(o + 9, width, strength, carryPattern ? 1 : 0) || changed;
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

  /// Writes the slots of the sources into [positions] and [shapes], one
  /// `Vector4` each per slot, as `WaterMaterial`'s fragment shader reads
  /// them, in the plane coordinates `(dot(p, uAxis), dot(p, vAxis))`, up to
  /// the last source whose strength is above `0`; returns how many slots it
  /// wrote. Free slots and hidden sources get a strength of `0`, and the
  /// sources that carry their pattern a negative strength: a source keeps
  /// its slot's index in the shader, which offsets the pattern it carries.
  @internal
  int writeUniforms(
    Vector3 uAxis,
    Vector3 vAxis,
    List<Vector4> positions,
    List<Vector4> shapes,
  ) {
    var count = 0;
    final slots = math.min(capacity, positions.length);
    for (var i = 0; i < slots; i++) {
      final o = i * _stride;
      final strength = _sources[o + 10];
      if (!_used[i] || !(strength > 0)) {
        positions[i].setZero();
        shapes[i].setZero();
        continue;
      }
      _inPlane(o, uAxis, vAxis);
      final width = _sources[o + 9];
      final corner = _sources[o + 8];
      final perWidth = 1 / (_planeAxis.z * width);
      positions[i].setValues(
        _plane.x,
        _plane.y,
        _planeAxis.x * perWidth,
        _planeAxis.y * perWidth,
      );
      shapes[i].setValues(
        (_sources[o + 6] - corner) / width,
        (_sources[o + 7] - corner) / width,
        corner / width,
        _sources[o + 11] > 0 ? -strength : strength,
      );
      count = i + 1;
    }
    return count;
  }

  /// Writes, per source whose strength is above `0` (packed first), the
  /// circle beyond which it has no foam, a little enlarged, as
  /// `WaterMaterial`'s vertex shader reads it to tell where the fragments may
  /// skip the sources: its center `c` in the plane coordinates relative to
  /// [origin] (set to the middle of the sources' centers) in `xy` and
  /// `|c|² - r²` in `z`; returns how many it wrote.
  @internal
  int writeBounds(
    Vector3 uAxis,
    Vector3 vAxis,
    List<Vector4> bounds,
    Vector2 origin,
  ) {
    var count = 0;
    var minU = double.infinity;
    var minV = double.infinity;
    var maxU = double.negativeInfinity;
    var maxV = double.negativeInfinity;
    for (var i = 0; i < capacity && count < bounds.length; i++) {
      final o = i * _stride;
      if (!_used[i] || !(_sources[o + 10] > 0)) {
        continue;
      }
      _inPlane(o, uAxis, vAxis);
      final width = _sources[o + 9];
      final corner = _sources[o + 8];
      final straightLength = _sources[o + 6] - corner;
      final straightWidth = _sources[o + 7] - corner;
      // The farthest its foam reaches from its center: the corner of its
      // straight part, the corner's radius and the width of its foam.
      final reach =
          math.sqrt(
            straightLength * straightLength + straightWidth * straightWidth,
          ) +
          corner +
          width;
      final u = _plane.x;
      final v = _plane.y;
      bounds[count].setValues(u, v, reach * 1.02 + 0.02, 0);
      minU = math.min(minU, u);
      minV = math.min(minV, v);
      maxU = math.max(maxU, u);
      maxV = math.max(maxV, v);
      count++;
    }
    if (count == 0) {
      origin.setZero();
      return 0;
    }
    origin.setValues((minU + maxU) / 2, (minV + maxV) / 2);
    // The fragments compare |q|² + z to 0 in 32-bit floats, after a
    // cancellation of terms about as large as |c|²: a margin of a few dozen
    // of their units in the last place keeps the test conservative.
    var far = 0.0;
    for (var i = 0; i < count; i++) {
      final b = bounds[i];
      final cu = b.x - origin.x;
      final cv = b.y - origin.y;
      far = math.max(far, cu * cu + cv * cv);
    }
    final margin = 1e-4 + far * 1e-5;
    for (var i = 0; i < count; i++) {
      final b = bounds[i];
      final cu = b.x - origin.x;
      final cv = b.y - origin.y;
      b.setValues(cu, cv, cu * cu + cv * cv - b.z * b.z - margin, 0);
    }
    return count;
  }

  // The center of the source at [o] in the plane coordinates, and the
  // direction of its length in them (xy) with its length (z).
  static final Vector2 _plane = Vector2.zero();
  static final Vector3 _planeAxis = Vector3.zero();

  void _inPlane(int o, Vector3 uAxis, Vector3 vAxis) {
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
    _plane.setValues(
      x * uAxis.x + y * uAxis.y + z * uAxis.z,
      x * vAxis.x + y * vAxis.y + z * vAxis.z,
    );
    _planeAxis.setValues(au, av, length);
  }
}
