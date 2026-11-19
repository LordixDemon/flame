import 'dart:convert';
import 'dart:typed_data';

import 'package:flame_3d/model.dart';
import 'package:flame_3d/parser.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

/// Packs [json] and [bin] into a GLB container.
Uint8List _glb(Map<String, Object?> json, Uint8List bin) {
  final jsonBytes = utf8.encode(jsonEncode(json));
  final jsonLength = (jsonBytes.length + 3) & ~3;
  final binLength = (bin.length + 3) & ~3;
  final out = Uint8List(12 + 8 + jsonLength + 8 + binLength);
  final bd = ByteData.sublistView(out);
  out.setRange(0, 4, 'glTF'.codeUnits);
  bd
    ..setUint32(4, 2, Endian.little)
    ..setUint32(8, out.length, Endian.little)
    ..setUint32(12, jsonLength, Endian.little);
  out
    ..setRange(16, 20, 'JSON'.codeUnits)
    ..setRange(20, 20 + jsonBytes.length, jsonBytes)
    ..fillRange(20 + jsonBytes.length, 20 + jsonLength, 0x20);
  final binStart = 20 + jsonLength;
  bd.setUint32(binStart, binLength, Endian.little);
  out
    ..setRange(binStart + 4, binStart + 8, 'BIN\x00'.codeUnits)
    ..setRange(binStart + 8, binStart + 8 + bin.length, bin);
  return out;
}

/// Appends byte arrays to one buffer, 4-byte aligned, returning views.
class _Bin() {
  final BytesBuilder bytes = BytesBuilder();
  final List<Map<String, Object?>> views = [];

  int add(Uint8List data, {int buffer = 0}) {
    while (bytes.length % 4 != 0) {
      bytes.addByte(0);
    }
    views.add({
      'buffer': buffer,
      'byteOffset': bytes.length,
      'byteLength': data.length,
    });
    bytes.add(data);
    return views.length - 1;
  }
}

Uint8List _floats(List<double> values) =>
    Float32List.fromList(values).buffer.asUint8List();

/// A triangle whose second vertex is moved by a sparse substitution, with a
/// morph target given only by a sparse accessor (no buffer view), as Blender
/// writes shape keys.
Uint8List _sparseGlb() {
  final bin = _Bin();
  final base = bin.add(_floats([0, 0, 0, 1, 0, 0, 0, 1, 0]));
  final sparseIndices = bin.add(Uint8List.fromList([1, 0, 0, 0]));
  final sparseValues = bin.add(_floats([5, 0, 0]));
  final morphIndices = bin.add(
    Uint16List.fromList([2, 0]).buffer.asUint8List(),
  );
  final morphValues = bin.add(_floats([0, 0, 3]));
  return _glb({
    'asset': {'version': '2.0'},
    'scene': 0,
    'scenes': [
      {
        'nodes': [0],
      },
    ],
    'nodes': [
      {'mesh': 0},
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0},
            'targets': [
              {'POSITION': 1},
            ],
          },
        ],
      },
    ],
    'buffers': [
      {'byteLength': bin.bytes.length},
    ],
    'bufferViews': bin.views,
    'accessors': [
      {
        'bufferView': base,
        'componentType': 5126,
        'count': 3,
        'type': 'VEC3',
        'sparse': {
          'count': 1,
          'indices': {'bufferView': sparseIndices, 'componentType': 5121},
          'values': {'bufferView': sparseValues},
        },
      },
      {
        'componentType': 5126,
        'count': 3,
        'type': 'VEC3',
        'sparse': {
          'count': 1,
          'indices': {'bufferView': morphIndices, 'componentType': 5123},
          'values': {'bufferView': morphValues},
        },
      },
    ],
  }, bin.bytes.toBytes());
}

