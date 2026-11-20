import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
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

/// Builds the binary chunk, buffer views and accessors of a test file.
class _Builder() {
  final BytesBuilder bytes = BytesBuilder();
  final List<Map<String, Object?>> views = [];
  final List<Map<String, Object?>> accessors = [];

  int _view(Uint8List data) {
    while (bytes.length % 4 != 0) {
      bytes.addByte(0);
    }
    views.add({
      'buffer': 0,
      'byteOffset': bytes.length,
      'byteLength': data.length,
    });
    bytes.add(data);
    return views.length - 1;
  }

  int floats(List<double> values, String type) {
    final size = switch (type) {
      'SCALAR' => 1,
      'VEC2' => 2,
      'VEC3' => 3,
      'MAT4' => 16,
      _ => 4,
    };
    accessors.add({
      'bufferView': _view(Float32List.fromList(values).buffer.asUint8List()),
      'componentType': 5126,
      'count': values.length ~/ size,
      'type': type,
    });
    return accessors.length - 1;
  }

  int bytesVec4(List<int> values) {
    accessors.add({
      'bufferView': _view(Uint8List.fromList(values)),
      'componentType': 5121,
      'count': values.length ~/ 4,
      'type': 'VEC4',
    });
    return accessors.length - 1;
  }

  int shorts(List<int> values) {
    accessors.add({
      'bufferView': _view(Uint16List.fromList(values).buffer.asUint8List()),
      'componentType': 5123,
      'count': values.length,
      'type': 'SCALAR',
    });
    return accessors.length - 1;
  }

  Uint8List file({
    required List<Map<String, Object?>> nodes,
    required List<Map<String, Object?>> meshes,
    List<Map<String, Object?>> materials = const [],
    List<Map<String, Object?>> skins = const [],
    List<Map<String, Object?>> animations = const [],
    List<String> extensionsUsed = const [],
  }) {
    return _glb({
      'asset': {'version': '2.0'},
      'extensionsUsed': ?(extensionsUsed.isEmpty ? null : extensionsUsed),
      'scene': 0,
      'scenes': [
        {
          'nodes': [for (var i = 0; i < nodes.length; i++) i],
        },
      ],
      'nodes': nodes,
      'meshes': meshes,
      if (materials.isNotEmpty) 'materials': materials,
      if (skins.isNotEmpty) 'skins': skins,
      if (animations.isNotEmpty) 'animations': animations,
      'buffers': [
        {'byteLength': bytes.length},
      ],
      'bufferViews': views,
      'accessors': accessors,
    }, bytes.toBytes());
  }
}

/// Both readers: [ModelParser] and the isolate reader of
/// [AsyncModelLoader3D].
final _readers = <String, Future<Model> Function(Uint8List)>{
  'ModelParser': (bytes) => GlbParser().parseModelBytes(bytes),
  'AsyncModelLoader3D': (bytes) =>
      AsyncModelLoader3D.parseGlbBytesAsync(bytes, buildBvhs: false),
};

List<Surface> _surfaces(Model model) => [
  for (final node in model.nodes.values) ...?node.mesh?.surfaces,
];

List<double> _vertex(Surface surface, int index, int offset, int length) {
  final o = index * surface.layout.strideInFloats + offset;
  return surface.vertexData.sublist(o, o + length).toList();
}

