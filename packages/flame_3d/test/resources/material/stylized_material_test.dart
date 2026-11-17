import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../_fakes/fake_gpu_backend.dart';

void main() {
  group('StylizedMaterial', () {
    late FakeGpuBackend backend;
    late GraphicsDevice device;
    late RenderContext3D context;

    setUp(() {
      // The fake backend lays members out 1024 bytes apart.
      backend = FakeGpuBackend(
        blockSizes: {'JointMatrices': 1024, 'Material': 16 * 1024},
      );
      device = GraphicsDevice(backend: backend);
      context = RenderContext3D(device);
    });

    void draw(List<Surface> surfaces) {
      device.begin();
      context.setCamera(Matrix4.identity(), Matrix4.identity());
      device.beginPass(const Size(8, 8));
      for (final surface in surfaces) {
        context.drawSurface(surface);
      }
      context.flush();
      device
        ..endPass()
        ..end();
    }

    Surface stylizedTriangle(Material material) {
      return StylizedMaterial.buildSurface(
        positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
        normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: [0, 1, 2],
        material: material,
      );
    }

    Surface standardTriangle(Material material) {
      return Surface(
        vertices: [
          Vertex(position: Vector3.zero(), texCoord: Vector2.zero()),
          Vertex(position: Vector3(1, 0, 0), texCoord: Vector2.zero()),
          Vertex(position: Vector3(0, 1, 0), texCoord: Vector2.zero()),
        ],
        indices: [0, 1, 2],
        material: material,
      );
    }

    test('lays out 16 floats per vertex', () {
      final layout = StylizedMaterial.vertexLayout;

      expect(layout.strideInFloats, 16);
      expect(
        [for (final a in layout.attributes) (a.name, a.components)],
        [
          ('vertexPosition', 3),
          ('vertexNormal', 3),
          ('vertexColor', 4),
          ('vertexMasks', 4),
          ('vertexOcclusion', 1),
          ('vertexSway', 1),
        ],
      );
    });

    test('draws its layout and the standard one with a variant each', () {
      final material = StylizedMaterial();

      draw([stylizedTriangle(material), standardTriangle(material)]);

      expect(backend.pipelines, hasLength(2));
      final [first, second] = backend.pipelines;
      expect(identical(first.vertexShader, second.vertexShader), isFalse);
      expect(identical(first.fragmentShader, second.fragmentShader), isTrue);
      expect(
        material.vertexShaderFor(StylizedMaterial.vertexLayout),
        material.vertexShader,
      );
      expect(
        material.vertexShaderFor(VertexLayout.standard),
        isNot(material.vertexShader),
      );
    });

    test('writes its values into its uniform blocks', () {
      final material = StylizedMaterial(
        accentColor: const Color(0xFF336699),
        skyFill: 0.4,
        specularPower: 16,
        windTime: 2.5,
        windDirection: Vector3(0, 0, 1),
      );

      draw([stylizedTriangle(material)]);

      double value(Shader shader, String block, String member) {
        final offset = shader.slot(block).getMemberOffsetInBytes(member)! ~/ 4;
        return backend.uniforms[block]![offset];
      }

      final fragment = material.fragmentShader;
      final vertex = material.vertexShader;
      expect(value(fragment, 'Material', 'skyFill'), closeTo(0.4, 1e-6));
      expect(value(fragment, 'Material', 'specularPower'), 16);
      expect(value(fragment, 'Material', 'groundBounce'), closeTo(0.1, 1e-6));
      // Without MatCap texture, it has no effect.
      expect(value(fragment, 'Material', 'matCapStrength'), 0);
      expect(value(vertex, 'Wind', 'time'), 2.5);
      expect(value(vertex, 'Wind', 'frequency'), closeTo(2.3, 1e-6));
      final direction =
          vertex.slot('Wind').getMemberOffsetInBytes('direction')! ~/ 4;
      expect(
        backend.uniforms['Wind']!.sublist(direction, direction + 3),
        [0, 0, 1],
      );
      final accent =
          fragment.slot('Material').getMemberOffsetInBytes('accentColor')! ~/ 4;
      expect(
        backend.uniforms['Material']!.sublist(accent, accent + 3),
        pairwiseCompare<double, double>(
          [0.2, 0.4, 0.6],
          (a, b) => (a - b).abs() < 1e-6,
          'close to',
        ),
      );
      expect(backend.textureBindings.keys, contains('matCapTexture'));
    });

    test('binds its MatCap texture with its strength', () {
      final matCap = ColorTexture(const Color(0xFFFF0000));
      final material = StylizedMaterial(
        matCapTexture: matCap,
        matCapStrength: 0.75,
      );

      draw([stylizedTriangle(material)]);

      final offset =
          material.fragmentShader
              .slot('Material')
              .getMemberOffsetInBytes('matCapStrength')! ~/
          4;
      expect(backend.uniforms['Material']![offset], 0.75);
      expect(
        identical(
          backend.textureBindings['matCapTexture']!.$1,
          matCap.resource,
        ),
        isTrue,
      );
    });

    group('buildSurface', () {
      test('packs the vertex arrays, with defaults', () {
        final surface = StylizedMaterial.buildSurface(
          positions: [1, 2, 3, 4, 5, 6],
          normals: [0, 1, 0, 0, 0, 1],
          colors: [0.1, 0.2, 0.3, 1, 0.5, 0.6, 0.7, 0.8],
          gloss: [0.5, 2],
          sway: [0, 1],
          indices: [0, 1, 0],
          material: StylizedMaterial(),
        );

        expect(surface.layout, StylizedMaterial.vertexLayout);
        expect(surface.vertexCount, 2);
        expect(
          surface.vertexData,
          Float32List.fromList([
            1, 2, 3, 0, 1, 0, 0.1, 0.2, 0.3, 1, 0, 0, 0, 0.5, 1, 0, //
            4, 5, 6, 0, 0, 1, 0.5, 0.6, 0.7, 0.8, 0, 0, 0, 2, 1, 1, //
          ]),
        );
        expect(surface.indices, isA<Uint16List>());
      });

      test('uses 32-bit indices when they do not fit in 16 bits', () {
        final surface = StylizedMaterial.buildSurface(
          positions: List.filled(70000 * 3, 0),
          normals: List.filled(70000 * 3, 0),
          indices: [0, 1, 69999],
          material: StylizedMaterial(),
        );

        expect(surface.indices, isA<Uint32List>());
      });

      test('rejects arrays of the wrong length', () {
        expect(
          () => StylizedMaterial.buildSurface(
            positions: [0, 0, 0, 1, 1, 1],
            normals: [0, 0, 1, 0, 0, 1],
            tint: [1],
            indices: [0, 1, 0],
            material: StylizedMaterial(),
          ),
          throwsArgumentError,
        );
      });
    });
  });
}
