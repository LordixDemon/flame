import 'dart:typed_data';

/// Seeded, zero-allocation 2D Simplex noise generator with fractal Brownian
/// motion (`fbm`) support.
///
/// The permutation table is derived from the low 32 bits of the seed with
/// 32-bit integer arithmetic only, so a seed yields the same noise field on
/// the Dart VM, in AOT builds and when compiled to JavaScript or Wasm.
class SimplexNoise2D({int seed = 1337}) {
  this {
    final perm = Uint8List(256);
    for (var i = 0; i < 256; i++) {
      perm[i] = i;
    }
    var state = (seed ^ 0x9E3779B9) & 0xFFFFFFFF;
    for (var i = 255; i > 0; i--) {
      state = (state + 0x6D2B79F5) & 0xFFFFFFFF;
      var z = state;
      z = _imul32(z ^ (z >>> 15), z | 1);
      z = (z ^ (z + _imul32(z ^ (z >>> 7), z | 61))) & 0xFFFFFFFF;
      final rand = (z ^ (z >>> 14)) & 0xFFFFFFFF;
      final j = rand % (i + 1);
      final tmp = perm[i];
      perm[i] = perm[j];
      perm[j] = tmp;
    }
    for (var i = 0; i < 512; i++) {
      final p = perm[i & 255];
      _perm[i] = p;
      _permMod12[i] = p % 12;
    }
  }

  /// Low 32 bits of `a * b` for 32-bit operands, computed in 16-bit halves so
  /// that no intermediate exceeds the 53 bits a JavaScript number holds
  /// exactly.
  static int _imul32(int a, int b) {
    final ah = (a >>> 16) & 0xFFFF;
    final al = a & 0xFFFF;
    final bh = (b >>> 16) & 0xFFFF;
    final bl = b & 0xFFFF;
    return ((al * bl) + (((ah * bl + al * bh) & 0xFFFF) << 16)) & 0xFFFFFFFF;
  }

  static const double _f2 = 0.3660254037844386; // 0.5 * (sqrt(3) - 1)
  static const double _g2 = 0.21132486540518713; // (3 - sqrt(3)) / 6

  static const List<double> _grad2 = <double>[
    1, 1, -1, 1, 1, -1, -1, -1, //
    1, 0, -1, 0, 1, 0, -1, 0, //
    0, 1, 0, -1, 0, 1, 0, -1, //
  ];

  final Uint8List _perm = Uint8List(512);
  final Uint8List _permMod12 = Uint8List(512);

  /// Evaluates single-octave 2D Simplex noise at `(x, y)` in `[-1.0, 1.0]`.
  double sample(double x, double y) {
    final s = (x + y) * _f2;
    final i = (x + s).floor();
    final j = (y + s).floor();
    final t = (i + j) * _g2;
    final x0 = x - (i - t);
    final y0 = y - (j - t);

    final int i1;
    final int j1;
    if (x0 > y0) {
      i1 = 1;
      j1 = 0;
    } else {
      i1 = 0;
      j1 = 1;
    }

    final x1 = x0 - i1 + _g2;
    final y1 = y0 - j1 + _g2;
    final x2 = x0 - 1.0 + 2.0 * _g2;
    final y2 = y0 - 1.0 + 2.0 * _g2;

    final ii = i & 255;
    final jj = j & 255;

    var n0 = 0.0;
    var t0 = 0.5 - x0 * x0 - y0 * y0;
    if (t0 > 0.0) {
      final gi0 = _permMod12[ii + _perm[jj]] * 2;
      t0 *= t0;
      n0 = t0 * t0 * (_grad2[gi0] * x0 + _grad2[gi0 + 1] * y0);
    }

    var n1 = 0.0;
    var t1 = 0.5 - x1 * x1 - y1 * y1;
    if (t1 > 0.0) {
      final gi1 = _permMod12[ii + i1 + _perm[jj + j1]] * 2;
      t1 *= t1;
      n1 = t1 * t1 * (_grad2[gi1] * x1 + _grad2[gi1 + 1] * y1);
    }

    var n2 = 0.0;
    var t2 = 0.5 - x2 * x2 - y2 * y2;
    if (t2 > 0.0) {
      final gi2 = _permMod12[ii + 1 + _perm[jj + 1]] * 2;
      t2 *= t2;
      n2 = t2 * t2 * (_grad2[gi2] * x2 + _grad2[gi2 + 1] * y2);
    }

    return (70.0 * (n0 + n1 + n2)).clamp(-1.0, 1.0);
  }

  /// Evaluates normalized multi-octave fractal Brownian motion (`[-1, 1]`).
  double fbm(
    double x,
    double y, {
    int octaves = 4,
    double lacunarity = 2.0,
    double gain = 0.5,
  }) {
    var sum = 0.0;
    var amplitude = 1.0;
    var frequency = 1.0;
    var norm = 0.0;
    for (var o = 0; o < octaves; o++) {
      sum += sample(x * frequency, y * frequency) * amplitude;
      norm += amplitude;
      amplitude *= gain;
      frequency *= lacunarity;
    }
    return norm > 0.0 ? (sum / norm).clamp(-1.0, 1.0) : 0.0;
  }
}
