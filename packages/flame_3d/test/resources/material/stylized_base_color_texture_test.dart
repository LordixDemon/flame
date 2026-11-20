import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_fakes/fake_gpu_backend.dart';

const _shaders = 'packages/flame_3d/assets/shaders';

void main() {
  group('StylizedMaterial base color texture', () {
    late FakeGpuBackend backend;
    late GraphicsDevice device;
    late RenderContext3D context;

    setUp(() {
      // The fake backend lays members out 1024 bytes apart.
      backend = FakeGpuBackend(
        blockSizes: {
          'JointMatrices': 3072,
          'Material': 40 * 1024,
          'Wind': 16 * 1024,
          RenderContext3D.stylizedPassBlock: 40 * 1024,
        },
      );
      device = GraphicsDevice(backend: backend);
      context = RenderContext3D(device);
    });

    void draw(List<Surface> surfaces, {List<Matrix4>? transforms}) {
      device.begin();
      context.setCamera(Matrix4.identity(), Matrix4.identity());
      device.beginPass(const Size(8, 8));
      for (final surface in surfaces) {
        for (final transform in transforms ?? [Matrix4.identity()]) {
          context.drawSurface(surface, transform: transform);
        }
      }
      context.flush();
      device
        ..endPass()
        ..end();
    }

    const positions = <double>[0, 0, 0, 1, 0, 0, 0, 1, 0];
    const normals = <double>[0, 0, 1, 0, 0, 1, 0, 0, 1];
    const texCoords = <double>[0, 0, 1, 0, 0, 1];

    Surface textured(Material material, {bool skinned = false}) {
      return StylizedMaterial.buildSurface(
        positions: positions,
        normals: normals,
        texCoords: texCoords,
        joints: skinned ? [0, 0, 0, 0, 1, 0, 0, 0, 1, 2, 0, 0] : null,
        weights: skinned ? [1, 0, 0, 0, 1, 0, 0, 0, 0.5, 0.5, 0, 0] : null,
        indices: [0, 1, 2],
        material: material,
      );
    }

    Surface plain(Material material) {
      return StylizedMaterial.buildSurface(
        positions: positions,
        normals: normals,
        indices: [0, 1, 2],
        material: material,
      );
    }

    Surface standard(Material material) {
      return Surface(
        vertices: [
          Vertex(position: Vector3.zero(), texCoord: Vector2.zero()),
          Vertex(position: Vector3(1, 0, 0), texCoord: Vector2(1, 0)),
          Vertex(position: Vector3(0, 1, 0), texCoord: Vector2(0, 1)),
        ],
        indices: [0, 1, 2],
        material: material,
      );
    }

    test('lays out the texture coordinates after the stylized layout', () {
      expect(StylizedMaterial.texturedVertexLayout.strideInFloats, 20);
      expect(StylizedMaterial.texturedSkinnedVertexLayout.strideInFloats, 28);
      expect(
        [
          for (final a
              in StylizedMaterial.texturedSkinnedVertexLayout.attributes)
            (a.name, a.components),
        ],
        [
          for (final a in StylizedMaterial.vertexLayout.attributes)
            (a.name, a.components),
          ('vertexTexCoord', 2),
          ('vertexJoints', 4),
          ('vertexWeights', 4),
        ],
      );
    });

    test('buildSurface packs the texture coordinates, joints and weights', () {
      final material = StylizedMaterial();
      final surface = textured(material);
      expect(surface.layout, StylizedMaterial.texturedVertexLayout);
      expect(surface.vertexData.sublist(20 + 18, 20 + 20), [1, 0]);

      final skinned = textured(material, skinned: true);
      expect(skinned.layout, StylizedMaterial.texturedSkinnedVertexLayout);
      // The third vertex: texture coordinates, then joints and weights.
      final third = skinned.vertexData.sublist(56, 84);
      expect(third.sublist(18, 20), [0, 1]);
      expect(third.sublist(20, 24), [1, 2, 0, 0]);
      expect(third.sublist(24, 28), [0.5, 0.5, 0, 0]);

      expect(
        () => StylizedMaterial.buildSurface(
          positions: positions,
          normals: normals,
          texCoords: const [0, 0],
          indices: const [0, 1, 2],
          material: material,
        ),
        throwsArgumentError,
      );
    });

    test('draws with the stages of before without a texture', () {
      final material = StylizedMaterial();
      draw([plain(material), textured(material), standard(material)]);

      expect(
        material.fragmentShader.assetName,
        '$_shaders/stylized_material.shaderbundle',
      );
      expect(
        {for (final p in backend.pipelines) p.fragmentShader},
        hasLength(1),
      );
      // A surface with texture coordinates is drawn as without them.
      expect(
        material.vertexShaderFor(StylizedMaterial.texturedVertexLayout),
        material.vertexShader,
      );
      expect(backend.commands, isNot(contains('bindTexture baseColorTexture')));
    });

    test('draws every layout with texture coordinates with its textured '
        'stage', () {
      final texture = ColorTexture(const Color(0xFF808080));
      final material = StylizedMaterial(baseColorTexture: texture);

      draw([
        textured(material),
        textured(material, skinned: true),
        standard(material),
      ]);

      expect(
        material.fragmentShader.assetName,
        '$_shaders/stylized_material_textured.shaderbundle',
      );
      expect(backend.pipelines, hasLength(3));
      expect(
        {for (final p in backend.pipelines) p.fragmentShader},
        {material.fragmentShader.resource},
      );
      expect(
        [
          for (final layout in [
            StylizedMaterial.texturedVertexLayout,
            StylizedMaterial.texturedSkinnedVertexLayout,
            VertexLayout.standard,
          ])
            material.vertexShaderFor(layout).assetName,
        ],
        [
          '$_shaders/stylized_material_textured.shaderbundle',
          '$_shaders/stylized_material_textured_skinned.shaderbundle',
          '$_shaders/stylized_material_textured_standard.shaderbundle',
        ],
      );
      expect(backend.commands, contains('bindTexture baseColorTexture'));
    });

    test('writes the mode and the alpha cutoff', () {
      final material = StylizedMaterial(
        baseColorTexture: ColorTexture(const Color(0xFFFFFFFF)),
        baseColorTextureMode: BaseColorTextureMode.replace,
        alphaCutoff: 0.4,
      );
      draw([textured(material)]);

      double value(String member) {
        final offset =
            material.fragmentShader
                .slot('Material')
                .getMemberOffsetInBytes(member)! ~/
            4;
        return backend.uniforms['Material']![offset];
      }

      expect(value('baseColorReplace'), 1);
      expect(value('alphaCutoff'), closeTo(0.4, 1e-7));

      material
        ..baseColorTextureMode = BaseColorTextureMode.multiply
        ..alphaCutoff = 0;
      draw([textured(material)]);
      expect(value('baseColorReplace'), 0);
      expect(value('alphaCutoff'), 0);
    });

    test('switches stages when the texture is set and cleared', () {
      final material = StylizedMaterial();
      final plainFragment = material.fragmentShader;
      final surface = textured(material);

      material.baseColorTexture = ColorTexture(const Color(0xFFFF0000));
      draw([surface]);
      final texturedFragment = material.fragmentShader;
      expect(texturedFragment, isNot(plainFragment));
      expect(
        material.vertexShaderFor(surface.layout).assetName,
        '$_shaders/stylized_material_textured.shaderbundle',
      );

      material.baseColorTexture = null;
      draw([surface]);
      expect(material.fragmentShader, plainFragment);
      expect(material.vertexShaderFor(surface.layout), material.vertexShader);
    });

    test('keeps a fragment shader that replaced its own', () {
      final material = StylizedMaterial(
        baseColorTexture: ColorTexture(const Color(0xFFFF0000)),
      );
      final custom = FragmentShader.fromAsset('custom');
      material.fragmentShader = custom;

      expect(material.fragmentShader, custom);
      expect(
        material.vertexShaderFor(StylizedMaterial.vertexLayout),
        material.vertexShader,
      );
    });

    test('refuses surfaces without texture coordinates', () {
      final material = StylizedMaterial(
        baseColorTexture: ColorTexture(const Color(0xFFFF0000)),
      );
      expect(
        () => material.vertexShaderFor(StylizedMaterial.vertexLayout),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('texture coordinates'),
          ),
        ),
      );
      expect(
        () => material.vertexShaderFor(StylizedMaterial.skinnedVertexLayout),
        throwsStateError,
      );
      // Still refused when asked again, and fine once the texture is gone.
      expect(
        () => material.vertexShaderFor(StylizedMaterial.vertexLayout),
        throwsStateError,
      );
      material.baseColorTexture = null;
      expect(
        material.vertexShaderFor(StylizedMaterial.vertexLayout),
        material.vertexShader,
      );
    });

    test('instances of a textured surface are one draw', () {
      final material = StylizedMaterial(
        baseColorTexture: ColorTexture(const Color(0xFF808080)),
      );
      draw(
        [textured(material)],
        transforms: [
          for (var i = 0; i < 12; i++) Matrix4.translationValues(i * 2.0, 0, 0),
        ],
      );
      expect(backend.commands.where((c) => c.startsWith('drawIndexed')), [
        'drawIndexed 3 x12',
      ]);
    });
  });
}
