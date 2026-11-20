import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/parser.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';
import 'glb_builder.dart';

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

/// A quad of 4 vertices with application attributes: `_WIND` (VEC3
/// floats), `_MASK` (normalized unsigned bytes), `TEXCOORD_1` and a matrix
/// `_POSE`, which is not kept.
Uint8List _quadFile({List<Map<String, Object?>> materials = const []}) {
  final b = GlbBuilder();
  final position = b.floats([0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0], 'VEC3');
  final normal = b.floats([
    for (var i = 0; i < 4; i++) ...[0, 0, 1],
  ], 'VEC3');
  final uv = b.floats([0, 0, 1, 0, 1, 1, 0, 1], 'VEC2');
  final uv1 = b.floats([0.5, 0.5, 0.75, 0.5, 0.75, 0.75, 0.5, 0.75], 'VEC2');
  final wind = b.floats([
    0, 0.1, 0.2, //
    1, 0.3, 0.4, //
    1, 0.5, 0.6, //
    0, 0.7, 0.8, //
  ], 'VEC3');
  final mask = b.bytesOf([0, 255, 51, 102], 'SCALAR', normalized: true);
  final pose = b.floats([
    for (var i = 0; i < 4; i++) ...Matrix4.identity().storage,
  ], 'MAT4');
  final indices = b.shorts([0, 1, 2, 2, 3, 0]);
  return b.file(
    nodes: [
      {'mesh': 0},
    ],
    meshes: [
      {
        'primitives': [
          {
            'attributes': {
              'POSITION': position,
              'NORMAL': normal,
              'TEXCOORD_0': uv,
              'TEXCOORD_1': uv1,
              '_WIND': wind,
              '_MASK': mask,
              '_POSE': pose,
            },
            'indices': indices,
            if (materials.isNotEmpty) 'material': 0,
          },
        ],
      },
    ],
    materials: materials,
  );
}

