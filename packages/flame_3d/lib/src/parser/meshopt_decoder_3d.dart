import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';

part 'meshopt_filters_3d.dart';
part 'meshopt_index_codec_3d.dart';
part 'meshopt_vertex_codec_3d.dart';

/// Stream compression mode defined by glTF `EXT_meshopt_compression`.
enum MeshoptMode3D(final String gltfValue) {
  /// General fixed-stride vertex/accessor attribute stream (`0xA0`).
  attributes('ATTRIBUTES'),

  /// Connected triangle index buffer (`0xE1`, `count % 3 == 0`).
  triangles('TRIANGLES'),

  /// Arbitrary scalar index sequence (`0xD1`).
  indices('INDICES');

  /// Resolves a [MeshoptMode3D] from its glTF JSON string (`ATTRIBUTES`,
  /// `TRIANGLES`, or `INDICES`).
  static MeshoptMode3D valueOf(String value) {
    return values.firstWhere(
      (e) => e.gltfValue == value,
      orElse: () =>
          throw FormatException('Unknown EXT_meshopt_compression mode: $value'),
    );
  }
}

/// Post-decompression attribute filter defined by glTF
/// `EXT_meshopt_compression`.
enum MeshoptFilter3D(final String gltfValue) {
  /// No post-decompression filter.
  none('NONE'),

  /// Octahedral unit-vector decoding (`4 x int8` or `4 x int16`).
  octahedral('OCTAHEDRAL'),

  /// Smallest-three unit-quaternion decoding (`4 x int16`).
  quaternion('QUATERNION'),

  /// 8-bit exponent + 24-bit signed mantissa float32 decoding.
  exponential('EXPONENTIAL');

  /// Resolves a [MeshoptFilter3D] from its glTF JSON string (defaults to
  /// [none] when `null`).
  static MeshoptFilter3D valueOf(String? value) {
    if (value == null || value.isEmpty) {
      return none;
    }
    return values.firstWhere(
      (e) => e.gltfValue == value,
      orElse: () => throw FormatException(
        'Unknown EXT_meshopt_compression filter: $value',
      ),
    );
  }
}

/// How [MeshoptDecoder3D.encodeFilterExp] chooses the exponent of each value.
enum MeshoptExpMode3D() {
  /// Every component of every element gets its own exponent.
  separate,

  /// All components of one element share the largest exponent among them
  /// (the default; what gltfpack uses for positions).
  sharedVector,

  /// Each component index shares the largest exponent across all elements.
  sharedComponent,

  /// Like [separate], but exponents below zero are raised to zero, so values
  /// below 1 lose precision instead of using tiny exponents.
  clamped,
}

const int _vertexHeader = 0xA0;
const int _indexHeader = 0xE0;
const int _sequenceHeader = 0xD0;
const int _maxVertexVersion = 1;
const int _maxIndexVersion = 1;

const int _byteGroupSize = 16;
const int _byteGroupDecodeLimit = 24;
const int _vertexBlockMaxSize = 256;
const int _tailMinSizeV0 = 32;
const int _tailMinSizeV1 = 24;

const List<int> _bitsV0 = <int>[0, 2, 4, 8];
const List<int> _bitsV1 = <int>[0, 1, 2, 4, 8];

const List<int> _codeAuxTable = <int>[
  0x00, 0x76, 0x87, 0x56, //
  0x67, 0x78, 0xA9, 0x86, //
  0x65, 0x89, 0x68, 0x98, //
  0x01, 0x69, 0x00, 0x00, //
];

