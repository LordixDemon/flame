part of 'graphics_device.dart';

extension _GraphicsDevicePool on GraphicsDevice {
  /// Acquire a render target from the pool, creating one if needed.
  GpuRenderTarget _acquireRenderTarget(Size size, int msaaSampleCount) {
    final width = _pixels(size.width);
    final height = _pixels(size.height);
    _PoolBucket? bucket;
    for (var i = 0; i < _poolBuckets.length; i++) {
      final b = _poolBuckets[i];
      if (b.width == width &&
          b.height == height &&
          b.msaaSampleCount == msaaSampleCount) {
        bucket = b;
        break;
      }
    }
    if (bucket == null) {
      bucket = _PoolBucket(width, height, msaaSampleCount, _frame);
      _poolBuckets.add(bucket);
    }
    final index = bucket.used;
    final targets = bucket.targets;
    if (index < targets.length) {
      bucket.used = index + 1;
      return targets[index];
    }

    final target = backend.createRenderTarget(
      width: width,
      height: height,
      clearValue: clearValue,
      msaaSampleCount: msaaSampleCount,
    );

    targets.add(target);
    bucket.used = index + 1;
    return target;
  }

  void _evictUnusedTargets() {
    for (var i = _poolBuckets.length - 1; i >= 0; i--) {
      final bucket = _poolBuckets[i];
      final used = bucket.used;
      if (used == 0) {
        if (_frame - bucket.lastUsedFrame >=
            GraphicsDevice.targetRetainFrames) {
          _poolBuckets.removeAt(i);
        }
      } else {
        bucket.lastUsedFrame = _frame;
        final targets = bucket.targets;
        if (used < targets.length) {
          targets.removeRange(used, targets.length);
        }
      }
    }
    for (var i = _textureTargetList.length - 1; i >= 0; i--) {
      if (_frame - _textureTargetList[i].lastUsedFrame >=
          GraphicsDevice.targetRetainFrames) {
        _textureTargetList.removeAt(i);
      }
    }
  }
}

int _pixels(double size) {
  final pixels = size.round();
  return pixels < 1 ? 1 : pixels;
}

class _PoolBucket(
  this.width,
  this.height,
  this.msaaSampleCount,
  this.lastUsedFrame,
) {
  final int width;
  final int height;
  final int msaaSampleCount;
  final List<GpuRenderTarget> targets = [];
  int used = 0;
  int lastUsedFrame;
}

class _TextureTargetEntry(
  final int width,
  final int height,
  final GpuPixelFormat format,
  final Color clearValue,
  final Object? role,
  final int msaaSampleCount,
  final GpuTextureTarget target,
  var int lastUsedFrame,
  final int estimatedBytes,
);
