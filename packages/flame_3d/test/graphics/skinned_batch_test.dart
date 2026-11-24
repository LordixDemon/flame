import 'dart:ui';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

Surface _skinnedTriangle(
  Material material, {
  double joint = 0,
  double weight = 1,
}) {
  return StylizedMaterial.buildSurface(
    positions: const [0, 0, 0, 1, 0, 0, 0, 1, 0],
    normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1],
    joints: [
      joint,
      2,
      0,
      0,
      joint,
      2,
      0,
      0,
      joint,
      2,
      0,
      0,
    ],
    weights: [
      weight,
      0,
      0,
      0,
      weight,
      0,
      0,
      0,
      weight,
      0,
      0,
      0,
    ],
    indices: const [0, 1, 2],
    material: material,
  );
}

void main() {
  group('StylizedMaterial skinned batching', () {
    late FakeGpuBackend backend;
    late GraphicsDevice device;
    late RenderContext3D context;

    setUp(() {
      backend = FakeGpuBackend();
      device = GraphicsDevice(backend: backend);
      context = RenderContext3D(device)
        ..setCamera(Matrix4.identity(), Matrix4.identity());
    });

    test(
      'buildSkinnedBatchedSurface shifts weighted joints and writes objectId',
      () {
        final mat = StylizedMaterial();
        final s0 = _skinnedTriangle(mat, joint: 1);
        final s1 = _skinnedTriangle(mat, joint: 3);

        final batched = StylizedMaterial.buildSkinnedBatchedSurface(
          surfaces: [s0, s1],
          jointOffsets: const [0, 12],
          material: mat,
        );

        expect(batched.layout, StylizedMaterial.skinnedBatchedVertexLayout);
        expect(batched.vertexCount, 6);
        expect(batched.indexCount, 6);

        final data = batched.vertexData;
        const stride = 27;
        // Object 0: joint0 +0 = 1; zero-weight slot 1 stays 2; objectId = 0.
        expect(data[18], 1.0);
        expect(data[19], 2.0);
        expect(data[26], 0.0);
        // Object 1: joint0 +12 = 15; zero-weight slot 1 stays 2; objectId = 1.
        expect(data[3 * stride + 18], 15.0);
        expect(data[3 * stride + 19], 2.0);
        expect(data[3 * stride + 26], 1.0);
      },
    );

    test(
      'buildSkinnedBatchedSurface validates layout, counts, and joint range',
      () {
        final mat = StylizedMaterial();
        final rigid = StylizedMaterial.buildSurface(
          positions: const [0, 0, 0, 1, 0, 0, 0, 1, 0],
          normals: const [0, 0, 1, 0, 0, 1, 0, 0, 1],
          indices: const [0, 1, 2],
          material: mat,
        );
        final skinned = _skinnedTriangle(mat, joint: 60);

        expect(
          () => StylizedMaterial.buildSkinnedBatchedSurface(
            surfaces: [rigid],
            jointOffsets: const [0],
            material: mat,
          ),
          throwsArgumentError,
        );
        expect(
          () => StylizedMaterial.buildSkinnedBatchedSurface(
            surfaces: [skinned],
            jointOffsets: const [10], // 60 + 10 = 70 >= maxJoints (64)
            material: mat,
          ),
          throwsArgumentError,
        );
        expect(
          () => StylizedMaterial.buildSkinnedBatchedSurface(
            surfaces: List.filled(9, _skinnedTriangle(mat)),
            jointOffsets: List.filled(9, 0),
            material: mat,
          ),
          throwsArgumentError,
        );
        final skinnedBuf = RigidBatchBuffer.skinned();
        expect(skinnedBuf.capacity, RigidBatchBuffer.maxSkinnedObjects);
        expect(skinnedBuf.data.length, 160);
        expect(skinnedBuf.bytes.length, 640);
        skinnedBuf.setObject(7, Matrix4.identity());
        expect(
          () => skinnedBuf.setObject(8, Matrix4.identity()),
          throwsRangeError,
        );
      },
    );

    test(
      'drawRigidBatch binds BatchObjects and JointMatrices for skinned',
      () {
        final mat = StylizedMaterial();
        final s0 = _skinnedTriangle(mat);
        final s1 = _skinnedTriangle(mat);
        final batched = StylizedMaterial.buildSkinnedBatchedSurface(
          surfaces: [s0, s1],
          jointOffsets: const [0, 4],
          material: mat,
        );
        final batch = RigidBatchBuffer.skinned()
          ..setObject(0, Matrix4.identity())
          ..setObject(1, Matrix4.translationValues(2, 0, 0))
          ..markChanged();
        final joints = List<Matrix4>.generate(8, (_) => Matrix4.identity());

        // Color pass.
        device.begin();
        device.beginPass(const Size(64, 64));
        context.drawRigidBatch(
          batched,
          batch: batch,
          jointTransforms: joints,
          material: mat,
        );
        context.flush();
        device.endPass().dispose();
        device.end();

        expect(device.lastFrameStats.drawCalls, 1);

        // Shadow pass (with textureTargets enabled).
        final texBackend = FakeGpuBackend(textureTargets: true);
        final texDevice = GraphicsDevice(backend: texBackend);
        final texCtx = RenderContext3D(texDevice)
          ..setCamera(Matrix4.identity(), Matrix4.identity())
          ..lights = [
            Light(
              position: Vector3.zero(),
              source: DirectionalLight(
                direction: Vector3(0, -1, -1),
                shadows: ShadowSettings(resolution: 256),
              ),
            ),
          ];
        final bounds = Aabb3.minMax(Vector3(-5, -5, -5), Vector3(5, 5, 5));

        texDevice.begin();
        expect(
          texCtx.beginShadowPass(
            projection: DirectionalShadowProjection(),
            sceneBounds: bounds,
          ),
          isTrue,
        );
        texCtx.drawRigidBatch(
          batched,
          batch: batch,
          jointTransforms: joints,
          material: mat,
        );
        texCtx.endShadowPass();
        texDevice.end();

        expect(texDevice.lastFrameStats.shadowPasses, 1);
        expect(texDevice.lastFrameStats.shadowDrawCalls, 1);
      },
    );
  });
}
