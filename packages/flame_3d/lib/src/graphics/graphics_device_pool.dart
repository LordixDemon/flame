part of 'graphics_device.dart';

class _RenderTargetPool() {
  final List<_PoolBucket> buckets = [];
  final List<_TextureTargetEntry> textureTargets = [];

  void beginFrame() {
    for (var i = 0; i < buckets.length; i++) {
      buckets[i].used = 0;
    }
  }

  GpuRenderTarget acquireRenderTarget(
    GpuBackend backend,
    Color clearValue,
    int frame,
    Size size,
    int msaaSampleCount,
  ) {
    final width = _pixels(size.width);
    final height = _pixels(size.height);
    _PoolBucket? bucket;
    for (var i = 0; i < buckets.length; i++) {
      final b = buckets[i];
      if (b.width == width &&
          b.height == height &&
          b.msaaSampleCount == msaaSampleCount) {
        bucket = b;
        break;
      }
    }
    if (bucket == null) {
      bucket = _PoolBucket(width, height, msaaSampleCount, frame);
      buckets.add(bucket);
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

  GpuTextureTarget acquireTextureTarget(
    GpuBackend backend,
    int frame,
    int width,
    int height,
    GpuPixelFormat format, {
    required Color clearValue,
    required Object? role,
    required int msaaSampleCount,
  }) {
    for (var i = 0; i < textureTargets.length; i++) {
      final entry = textureTargets[i];
      if (entry.width == width &&
          entry.height == height &&
          entry.format == format &&
          entry.msaaSampleCount == msaaSampleCount &&
          entry.clearValue == clearValue &&
          (identical(entry.role, role) || entry.role == role)) {
        entry.lastUsedFrame = frame;
        return entry.target;
      }
    }
    final target = backend.createTextureTarget(
      width: width,
      height: height,
      format: format,
      clearValue: clearValue,
      msaaSampleCount: msaaSampleCount,
    );
    final estimatedBytes =
        width *
        height *
        (format.bytesPerBlock *
                (msaaSampleCount > 1 ? 1 + msaaSampleCount : 1) +
            4 * msaaSampleCount);
    textureTargets.add(
      _TextureTargetEntry(
        width,
        height,
        format,
        clearValue,
        role,
        msaaSampleCount,
        target,
        frame,
        estimatedBytes,
      ),
    );
    return target;
  }

  void touchTextureTarget(GpuTextureTarget target, int frame) {
    for (var i = 0; i < textureTargets.length; i++) {
      final entry = textureTargets[i];
      if (identical(entry.target, target)) {
        entry.lastUsedFrame = frame;
        return;
      }
    }
  }

  void evictUnused(int frame) {
    for (var i = buckets.length - 1; i >= 0; i--) {
      final bucket = buckets[i];
      final used = bucket.used;
      if (used == 0) {
        if (frame - bucket.lastUsedFrame >= GraphicsDevice.targetRetainFrames) {
          buckets.removeAt(i);
        }
      } else {
        bucket.lastUsedFrame = frame;
        final targets = bucket.targets;
        if (used < targets.length) {
          targets.removeRange(used, targets.length);
        }
      }
    }
    for (var i = textureTargets.length - 1; i >= 0; i--) {
      if (frame - textureTargets[i].lastUsedFrame >=
          GraphicsDevice.targetRetainFrames) {
        textureTargets.removeAt(i);
      }
    }
  }

  int get estimatedVramBytes {
    var total = 0;
    for (var i = 0; i < buckets.length; i++) {
      final b = buckets[i];
      // Triple-buffered color + depth-stencil estimate.
      final perTarget = b.width * b.height * 4 * (3 + b.msaaSampleCount);
      total += perTarget * b.targets.length;
    }
    for (var i = 0; i < textureTargets.length; i++) {
      total += textureTargets[i].estimatedBytes;
    }
    return total;
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
