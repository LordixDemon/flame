import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// Volumetric 3D lattice of `L0..L2` Spherical Harmonics (`SH9`) diffuse
/// irradiance probes over a world-space [bounds] box, backed by a flat
/// zero-allocation `Float32List` (`resolutionX * resolutionY * resolutionZ *`
/// `27` floats).
///
/// Set as `World3D.lightProbeGrid`, it adds its light to the ambient term of
/// `SpatialMaterial` surfaces: each fragment reads the probes around it
/// trilinearly from [volumeTextureFor], the irradiance of each probe along
/// the six axis directions, and rebuilds the irradiance for its normal.
class LightProbeGrid3D({
  required Aabb3 bounds,
  final int resolutionX = 4,
  final int resolutionY = 2,
  final int resolutionZ = 4,
  var double intensity = 1.0,
}) {
  /// Creates an empty [LightProbeGrid3D] covering [bounds] with
  /// `resolutionX * resolutionY * resolutionZ` lattice points (`>= 1` per
  /// axis).
  this
    : assert(
        resolutionX >= 1 && resolutionY >= 1 && resolutionZ >= 1,
        'Grid resolutions must be at least 1 along each axis',
      );

  /// Bakes direct [lights] (`PointLight`, `SpotLight`, `DirectionalLight`,
  /// `HemisphereLight`, `AmbientLight`) into `SH9` diffuse probes at every
  /// lattice node of [bounds].
  factory LightProbeGrid3D.bakeFromLights({
    required Aabb3 bounds,
    required List<Light> lights,
    int resolutionX = 4,
    int resolutionY = 2,
    int resolutionZ = 4,
    double intensity = 1.0,
    Color ambientColor = const Color(0xFFFFFFFF),
    double ambientIntensity = 0.02,
  }) {
    final grid = LightProbeGrid3D(
      bounds: bounds,
      resolutionX: resolutionX,
      resolutionY: resolutionY,
      resolutionZ: resolutionZ,
      intensity: intensity,
    );
    final pos = Vector3.zero();
    final dir = Vector3.zero();
    final sh = List.generate(9, (_) => Vector3.zero());

    for (var iz = 0; iz < resolutionZ; iz++) {
      final tz = resolutionZ > 1 ? iz / (resolutionZ - 1) : 0.5;
      final wz = bounds.min.z + (bounds.max.z - bounds.min.z) * tz;
      for (var iy = 0; iy < resolutionY; iy++) {
        final ty = resolutionY > 1 ? iy / (resolutionY - 1) : 0.5;
        final wy = bounds.min.y + (bounds.max.y - bounds.min.y) * ty;
        for (var ix = 0; ix < resolutionX; ix++) {
          final tx = resolutionX > 1 ? ix / (resolutionX - 1) : 0.5;
          final wx = bounds.min.x + (bounds.max.x - bounds.min.x) * tx;
          pos.setValues(wx, wy, wz);

          for (var c = 0; c < 9; c++) {
            sh[c].setZero();
          }

          // Base omnidirectional ambient term (Y00 integral = 2*sqrt(pi)).
          if (ambientIntensity > 0) {
            const omnidirY00 = 3.5449077;
            sh[0].setValues(
              ambientColor.r * ambientIntensity * omnidirY00,
              ambientColor.g * ambientIntensity * omnidirY00,
              ambientColor.b * ambientIntensity * omnidirY00,
            );
          }

          for (final light in lights) {
            final src = light.source;
            if (src.intensity <= 0) {
              continue;
            }
            if (src is AmbientLight) {
              const omnidirY00 = 3.5449077;
              sh[0].x += src.color.r * src.intensity * omnidirY00;
              sh[0].y += src.color.g * src.intensity * omnidirY00;
              sh[0].z += src.color.b * src.intensity * omnidirY00;
            } else if (src is HemisphereLight) {
              final up = src.up.normalized();
              final avgR = (src.skyColor.r + src.groundColor.r) * 0.5;
              final avgG = (src.skyColor.g + src.groundColor.g) * 0.5;
              final avgB = (src.skyColor.b + src.groundColor.b) * 0.5;
              const omnidirY00 = 3.5449077;
              sh[0].x += avgR * src.intensity * omnidirY00;
              sh[0].y += avgG * src.intensity * omnidirY00;
              sh[0].z += avgB * src.intensity * omnidirY00;
              // The light gives the diffuse light (avg + diff * n.up) times
              // the color: irradiance pi * (avg + diff * n.up), whose band-1
              // coefficients are diff * up * 3 / (2 * 0.488603).
              const l1 = 1.5 / 0.488603;
              final diffR = (src.skyColor.r - src.groundColor.r) * 0.5;
              final diffG = (src.skyColor.g - src.groundColor.g) * 0.5;
              final diffB = (src.skyColor.b - src.groundColor.b) * 0.5;
              final k = src.intensity * l1;
              // SH order: 1 is y, 2 is z, 3 is x.
              sh[1].x += diffR * k * up.y;
              sh[1].y += diffG * k * up.y;
              sh[1].z += diffB * k * up.y;
              sh[2].x += diffR * k * up.z;
              sh[2].y += diffG * k * up.z;
              sh[2].z += diffB * k * up.z;
              sh[3].x += diffR * k * up.x;
              sh[3].y += diffG * k * up.x;
              sh[3].z += diffB * k * up.x;
            } else if (src is DirectionalLight) {
              light.direction(dir);
              _projectDirectionalLobe(
                sh,
                -dir.x,
                -dir.y,
                -dir.z,
                src.color.r * src.intensity,
                src.color.g * src.intensity,
                src.color.b * src.intensity,
              );
            } else if (src is PointLight) {
              final dx = light.position.x - pos.x;
              final dy = light.position.y - pos.y;
              final dz = light.position.z - pos.z;
              final dist = math.max(
                0.25,
                math.sqrt(dx * dx + dy * dy + dz * dz),
              );
              final range = src.range;
              double atten;
              if (range != null && range > 0) {
                final f = math.max(0.0, 1.0 - dist / range);
                atten = src.intensity * f * f;
              } else {
                atten = src.intensity / (dist * dist);
              }
              if (atten > 1e-5) {
                _projectDirectionalLobe(
                  sh,
                  dx / dist,
                  dy / dist,
                  dz / dist,
                  src.color.r * atten,
                  src.color.g * atten,
                  src.color.b * atten,
                );
              }
            } else if (src is SpotLight) {
              final dx = light.position.x - pos.x;
              final dy = light.position.y - pos.y;
              final dz = light.position.z - pos.z;
              final dist = math.max(
                0.25,
                math.sqrt(dx * dx + dy * dy + dz * dz),
              );
              final lx = dx / dist;
              final ly = dy / dist;
              final lz = dz / dist;
              light.direction(dir);
              final cosT = -(lx * dir.x + ly * dir.y + lz * dir.z);
              final cosOuter = math.cos(src.outerConeAngle);
              final cosInner = math.cos(src.innerConeAngle);
              final ang =
                  ((cosT - cosOuter) / math.max(1e-4, cosInner - cosOuter))
                      .clamp(0.0, 1.0);
              if (ang > 0.0) {
                final range = src.range;
                final atten = (range != null && range > 0)
                    ? math
                          .pow(math.max(0.0, 1.0 - dist / range), 2.0)
                          .toDouble()
                    : 1.0 / (dist * dist);
                final e = src.intensity * atten * ang * ang;
                _projectDirectionalLobe(
                  sh,
                  lx,
                  ly,
                  lz,
                  src.color.r * e,
                  src.color.g * e,
                  src.color.b * e,
                );
              }
            }
          }

          grid.setProbeSh9(ix, iy, iz, sh);
        }
      }
    }
    return grid;
  }

  /// World-space AABB spanned by this probe grid.
  final Aabb3 bounds = Aabb3.copy(bounds);

  final Float32List _shData = Float32List(
    resolutionX * resolutionY * resolutionZ * 27,
  );
  int _version = 0;

  final Expando<(int, Texture)> _gpuTextures = Expando('LightProbeGrid3D');

  /// Total number of probes in the 3D lattice.
  int get probeCount => resolutionX * resolutionY * resolutionZ;

  int _nodeOffset(int ix, int iy, int iz) =>
      ((iz * resolutionY + iy) * resolutionX + ix) * 27;

  /// Writes the `9` `RGB` SH coefficients of lattice node `(ix, iy, iz)`.
  void setProbeSh9(int ix, int iy, int iz, List<Vector3> sh9) {
    assert(sh9.length == 9, 'SH9 requires 9 Vector3 coefficients');
    final base = _nodeOffset(
      ix.clamp(0, resolutionX - 1),
      iy.clamp(0, resolutionY - 1),
      iz.clamp(0, resolutionZ - 1),
    );
    for (var c = 0; c < 9; c++) {
      final v = sh9[c];
      _shData[base + c * 3] = v.x;
      _shData[base + c * 3 + 1] = v.y;
      _shData[base + c * 3 + 2] = v.z;
    }
    _version++;
  }

  /// Trilinearly interpolates the `9` `SH9` coefficients at [worldPosition]
  /// into [outSh9] (a list of `9` [Vector3]s) with zero heap allocations.
  void sampleSh9At(Vector3 worldPosition, List<Vector3> outSh9) {
    assert(outSh9.length >= 9, 'outSh9 must hold at least 9 Vector3 elements');
    final spanX = math.max(1e-6, bounds.max.x - bounds.min.x);
    final spanY = math.max(1e-6, bounds.max.y - bounds.min.y);
    final spanZ = math.max(1e-6, bounds.max.z - bounds.min.z);

    final fx =
        ((worldPosition.x - bounds.min.x) / spanX).clamp(0.0, 1.0) *
        (resolutionX - 1);
    final fy =
        ((worldPosition.y - bounds.min.y) / spanY).clamp(0.0, 1.0) *
        (resolutionY - 1);
    final fz =
        ((worldPosition.z - bounds.min.z) / spanZ).clamp(0.0, 1.0) *
        (resolutionZ - 1);

    final x0 = fx.floor().clamp(0, resolutionX - 1);
    final y0 = fy.floor().clamp(0, resolutionY - 1);
    final z0 = fz.floor().clamp(0, resolutionZ - 1);
    final x1 = math.min(x0 + 1, resolutionX - 1);
    final y1 = math.min(y0 + 1, resolutionY - 1);
    final z1 = math.min(z0 + 1, resolutionZ - 1);

    final tx = fx - x0;
    final ty = fy - y0;
    final tz = fz - z0;

    final o000 = _nodeOffset(x0, y0, z0);
    final o100 = _nodeOffset(x1, y0, z0);
    final o010 = _nodeOffset(x0, y1, z0);
    final o110 = _nodeOffset(x1, y1, z0);
    final o001 = _nodeOffset(x0, y0, z1);
    final o101 = _nodeOffset(x1, y0, z1);
    final o011 = _nodeOffset(x0, y1, z1);
    final o111 = _nodeOffset(x1, y1, z1);

    final w000 = (1.0 - tx) * (1.0 - ty) * (1.0 - tz);
    final w100 = tx * (1.0 - ty) * (1.0 - tz);
    final w010 = (1.0 - tx) * ty * (1.0 - tz);
    final w110 = tx * ty * (1.0 - tz);
    final w001 = (1.0 - tx) * (1.0 - ty) * tz;
    final w101 = tx * (1.0 - ty) * tz;
    final w011 = (1.0 - tx) * ty * tz;
    final w111 = tx * ty * tz;

    final d = _shData;
    for (var c = 0; c < 9; c++) {
      final k = c * 3;
      final rx =
          d[o000 + k] * w000 +
          d[o100 + k] * w100 +
          d[o010 + k] * w010 +
          d[o110 + k] * w110 +
          d[o001 + k] * w001 +
          d[o101 + k] * w101 +
          d[o011 + k] * w011 +
          d[o111 + k] * w111;
      final ry =
          d[o000 + k + 1] * w000 +
          d[o100 + k + 1] * w100 +
          d[o010 + k + 1] * w010 +
          d[o110 + k + 1] * w110 +
          d[o001 + k + 1] * w001 +
          d[o101 + k + 1] * w101 +
          d[o011 + k + 1] * w011 +
          d[o111 + k + 1] * w111;
      final rz =
          d[o000 + k + 2] * w000 +
          d[o100 + k + 2] * w100 +
          d[o010 + k + 2] * w010 +
          d[o110 + k + 2] * w110 +
          d[o001 + k + 2] * w001 +
          d[o101 + k + 2] * w101 +
          d[o011 + k + 2] * w011 +
          d[o111 + k + 2] * w111;
      outSh9[c].setValues(rx, ry, rz);
    }
  }

  final List<Vector3> _scratchSh9 = List.generate(9, (_) => Vector3.zero());

  /// Evaluates trilinearly interpolated diffuse irradiance (`RGB`, linear) at
  /// [worldPosition] along unit [normal], times [intensity].
  ///
  /// A Lambertian surface of albedo `a` reflects `a * E / π` of it, which is
  /// what `SpatialMaterial` adds to its ambient term.
  Vector3 sampleIrradiance(
    Vector3 worldPosition,
    Vector3 normal, {
    Vector3? out,
  }) {
    sampleSh9At(worldPosition, _scratchSh9);
    final res = out ?? Vector3.zero();
    final nx = normal.x;
    final ny = normal.y;
    final nz = normal.z;

    final c = _scratchSh9;
    double evalChannel(int ch) {
      double at(int band) =>
          ch == 0 ? c[band].x : (ch == 1 ? c[band].y : c[band].z);
      return at(0) * 0.886227 +
          at(1) * (1.023327 * ny) +
          at(2) * (1.023327 * nz) +
          at(3) * (1.023327 * nx) +
          at(4) * (0.858086 * nx * ny) +
          at(5) * (0.858086 * ny * nz) +
          at(6) * (0.247708 * (3.0 * nz * nz - 1.0)) +
          at(7) * (0.858086 * nx * nz) +
          at(8) * (0.429043 * (nx * nx - ny * ny));
    }

    return res..setValues(
      math.max(0.0, evalChannel(0) * intensity),
      math.max(0.0, evalChannel(1) * intensity),
      math.max(0.0, evalChannel(2) * intensity),
    );
  }

  /// The irradiance that a texel value of `1` stands for in
  /// [volumeTextureFor]: the largest irradiance of the grid along any axis.
  double get volumeTextureRange {
    _packVolume();
    return _packedRange;
  }

  /// Lazily packs the grid into a 2D strip [Texture] for the GPU.
  ///
  /// Every probe is stored as an ambient cube: its irradiance (from the full
  /// `SH9`) along `+X`, `-X`, `+Y`, `-Y`, `+Z` and `-Z`. The texture is
  /// `resolutionX * resolutionZ` texels wide (the `Z` slices side by side)
  /// and `6 * resolutionY` tall (one band of `resolutionY` rows per axis
  /// direction, in that order). A texel holds `sqrt(E / range)` in `RGBA8`,
  /// where `range` is [volumeTextureRange]: dim probes keep their precision
  /// next to bright ones, and nothing clips. With `E+` and `E-` the values
  /// along an axis, a shader rebuilds the irradiance for a normal `n` as the
  /// sum over the axes of `n² (E+ + E-) / 2 + n (E+ - E-) / 2`: the `SH9`
  /// irradiance without the `xy`, `yz` and `zx` terms of band 2.
  Texture volumeTextureFor([GpuBackend? backend]) {
    final b = backend ?? GpuBackend.instance;
    _packVolume();
    final cached = _gpuTextures[b];
    if (cached != null) {
      if (cached.$1 != _version) {
        // Same size and buffer: upload the new texels on the next use.
        cached.$2.recreateResource = true;
        _gpuTextures[b] = (_version, cached.$2);
      }
      return cached.$2;
    }
    final tex = Texture(
      ByteData.sublistView(_packed),
      width: resolutionX * resolutionZ,
      height: resolutionY * 6,
      sampler: TextureSampler.linear,
    );
    _gpuTextures[b] = (_version, tex);
    return tex;
  }

  late final Uint8List _packed = Uint8List(probeCount * 6 * 4);
  late final Float32List _faceIrradiance = Float32List(probeCount * 6 * 3);
  int _packedVersion = -1;
  double _packedRange = 1;

  void _packVolume() {
    if (_packedVersion == _version) {
      return;
    }
    _packedVersion = _version;
    const a0 = 0.886227;
    const a1 = 1.023327;
    const a2zz = 0.247708;
    const a2xy = 0.429043;
    final faces = _faceIrradiance;
    var maxE = 0.0;
    for (var node = 0; node < probeCount; node++) {
      final base = node * 27;
      for (var ch = 0; ch < 3; ch++) {
        final c0 = _shData[base + ch] * a0;
        final c1 = _shData[base + 3 + ch] * a1;
        final c2 = _shData[base + 6 + ch] * a1;
        final c3 = _shData[base + 9 + ch] * a1;
        final c6 = _shData[base + 18 + ch] * a2zz;
        final c8 = _shData[base + 24 + ch] * a2xy;
        final o = node * 18 + ch;
        faces
          ..[o] = math.max(0.0, c0 + c3 - c6 + c8)
          ..[o + 3] = math.max(0.0, c0 - c3 - c6 + c8)
          ..[o + 6] = math.max(0.0, c0 + c1 - c6 - c8)
          ..[o + 9] = math.max(0.0, c0 - c1 - c6 - c8)
          ..[o + 12] = math.max(0.0, c0 + c2 + 2 * c6)
          ..[o + 15] = math.max(0.0, c0 - c2 + 2 * c6);
        for (var f = 0; f < 6; f++) {
          maxE = math.max(maxE, faces[o + f * 3]);
        }
      }
    }
    _packedRange = maxE > 1e-6 ? maxE : 1.0;
    final invRange = 1.0 / _packedRange;
    final width = resolutionX * resolutionZ;
    for (var iz = 0; iz < resolutionZ; iz++) {
      for (var iy = 0; iy < resolutionY; iy++) {
        for (var ix = 0; ix < resolutionX; ix++) {
          final node = (iz * resolutionY + iy) * resolutionX + ix;
          final x = iz * resolutionX + ix;
          for (var f = 0; f < 6; f++) {
            final src = node * 18 + f * 3;
            final dst = ((f * resolutionY + iy) * width + x) * 4;
            for (var ch = 0; ch < 3; ch++) {
              final t = math.sqrt(faces[src + ch] * invRange);
              _packed[dst + ch] = (t.clamp(0.0, 1.0) * 255.0).round();
            }
            _packed[dst + 3] = 255;
          }
        }
      }
    }
  }

  static void _projectDirectionalLobe(
    List<Vector3> sh,
    double lx,
    double ly,
    double lz,
    double r,
    double g,
    double b,
  ) {
    void add(int idx, double basis) {
      sh[idx].x += r * basis;
      sh[idx].y += g * basis;
      sh[idx].z += b * basis;
    }

    add(0, 0.282095);
    add(1, 0.488603 * ly);
    add(2, 0.488603 * lz);
    add(3, 0.488603 * lx);
    add(4, 1.092548 * lx * ly);
    add(5, 1.092548 * ly * lz);
    add(6, 0.315392 * (3.0 * lz * lz - 1.0));
    add(7, 1.092548 * lx * lz);
    add(8, 0.546274 * (lx * lx - ly * ly));
  }
}
