part of 'graphics_device.dart';

extension _GraphicsDevicePool on GraphicsDevice {
  /// Acquire a render target from the pool, creating one if needed.
  GpuRenderTarget _acquireRenderTarget(Size size, int msaaSampleCount) {
    final key = (
      _pixels(size.width),
      _pixels(size.height),
      msaaSampleCount,
    );
    final bucket = _pool[key] ??= _PoolBucket(_frame);
    final index = bucket.used;
    final targets = bucket.targets;
    if (index < targets.length) {
      bucket.used = index + 1;
      return targets[index];
    }

    final target = backend.createRenderTarget(
      width: key.$1,
      height: key.$2,
      clearValue: clearValue,
      msaaSampleCount: key.$3,
    );

    targets.add(target);
    bucket.used = index + 1;
    return target;
  }

  void _evictUnusedTargets() {
    if (_pool.isNotEmpty) {
      _evictPoolKeys.clear();
      for (final entry in _pool.entries) {
        final bucket = entry.value;
        final used = bucket.used;
        if (used == 0) {
          if (_frame - bucket.lastUsedFrame >=
              GraphicsDevice.targetRetainFrames) {
            _evictPoolKeys.add(entry.key);
          }
        } else {
          bucket.lastUsedFrame = _frame;
          final targets = bucket.targets;
          if (used < targets.length) {
            targets.removeRange(used, targets.length);
          }
        }
      }
      for (var i = 0; i < _evictPoolKeys.length; i++) {
        _pool.remove(_evictPoolKeys[i]);
      }
    }
    if (_textureTargets.isNotEmpty) {
      _evictTextureKeys.clear();
      for (final entry in _textureTargets.entries) {
        if (_frame - entry.value.lastUsedFrame >=
            GraphicsDevice.targetRetainFrames) {
          _evictTextureKeys.add(entry.key);
        }
      }
      for (var i = 0; i < _evictTextureKeys.length; i++) {
        _textureTargets.remove(_evictTextureKeys[i]);
      }
    }
  }
}

int _pixels(double size) {
  final pixels = size.round();
  return pixels < 1 ? 1 : pixels;
}

class _PoolBucket(this.lastUsedFrame) {
  final List<GpuRenderTarget> targets = [];
  int used = 0;
  int lastUsedFrame;
}

class _TextureTargetEntry(
  final GpuTextureTarget target,
  var int lastUsedFrame,
  final int estimatedBytes,
);
