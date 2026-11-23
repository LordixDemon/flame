import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:meta/meta.dart';

/// Shared contiguous `Float32List` instance buffer (`24` floats per instance:
/// 4x4 transform matrix, RGBA color, and `vec4` payload) with O(1) swap-remove
/// and cached world-transform resolution.
@internal
class InstanceBuffer3D({int initialCapacity = 16}) {
  /// Allocates an [InstanceBuffer3D] with initial slot capacity
  /// [initialCapacity].
  this {
    if (initialCapacity < 1) {
      throw ArgumentError.value(
        initialCapacity,
        'initialCapacity',
        'Must be at least 1',
      );
    }
    _capacity = initialCapacity;
    _instances = Float32List(_capacity * stride);
  }

  /// Float stride per instance ([VertexLayout.instanceStrideInFloats]).
  static const int stride = VertexLayout.instanceStrideInFloats;

  int _capacity = 16;
  int _length = 0;
  late Float32List _instances;
  Float32List? _worldInstances;
  int _localVersion = 0;
  int _transformedVersion = -1;
  int _transformedWorldVer = -1;
  int _worldBufferVersion = 1;

  /// Number of active instances currently stored.
  int get length => _length;

  /// Allocated capacity in instance slots.
  int get capacity => _capacity;

  /// Whether zero instances are currently stored.
  bool get isEmpty => _length == 0;

  /// Whether at least one instance is stored.
  bool get isNotEmpty => _length > 0;

  /// Monotonically incremented whenever local instance data changes.
  int get localVersion => _localVersion;

  /// Raw backing `Float32List` holding local-space instance records.
  Float32List get localData => _instances;

  /// Appends an instance record and returns its assigned index.
  int append(
    Matrix4 transform,
    Color color,
    double d0,
    double d1,
    double d2,
    double d3,
  ) {
    final index = _length;
    if (index == _capacity) {
      _grow(_capacity * 2);
    }
    _length++;
    final base = index * stride;
    final s = transform.storage;
    for (var i = 0; i < 16; i++) {
      _instances[base + i] = s[i];
    }
    _instances
      ..[base + 16] = color.r
      ..[base + 17] = color.g
      ..[base + 18] = color.b
      ..[base + 19] = color.a
      ..[base + 20] = d0
      ..[base + 21] = d1
      ..[base + 22] = d2
      ..[base + 23] = d3;
    _localVersion++;
    return index;
  }

  /// Updates the non-null fields of the existing instance at [index] in place.
  void update(
    int index, {
    Matrix4? transform,
    Color? color,
    double? d0,
    double? d1,
    double? d2,
    double? d3,
  }) {
    final base = index * stride;
    if (transform != null) {
      final s = transform.storage;
      for (var i = 0; i < 16; i++) {
        _instances[base + i] = s[i];
      }
    }
    if (color != null) {
      _instances
        ..[base + 16] = color.r
        ..[base + 17] = color.g
        ..[base + 18] = color.b
        ..[base + 19] = color.a;
    }
    if (d0 != null) {
      _instances[base + 20] = d0;
    }
    if (d1 != null) {
      _instances[base + 21] = d1;
    }
    if (d2 != null) {
      _instances[base + 22] = d2;
    }
    if (d3 != null) {
      _instances[base + 23] = d3;
    }
    _localVersion++;
  }

  /// Removes [index] in `O(1)` by copying the last record into its slot.
  void removeAtSwapLast(int index) {
    final last = --_length;
    if (index != last) {
      _instances.setRange(
        index * stride,
        (index + 1) * stride,
        _instances,
        last * stride,
      );
    }
    _localVersion++;
  }

  /// Clears all active instances without releasing backing storage.
  ///
  /// Returns `false` when already empty.
  bool clear() {
    if (_length == 0) {
      return false;
    }
    _length = 0;
    _localVersion++;
    return true;
  }

  /// Reads the local transform of [index] into [out] (or a new [Matrix4]).
  Matrix4 readTransform(int index, {Matrix4? out}) {
    final result = out ?? Matrix4.zero();
    final base = index * stride;
    for (var i = 0; i < 16; i++) {
      result.storage[i] = _instances[base + i];
    }
    return result;
  }

  /// Reads the RGBA color of [index].
  Color readColor(int index) {
    final base = index * stride;
    return Color.from(
      red: _instances[base + 16],
      green: _instances[base + 17],
      blue: _instances[base + 18],
      alpha: _instances[base + 19],
    );
  }

  /// Reads the `vec4` payload of [index] into [out] (or a new [Vector4]).
  Vector4 readData(int index, {Vector4? out}) {
    final base = index * stride;
    return (out ?? Vector4.zero())..setValues(
      _instances[base + 20],
      _instances[base + 21],
      _instances[base + 22],
      _instances[base + 23],
    );
  }

  /// Returns a buffer containing all active instances transformed by [world]
  /// (associated with [worldVer]), returning [localData] directly when [world]
  /// is identity.
  Float32List resolveWorld(Matrix4 world, int worldVer) {
    if (world.isIdentity()) {
      return _instances;
    }
    var out = _worldInstances;
    if (out == null || out.length < _length * stride) {
      out = _worldInstances = Float32List(_capacity * stride);
      _transformedVersion = -1;
    }
    if (_transformedVersion != _localVersion ||
        _transformedWorldVer != worldVer) {
      _transformedVersion = _localVersion;
      _transformedWorldVer = worldVer;
      _worldBufferVersion++;
      final w = world.storage;
      for (var i = 0; i < _length; i++) {
        final b = i * stride;
        for (var col = 0; col < 4; col++) {
          final c = b + col * 4;
          final x = _instances[c];
          final y = _instances[c + 1];
          final z = _instances[c + 2];
          final mw = _instances[c + 3];
          out
            ..[c] = w[0] * x + w[4] * y + w[8] * z + w[12] * mw
            ..[c + 1] = w[1] * x + w[5] * y + w[9] * z + w[13] * mw
            ..[c + 2] = w[2] * x + w[6] * y + w[10] * z + w[14] * mw
            ..[c + 3] = w[3] * x + w[7] * y + w[11] * z + w[15] * mw;
        }
        for (var k = 16; k < 24; k++) {
          out[b + k] = _instances[b + k];
        }
      }
    }
    return out;
  }

  /// Version counter corresponding to [resolved] (either `localVersion` or the
  /// cached world-transformed buffer version).
  int versionOf(Float32List resolved) =>
      identical(resolved, _instances) ? _localVersion : _worldBufferVersion;

  void _grow(int newCapacity) {
    final next = Float32List(newCapacity * stride)
      ..setRange(0, _length * stride, _instances);
    _instances = next;
    _capacity = newCapacity;
    _worldInstances = null;
  }
}