/// Pure-Dart codec for the bitstreams of glTF 2.0 `EXT_meshopt_compression`,
/// compatible with meshoptimizer (`meshopt_decodeVertexBuffer`,
/// `meshopt_decodeIndexBuffer`, `meshopt_decodeIndexSequence` and the
/// `meshopt_decodeFilter*` functions), running identically on the Dart VM,
/// AOT and the web.
///
/// Decoding reads:
/// - `ATTRIBUTES` streams of vertex codec versions 0 (`0xA0`, the only version
///   `EXT_meshopt_compression` allows) and 1 (`0xA1`, written by
///   meshoptimizer 0.23 and later when asked for it);
/// - `TRIANGLES` streams of index codec versions 0 and 1 (`0xE0`, `0xE1`);
/// - `INDICES` streams (`0xD1`);
/// - the `OCTAHEDRAL`, `QUATERNION` and `EXPONENTIAL` filters, computed in
///   32-bit floating point like the reference.
///
/// A malformed or truncated stream throws a [FormatException]; a stream of a
/// newer codec version throws a [FormatException] naming the version, rather
/// than producing wrong data.
///
/// The encoders write streams that meshoptimizer decodes: vertex codec
/// version 0, index codec version 1, and the filter encodings of
/// `meshopt_encodeFilterOct`, `meshopt_encodeFilterQuat` and
/// `meshopt_encodeFilterExp`. They are meant for tests and small procedural
/// assets, not as a replacement for gltfpack.
abstract final class MeshoptDecoder3D._() {
  static final Float32List _f32 = Float32List(1);
  static final ByteData _bits = ByteData(4);

  /// Decompresses a complete `EXT_meshopt_compression` buffer view slice and
  /// applies [filter] in place when `mode == MeshoptMode3D.attributes`.
  ///
  /// Checks the constraints of the extension (strides per mode and filter,
  /// filters only on attributes) and throws a [FormatException] when one does
  /// not hold.
  static Uint8List decodeBufferView(
    Uint8List compressed, {
    required int count,
    required int byteStride,
    required MeshoptMode3D mode,
    MeshoptFilter3D filter = MeshoptFilter3D.none,
  }) {
    switch (mode) {
      case MeshoptMode3D.attributes:
        if (byteStride <= 0 || byteStride > 256 || byteStride % 4 != 0) {
          throw FormatException(
            'EXT_meshopt_compression ATTRIBUTES needs a byteStride divisible '
            'by 4 and at most 256, got $byteStride',
          );
        }
        _checkFilterStride(filter, byteStride);
        final out = decodeVertexStream(
          compressed,
          count: count,
          byteStride: byteStride,
        );
        applyFilterInPlace(
          out,
          count: count,
          byteStride: byteStride,
          filter: filter,
        );
        return out;
      case MeshoptMode3D.triangles:
      case MeshoptMode3D.indices:
        if (filter != MeshoptFilter3D.none) {
          throw FormatException(
            'EXT_meshopt_compression filter ${filter.gltfValue} is only '
            'allowed with ATTRIBUTES, not ${mode.gltfValue}',
          );
        }
        if (byteStride != 2 && byteStride != 4) {
          throw FormatException(
            'EXT_meshopt_compression ${mode.gltfValue} needs a byteStride of '
            '2 or 4, got $byteStride',
          );
        }
        return decodeIndexStream(
          compressed,
          count: count,
          byteStride: byteStride,
          mode: mode,
        );
    }
  }

  static void _checkFilterStride(MeshoptFilter3D filter, int byteStride) {
    final ok = switch (filter) {
      MeshoptFilter3D.none => true,
      MeshoptFilter3D.octahedral => byteStride == 4 || byteStride == 8,
      MeshoptFilter3D.quaternion => byteStride == 8,
      MeshoptFilter3D.exponential => byteStride % 4 == 0,
    };
    if (!ok) {
      throw FormatException(
        'EXT_meshopt_compression filter ${filter.gltfValue} does not allow '
        'a byteStride of $byteStride',
      );
    }
  }

  /// Compresses [vertices] (`count * byteStride` bytes, `byteStride` a
  /// multiple of `4` in `4..256`) into an `ATTRIBUTES` stream of vertex codec
  /// version 0 (`0xA0`), as `meshopt_encodeVertexBuffer` writes it with
  /// version 0.
  static Uint8List encodeVertexStream(
    Uint8List vertices, {
    required int count,
    required int byteStride,
  }) => _encodeVertexStream(vertices, count: count, byteStride: byteStride);

  /// Decompresses an `ATTRIBUTES` stream (vertex codec version 0 or 1) into
  /// `count * byteStride` bytes.
  static Uint8List decodeVertexStream(
    Uint8List encoded, {
    required int count,
    required int byteStride,
  }) => _decodeVertexStream(encoded, count: count, byteStride: byteStride);