/// A strip of 70 quads, each moved by a joint of its own, so that the
/// readers split it into surfaces of at most 64 joints; `_ID` holds the
/// index of each vertex.
Uint8List _skinnedStripFile() {
  const quads = 70;
  final b = GlbBuilder();
  final positions = <double>[];
  final joints = <int>[];
  final weights = <double>[];
  final ids = <double>[];
  final indices = <int>[];
  for (var q = 0; q < quads; q++) {
    for (final (x, y) in const [
      (0.0, 0.0),
      (1.0, 0.0),
      (1.0, 1.0),
      (0.0, 1.0),
    ]) {
      positions.addAll([q + x, y, 0]);
      joints.addAll([q, 0, 0, 0]);
      weights.addAll([1, 0, 0, 0]);
      ids.add(ids.length.toDouble());
    }
    final a = q * 4;
    indices.addAll([a, a + 1, a + 2, a + 2, a + 3, a]);
  }
  final position = b.floats(positions, 'VEC3');
  final joint = b.bytesOf(joints, 'VEC4');
  final weight = b.floats(weights, 'VEC4');
  final id = b.floats(ids, 'SCALAR');
  final index = b.shorts(indices);
  final ibm = b.floats([
    for (var j = 0; j < quads; j++) ...Matrix4.identity().storage,
  ], 'MAT4');
  return b.file(
    nodes: [
      {
        'mesh': 0,
        'skin': 0,
        'children': [for (var j = 1; j <= quads; j++) j],
      },
      for (var j = 0; j < quads; j++) {'name': 'bone$j'},
    ],
    meshes: [
      {
        'primitives': [
          {
            'attributes': {
              'POSITION': position,
              'JOINTS_0': joint,
              'WEIGHTS_0': weight,
              '_ID': id,
            },
            'indices': index,
          },
        ],
      },
    ],
    skins: [
      {
        'joints': [for (var j = 1; j <= quads; j++) j],
        'inverseBindMatrices': ibm,
      },
    ],
  );
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
    group('$reader keeps custom attributes', () {
      test('as floats, normalized, and drops matrices', () async {
        final surface = _surfaces(await read(_quadFile())).single;
        final custom = surface.customAttributes;
        expect(custom.keys, unorderedEquals(['_WIND', '_MASK', 'TEXCOORD_1']));
        expect(custom['_WIND']!.components, 3);
        expect(custom['_WIND']!.values.sublist(3, 6), [
          1,
          closeTo(0.3, 1e-6),
          closeTo(0.4, 1e-6),
        ]);
        expect(custom['_MASK']!.components, 1);
        expect(custom['_MASK']!.values, [
          0,
          1,
          closeTo(0.2, 1e-6),
          closeTo(0.4, 1e-6),
        ]);
        expect(custom['TEXCOORD_1']!.vertexCount, 4);
        expect(
          warnings,
          contains(contains('_POSE (MAT4) is dropped')),
        );
        expect(warnings.any((w) => w.contains('not read')), isFalse);
      });

      test('in each surface of a split skin', () async {
        final surfaces = _surfaces(await read(_skinnedStripFile()));
        expect(surfaces.length, greaterThan(1));
        for (final surface in surfaces) {
          final ids = surface.customAttributes['_ID']!;
          expect(ids.vertexCount, surface.vertexCount);
          // The id of each vertex is where its position came from.
          for (var v = 0; v < surface.vertexCount; v++) {
            final id = ids.values[v].toInt();
            final x = surface.vertexData[v * surface.layout.strideInFloats];
            expect(x, (id ~/ 4) + (id % 4 == 1 || id % 4 == 2 ? 1 : 0));
          }
        }
      });
    });
  }

  group('StylizedVertexMapping', () {
    const mapping = StylizedVertexMapping(
      tint: AttributeChannel('_MASK'),
      accent: AttributeChannel.constant(0.5),
      sway: AttributeChannel('_WIND'),
      windPhase: AttributeChannel('_WIND', 1),
      windFlutter: AttributeChannel('_WIND', 2),
      gloss: AttributeChannel('_GLOSS'),
    );

    test('fills the stylized layout from the custom attributes', () async {
      final model = await GlbParser().parseModelBytes(_quadFile());
      final conversion = mapping.convertModel(model);
      final surface = _surfaces(model).single;

      expect(surface.layout, same(StylizedMaterial.vertexLayout));
      expect(surface.material, isA<StylizedMaterial>());
      expect(conversion.surfaces, 1);
      final v1 = surface.vertexData.sublist(18, 36);
      // Position, normal, white vertex color.
      expect(v1.sublist(0, 10), [1, 0, 0, 0, 0, 1, 1, 1, 1, 1]);
      // Tint, accent, emissive, gloss (missing: 0), occlusion (1).
      expect(v1.sublist(10, 15), [1, 0.5, 0, 0, 1]);
      // Sway, phase, flutter.
      expect(v1.sublist(15, 18), [
        1,
        closeTo(0.3, 1e-6),
        closeTo(0.4, 1e-6),
      ]);
      expect(conversion.mapped, {
        'tint': '_MASK',
        'accent': '0.5',
        'gloss': '_GLOSS',
        'sway': '_WIND',
        'windPhase': '_WIND.y',
        'windFlutter': '_WIND.z',
      });
      expect(conversion.dropped, {'TEXCOORD_1'});
      expect(conversion.missing, {'gloss (_GLOSS)'});
      expect(warnings, contains(contains('mapped tint <- _MASK')));
      expect(
        warnings,
        contains(contains('dropped the custom attributes TEXCOORD_1')),
      );
      expect(warnings, contains(contains('lack gloss (_GLOSS)')));
    });

    test('lays textured surfaces out with their texture coordinates', () async {
      final model = await GlbParser().parseModelBytes(_quadFile());
      final texture = ColorTexture(const Color(0xFF808080));
      const StylizedVertexMapping(texCoord: 'TEXCOORD_1').convertModel(
        model,
        materialFor: (_) => StylizedMaterial(baseColorTexture: texture),
      );
      final surface = _surfaces(model).single;
      expect(surface.layout, same(StylizedMaterial.texturedVertexLayout));
      expect(surface.vertexData.sublist(20 + 18, 20 + 20), [0.75, 0.5]);
    });

    test('bakes the texture transform of a glTF material', () async {
      final model = await GlbParser().parseModelBytes(_quadFile());
      final mesh = model.nodes.values.single.mesh!;
      final source = mesh.surfaces.single;
      final surface = const StylizedVertexMapping().convertSurface(
        source,
        material: StylizedMaterial(
          baseColorTexture: ColorTexture(const Color(0xFFFFFFFF)),
        ),
        uvScale: Vector2(2, 3),
        uvOffset: Vector2(0.5, 0.25),
      );
      // Vertex 2: uv (1, 1).
      expect(surface.vertexData.sublist(40 + 18, 40 + 20), [2.5, 3.25]);
      expect(surface.indices, source.indices);
      expect(surface.aabb.max, source.aabb.max);
    });

    test('keeps joints, weights and joint maps of skinned surfaces', () async {
      final model = await GlbParser().parseModelBytes(_skinnedStripFile());
      final sources = _surfaces(model);
      final ids = [for (final s in sources) s.customAttributes['_ID']];
      const StylizedVertexMapping(occlusion: AttributeChannel('_ID'))
          .convertModel(model);
      final surfaces = _surfaces(model);
      for (final (i, surface) in surfaces.indexed) {
        expect(surface.layout, same(StylizedMaterial.skinnedVertexLayout));
        expect(surface.jointMap, sources[i].jointMap);
        expect(surface.customAttributes['_ID'], same(ids[i]));
        final stride = surface.layout.strideInFloats;
        final source = sources[i];
        final sourceStride = source.layout.strideInFloats;
        for (var v = 0; v < surface.vertexCount; v++) {
          // Joints and weights.
          expect(
            surface.vertexData.sublist(v * stride + 18, v * stride + 26),
            source.vertexData.sublist(
              v * sourceStride + 12,
              v * sourceStride + 20,
            ),
          );
          expect(surface.vertexData[v * stride + 14], ids[i]!.values[v]);
        }
      }
    });

    test('keeps the rest vertices and the morph targets', () {
      final source = Surface.fromBuffers(
        vertices: Float32List.fromList([
          for (var v = 0; v < 3; v++) ...[
            v.toDouble(), 0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 1, //
            0, 0, 0, 0, 0, 0, 0, 0, //
          ],
        ]),
        indices: Uint16List.fromList([0, 1, 2]),
        morphTargets: [
          MorphTargetData(
            positionDeltas: Float32List.fromList([0, 1, 0, 0, 1, 0, 0, 1, 0]),
          ),
        ],
      )..applyMorphWeights([1]);
      expect(source.vertexData[1], 1);

      final surface = const StylizedVertexMapping().convertSurface(
        source,
        material: StylizedMaterial(),
      );
      expect(surface.vertexData[1], 0);
      expect(surface.morphTargets, source.morphTargets);
      surface.applyMorphWeights([0.5]);
      expect(surface.vertexData[1], 0.5);
    });

    test('makes one material per source material', () async {
      final model = await GlbParser().parseModelBytes(
        _quadFile(
          materials: [
            {
              'pbrMetallicRoughness': {
                'baseColorFactor': [1, 0.5, 0.25, 1],
              },
              'alphaMode': 'BLEND',
              'doubleSided': false,
              'emissiveFactor': [1, 0, 0],
            },
          ],
        ),
      );
      final source = _surfaces(model).single.material;
      final conversion = const StylizedVertexMapping().convertModel(model);
      final material = conversion.materials[source]!;
      expect(_surfaces(model).single.material, same(material));
      expect(material.albedoColor, (source as SpatialMaterial).albedoColor);
      expect(material.baseColorTexture, isNull);
      expect(material.renderState.translucent, isTrue);
      expect(material.renderState.cullMode, CullMode.backFace);
      expect(conversion.droppedMaterialParts, {'emissive colors'});
      expect(warnings, contains(contains('dropped the emissive colors')));
    });

    test('primitives that share a glTF material share one', () async {
      final b = GlbBuilder();
      final position = b.floats([0, 0, 0, 1, 0, 0, 0, 1, 0], 'VEC3');
      final model = await GlbParser().parseModelBytes(
        b.file(
          nodes: [
            {'mesh': 0},
          ],
          meshes: [
            {
              'primitives': [
                for (var i = 0; i < 3; i++)
                  {
                    'attributes': {'POSITION': position},
                    'material': i == 2 ? 1 : 0,
                  },
              ],
            },
          ],
          materials: [
            {
              'pbrMetallicRoughness': {
                'baseColorFactor': [1, 0, 0, 1],
              },
            },
            {
              'pbrMetallicRoughness': {
                'baseColorFactor': [0, 0, 1, 1],
              },
            },
          ],
        ),
      );
      final sources = [for (final s in _surfaces(model)) s.material];
      // The reader gives each primitive a material of its own.
      expect(identical(sources[0], sources[1]), isFalse);

      const StylizedVertexMapping().convertModel(model);
      final [first, second, third] = [
        for (final s in _surfaces(model)) s.material,
      ];
      expect(first, same(second));
      expect(third, isNot(same(first)));
    });

    test('materialFrom takes the texture and cutoff of a SpatialMaterial', () {
      final texture = ColorTexture(const Color(0xFF406080));
      final material = StylizedVertexMapping.materialFrom(
        SpatialMaterial(
          albedoColor: const Color(0xFFFFFF00),
          albedoTexture: texture,
          alphaCutoff: 0.5,
        ),
      );
      expect(material.baseColorTexture, same(texture));
      expect(material.alphaCutoff, 0.5);
      expect(material.albedoColor, const Color(0xFFFFFF00));
      final stylized = StylizedMaterial();
      expect(StylizedVertexMapping.materialFrom(stylized), same(stylized));
      final plain = StylizedVertexMapping.materialFrom(SpatialMaterial());
      expect(plain.baseColorTexture, isNull);
    });

    test('copies of a surface share its custom attributes', () async {
      final surface = _surfaces(
        await GlbParser().parseModelBytes(_quadFile()),
      ).single;
      final copy = surface.copyWithOwnVertices();
      expect(
        copy.customAttributes['_WIND'],
        same(surface.customAttributes['_WIND']),
      );
      expect(
        () => copy.customAttributes.remove('_WIND'),
        throwsUnsupportedError,
      );
    });

    test('keeps surfaces already in the stylized layout', () {
      final material = StylizedMaterial();
      final surface = StylizedMaterial.buildSurface(
        positions: const [0, 0, 0, 1, 0, 0, 0, 1, 0],
        normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1],
        tint: const [1, 1, 1],
        indices: const [0, 1, 2],
        material: material,
      );
      final model = Model.simple(mesh: Mesh()..addSurface(surface));
      final conversion = mapping.convertModel(model);
      expect(_surfaces(model).single, same(surface));
      expect(conversion.surfaces, 0);
    });
  });
}
