import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

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
  final Matrix4 _lastWorldMatrix = Matrix4.zero();
  int _localVersion = 0;
  int _transformedVersion = -1;

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
  Aabb3? computeLocalAabb() {
    if (_length == 0) {
      return null;
    }
    if (_localBoundsDirty) {
      _localBoundsDirty = false;
      final meshBox = mesh.aabb;
      final cx = 0.5 * (meshBox.min.x + meshBox.max.x);
      final cy = 0.5 * (meshBox.min.y + meshBox.max.y);
      final cz = 0.5 * (meshBox.min.z + meshBox.max.z);
      final hx = 0.5 * (meshBox.max.x - meshBox.min.x);
      final hy = 0.5 * (meshBox.max.y - meshBox.min.y);
      final hz = 0.5 * (meshBox.max.z - meshBox.min.z);
      final instances = _instances;

      var minX = double.infinity;
      var minY = double.infinity;
      var minZ = double.infinity;
      var maxX = double.negativeInfinity;
      var maxY = double.negativeInfinity;
      var maxZ = double.negativeInfinity;

      for (var idx = 0; idx < _length; idx++) {
        final b = idx * _stride;
        final m0 = instances[b];
        final m1 = instances[b + 1];
        final m2 = instances[b + 2];
        final m4 = instances[b + 4];
        final m5 = instances[b + 5];
        final m6 = instances[b + 6];
        final m8 = instances[b + 8];
        final m9 = instances[b + 9];
        final m10 = instances[b + 10];

        final wx = m0 * cx + m4 * cy + m8 * cz + instances[b + 12];
        final wy = m1 * cx + m5 * cy + m9 * cz + instances[b + 13];
        final wz = m2 * cx + m6 * cy + m10 * cz + instances[b + 14];

        final ex = m0.abs() * hx + m4.abs() * hy + m8.abs() * hz;
        final ey = m1.abs() * hx + m5.abs() * hy + m9.abs() * hz;
        final ez = m2.abs() * hx + m6.abs() * hy + m10.abs() * hz;

        if (wx - ex < minX) {
          minX = wx - ex;
        }
        if (wy - ey < minY) {
          minY = wy - ey;
        }
        if (wz - ez < minZ) {
          minZ = wz - ez;
        }
        if (wx + ex > maxX) {
          maxX = wx + ex;
        }
        if (wy + ey > maxY) {
          maxY = wy + ey;
        }
        if (wz + ez > maxZ) {
          maxZ = wz + ez;
        }
      }
      _localAabb
        ..min.setValues(minX, minY, minZ)
        ..max.setValues(maxX, maxY, maxZ);
    }
    return _localAabb;
  }

  @override
  void draw(covariant RenderContext3D context) {
    if (_length == 0) {
      return;
    }
    final world = worldTransformMatrix;
    final buffer = _resolvedBuffer(world);
    _updateMirroring(buffer, world);
    final mirrored = _mirroredCount;
    if (mirrored == 0 || mirrored == _length) {
      for (final surface in mesh.surfaces) {
        context.drawInstances(
          surface,
          instances: buffer,
          count: _length,
          mirrored: mirrored > 0,
        );
      }
      return;
    }
    // Mirrored and unmirrored instances need different front faces: draw
    // them apart, from a copy holding the unmirrored ones first.
    final plain = _length - mirrored;
    for (final surface in mesh.surfaces) {
      context
        ..drawInstances(surface, instances: _partitioned!, count: plain)
        ..drawInstances(
          surface,
          instances: _mirroredView!,
          count: mirrored,
          mirrored: true,
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
  final Matrix4 _mirroringWorld = Matrix4.zero();
  Float32List? _partitioned;
  Float32List? _mirroredView;

  void _updateMirroring(Float32List buffer, [Matrix4? worldMatrix]) {
    final world = worldMatrix ?? worldTransformMatrix;
    if (identical(buffer, _mirroringBuffer) &&
        _mirroringVersion == _localVersion &&
        _mirroringWorld == world) {
      return;
    }
    _mirroringBuffer = buffer;
    _mirroringVersion = _localVersion;
    _mirroringWorld.setFrom(world);

    var mirrored = 0;
    for (var i = 0; i < _length; i++) {
      if (_mirrors(buffer, i * _stride)) {
        mirrored++;
      }
    }
    _mirroredCount = mirrored;
    if (mirrored == 0 || mirrored == _length) {
      return;
    }

    var partitioned = _partitioned;
    if (partitioned == null || partitioned.length < _capacity * _stride) {
      partitioned = _partitioned = Float32List(_capacity * _stride);
    }
    var plainAt = 0;
    var mirroredAt = (_length - mirrored) * _stride;
    for (var i = 0; i < _length; i++) {
      final base = i * _stride;
      if (_mirrors(buffer, base)) {
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

  /// Whether the model matrix at [base] in [buffer] mirrors (its upper 3x3
  /// has a negative determinant).
  static bool _mirrors(Float32List buffer, int base) {
    final m0 = buffer[base];
    final m1 = buffer[base + 1];
    final m2 = buffer[base + 2];
    final m4 = buffer[base + 4];
    final m5 = buffer[base + 5];
    final m6 = buffer[base + 6];
    final m8 = buffer[base + 8];
    final m9 = buffer[base + 9];
    final m10 = buffer[base + 10];
    final determinant =
        m0 * (m5 * m10 - m6 * m9) -
        m4 * (m1 * m10 - m2 * m9) +
        m8 * (m1 * m6 - m2 * m5);
    return determinant < 0;
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

  Float32List _resolvedBuffer([Matrix4? worldMatrix]) {
    final world = worldMatrix ?? worldTransformMatrix;
    if (world.isIdentity()) {
      return _instances;
    }
    var out = _worldInstances;
    if (out == null || out.length < _length * _stride) {
      out = _worldInstances = Float32List(_capacity * _stride);
      _transformedVersion = -1;
    }
    if (_transformedVersion != _localVersion || _lastWorldMatrix != world) {
      _transformedVersion = _localVersion;
      _lastWorldMatrix.setFrom(world);
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

  static final Matrix4 _scratchMatrix = Matrix4.identity();
}