  /// Compresses `count` `Uint16` (`byteStride == 2`) or `Uint32`
  /// (`byteStride == 4`) indices into a `TRIANGLES` stream of index codec
  /// version 1 (`0xE1`) or an `INDICES` stream (`0xD1`).
  ///
  /// The triangle codec may rotate the corners of a triangle (keeping its
  /// winding), as meshoptimizer does.
  static Uint8List encodeIndexStream(
    Uint8List indices, {
    required int count,
    required int byteStride,
    MeshoptMode3D mode = MeshoptMode3D.triangles,
  }) => _encodeIndexStream(
    indices,
    count: count,
    byteStride: byteStride,
    mode: mode,
  );

  /// Decompresses a `TRIANGLES` (`0xE0`/`0xE1`) or `INDICES` (`0xD1`) stream
  /// into `count * byteStride` little-endian index bytes.
  ///
  /// When [mode] is given, a stream of the other kind throws a
  /// [FormatException]; otherwise the header decides.
  static Uint8List decodeIndexStream(
    Uint8List encoded, {
    required int count,
    required int byteStride,
    MeshoptMode3D? mode,
  }) => _decodeIndexStream(
    encoded,
    count: count,
    byteStride: byteStride,
    mode: mode,
  );

  /// Applies the decoding of [filter] in place across [count] elements of
  /// [byteStride] bytes in [buffer].
  static void applyFilterInPlace(
    Uint8List buffer, {
    required int count,
    required int byteStride,
    required MeshoptFilter3D filter,
  }) => _applyFilterInPlace(
    buffer,
    count: count,
    byteStride: byteStride,
    filter: filter,
  );

  /// Encodes unit vectors `(x, y, z, w)` for the `OCTAHEDRAL` filter, like
  /// `meshopt_encodeFilterOct`: `byteStride == 4` stores `4 x int8` with
  /// [bits] in `2..8`, `byteStride == 8` stores `4 x int16` with [bits] in
  /// `2..16`. `w` (a tangent's handedness, for example) is stored as a
  /// normalized 8-bit or 16-bit value.
  static Uint8List encodeFilterOct(
    List<Vector4> vectors, {
    int byteStride = 4,
    int bits = 8,
  }) => _encodeFilterOct(vectors, byteStride: byteStride, bits: bits);

  /// Decodes `OCTAHEDRAL`-filtered vectors in place into normalized `int8`
  /// (`byteStride == 4`) or `int16` (`byteStride == 8`) components, like
  /// `meshopt_decodeFilterOct`. The fourth component passes through.
  static void decodeFilterOct(
    Uint8List buffer, {
    required int count,
    required int byteStride,
  }) => _decodeFilterOct(buffer, count: count, byteStride: byteStride);

  /// Encodes unit quaternions `(x, y, z, w)` as smallest-three `4 x int16`
  /// records (`byteStride == 8`) for the `QUATERNION` filter, like
  /// `meshopt_encodeFilterQuat`; [bits] is in `4..16`. The quaternions are
  /// expected to be unit length.
  static Uint8List encodeFilterQuat(
    List<Quaternion> rotations, {
    int bits = 12,
  }) => _encodeFilterQuat(rotations, bits: bits);

  /// Decodes `QUATERNION`-filtered `4 x int16` records (`byteStride == 8`) in
  /// place into normalized `int16` quaternions, like
  /// `meshopt_decodeFilterQuat`.
  static void decodeFilterQuat(
    Uint8List buffer, {
    required int count,
    int byteStride = 8,
  }) => _decodeFilterQuat(buffer, count: count, byteStride: byteStride);

  /// Encodes `count * (byteStride ~/ 4)` floats as `(8-bit exponent |
  /// 24-bit signed mantissa)` words for the `EXPONENTIAL` filter, like
  /// `meshopt_encodeFilterExp`; [bits] (`1..24`) is the mantissa precision
  /// and [mode] how exponents are shared.
  static Uint8List encodeFilterExp(
    Float32List floats, {
    required int count,
    required int byteStride,
    int bits = 16,
    MeshoptExpMode3D mode = MeshoptExpMode3D.sharedVector,
  }) => _encodeFilterExp(
    floats,
    count: count,
    byteStride: byteStride,
    bits: bits,
    mode: mode,
  );

