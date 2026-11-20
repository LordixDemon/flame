import 'package:flame_3d/src/graphics/backend/gpu_backend.dart';

/// {@template resource}
/// Base lazy GPU resource wrapper (`GpuBuffer`, `GpuTexture`, `GpuShader`).
///
/// The GPU handle is created on first use, and again on the first use after
/// [dispose] or after a device loss (see [GpuBackend.deviceGeneration]), so
/// a resource never hands out a handle of a lost device.
/// {@endtemplate}
abstract class Resource<R>() {
  R? _resource;
  int _generation = 0;
  bool recreateResource = true;

  /// Whether a live GPU resource is currently allocated and up to date.
  bool get hasResource =>
      _resource != null &&
      !recreateResource &&
      _generation == GpuBackend.deviceGeneration;

  R createResource();

  R get resource {
    final generation = GpuBackend.deviceGeneration;
    if (recreateResource || _resource == null || _generation != generation) {
      _resource = createResource();
      _generation = generation;
      recreateResource = false;
    }
    return _resource!;
  }

  /// Releases the cached GPU handle so it can be reclaimed (and lazily
  /// recreated if accessed again).
  void dispose() {
    _resource = null;
    recreateResource = true;
  }
}
