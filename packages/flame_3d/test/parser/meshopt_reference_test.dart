import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/parser.dart';
import 'package:flutter_test/flutter_test.dart';

// Reference vectors of meshoptimizer (`demo/tests.cpp`, MIT license), the
// library that writes the streams of glTF `EXT_meshopt_compression`.

const _indexBuffer = [0, 1, 2, 2, 1, 3, 4, 6, 5, 7, 8, 9];

const _indexDataV0 = [
  0xe0, 0xf0, 0x10, 0xfe, 0xff, 0xf0, 0x0c, 0xff, 0x02, 0x02, 0x02, 0x00, //
  0x76, 0x87, 0x56, 0x67, 0x78, 0xa9, 0x86, 0x65, 0x89, 0x68, 0x98, 0x01, //
  0x69, 0x00, 0x00, //
];

const _indexBufferTricky = [0, 1, 2, 2, 1, 3, 0, 1, 2, 2, 1, 5, 2, 1, 4];

const _indexDataV1 = [
  0xe1, 0xf0, 0x10, 0xfe, 0x1f, 0x3d, 0x00, 0x0a, 0x00, 0x76, 0x87, 0x56, //
  0x67, 0x78, 0xa9, 0x86, 0x65, 0x89, 0x68, 0x98, 0x01, 0x69, 0x00, 0x00, //
];

const _indexDataV1More = [
  0xe1, 0xf0, 0x10, 0xfe, 0xff, 0xf0, 0x0c, 0xff, 0x02, 0x02, 0x02, 0x00, //
  0x76, 0x87, 0x56, 0x67, 0x78, 0xa9, 0x86, 0x65, 0x89, 0x68, 0x98, 0x01, //
  0x69, 0x00, 0x00, //
];

const _indexSequence = [0, 1, 51, 2, 49, 1000];

const _indexSequenceV1 = [
  0xd1, 0x00, 0x04, 0xcd, 0x01, 0x04, 0x07, 0x98, 0x1f, 0x00, 0x00, 0x00, //
  0x00, //
];

/// `struct PV { u16 px, py, pz; u8 nu, nv; u16 tx, ty; }` (12 bytes).
const _vertexBuffer = [
  [0, 0, 0, 0, 0, 0, 0],
  [300, 0, 0, 0, 0, 500, 0],
  [0, 300, 0, 0, 0, 0, 500],
  [300, 300, 0, 0, 0, 500, 500],
];

const _vertexDataV0 = [
  0xa0, 0x01, 0x3f, 0x00, 0x00, 0x00, 0x58, 0x57, 0x58, 0x01, 0x26, 0x00, //
  0x00, 0x00, 0x01, 0x0c, 0x00, 0x00, 0x00, 0x58, 0x01, 0x08, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x3f, 0x00, 0x00, 0x00, 0x17, 0x18, //
  0x17, 0x01, 0x26, 0x00, 0x00, 0x00, 0x01, 0x0c, 0x00, 0x00, 0x00, 0x17, //
  0x01, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, //
];

const _vertexDataV1 = [
  0xa1, 0xee, 0xaa, 0xee, 0x00, 0x4b, 0x4b, 0x4b, 0x00, 0x00, 0x4b, 0x00, //
  0x00, 0x7d, 0x7d, 0x7d, 0x00, 0x00, 0x7d, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x62, 0x00, 0x62, //
];

const _vertexDataV1Custom = [
  0xa1, 0xd4, 0x94, 0xd4, 0x01, 0x0e, 0x00, 0x58, 0x57, 0x58, 0x02, 0x02, //
  0x12, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x58, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x02, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x0e, 0x00, 0x7d, 0x7d, 0x7d, 0x01, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x7d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
  0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x62, //
];

Uint8List _bytes(List<int> values) => Uint8List.fromList(values);

Uint8List _pvBytes() {
  final out = Uint8List(_vertexBuffer.length * 12);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < _vertexBuffer.length; i++) {
    final v = _vertexBuffer[i];
    final b = i * 12;
    bd
      ..setUint16(b, v[0], Endian.little)
      ..setUint16(b + 2, v[1], Endian.little)
      ..setUint16(b + 4, v[2], Endian.little)
      ..setUint8(b + 6, v[3])
      ..setUint8(b + 7, v[4])
      ..setUint16(b + 8, v[5], Endian.little)
      ..setUint16(b + 10, v[6], Endian.little);
  }
  return out;
}

