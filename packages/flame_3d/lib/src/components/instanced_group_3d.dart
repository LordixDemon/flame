import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/components/instance_buffer_3d.dart';
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
  final InstanceBuffer3D _buffer = InstanceBuffer3D(
    initialCapacity: initialCapacity,
  );

  static const int _stride = InstanceBuffer3D.stride;

  final Aabb3 _localAabb = Aabb3();
  bool _localBoundsDirty = true;

  /// Number of active instances in the group.
  int get length => _buffer.length;

  /// Whether the group holds no instances.
  bool get isEmpty => _buffer.isEmpty;

  /// Whether the group holds at least one instance.
  bool get isNotEmpty => _buffer.isNotEmpty;

  /// Appends an instance and returns its index.
  int addInstance({
    required Matrix4 transform,
    Color color = const Color(0xFFFFFFFF),
    Vector4? instanceData,
  }) {
    final index = _buffer.append(
      transform,
      color,
      instanceData?.x ?? 0,
      instanceData?.y ?? 0,
      instanceData?.z ?? 0,
      instanceData?.w ?? 0,
    );
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
    RangeError.checkValidIndex(index, this, 'index', _buffer.length);
    _buffer.update(
      index,
      transform: transform,
      color: color,
      d0: instanceData?.x,
      d1: instanceData?.y,
      d2: instanceData?.z,
      d3: instanceData?.w,
    );
    if (transform != null) {
      _localBoundsDirty = true;
      markAabbDirty();
    }
    _notifyWorldDirty(shadows: transform != null);
  }

  /// Removes the instance at [index] in `O(1)` by moving the last instance into
  /// its slot.
  void removeAtSwapLast(int index) {
    RangeError.checkValidIndex(index, this, 'index', _buffer.length);
    _buffer.removeAtSwapLast(index);
    _invalidate();
  }

  /// Removes all instances without releasing the backing buffer.
  void clear() {
    if (!_buffer.clear()) {
      return;
    }
    _invalidate();
  }

  /// Reads the local transform of [index] into [out] (or a new [Matrix4]).
  Matrix4 instanceTransform(int index, {Matrix4? out}) {
    RangeError.checkValidIndex(index, this, 'index', _buffer.length);
    return _buffer.readTransform(index, out: out);
  }

  /// Reads the color of the instance at [index].
  Color instanceColor(int index) {
    RangeError.checkValidIndex(index, this, 'index', _buffer.length);
    return _buffer.readColor(index);
  }

  /// Reads the instance data of [index] into [out] (or a new [Vector4]).
  Vector4 instanceDataAt(int index, {Vector4? out}) {
    RangeError.checkValidIndex(index, this, 'index', _buffer.length);
    return _buffer.readData(index, out: out);
  }

  @override
  bool get usesDefaultFrustumVisibility => runtimeType == InstancedGroup3D;

  @override
  Aabb3? computeLocalAabb() {
    if (_buffer.isEmpty) {
      return null;
    }
    if (_localBoundsDirty) {
      _localBoundsDirty = false;
      expandAabbByTransformedInstances(
        _buffer.localData,
        _buffer.length,
        _stride,
        mesh.aabb,
        _localAabb,
      );
    }
    return _localAabb;
  }

  @override
  void draw(covariant RenderContext3D context) {
    final count = _buffer.length;
    if (count == 0) {
      return;
    }
    final world = worldTransformMatrix;
    final worldVer = worldTransformVersion;
    final buffer = _buffer.resolveWorld(world, worldVer);
    _updateMirroring(buffer, worldVer);
    final bufVer = _buffer.versionOf(buffer);
    final mirrored = _mirroredCount;
    if (mirrored == 0 || mirrored == count) {
      for (final surface in mesh.surfaces) {
        context.drawInstances(
          surface,
          instances: buffer,
          count: count,
          mirrored: mirrored > 0,
          instanceVersion: bufVer,
        );
      }
      return;
    }
    // Mirrored and unmirrored instances need different front faces: draw
    // them apart, from a copy holding the unmirrored ones first.
    final plain = count - mirrored;
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
    final count = _buffer.length;
    final localVer = _buffer.localVersion;
    if (identical(buffer, _mirroringBuffer) &&
        _mirroringVersion == localVer &&
        _mirroringWorldVer == worldVer) {
      return;
    }
    _mirroringBuffer = buffer;
    _mirroringVersion = localVer;
    _mirroringWorldVer = worldVer;

    var mirrored = 0;
    for (var i = 0; i < count; i++) {
      if (isMirrored3x3(buffer, i * _stride)) {
        mirrored++;
      }
    }
    _mirroredCount = mirrored;
    if (mirrored == 0 || mirrored == count) {
      return;
    }

    _partitionVersion++;
    var partitioned = _partitioned;
    final cap = _buffer.capacity;
    if (partitioned == null || partitioned.length < cap * _stride) {
      partitioned = _partitioned = Float32List(cap * _stride);
    }
    var plainAt = 0;
    var mirroredAt = (count - mirrored) * _stride;
    for (var i = 0; i < count; i++) {
      final base = i * _stride;
      if (isMirrored3x3(buffer, base)) {
        partitioned.setRange(mirroredAt, mirroredAt + _stride, buffer, base);
        mirroredAt += _stride;
      } else {
        partitioned.setRange(plainAt, plainAt + _stride, buffer, base);
        plainAt += _stride;
      }
    }
    final viewStart = (count - mirrored) * _stride;
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
    final count = _buffer.length;
    if (count == 0) {
      return null;
    }
    final buffer = _buffer.resolveWorld(
      worldTransformMatrix,
      worldTransformVersion,
    );
    RayHit3D? best;
    var limit = maxDistance;
    for (var i = 0; i < count; i++) {
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

  void _invalidate() {
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
