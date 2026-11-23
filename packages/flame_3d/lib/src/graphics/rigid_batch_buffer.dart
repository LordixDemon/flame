import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/core.dart' show Matrix4, Vector4;

/// A reusable per-object uniform table for `RenderContext3D.drawRigidBatch`.
///
/// Packs up to [maxObjects] (40) rigid transforms (as three transposed `vec4`
/// rows each), RGBA tint colors, and per-object `instanceData` vectors into a
/// single `3200`-byte std140 buffer matching `flame_3d/rigid_batch.glsl`'s
/// `BatchObjects` block.
///
/// Keep [version] synced (via [setObject] + [markChanged], or [clear]) so
/// `GraphicsDevice.bindRigidBatch` promotes static tables to a persistent GPU
/// uniform buffer after two unchanged frames.
class RigidBatchBuffer() {
  /// Maximum number of distinct objects packed in a single batch draw.
  static const int maxObjects = 40;

  /// Float offset where `modelRows[120]` (`3 * 40` vec4 rows) begins.
  static const int modelRowsOffset = 0;

  /// Float offset where `colors[40]` begins.
  static const int colorsOffset = 480;

  /// Float offset where `data[40]` begins.
  static const int dataOffset = 640;

  /// Total number of 32-bit floats in [data] (`3200` bytes).
  static const int floatCount = 800;

  /// Packed std140 float storage (`800` floats = `3200` bytes).
  final Float32List data = Float32List(floatCount);

  /// Byte view over [data] uploaded to the uniform buffer.
  late final Uint8List bytes = data.buffer.asUint8List();

  /// Monotonically incremented whenever [data] changes so GPU caches re-upload.
  int version = 0;

  /// Writes [transform], [color], and [instanceData] into slot [index]
  /// (`0 <= index < maxObjects`) with zero heap allocations.
  void setObject(
    int index,
    Matrix4 transform, {
    Color color = const Color(0xFFFFFFFF),
    Vector4? instanceData,
  }) {
    RangeError.checkValueInInterval(index, 0, maxObjects - 1, 'index');
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

    final colBase = colorsOffset + index * 4;
    data
      ..[colBase] = color.r
      ..[colBase + 1] = color.g
      ..[colBase + 2] = color.b
      ..[colBase + 3] = color.a;

    final datBase = dataOffset + index * 4;
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

  /// Zeroes the transform rows for slot [index] (`0 <= index < maxObjects`),
  /// collapsing its vertices cleanly without rebuilding the surface.
  void hideObject(int index) {
    RangeError.checkValueInInterval(index, 0, maxObjects - 1, 'index');
    final rowBase = modelRowsOffset + index * 12;
    data.fillRange(rowBase, rowBase + 12, 0.0);
  }

  /// Zeroes the entire buffer and bumps [version].
  void clear() {
    data.fillRange(0, floatCount, 0.0);
    version++;
  }

  /// Increments [version] after updating slots via [setObject] or [hideObject].
  void markChanged() {
    version++;
  }
}
