import 'package:meta/meta.dart';

/// Configuration for a depth layer rendered inside a single `World3D` color
/// pass by remapping the GPU viewport depth range `[zNear, zFar]` between
/// layer batches.
///
/// Using multiple [DepthLayer3D] entries lets distinct foreground and
/// background layers depth-test cleanly against themselves while guaranteeing
/// strict layer priority ordering within a single render pass.
@immutable
class const DepthLayer3D(
  /// Non-negative layer index (layers flush in ascending [index] order).
  final int index, {

  /// Viewport depth-range lower bound (`0.0..1.0`).
  final double zNear = 0.0,

  /// Viewport depth-range upper bound (`0.0..1.0`).
  final double zFar = 1.0,

  /// Whether draws in this layer use the active `World3D.waterVolume`.
  ///
  /// Set to `false` for foreground overlay layers rendered inside the same
  /// pass above an underwater scene.
  final bool applyWaterVolume = true,
}) {
  this
    : assert(index >= 0, 'index must be non-negative'),
      assert(
        zNear >= 0.0 && zNear <= zFar && zFar <= 1.0,
        'depth range must satisfy 0.0 <= zNear <= zFar <= 1.0',
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DepthLayer3D &&
          index == other.index &&
          zNear == other.zNear &&
          zFar == other.zFar &&
          applyWaterVolume == other.applyWaterVolume;

  @override
  int get hashCode => Object.hash(index, zNear, zFar, applyWaterVolume);

  @override
  String toString() =>
      'DepthLayer3D($index, zNear: $zNear, zFar: $zFar, '
      'applyWaterVolume: $applyWaterVolume)';
}
