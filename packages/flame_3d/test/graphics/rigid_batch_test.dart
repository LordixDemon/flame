import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  group('RigidBatchBuffer and RenderContext3D.drawRigidBatch', () {
    late FakeGpuBackend backend;
    late GraphicsDevice device;
    late RenderContext3D context;

    setUp(() {
      backend = FakeGpuBackend(
        textureTargets: true,
        blockSizes: {
          'Material': 40 * 1024,
          'Wind': 16 * 1024,
          RenderContext3D.stylizedPassBlock: 40 * 1024,
          RenderContext3D.batchObjectsBlock: 3200,
        },
      );
      device = GraphicsDevice(backend: backend);
      context = RenderContext3D(device);
    });

    void frame(void Function() draw) {
      device.begin();
      context.setCamera(
        Matrix4.identity(),
        Matrix4.identity()..setAsPerspective(60, 1, 0.1, 100),
      );
      device.beginPass(const Size(16, 16), frontFace: context.frontFace);
      draw();
      context.flush();
      device
        ..endPass()
        ..end();
    }

    Surface stylizedTriangle(Material material, {double xOffset = 0}) {
      return StylizedMaterial.buildSurface(
        positions: [xOffset, 0, 0, xOffset + 1, 0, 0, xOffset, 1, 0],
        normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: const [0, 1, 2],
        material: material,
      );
    }

    test('RigidBatchBuffer packs std140 rows, colors, and instanceData', () {
      final buffer = RigidBatchBuffer();
      expect(RigidBatchBuffer.floatCount, 800);
      expect(buffer.bytes.lengthInBytes, 3200);
      expect(buffer.version, 0);

      final m = Matrix4.identity()..setTranslationRaw(3, 4, 5);
      buffer
        ..setObject(
          2,
          m,
          color: const Color.from(
            alpha: 0.75,
            red: 0.25,
            green: 0.5,
            blue: 1,
          ),
          instanceData: Vector4(0.1, 0.2, 0.3, 0.4),
        )
        ..markChanged();
      expect(buffer.version, 1);

      const rowBase = RigidBatchBuffer.modelRowsOffset + 2 * 12;
      expect(buffer.data[rowBase], closeTo(1, 1e-6));
      expect(buffer.data[rowBase + 3], closeTo(3, 1e-6));
      expect(buffer.data[rowBase + 7], closeTo(4, 1e-6));
      expect(buffer.data[rowBase + 11], closeTo(5, 1e-6));

      const colBase = RigidBatchBuffer.colorsOffset + 2 * 4;
      expect(buffer.data[colBase], closeTo(0.25, 1e-6));
      expect(buffer.data[colBase + 1], closeTo(0.5, 1e-6));
      expect(buffer.data[colBase + 2], closeTo(1.0, 1e-6));
      expect(buffer.data[colBase + 3], closeTo(0.75, 1e-6));

      const datBase = RigidBatchBuffer.dataOffset + 2 * 4;
      expect(buffer.data[datBase], closeTo(0.1, 1e-5));
      expect(buffer.data[datBase + 1], closeTo(0.2, 1e-5));
      expect(buffer.data[datBase + 2], closeTo(0.3, 1e-5));
      expect(buffer.data[datBase + 3], closeTo(0.4, 1e-5));

      buffer
        ..hideObject(2)
        ..markChanged();
      expect(buffer.version, 2);
      for (var i = 0; i < 12; i++) {
        expect(buffer.data[rowBase + i], 0.0);
      }

      buffer.clear();
      expect(buffer.version, 3);
      expect(buffer.data.every((v) => v == 0.0), isTrue);
    });

    test(
      'StylizedMaterial.buildBatchedSurface packs vertices and indices',
      () {
        final mat = StylizedMaterial();
        final s0 = stylizedTriangle(mat);
        final s1 = stylizedTriangle(mat, xOffset: 10);

        final batched = StylizedMaterial.buildBatchedSurface(
          surfaces: [s0, s1],
          material: mat,
        );
        expect(batched.layout, StylizedMaterial.batchedVertexLayout);
        expect(batched.layout.strideInFloats, 19);
        expect(batched.vertexCount, 6);
        expect(batched.indexCount, 6);
        expect(batched.indices, [0, 1, 2, 3, 4, 5]);
        for (var v = 0; v < 3; v++) {
          expect(batched.vertexData[v * 19 + 18], 0.0);
        }
        for (var v = 3; v < 6; v++) {
          expect(batched.vertexData[v * 19 + 18], 1.0);
        }
        expect(batched.vertexData[3 * 19], 10.0);

        expect(
          () => StylizedMaterial.buildBatchedSurface(
            surfaces: [],
            material: mat,
          ),
          throwsArgumentError,
        );
        expect(
          () => StylizedMaterial.buildBatchedSurface(
            surfaces: List.filled(StylizedMaterial.maxBatchObjects + 1, s0),
            material: mat,
          ),
          throwsArgumentError,
        );
      },
    );

    test(
      'StylizedMaterial selects batched vertex shader and rejects textures',
      () {
        final mat = StylizedMaterial();
        final batchedVert = mat.vertexShaderFor(
          StylizedMaterial.batchedVertexLayout,
        );
        expect(
          batchedVert.slots,
          contains(RenderContext3D.batchObjectsBlock),
        );

        final textured = StylizedMaterial(baseColorTexture: Texture.empty);
        expect(
          () => textured.vertexShaderFor(StylizedMaterial.batchedVertexLayout),
          throwsStateError,
        );
      },
    );

    test('drawRigidBatch submits one draw and promotes static buffer', () {
      final mat = StylizedMaterial();
      final s0 = stylizedTriangle(mat);
      final s1 = stylizedTriangle(mat, xOffset: 2);
      final batched = StylizedMaterial.buildBatchedSurface(
        surfaces: [s0, s1],
        material: mat,
      );
      final batch = RigidBatchBuffer()
        ..setObject(0, Matrix4.identity())
        ..setObject(1, Matrix4.translationValues(1, 2, 0))
        ..markChanged();

      // Frame 1: transient arena upload of 3200-byte batch + Stylized blocks.
      frame(() => context.drawRigidBatch(batched, batch: batch, material: mat));
      expect(backend.countCommands('drawIndexed'), 1);
      final f1Bytes = device.lastFrameStats.uploadedBytes;

      // Frame 2 (same version): promotes to a persistent GpuBuffer once.
      frame(() => context.drawRigidBatch(batched, batch: batch, material: mat));
      expect(backend.countCommands('drawIndexed'), 2);
      final f2Bytes = device.lastFrameStats.uploadedBytes;
      expect(f2Bytes, f1Bytes);

      // Frame 3 (same version): zero re-upload for the BatchObjects buffer.
      frame(() => context.drawRigidBatch(batched, batch: batch, material: mat));
      final f3Bytes = device.lastFrameStats.uploadedBytes;
      expect(f3Bytes, lessThan(f2Bytes));

      // Changing version triggers re-upload on the next frame.
      batch
        ..setObject(1, Matrix4.translationValues(2, 3, 0))
        ..markChanged();
      frame(() => context.drawRigidBatch(batched, batch: batch, material: mat));
      final f4Bytes = device.lastFrameStats.uploadedBytes;
      expect(f4Bytes, greaterThan(f3Bytes));
    });

    test('drawRigidBatch works inside directional shadow pass', () {
      final mat = StylizedMaterial();
      final s0 = stylizedTriangle(mat);
      final s1 = stylizedTriangle(mat, xOffset: 2);
      final batched = StylizedMaterial.buildBatchedSurface(
        surfaces: [s0, s1],
        material: mat,
      );
      final batch = RigidBatchBuffer()
        ..setObject(0, Matrix4.identity())
        ..setObject(1, Matrix4.translationValues(1, 2, 0))
        ..markChanged();
      final sun = Light(
        position: Vector3.zero(),
        source: DirectionalLight(
          direction: Vector3(0, -1, -1)..normalize(),
          shadows: ShadowSettings(resolution: 64),
        ),
      );
      final proj = DirectionalShadowProjection();

      device.begin();
      context
        ..lights = [sun]
        ..setCamera(
          Matrix4.identity(),
          Matrix4.identity()..setAsPerspective(60, 1, 0.1, 100),
        );
      final shadows = context.beginShadowPass(
        projection: proj,
        sceneBounds: Aabb3.minMax(
          Vector3(-10, -10, -10),
          Vector3(10, 10, 10),
        ),
      );
      expect(shadows, isTrue);
      context
        ..drawRigidBatch(batched, batch: batch, material: mat)
        ..endShadowPass();
      device.beginPass(const Size(16, 16), frontFace: context.frontFace);
      context
        ..drawRigidBatch(batched, batch: batch, material: mat)
        ..flush();
      device
        ..endPass()
        ..end();

      expect(device.lastFrameStats.shadowDrawCalls, 1);
      expect(backend.countCommands('drawIndexed'), 2);
    });
  });
}
