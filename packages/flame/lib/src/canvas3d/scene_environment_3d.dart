import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:meta/meta.dart';

/// Value descriptor for a 3D omni-directional point light in
/// [SceneEnvironment3D].
@immutable
class const PointLight3D({
  required final double x,
  required final double y,
  required final double z,
  required final double radius,
  final Color color = const Color(0xFFFFD89B),
  final double intensity = 1.0,
});

/// Unified 3D scene environment combining a zero-allocation Struct-of-Arrays
/// [PointLight3D] pool and distance/height atmospheric fog for
/// `BatchMeshRenderer3D` and `StaticMeshChunk3D`.
class SceneEnvironment3D({
  int initialLightCapacity = 16,
  var bool fogEnabled = false,
  var Color fogColor = const Color(0xFFB8CCE0),
  var double fogOriginDepth = 12.0,
  var double fogStartDepth = 8.0,
  var double fogEndDepth = 36.0,
  var double fogMaxOpacity = 0.85,
  var double heightFogBaseZ = 0.0,
  var double heightFogFalloff = 1.0,
  var double heightFogDensity = 0.0,
}) {
  Float32List _plX = Float32List(math.max(4, initialLightCapacity));
  Float32List _plY = Float32List(math.max(4, initialLightCapacity));
  Float32List _plZ = Float32List(math.max(4, initialLightCapacity));
  Float32List _plRadius = Float32List(math.max(4, initialLightCapacity));
  Float32List _plInvRadSq = Float32List(math.max(4, initialLightCapacity));
  Float32List _plR = Float32List(math.max(4, initialLightCapacity));
  Float32List _plG = Float32List(math.max(4, initialLightCapacity));
  Float32List _plB = Float32List(math.max(4, initialLightCapacity));
  int _pointLightCount = 0;

  /// Number of active point lights currently in the SoA pool.
  int get pointLightCount => _pointLightCount;

  /// Typed SoA X coordinates of active point lights.
  Float32List get lightX => _plX;

  /// Typed SoA Y coordinates of active point lights.
  Float32List get lightY => _plY;

  /// Typed SoA Z coordinates of active point lights.
  Float32List get lightZ => _plZ;

  /// Typed SoA attenuation radii of active point lights.
  Float32List get lightRadius => _plRadius;

  /// Typed SoA `1 / (radius * radius)` of active point lights.
  Float32List get lightInvRadiusSq => _plInvRadSq;

  /// Typed SoA pre-multiplied linear red (`color.r * intensity`).
  Float32List get lightR => _plR;

  /// Typed SoA pre-multiplied linear green (`color.g * intensity`).
  Float32List get lightG => _plG;

  /// Typed SoA pre-multiplied linear blue (`color.b * intensity`).
  Float32List get lightB => _plB;

  void _ensureCapacity(int needed) {
    if (needed <= _plX.length) {
      return;
    }
    var cap = _plX.length * 2;
    while (cap < needed) {
      cap *= 2;
    }
    _plX = Float32List(cap)..setRange(0, _pointLightCount, _plX);
    _plY = Float32List(cap)..setRange(0, _pointLightCount, _plY);
    _plZ = Float32List(cap)..setRange(0, _pointLightCount, _plZ);
    _plRadius = Float32List(cap)..setRange(0, _pointLightCount, _plRadius);
    _plInvRadSq = Float32List(cap)..setRange(0, _pointLightCount, _plInvRadSq);
    _plR = Float32List(cap)..setRange(0, _pointLightCount, _plR);
    _plG = Float32List(cap)..setRange(0, _pointLightCount, _plG);
    _plB = Float32List(cap)..setRange(0, _pointLightCount, _plB);
  }

  /// Clears all active point lights in `O(1)` without reallocating buffers.
  void clearPointLights() {
    _pointLightCount = 0;
  }

  /// Appends a point light into the SoA pool with zero heap allocations.
  void addPointLight({
    required double x,
    required double y,
    required double z,
    required double radius,
    Color color = const Color(0xFFFFD89B),
    double intensity = 1.0,
  }) {
    if (radius <= 1e-4 || intensity <= 0.0) {
      return;
    }
    final slot = _pointLightCount;
    _ensureCapacity(slot + 1);
    _plX[slot] = x;
    _plY[slot] = y;
    _plZ[slot] = z;
    _plRadius[slot] = radius;
    _plInvRadSq[slot] = 1.0 / (radius * radius);
    _plR[slot] = color.r * intensity;
    _plG[slot] = color.g * intensity;
    _plB[slot] = color.b * intensity;
    _pointLightCount = slot + 1;
  }

  /// Convenience wrapper adding a [PointLight3D] value descriptor.
  void addPointLightDescriptor(PointLight3D light) {
    addPointLight(
      x: light.x,
      y: light.y,
      z: light.z,
      radius: light.radius,
      color: light.color,
      intensity: light.intensity,
    );
  }

  /// Evaluates accumulated `(r, g, b)` irradiance from all overlapping active
  /// point lights at world position `(wx, wy, wz)` with unit normal
  /// `(nx, ny, nz)` using zero heap allocations.
  (double, double, double) samplePointLights({
    required double wx,
    required double wy,
    required double wz,
    required double nx,
    required double ny,
    required double nz,
  }) {
    final count = _pointLightCount;
    if (count == 0) {
      return (0.0, 0.0, 0.0);
    }
    var sumR = 0.0;
    var sumG = 0.0;
    var sumB = 0.0;
    for (var i = 0; i < count; i++) {
      final dx = _plX[i] - wx;
      final r = _plRadius[i];
      if (dx > r || dx < -r) {
        continue;
      }
      final dy = _plY[i] - wy;
      if (dy > r || dy < -r) {
        continue;
      }
      final dz = _plZ[i] - wz;
      if (dz > r || dz < -r) {
        continue;
      }
      final distSq = dx * dx + dy * dy + dz * dz;
      if (distSq >= r * r) {
        continue;
      }
      final t = 1.0 - distSq * _plInvRadSq[i];
      final falloff = t * t;
      double nDotL;
      if (distSq > 1e-8) {
        final invDist = 1.0 / math.sqrt(distSq);
        nDotL = math.max(0.0, (dx * nx + dy * ny + dz * nz) * invDist);
      } else {
        nDotL = 1.0;
      }
      final weight = falloff * (0.22 + 0.78 * nDotL);
      sumR += _plR[i] * weight;
      sumG += _plG[i] * weight;
      sumB += _plB[i] * weight;
    }
    return (sumR, sumG, sumB);
  }

  /// Computes fog blend factor `[0.0 .. fogMaxOpacity]` for a vertex at either
  /// explicit [cameraDistance] or `CameraRig3D.viewDepth` (`fogOriginDepth -
  /// viewDepth`) and world height [worldZ].
  double computeFogFactor({
    required double worldZ,
    double? cameraDistance,
    double? viewDepth,
  }) {
    if (!fogEnabled || fogMaxOpacity <= 0.0) {
      return 0.0;
    }
    final dist = cameraDistance ?? (fogOriginDepth - (viewDepth ?? 0.0));
    var factor = 0.0;
    final span = fogEndDepth - fogStartDepth;
    if (span > 1e-4 && dist > fogStartDepth) {
      final t = ((dist - fogStartDepth) / span).clamp(0.0, 1.0);
      factor = t * t * (3.0 - 2.0 * t);
    }
    if (heightFogDensity > 0.0) {
      final dz = worldZ - heightFogBaseZ;
      final heightAtten = dz <= 0.0
          ? 1.0
          : math.exp(-dz * math.max(0.01, heightFogFalloff));
      final hFactor = (heightFogDensity * heightAtten).clamp(0.0, 1.0);
      factor = 1.0 - (1.0 - factor) * (1.0 - hFactor);
    }
    return (factor * fogMaxOpacity).clamp(0.0, 1.0);
  }

  int _hashFogState(int seed) {
    var h = 0x1fffffff & (seed * 31 + (fogEnabled ? 1 : 0));
    if (fogEnabled) {
      h = 0x1fffffff & (h * 31 + fogColor.toARGB32());
      h = 0x1fffffff & (h * 31 + (fogOriginDepth * 20.0).round());
      h = 0x1fffffff & (h * 31 + (fogStartDepth * 20.0).round());
      h = 0x1fffffff & (h * 31 + (fogEndDepth * 20.0).round());
      h = 0x1fffffff & (h * 31 + (fogMaxOpacity * 200.0).round());
      h = 0x1fffffff & (h * 31 + (heightFogBaseZ * 20.0).round());
      h = 0x1fffffff & (h * 31 + (heightFogFalloff * 50.0).round());
      h = 0x1fffffff & (h * 31 + (heightFogDensity * 200.0).round());
    }
    return h;
  }

  /// Computes a global quantized 31-bit state signature across all active point
  /// lights and fog parameters.
  int computeSignature() {
    var h = 23;
    h = 0x1fffffff & (h * 31 + _pointLightCount);
    for (var i = 0; i < _pointLightCount; i++) {
      h = 0x1fffffff & (h * 31 + (_plX[i] * 20.0).round());
      h = 0x1fffffff & (h * 31 + (_plY[i] * 20.0).round());
      h = 0x1fffffff & (h * 31 + (_plZ[i] * 20.0).round());
      h = 0x1fffffff & (h * 31 + (_plRadius[i] * 20.0).round());
      h = 0x1fffffff & (h * 31 + (_plR[i] * 255.0).round());
      h = 0x1fffffff & (h * 31 + (_plG[i] * 255.0).round());
      h = 0x1fffffff & (h * 31 + (_plB[i] * 255.0).round());
    }
    return _hashFogState(h);
  }

  /// Computes a spatial-AABB-filtered 31-bit signature hashing ONLY active
  /// point lights whose attenuation sphere intersects `[minX..maxX, minY..maxY,
  /// minZ..maxZ]` plus global fog settings.
  ///
  /// Ensures `StaticMeshChunk3D` caches do not re-bake geometry when distant
  /// point lights outside the chunk's AABB move or pulse.
  int computeSignatureForBounds({
    required double minX,
    required double minY,
    required double minZ,
    required double maxX,
    required double maxY,
    required double maxZ,
  }) {
    var h = 29;
    var affecting = 0;
    for (var i = 0; i < _pointLightCount; i++) {
      final lx = _plX[i];
      final ly = _plY[i];
      final lz = _plZ[i];
      final r = _plRadius[i];

      final cx = lx < minX ? minX : (lx > maxX ? maxX : lx);
      final cy = ly < minY ? minY : (ly > maxY ? maxY : ly);
      final cz = lz < minZ ? minZ : (lz > maxZ ? maxZ : lz);
      final dx = lx - cx;
      final dy = ly - cy;
      final dz = lz - cz;
      if (dx * dx + dy * dy + dz * dz >= r * r) {
        continue;
      }
      affecting++;
      h = 0x1fffffff & (h * 31 + (lx * 20.0).round());
      h = 0x1fffffff & (h * 31 + (ly * 20.0).round());
      h = 0x1fffffff & (h * 31 + (lz * 20.0).round());
      h = 0x1fffffff & (h * 31 + (r * 20.0).round());
      h = 0x1fffffff & (h * 31 + (_plR[i] * 255.0).round());
      h = 0x1fffffff & (h * 31 + (_plG[i] * 255.0).round());
      h = 0x1fffffff & (h * 31 + (_plB[i] * 255.0).round());
    }
    h = 0x1fffffff & (h * 31 + affecting);
    return _hashFogState(h);
  }
}