Uint8List _indices32(List<int> values) =>
    Uint32List.fromList(values).buffer.asUint8List();

List<int> _decodeIndices(List<int> stream, int count, {int byteStride = 4}) {
  final bytes = MeshoptDecoder3D.decodeIndexStream(
    _bytes(stream),
    count: count,
    byteStride: byteStride,
  );
  return byteStride == 4
      ? bytes.buffer.asUint32List().toList()
      : bytes.buffer.asUint16List().toList();
}

Uint8List _shorts(List<int> values) {
  final out = Uint8List(values.length * 2);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < values.length; i++) {
    bd.setUint16(i * 2, values[i], Endian.little);
  }
  return out;
}

List<int> _readShorts(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  return [
    for (var i = 0; i < bytes.length ~/ 2; i++)
      bd.getUint16(i * 2, Endian.little),
  ];
}

void main() {
  group('MeshoptDecoder3D against meshoptimizer reference streams', () {
    group('ATTRIBUTES', () {
      test('decodes vertex codec version 0', () {
        final decoded = MeshoptDecoder3D.decodeVertexStream(
          _bytes(_vertexDataV0),
          count: 4,
          byteStride: 12,
        );
        expect(decoded, _pvBytes());
      });

      test('decodes version 0 with 2-bit groups and escapes', () {
        const expected = [
          0, 0, 0, 0, 0, 1, 2, 8, 0, 2, 4, 16, 0, 3, 6, 24, //
          0, 4, 8, 32, 0, 5, 10, 40, 0, 6, 12, 48, 0, 7, 14, 56, //
          0, 8, 16, 64, 0, 9, 18, 72, 0, 10, 20, 80, 0, 11, 22, 88, //
          0, 12, 24, 96, 0, 13, 26, 104, 0, 14, 28, 112, 0, 15, 30, 120, //
        ];
        const input = [
          0xa0, 0x00, 0x01, 0x2a, 0xaa, 0xaa, 0xaa, 0x02, 0x04, 0x44, 0x44, //
          0x44, 0x44, 0x44, 0x44, 0x44, 0x03, 0x00, 0x10, 0x10, 0x10, 0x10, //
          0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, //
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
        ];
        final decoded = MeshoptDecoder3D.decodeVertexStream(
          _bytes(input),
          count: 16,
          byteStride: 4,
        );
        expect(decoded, expected);
      });

      test('decodes version 0 with 4-bit groups', () {
        const expected = [
          0, 0, 0, 0, 4, 5, 6, 7, 8, 10, 12, 14, 12, 15, 18, 21, //
          16, 20, 24, 28, 20, 25, 30, 35, 24, 30, 36, 42, 28, 35, 42, 49, //
          32, 40, 48, 56, 36, 45, 54, 63, 40, 50, 60, 70, 44, 55, 66, 77, //
          48, 60, 72, 84, 52, 65, 78, 91, 56, 70, 84, 98, 60, 75, 90, 105, //
        ];
        const input = [
          0xa0, 0x02, 0x08, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x88, 0x02, //
          0x0a, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0xaa, 0x02, 0x0c, 0xcc, //
          0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0xcc, 0x02, 0x0e, 0xee, 0xee, 0xee, //
          0xee, 0xee, 0xee, 0xee, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
          0x00, 0x00, 0x00, //
        ];
        final decoded = MeshoptDecoder3D.decodeVertexStream(
          _bytes(input),
          count: 16,
          byteStride: 4,
        );
        expect(decoded, expected);
      });

      test('decodes vertex codec version 1, default and custom encodings', () {
        for (final stream in [_vertexDataV1, _vertexDataV1Custom]) {
          final decoded = MeshoptDecoder3D.decodeVertexStream(
            _bytes(stream),
            count: 4,
            byteStride: 12,
          );
          expect(decoded, _pvBytes());
        }
      });

      test('decodes version 1 16-bit delta channels', () {
        const expected = [
          248, 248, 240, 240, 249, 250, 243, 244, 250, 252, 246, 248, //
          251, 254, 249, 252, 252, 256, 252, 256, 253, 258, 255, 260, //
          254, 260, 258, 264, 255, 262, 261, 268, 256, 264, 264, 272, //
          257, 262, 267, 268, 258, 260, 270, 264, 259, 258, 273, 260, //
          260, 256, 276, 256, 261, 254, 279, 252, 262, 252, 282, 248, //
          263, 250, 285, 244, //
        ];
        const input = [
          0xa1, 0x99, 0x99, 0x01, 0x2a, 0xaa, 0xaa, 0xaa, 0x02, 0x04, 0x44, //
          0x44, 0x44, 0x43, 0x33, 0x33, 0x33, 0x02, 0x06, 0x66, 0x66, 0x66, //
          0x66, 0x66, 0x66, 0x66, 0x02, 0x08, 0x88, 0x88, 0x88, 0x87, 0x77, //
          0x77, 0x77, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00, 0x00, 0xf8, 0x00, 0xf8, 0x00, 0xf0, 0x00, //
          0xf0, 0x00, 0x01, 0x01, //
        ];
        final decoded = MeshoptDecoder3D.decodeVertexStream(
          _bytes(input),
          count: 16,
          byteStride: 8,
        );
        expect(_readShorts(decoded), expected);
      });

      test('decodes version 1 1-bit and 2-bit sentinels', () {
        const expected = [
          0xff, 0, 0, 0, 0xfe, 0, 0, 0, 0xfd, 0, 0, 0, 0xfd, 0, 0, 0, //
          0xfd, 0, 0, 0, 0xfc, 0, 0, 0, 0xfb, 0, 0, 0, 0xfb, 0, 0, 0, //
          0xfa, 0, 0, 0, 0xfa, 0, 0, 0, 0xf9, 0, 0, 0, 0xf9, 0, 0, 0, //
          0xf8, 0, 0, 0, //
        ];
        const input = [
          0xa1, 0xa9, 0x01, 0xfc, 0x3c, 0xcc, 0xcc, 0x01, 0x01, 0x01, 0x01, //
          0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, //
        ];
        final decoded = MeshoptDecoder3D.decodeVertexStream(
          _bytes(input),
          count: 13,
          byteStride: 4,
        );
        expect(decoded, expected);
      });

      test('encodes the reference version 0 stream byte for byte', () {
        final encoded = MeshoptDecoder3D.encodeVertexStream(
          _pvBytes(),
          count: 4,
          byteStride: 12,
        );
        expect(encoded, _vertexDataV0);
      });

      test('round-trips bit groups, sentinels, several blocks and tails', () {
        for (final count in [13, 16, 128, 300]) {
          for (final sentinels in [false, true]) {
            final data = Uint8List(count * 4);
            for (var i = 0; i < count; i++) {
              final special = sentinels && (i == 7 || i == 13);
              data[i * 4] = special ? 42 : 0;
              data[i * 4 + 1] = special ? 42 : i & 0xFF;
              data[i * 4 + 2] = special ? 42 : (i * 2) & 0xFF;
              data[i * 4 + 3] = special ? 42 : (i * 8) & 0xFF;
            }
            final encoded = MeshoptDecoder3D.encodeVertexStream(
              data,
              count: count,
              byteStride: 4,
            );
            expect(encoded[0], 0xa0);
            expect(
              MeshoptDecoder3D.decodeVertexStream(
                encoded,
                count: count,
                byteStride: 4,
              ),
              data,
            );
          }
        }
        final empty = MeshoptDecoder3D.encodeVertexStream(
          Uint8List(0),
          count: 0,
          byteStride: 16,
        );
        expect(
          MeshoptDecoder3D.decodeVertexStream(empty, count: 0, byteStride: 16),
          isEmpty,
        );
      });

      test('rejects extra bytes, broken headers and newer versions', () {
        final valid = _bytes(_vertexDataV0);
        expect(
          () => MeshoptDecoder3D.decodeVertexStream(
            _bytes([..._vertexDataV0, 0]),
            count: 4,
            byteStride: 12,
          ),
          throwsFormatException,
        );
        expect(
          () => MeshoptDecoder3D.decodeVertexStream(
            Uint8List.fromList(valid)..[0] = 0,
            count: 4,
            byteStride: 12,
          ),
          throwsFormatException,
        );
        expect(
          () => MeshoptDecoder3D.decodeVertexStream(
            Uint8List.fromList(valid)..[0] = 0xa2,
            count: 4,
            byteStride: 12,
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('version 2'),
            ),
          ),
        );
        for (var cut = 1; cut < valid.length; cut += 7) {
          expect(
            () => MeshoptDecoder3D.decodeVertexStream(
              Uint8List.sublistView(valid, 0, cut),
              count: 4,
              byteStride: 12,
            ),
            throwsFormatException,
          );
        }
      });
    });

    group('TRIANGLES', () {
      test('decodes index codec versions 0 and 1', () {
        expect(_decodeIndices(_indexDataV0, 12), _indexBuffer);
        expect(_decodeIndices(_indexDataV1, 15), _indexBufferTricky);
        expect(_decodeIndices(_indexDataV1More, 12), _indexBuffer);
        expect(_decodeIndices(_indexDataV1More, 12, byteStride: 2), [
          ..._indexBuffer,
        ]);
        const threeEdges = [
          0xe1, 0xf0, 0x20, 0x30, 0x40, 0x00, 0x76, 0x87, 0x56, 0x67, 0x78, //
          0xa9, 0x86, 0x65, 0x89, 0x68, 0x98, 0x01, 0x69, 0x00, 0x00, //
        ];
        expect(_decodeIndices(threeEdges, 12), [
          0, 1, 2, 1, 0, 3, 2, 1, 4, 0, 2, 5, //
        ]);
      });

      test('encodes the reference version 1 streams byte for byte', () {
        expect(
          MeshoptDecoder3D.encodeIndexStream(
            _indices32(_indexBufferTricky),
            count: 15,
            byteStride: 4,
          ),
          _indexDataV1,
        );
        expect(
          MeshoptDecoder3D.encodeIndexStream(
            _indices32(_indexBuffer),
            count: 12,
            byteStride: 4,
          ),
          _indexDataV1More,
        );
      });

      test('rejects extra bytes, broken headers and malformed data', () {
        expect(
          () => _decodeIndices([..._indexDataV1More, 0], 12),
          throwsFormatException,
        );
        expect(
          () => _decodeIndices([0, ..._indexDataV1More.skip(1)], 12),
          throwsFormatException,
        );
        expect(
          () => _decodeIndices([0xef, ..._indexDataV1More.skip(1)], 12),
          throwsFormatException,
        );
        const malformedVByte = [
          0xe1, 0x20, 0x20, 0x20, 0xff, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, //
          0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, 0x20, //
          0x20, 0x20, 0xff, 0xff, 0xff, 0xff, 0x20, 0x20, 0x20, 0x20, 0x20, //
          0x20, 0x20, 0x20, 0x20, 0x20, 0x20, //
        ];
        expect(() => _decodeIndices(malformedVByte, 66), throwsFormatException);
      });
    });

    group('INDICES', () {
      test('decodes and encodes the reference sequence', () {
        expect(_decodeIndices(_indexSequenceV1, 6), _indexSequence);
        expect(
          _decodeIndices(_indexSequenceV1, 6, byteStride: 2),
          _indexSequence,
        );
        expect(
          MeshoptDecoder3D.encodeIndexStream(
            _indices32(_indexSequence),
            count: 6,
            byteStride: 4,
            mode: MeshoptMode3D.indices,
          ),
          _indexSequenceV1,
        );
        expect(
          () => _decodeIndices([..._indexSequenceV1, 0], 6),
          throwsFormatException,
        );
      });
    });

    group('filters', () {
      test('OCTAHEDRAL decodes 8-bit and 16-bit vectors', () {
        final oct8 = Uint8List.fromList(const [
          0, 1, 127, 0, 0, 187, 127, 1, 255, 1, 127, 0, 14, 130, 127, 1, //
        ]);
        MeshoptDecoder3D.decodeFilterOct(oct8, count: 4, byteStride: 4);
        expect(oct8, const [
          0, 1, 127, 0, 0, 159, 82, 1, 255, 1, 127, 0, 1, 130, 241, 1, //
        ]);

        final oct12 = _shorts(const [
          0,
          1,
          2047,
          0,
          0,
          1870,
          2047,
          1,
          2017,
          1,
          2047,
          0,
          14,
          1300,
          2047,
          1,
        ]);
        MeshoptDecoder3D.decodeFilterOct(oct12, count: 4, byteStride: 8);
        expect(_readShorts(oct12), const [
          0, 16, 32767, 0, 0, 32621, 3088, 1, 32764, 16, 471, 0, 307, 28541, //
          16093, 1, //
        ]);
      });

      test('QUATERNION decodes 12-bit quaternions', () {
        final quat = _shorts(const [
          0, 1, 0, 0x7fc, 0, 1870, 0, 0x7fd, 2017, 1, 0, 0x7fe, 14, 1300, 0, //
          0x7ff, //
        ]);
        MeshoptDecoder3D.decodeFilterQuat(quat, count: 4);
        expect(_readShorts(quat), const [
          32767, 0, 11, 0, 0, 25013, 0, 21166, 11, 0, 23504, 22830, 158, //
          14715, 0, 29277, //
        ]);
      });

      test('EXPONENTIAL decodes mantissa and exponent words', () {
        final exp = Uint32List.fromList(const [
          0,
          0xff000003,
          0x02fffff7,
          0xfe7fffff,
        ]);
        MeshoptDecoder3D.decodeFilterExp(
          exp.buffer.asUint8List(),
          count: 4,
          byteStride: 4,
        );
        expect(exp, const [0, 0x3fc00000, 0xc2100000, 0x49fffffe]);
      });

      test('encoders write the reference encodings', () {
        final vectors = [
          Vector4(1, 0, 0, 0),
          Vector4(0, -1, 0, 0),
          Vector4(0.7071068, 0, 0.707168, 1),
          Vector4(-0.7071068, 0, -0.707168, 1),
        ];
        expect(MeshoptDecoder3D.encodeFilterOct(vectors), const [
          0x7f, 0, 0x7f, 0, 0, 0x81, 0x7f, 0, 0x3f, 0, 0x7f, 0x7f, 0x81, //
          0x40, 0x7f, 0x7f, //
        ]);
        expect(
          _readShorts(
            MeshoptDecoder3D.encodeFilterOct(vectors, byteStride: 8, bits: 12),
          ),
          const [
            0x7ff, 0, 0x7ff, 0, 0x0, 0xf801, 0x7ff, 0, 0x3ff, 0, 0x7ff, //
            0x7fff, 0xf801, 0x400, 0x7ff, 0x7fff, //
          ],
        );

        final quats = [
          Quaternion(1, 0, 0, 0),
          Quaternion(0, -1, 0, 0),
          Quaternion(0.7071068, 0, 0, 0.707168),
          Quaternion(-0.7071068, 0, 0, -0.707168),
        ];
        expect(_readShorts(MeshoptDecoder3D.encodeFilterQuat(quats)), const [
          0, 0, 0, 0x7fc, 0, 0, 0, 0x7fd, 0x7ff, 0, 0, 0x7ff, 0x7ff, 0, 0, //
          0x7ff, //
        ]);

        final floats = Float32List.fromList(const [1, -23.4, -0.1, 11.0]);
        Uint32List exp(MeshoptExpMode3D mode) =>
            MeshoptDecoder3D.encodeFilterExp(
              floats,
              count: 2,
              byteStride: 8,
              bits: 15,
              mode: mode,
            ).buffer.asUint32List();
        expect(exp(MeshoptExpMode3D.separate), const [
          0xf3002000,
          0xf7ffd133,
          0xefffcccd,
          0xf6002c00,
        ]);
        expect(exp(MeshoptExpMode3D.sharedVector), const [
          0xf7000200,
          0xf7ffd133,
          0xf6ffff9a,
          0xf6002c00,
        ]);
        expect(exp(MeshoptExpMode3D.sharedComponent), const [
          0xf3002000,
          0xf7ffd133,
          0xf3fffccd,
          0xf7001600,
        ]);
      });
    });

    test('decodeBufferView enforces the constraints of the extension', () {
      expect(
        () => MeshoptDecoder3D.decodeBufferView(
          _bytes(_indexSequenceV1),
          count: 6,
          byteStride: 4,
          mode: MeshoptMode3D.indices,
          filter: MeshoptFilter3D.octahedral,
        ),
        throwsFormatException,
      );
      expect(
        () => MeshoptDecoder3D.decodeBufferView(
          _bytes(_vertexDataV0),
          count: 4,
          byteStride: 12,
          mode: MeshoptMode3D.attributes,
          filter: MeshoptFilter3D.quaternion,
        ),
        throwsFormatException,
      );
      expect(
        MeshoptDecoder3D.decodeBufferView(
          _bytes(_vertexDataV0),
          count: 4,
          byteStride: 12,
          mode: MeshoptMode3D.attributes,
        ),
        _pvBytes(),
      );
    });
  });
}