  /// Decodes `EXPONENTIAL`-filtered words in place into IEEE-754 `float32`
  /// values (`2^e * m`), like `meshopt_decodeFilterExp`.
  static void decodeFilterExp(
    Uint8List buffer, {
    required int count,
    required int byteStride,
  }) => _decodeFilterExp(buffer, count: count, byteStride: byteStride);
}

void _checkVertexParams(int count, int byteStride) {
  if (count < 0) {
    throw ArgumentError.value(count, 'count', 'Must be >= 0');
  }
  if (byteStride < 4 || byteStride > 256 || byteStride % 4 != 0) {
    throw ArgumentError.value(
      byteStride,
      'byteStride',
      'Must be a multiple of 4 in [4..256]',
    );
  }
}

/// Elements per attribute block; part of the format.
int _vertexBlockSize(int byteStride) =>
    math.min((8192 ~/ byteStride) & ~15, _vertexBlockMaxSize);

int _align16(int v) => (v + 15) & ~15;

int _zigzag8(int v) => ((v << 1) ^ ((v & 0x80) != 0 ? 0xFF : 0)) & 0xFF;

int _unzigzag8(int v) => ((v >> 1) ^ ((v & 1) != 0 ? 0xFF : 0)) & 0xFF;

int _unzigzag16(int v) => ((v >> 1) ^ ((v & 1) != 0 ? 0xFFFF : 0)) & 0xFFFF;

int _rotl32(int v, int r) => ((v << r) | (v >>> ((32 - r) & 31))) & 0xFFFFFFFF;

int _reverseBits8(int v) {
  var r = 0;
  for (var i = 0; i < 8; i++) {
    r |= ((v >> i) & 1) << (7 - i);
  }
  return r;
}

void _writeVByte(int value, BytesBuilder out) {
  var v = value;
  do {
    out.addByte((v & 127) | (v > 127 ? 128 : 0));
    v >>>= 7;
  } while (v != 0);
}

String _hex(int byte) => byte.toRadixString(16).padLeft(2, '0');

/// Rounds [v] to the nearest 32-bit float, so results match the reference's
/// `float` arithmetic.
double _f(double v) {
  MeshoptDecoder3D._f32[0] = v;
  return MeshoptDecoder3D._f32[0];
}

int _quantizeSnorm(double value, int n) {
  if (value.isNaN) {
    return 0;
  }
  final scale = ((1 << (n - 1)) - 1).toDouble();
  final round = value >= 0 ? 0.5 : -0.5;
  final v = value < -1.0 ? -1.0 : (value > 1.0 ? 1.0 : value);
  return _f(_f(v * scale) + round).toInt();
}

/// Truncates [v] toward zero like a C `int` cast, with `0` for the
/// undefined cases (NaN, infinities) of malformed input.
int _trunc(double v) => v.isFinite ? v.toInt() : 0;

/// The exponent of [v] plus one, like the reference `optlog2`.
int _optLog2(double v) {
  MeshoptDecoder3D._bits.setFloat32(0, v);
  return ((MeshoptDecoder3D._bits.getUint32(0) >> 23) & 0xFF) - 127 + 1;
}

/// `2^e` as a float built from its bits, like the reference `optexp2`.
double _optExp2(int e) {
  MeshoptDecoder3D._bits.setUint32(0, ((e + 127) << 23) & 0xFFFFFFFF);
  return MeshoptDecoder3D._bits.getFloat32(0);
}

/// A read cursor over a byte list for variable-length integers.
class _Cursor(final Uint8List bytes) {
  int position = 0;

  /// Reads a little-endian base-128 integer of at most 5 bytes, like the
  /// reference `decodeVByte`.
  int readVByte() {
    if (position >= bytes.length) {
      throw const FormatException('Truncated meshopt varint');
    }
    final lead = bytes[position++];
    if (lead < 128) {
      return lead;
    }
    var result = lead & 127;
    var shift = 7;
    for (var i = 0; i < 4; i++) {
      if (position >= bytes.length) {
        throw const FormatException('Truncated meshopt varint');
      }
      final group = bytes[position++];
      result |= (group & 127) << shift;
      shift += 7;
      if (group < 128) {
        break;
      }
    }
    return result & 0xFFFFFFFF;
  }
}
