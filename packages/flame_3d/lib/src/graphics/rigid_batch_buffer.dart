import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/core.dart' show Matrix4, Vector4;

/// A reusable per-object uniform table for `RenderContext3D.drawRigidBatch`.
///
/// Packs up to [capacity] transforms (default [maxObjects] = `40` for rigid
/// batches, or [maxSkinnedObjects] = `8` via [RigidBatchBuffer.skinned]) as
/// three transposed `vec4` rows each, RGBA tint colors, and per-object
/// `instanceData` vectors into a std140 buffer matching
/// `flame_3d/rigid_batch.glsl`'s `BatchObjects` block (`3200` bytes for rigid,
/// `640` bytes for skinned).
///
/// Keep [version] synced (via [setObject] + [markChanged], or [clear]) so
/// `GraphicsDevice.bindRigidBatch` promotes static tables to a persistent GPU
/// uniform buffer after two unchanged frames.
class RigidBatchBuffer({
  /// Number of object slots in this buffer (`40` for rigid, `8` for skinned).
  final int capacity = maxObjects,
}) {
  /// Creates a uniform table sized for skinned multi-object batches
  /// ([maxSkinnedObjects] = `8` slots, `640` bytes), keeping vertex uniforms
  /// within OpenGL ES 3.0's `256`-vector minimum alongside `JointMatrices`.
  RigidBatchBuffer.skinned() : this(capacity: maxSkinnedObjects);

  this : assert(capacity > 0, 'capacity must be positive');

  /// Maximum number of distinct objects packed in a single rigid batch draw.
  static const int maxObjects = 40;

  /// Maximum number of distinct objects packed in a single skinned batch draw.
  static const int maxSkinnedObjects = 8;

  /// Float offset where `modelRows` (`3 * capacity` vec4 rows) begins.
  static const int modelRowsOffset = 0;

  /// Default float offset where `colors[40]` begins for a [maxObjects] buffer.
  static const int colorsOffset = 480;

  /// Default float offset where `data[40]` begins for a [maxObjects] buffer.
  static const int dataOffset = 640;

  /// Total number of 32-bit floats in [maxObjects] buffer (`3200` bytes).
  static const int floatCount = 800;

  final int _colorsOffset = capacity * 12;
  final int _dataOffset = capacity * 16;

  /// Packed std140 float storage (`capacity * 20` floats).
  final Float32List data = Float32List(capacity * 20);

  /// Byte view over [data] uploaded to the uniform buffer.
  late final Uint8List bytes = data.buffer.asUint8List();

  /// Monotonically incremented whenever [data] changes so GPU caches re-upload.
  int version = 0;

  /// Writes [transform], [color], and [instanceData] into slot [index]
  /// (`0 <= index < capacity`) with zero heap allocations.
  void setObject(
    int index,
    Matrix4 transform, {
    Color color = const Color(0xFFFFFFFF),
    Vector4? instanceData,
  }) {
    RangeError.checkValueInInterval(index, 0, capacity - 1, 'index');
    final m = transform.storage;
    final rowBase = modelRowsOffset + index * 12;
    data
      ..[rowBase] = m[0]
      ..[rowBase + 1] = m[4]
      ..[rowBase + 2] = m[8]
      ..[rowBase + 3] = m[12]
      ..[rowBase + 4] = m[1]
      ..[rowBase + 5] = m[5]
      ..[rowBase + 6] = m[9]
      ..[rowBase + 7] = m[13]
      ..[rowBase + 8] = m[2]
      ..[rowBase + 9] = m[6]
      ..[rowBase + 10] = m[10]
      ..[rowBase + 11] = m[14];

    final colBase = _colorsOffset + index * 4;
    data
      ..[colBase] = color.r
      ..[colBase + 1] = color.g
      ..[colBase + 2] = color.b
      ..[colBase + 3] = color.a;

    final datBase = _dataOffset + index * 4;
    if (instanceData == null) {
      data
        ..[datBase] = 0.0
        ..[datBase + 1] = 0.0
        ..[datBase + 2] = 0.0
        ..[datBase + 3] = 0.0;
    } else {
      final d = instanceData.storage;
      data
        ..[datBase] = d[0]
        ..[datBase + 1] = d[1]
        ..[datBase + 2] = d[2]
        ..[datBase + 3] = d[3];
    }
  }

  /// Zeroes the transform rows for slot [index] (`0 <= index < capacity`),
  /// collapsing its vertices cleanly without rebuilding the surface.
  void hideObject(int index) {
    RangeError.checkValueInInterval(index, 0, capacity - 1, 'index');
    final rowBase = modelRowsOffset + index * 12;
    data.fillRange(rowBase, rowBase + 12, 0.0);
  }

  /// Zeroes the entire buffer and bumps [version].
  void clear() {
    data.fillRange(0, data.length, 0.0);
    version++;
  }

  /// Increments [version] after updating slots via [setObject] or [hideObject].
  void markChanged() {
    version++;
  }
}