/// A triangle whose positions and indices are `EXT_meshopt_compression`
/// streams, with a fallback buffer that holds no data.
Uint8List _meshoptGlb() {
  final positions = _floats([0, 0, 0, 2, 0, 0, 0, 2, 0, 2, 2, 0]);
  final indices = Uint16List.fromList([0, 1, 2, 2, 1, 3]).buffer.asUint8List();
  final bin = _Bin();
  final posStream = bin.add(
    MeshoptDecoder3D.encodeVertexStream(positions, count: 4, byteStride: 12),
  );
  final idxStream = bin.add(
    MeshoptDecoder3D.encodeIndexStream(indices, count: 6, byteStride: 2),
  );
  Map<String, Object?> view(int stream, int length, int stride, String mode) {
    final compressed = bin.views[stream];
    return {
      'buffer': 1,
      'byteOffset': 0,
      'byteLength': length,
      if (mode == 'ATTRIBUTES') 'byteStride': stride,
      'extensions': {
        'EXT_meshopt_compression': {
          'buffer': 0,
          'byteOffset': compressed['byteOffset'],
          'byteLength': compressed['byteLength'],
          'byteStride': stride,
          'count': length ~/ stride,
          'mode': mode,
        },
      },
    };
  }

  return _glb({
    'asset': {'version': '2.0'},
    'extensionsUsed': ['EXT_meshopt_compression'],
    'extensionsRequired': ['EXT_meshopt_compression'],
    'scene': 0,
    'scenes': [
      {
        'nodes': [0],
      },
    ],
    'nodes': [
      {'mesh': 0},
    ],
    'meshes': [
      {
        'primitives': [
          {
            'attributes': {'POSITION': 0},
            'indices': 1,
          },
        ],
      },
    ],
    'buffers': [
      {'byteLength': bin.bytes.length},
      {
        'byteLength': 60,
        'extensions': {
          'EXT_meshopt_compression': {'fallback': true},
        },
      },
    ],
    'bufferViews': [
      view(posStream, 48, 12, 'ATTRIBUTES'),
      view(idxStream, 12, 2, 'TRIANGLES'),
    ],
    'accessors': [
      {
        'bufferView': 0,
        'componentType': 5126,
        'count': 4,
        'type': 'VEC3',
      },
      {
        'bufferView': 1,
        'componentType': 5123,
        'count': 6,
        'type': 'SCALAR',
      },
    ],
  }, bin.bytes.toBytes());
}

Surface _onlySurface(Model model) =>
    model.nodes.values.single.mesh!.surfaces.single;

List<double> _position(Surface surface, int vertex) {
  final o = vertex * surface.layout.strideInFloats;
  return surface.vertexData.sublist(o, o + 3).toList();
}

void main() {
  setUp(FakeGpuBackend.new);

  group('sparse accessors', () {
    void expectSparse(Model model) {
      final surface = _onlySurface(model);
      expect(_position(surface, 0), [0, 0, 0]);
      expect(_position(surface, 1), [5, 0, 0]);
      expect(_position(surface, 2), [0, 1, 0]);
      final deltas = surface.morphTargets.single.positionDeltas;
      expect(deltas.toList(), [0, 0, 0, 0, 0, 0, 0, 0, 3]);
    }

    test('are applied by ModelParser', () async {
      expectSparse(await GlbParser().parseModelBytes(_sparseGlb()));
    });

    test('are applied by AsyncModelLoader3D', () async {
      expectSparse(
        await AsyncModelLoader3D.parseGlbBytesAsync(
          _sparseGlb(),
          buildBvhs: false,
        ),
      );
    });
  });

  group('EXT_meshopt_compression files', () {
    void expectQuad(Model model) {
      final surface = _onlySurface(model);
      expect(surface.vertexCount, 4);
      expect(_position(surface, 3), [2, 2, 0]);
      final corners = <List<double>>[
        for (final i in surface.indices) _position(surface, i),
      ];
      expect(corners, hasLength(6));
      // Each triangle keeps its corners (possibly rotated).
      final triangles = {
        for (var t = 0; t < 6; t += 3)
          ([
            for (final c in corners.sublist(t, t + 3)) c.join(','),
          ]..sort()).join(' '),
      };
      expect(triangles, {
        '0.0,0.0,0.0 0.0,2.0,0.0 2.0,0.0,0.0',
        '0.0,2.0,0.0 2.0,0.0,0.0 2.0,2.0,0.0',
      });
    }

    test('load through ModelParser', () async {
      expectQuad(await GlbParser().parseModelBytes(_meshoptGlb()));
    });

    test('load through AsyncModelLoader3D', () async {
      expectQuad(
        await AsyncModelLoader3D.parseGlbBytesAsync(
          _meshoptGlb(),
          buildBvhs: false,
        ),
      );
    });
  });
}