void main() {
  final warnings = <String>[];

  setUp(() {
    FakeGpuBackend();
    warnings.clear();
    GltfWarnings.reset();
    GltfWarnings.onWarning = warnings.add;
  });

  tearDown(() => GltfWarnings.onWarning = null);

  for (final MapEntry(key: reader, value: read) in _readers.entries) {
    group(reader, () {
      test('keeps the 4 largest of 8 joint influences, renormalized', () async {
        final b = _Builder();
        final position = b.floats([0, 0, 0, 1, 0, 0, 0, 1, 0], 'VEC3');
        final joints0 = b.bytesVec4([0, 1, 2, 3, 0, 1, 2, 3, 0, 1, 2, 3]);
        final weights0 = b.floats([
          0.3, 0.1, 0.1, 0.1, //
          1, 0, 0, 0, //
          1, 0, 0, 0, //
        ], 'VEC4');
        final joints1 = b.bytesVec4([4, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        final weights1 = b.floats([
          0.2, 0.2, 0, 0, //
          0, 0, 0, 0, //
          0, 0, 0, 0, //
        ], 'VEC4');
        final ibm = b.floats([
          for (var j = 0; j < 6; j++) ...Matrix4.identity().storage,
        ], 'MAT4');
        final model = await read(
          b.file(
            nodes: [
              {
                'mesh': 0,
                'skin': 0,
                'children': [1, 2, 3, 4, 5, 6],
              },
              for (var j = 0; j < 6; j++) {'name': 'bone$j'},
            ],
            meshes: [
              {
                'primitives': [
                  {
                    'attributes': {
                      'POSITION': position,
                      'JOINTS_0': joints0,
                      'WEIGHTS_0': weights0,
                      'JOINTS_1': joints1,
                      'WEIGHTS_1': weights1,
                    },
                  },
                ],
              },
            ],
            skins: [
              {
                'joints': [1, 2, 3, 4, 5, 6],
                'inverseBindMatrices': ibm,
              },
            ],
          ),
        );
        final surface = _surfaces(model).single;
        final weights = _vertex(surface, 0, 16, 4);
        final joints = _vertex(surface, 0, 12, 4);
        expect(weights.fold<double>(0, (a, w) => a + w), closeTo(1, 1e-6));
        expect(weights[0], closeTo(0.3 / 0.8, 1e-6));
        expect(weights.where((w) => (w - 0.25).abs() < 1e-6), hasLength(2));
        // Joints 4 and 5 (from JOINTS_1) are among the kept influences.
        final skinJoints = {
          for (final MapEntry(:key, :value) in surface.jointMap!.entries)
            value: key,
        };
        final kept = {for (final j in joints) skinJoints[j.toInt()]};
        expect(kept, containsAll([0, 4, 5]));
        expect(
          warnings,
          contains(contains('more than 4 joints keep their 4 largest')),
        );
      });

      test('converts strips and fans, skips points and reports', () async {
        final b = _Builder();
        // A quad as a strip (zigzag order) and as a fan (around the quad).
        final position = b.floats([
          0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 0, //
        ], 'VEC3');
        final around = b.floats([
          0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, //
        ], 'VEC3');
        final model = await read(
          b.file(
            nodes: [
              {'mesh': 0},
            ],
            meshes: [
              {
                'primitives': [
                  {
                    'attributes': {'POSITION': position},
                    'mode': 5,
                  },
                  {
                    'attributes': {'POSITION': around},
                    'mode': 6,
                  },
                  {
                    'attributes': {'POSITION': position},
                    'mode': 0,
                  },
                ],
              },
            ],
          ),
        );
        final surfaces = _surfaces(model);
        expect(surfaces, hasLength(2));
        for (final surface in surfaces) {
          expect(surface.indexCount, 6);
          for (var t = 0; t < 6; t += 3) {
            Vector3 p(int k) =>
                Vector3.array(_vertex(surface, surface.indices[t + k], 0, 3));
            // Strips alternate their winding so every triangle faces +z.
            expect((p(1) - p(0)).cross(p(2) - p(0)).z, greaterThan(0));
          }
        }
        expect(warnings, contains(contains('mode')));
      });

      test('applies the morph weights of the node over the mesh', () async {
        final b = _Builder();
        final position = b.floats([0, 0, 0, 1, 0, 0, 0, 1, 0], 'VEC3');
        final lift = b.floats([0, 0, 2, 0, 0, 2, 0, 0, 2], 'VEC3');
        final model = await read(
          b.file(
            nodes: [
              {
                'mesh': 0,
                'weights': [0.5],
              },
            ],
            meshes: [
              {
                'primitives': [
                  {
                    'attributes': {'POSITION': position},
                    'targets': [
                      {'POSITION': lift},
                    ],
                  },
                ],
                'weights': [0.0],
              },
            ],
          ),
        );
        expect(_vertex(_surfaces(model).single, 1, 0, 3), [1, 0, 1]);
      });

      test('reports unread attributes, extensions and channels once', () async {
        final b = _Builder();
        final position = b.floats([0, 0, 0, 1, 0, 0, 0, 1, 0], 'VEC3');
        final tangent = b.floats([
          for (var i = 0; i < 3; i++) ...[1, 0, 0, 1],
        ], 'VEC4');
        final uv1 = b.floats([0, 0, 1, 0, 0, 1], 'VEC2');
        final times = b.floats([0, 1], 'SCALAR');
        final values = b.floats([0, 1], 'SCALAR');
        final model = await read(
          b.file(
            extensionsUsed: ['KHR_animation_pointer', 'KHR_materials_sheen'],
            nodes: [
              {'mesh': 0},
              {'mesh': 0},
            ],
            meshes: [
              {
                'primitives': [
                  {
                    'attributes': {
                      'POSITION': position,
                      'TANGENT': tangent,
                      'TEXCOORD_1': uv1,
                      '_CUSTOM': uv1,
                    },
                  },
                ],
              },
            ],
            animations: [
              {
                'channels': [
                  {
                    'sampler': 0,
                    'target': {
                      'path': 'pointer',
                      'extensions': {
                        'KHR_animation_pointer': {
                          'pointer': '/materials/0/alphaCutoff',
                        },
                      },
                    },
                  },
                ],
                'samplers': [
                  {'input': times, 'output': values},
                ],
              },
            ],
          ),
        );
        expect(_surfaces(model), hasLength(2));
        expect(
          warnings.where((w) => w.contains('attributes TANGENT are not read')),
          hasLength(1),
        );
        // Kept in Surface.customAttributes, not reported.
        expect(warnings.any((w) => w.contains('TEXCOORD_1')), isFalse);
        expect(warnings.any((w) => w.contains('_CUSTOM')), isFalse);
        expect(
          _surfaces(model).first.customAttributes.keys,
          unorderedEquals(['TEXCOORD_1', '_CUSTOM']),
        );
        expect(
          warnings,
          contains(contains('KHR_animation_pointer, KHR_materials_sheen')),
        );
        expect(warnings, contains(contains('"pointer" are skipped')));
      });
    });
  }

  group('ModelParser', () {
    test('unlit MASK materials blend and report, single-sided cull', () async {
      final b = _Builder();
      final position = b.floats([0, 0, 0, 1, 0, 0, 0, 1, 0], 'VEC3');
      final model = await GlbParser().parseModelBytes(
        b.file(
          extensionsUsed: ['KHR_materials_unlit'],
          nodes: [
            {'mesh': 0},
          ],
          meshes: [
            {
              'primitives': [
                {
                  'attributes': {'POSITION': position},
                  'material': 0,
                },
              ],
            },
          ],
          materials: [
            {
              'alphaMode': 'MASK',
              'extensions': {'KHR_materials_unlit': <String, Object?>{}},
            },
          ],
        ),
      );
      final material = _surfaces(model).single.material as UnlitMaterial;
      expect(material.renderState.blend, isNot(RenderState.opaque.blend));
      expect(material.renderState.cullMode, CullMode.backFace);
      expect(warnings, contains(contains('MASK')));
    });

    test('a mesh transform moves normals and morph deltas correctly', () async {
      final b = _Builder();
      final position = b.floats([0, 0, 0, 1, 0, 0, 0, 1, 0], 'VEC3');
      final normal = b.floats([
        for (var i = 0; i < 3; i++) ...[
          math.sqrt1_2,
          math.sqrt1_2,
          0,
        ],
      ], 'VEC3');
      final lift = b.floats([0, 0, 1, 0, 0, 1, 0, 0, 1], 'VEC3');
      final bytes = b.file(
        nodes: [
          {'mesh': 0},
        ],
        meshes: [
          {
            'primitives': [
              {
                'attributes': {'POSITION': position, 'NORMAL': normal},
                'targets': [
                  {'POSITION': lift},
                ],
              },
            ],
          },
        ],
      );
      final glb = GlbParser().parseGlbBytes(bytes);
      final root = await glb.parse();
      // Stretch x by 2 and move by (5, 0, 0).
      final transform = Matrix4.translationValues(5, 0, 0)
        ..scaleByVector3(Vector3(2, 1, 1));
      final surface = root.meshes[0].toFlameMesh(transform).surfaces.single;

      // The normal of a 45-degree slope stretched along x leans towards y:
      // the inverse transpose divides x by 2.
      final n = Vector3.array(_vertex(surface, 0, 9, 3));
      expect(n.x, closeTo(1 / math.sqrt(5), 1e-5));
      expect(n.y, closeTo(2 / math.sqrt(5), 1e-5));
      // Deltas are not translated.
      expect(surface.morphTargets.single.positionDeltas.sublist(0, 3), [
        0,
        0,
        1,
      ]);
    });
  });
}
