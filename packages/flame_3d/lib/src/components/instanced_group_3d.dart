import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';

/// {@template instanced_group_3d}
/// Draws many instances of one [Mesh] in a single `O(1)` submission per
/// [Surface] without creating a child component per instance.
///
/// Transforms, per-instance colors, and per-instance `Vector4` data live in a
/// contiguous `Float32List` (`24` floats per instance) handed straight to
/// [RenderContext3D.drawInstances] (including during shadow passes).
/// {@endtemplate}
class InstancedGroup3D({
  required final Mesh mesh,
  int initialCapacity = 16,
  super.position,
  super.scale,
  super.rotation,
  super.children,
  super.castsShadows,
}) extends Object3D {
  /// {@macro instanced_group_3d}
  this {
    if (initialCapacity < 1) {
      throw ArgumentError.value(
        initialCapacity,
        'initialCapacity',
        'Must be at least 1',
      );
    }
    _capacity = initialCapacity;
    _instances = Float32List(_capacity * _stride);
  }

  static const int _stride = VertexLayout.instanceStrideInFloats;

  int _capacity = 16;
  int _length = 0;
  late Float32List _instances;
  Float32List? _worldInstances;
  int _localVersion = 0;
  int _transformedVersion = -1;
  int _transformedWorldVer = -1;
  int _worldBufferVersion = 1;

  final Aabb3 _localAabb = Aabb3();
  bool _localBoundsDirty = true;

  /// Number of active instances in the group.
  int get length => _length;

  /// Whether the group holds no instances.
  bool get isEmpty => _length == 0;

  /// Whether the group holds at least one instance.
  bool get isNotEmpty => _length > 0;

  /// Appends an instance and returns its index.
  int addInstance({
    required Matrix4 transform,
    Color color = const Color(0xFFFFFFFF),
    Vector4? instanceData,
  }) {
    final index = _length;
    if (index == _capacity) {
      _grow(_capacity * 2);
    }
    _length++;
    _writeInstance(index, transform, color, instanceData);
    _invalidate();
    return index;
  }

  /// Updates fields of the instance at [index] in place.
  void setInstance(
    int index, {
    Matrix4? transform,
    Color? color,
    Vector4? instanceData,
  }) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    final base = index * _stride;
    if (transform != null) {
      final s = transform.storage;
      for (var i = 0; i < 16; i++) {
        _instances[base + i] = s[i];
      }
      _localBoundsDirty = true;
    }
    if (color != null) {
      _instances
        ..[base + 16] = color.r
        ..[base + 17] = color.g
        ..[base + 18] = color.b
        ..[base + 19] = color.a;
    }
    if (instanceData != null) {
      _instances
        ..[base + 20] = instanceData.x
        ..[base + 21] = instanceData.y
        ..[base + 22] = instanceData.z
        ..[base + 23] = instanceData.w;
    }
    _localVersion++;
    if (transform != null) {
      markAabbDirty();
    }
    _notifyWorldDirty(shadows: transform != null);
  }

  /// Removes the instance at [index] in `O(1)` by moving the last instance into
  /// its slot.
  void removeAtSwapLast(int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    final last = --_length;
    if (index != last) {
      _instances.setRange(
        index * _stride,
        (index + 1) * _stride,
        _instances,
        last * _stride,
      );
    }
    _invalidate();
  }

  /// Removes all instances without releasing the backing buffer.
  void clear() {
    if (_length == 0) {
      return;
    }
    _length = 0;
    _invalidate();
  }

  /// Reads the local transform of [index] into [out] (or a new [Matrix4]).
  Matrix4 instanceTransform(int index, {Matrix4? out}) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    final result = out ?? Matrix4.zero();
    final base = index * _stride;
    for (var i = 0; i < 16; i++) {
      result.storage[i] = _instances[base + i];
    }
    return result;
  }

  /// Reads the color of the instance at [index].
  Color instanceColor(int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    final base = index * _stride;
    return Color.from(
      red: _instances[base + 16],
      green: _instances[base + 17],
      blue: _instances[base + 18],
      alpha: _instances[base + 19],
    );
  }

  /// Reads the instance data of [index] into [out] (or a new [Vector4]).
  Vector4 instanceDataAt(int index, {Vector4? out}) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    final base = index * _stride;
    return (out ?? Vector4.zero())..setValues(
      _instances[base + 20],
      _instances[base + 21],
      _instances[base + 22],
      _instances[base + 23],
    );
  }

  @override
  bool get usesDefaultFrustumVisibility => runtimeType == InstancedGroup3D;

  @override
  Aabb3? computeLocalAabb() {
    if (_length == 0) {
      return null;
    }
    if (_localBoundsDirty) {
      _localBoundsDirty = false;
      expandAabbByTransformedInstances(
        _instances,
        _length,
        _stride,
        mesh.aabb,
        _localAabb,
      );
    }
    return _localAabb;
  }

  @override
  void draw(covariant RenderContext3D context) {
    if (_length == 0) {
      return;
    }
    final world = worldTransformMatrix;
    final worldVer = worldTransformVersion;
    final buffer = _resolvedBuffer(world, worldVer);
    _updateMirroring(buffer, worldVer);
    final bufVer = identical(buffer, _instances)
        ? _localVersion
        : _worldBufferVersion;
    final mirrored = _mirroredCount;
    if (mirrored == 0 || mirrored == _length) {
      for (final surface in mesh.surfaces) {
        context.drawInstances(
          surface,
          instances: buffer,
          count: _length,
          mirrored: mirrored > 0,
          instanceVersion: bufVer,
        );
      }
      return;
    }
    // Mirrored and unmirrored instances need different front faces: draw
    // them apart, from a copy holding the unmirrored ones first.
    final plain = _length - mirrored;
    for (final surface in mesh.surfaces) {
      context
        ..drawInstances(
          surface,
          instances: _partitioned!,
          count: plain,
          instanceVersion: _partitionVersion,
        )
        ..drawInstances(
          surface,
          instances: _mirroredView!,
          count: mirrored,
          mirrored: true,
          instanceVersion: _partitionVersion,
        );
    }
  }

  // How many instances of the drawn buffer mirror, for the buffer and the
  // version they were counted for; when some do and some do not,
  // [_partitioned] holds the unmirrored instances first and [_mirroredView]
  // starts at the mirrored ones.
  int _mirroredCount = 0;
  Float32List? _mirroringBuffer;
  int _mirroringVersion = -1;
  int _mirroringWorldVer = -1;
  int _partitionVersion = 1;
  Float32List? _partitioned;
  Float32List? _mirroredView;

  void _updateMirroring(Float32List buffer, int worldVer) {
    if (identical(buffer, _mirroringBuffer) &&
        _mirroringVersion == _localVersion &&
        _mirroringWorldVer == worldVer) {
      return;
    }
    _mirroringBuffer = buffer;
    _mirroringVersion = _localVersion;
    _mirroringWorldVer = worldVer;

    var mirrored = 0;
    for (var i = 0; i < _length; i++) {
      if (isMirrored3x3(buffer, i * _stride)) {
        mirrored++;
      }
    }
    _mirroredCount = mirrored;
    if (mirrored == 0 || mirrored == _length) {
      return;
    }

    _partitionVersion++;
    var partitioned = _partitioned;
    if (partitioned == null || partitioned.length < _capacity * _stride) {
      partitioned = _partitioned = Float32List(_capacity * _stride);
    }
    var plainAt = 0;
    var mirroredAt = (_length - mirrored) * _stride;
    for (var i = 0; i < _length; i++) {
      final base = i * _stride;
      if (isMirrored3x3(buffer, base)) {
        partitioned.setRange(mirroredAt, mirroredAt + _stride, buffer, base);
        mirroredAt += _stride;
      } else {
        partitioned.setRange(plainAt, plainAt + _stride, buffer, base);
        plainAt += _stride;
      }
    }
    final viewStart = (_length - mirrored) * _stride;
    final view = _mirroredView;
    if (view == null ||
        !identical(view.buffer, partitioned.buffer) ||
        view.offsetInBytes != viewStart * Float32List.bytesPerElement) {
      _mirroredView = Float32List.sublistView(partitioned, viewStart);
    }
  }

  @override
  RayHit3D? raycast(
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) {
    if (_length == 0) {
      return null;
    }
    final buffer = _resolvedBuffer();
    RayHit3D? best;
    var limit = maxDistance;
    for (var i = 0; i < _length; i++) {
      final base = i * _stride;
      for (var k = 0; k < 16; k++) {
        _scratchMatrix.storage[k] = buffer[base + k];
      }
      final hit = RayHit3D.intersectMesh(
        owner: this,
        mesh: mesh,
        modelMatrix: _scratchMatrix,
        worldRay: worldRay,
        maxDistance: limit,
        cullMode: cullMode,
      );
      if (hit != null && hit.distance < limit) {
        limit = hit.distance;
        // surfaceIndex holds the instance too, as it always has.
        best = hit.onInstance(i, surfaceIndex: i);
      }
    }
    return best;
  }

  Float32List _resolvedBuffer([Matrix4? worldMatrix, int? worldVer]) {
    final world = worldMatrix ?? worldTransformMatrix;
    final wVer = worldVer ?? worldTransformVersion;
    if (world.isIdentity()) {
      return _instances;
    }
    var out = _worldInstances;
    if (out == null || out.length < _length * _stride) {
      out = _worldInstances = Float32List(_capacity * _stride);
      _transformedVersion = -1;
    }
    if (_transformedVersion != _localVersion || _transformedWorldVer != wVer) {
      _transformedVersion = _localVersion;
      _transformedWorldVer = wVer;
      _worldBufferVersion++;
      final w = world.storage;
      for (var i = 0; i < _length; i++) {
        final b = i * _stride;
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

  void _writeInstance(
    int index,
    Matrix4 transform,
    Color color,
    Vector4? instanceData,
  ) {
    final base = index * _stride;
    final s = transform.storage;
    for (var i = 0; i < 16; i++) {
      _instances[base + i] = s[i];
    }
    _instances
      ..[base + 16] = color.r
      ..[base + 17] = color.g
      ..[base + 18] = color.b
      ..[base + 19] = color.a
      ..[base + 20] = instanceData?.x ?? 0
      ..[base + 21] = instanceData?.y ?? 0
      ..[base + 22] = instanceData?.z ?? 0
      ..[base + 23] = instanceData?.w ?? 0;
  }

  void _grow(int newCapacity) {
    final next = Float32List(newCapacity * _stride)
      ..setRange(0, _length * _stride, _instances);
    _instances = next;
    _capacity = newCapacity;
    _worldInstances = null;
  }

  void _invalidate() {
    _localVersion++;
    _localBoundsDirty = true;
    markAabbDirty();
    _notifyWorldDirty(shadows: true);
  }

  void _notifyWorldDirty({required bool shadows}) {
    markDrawDirty(shadows: shadows && castsShadows);
  }

  @override
  Component3D cloneSelf() {
    if (runtimeType != InstancedGroup3D) {
      return super.cloneSelf();
    }
    final copy = InstancedGroup3D(
      mesh: mesh,
      initialCapacity: math.max(1, length),
      castsShadows: castsShadows,
    );
    final transform = Matrix4.zero();
    final data = Vector4.zero();
    for (var i = 0; i < length; i++) {
      copy.addInstance(
        transform: instanceTransform(i, out: transform),
        color: instanceColor(i),
        instanceData: instanceDataAt(i, out: data),
      );
    }
    return copy;
  }

  static final Matrix4 _scratchMatrix = Matrix4.identity();
}
