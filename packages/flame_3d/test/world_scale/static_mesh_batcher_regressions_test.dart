import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  late FakeGpuBackend backend;
  setUp(() => backend = FakeGpuBackend());

  group('StaticMeshBatcher3D', () {
    test('merges only instances drawn with the same instance data', () {
      final material = SpatialMaterial();
      final cube = CuboidMesh(size: Vector3.all(1), material: material);
      final batcher = StaticMeshBatcher3D()
        ..addStaticInstance(mesh: cube, transform: Matrix4.identity())
        ..addStaticInstance(
          mesh: cube,
          transform: Matrix4.translationValues(2, 0, 0),
        )
        ..addStaticInstance(
          mesh: cube,
          transform: Matrix4.translationValues(4, 0, 0),
          instanceData: Vector4(0, 0, 0, 0.5),
        );
      batcher.bakeDirtyChunks();
      expect(batcher.surfaceBatchCount, 2);
    });

    test('bakes colors only for materials that multiply vertex colors', () {
      final spatial = SpatialMaterial();
      final stylized = StylizedMaterial();
      final batcher = StaticMeshBatcher3D();
      for (final (i, color) in const [
        Color(0xFFFF0000),
        Color(0xFF00FF00),
      ].indexed) {
        batcher
          ..addStaticInstance(
            mesh: CuboidMesh(size: Vector3.all(1), material: spatial),
            transform: Matrix4.translationValues(i * 2.0, 0, 0),
            color: color,
          )
          ..addStaticInstance(
            mesh: CuboidMesh(size: Vector3.all(1), material: stylized),
            transform: Matrix4.translationValues(i * 2.0, 0, 4),
            color: color,
          );
      }
      batcher.bakeDirtyChunks();
      // One spatial surface with both colors baked into its vertex colors;
      // two stylized surfaces drawn with their instance color.
      expect(batcher.surfaceBatchCount, 3);

      final spatialHit = batcher.raycast(
        Ray.originDirection(Vector3(0, 5, 0), Vector3(0, -1, 0)),
      )!;
      final layout = spatialHit.surface.layout;
      final colorOffset = layout.offsetOf('vertexColor')!;
      final data = spatialHit.surface.vertexData;
      final stride = layout.strideInFloats;
      final reds = <double>{
        for (var v = 0; v < spatialHit.surface.vertexCount; v++)
          data[v * stride + colorOffset],
      };
      expect(reds, {0.0, 1.0});
    });

    test('mirrored instances keep outward normals and front faces', () {
      final material = UnlitMaterial()
        ..renderState = const RenderState(cullMode: CullMode.backFace);
      final batcher = StaticMeshBatcher3D()
        ..addStaticInstance(
          mesh: CuboidMesh(size: Vector3.all(1), material: material),
          transform: Matrix4.diagonal3Values(-1, 1, 1),
        );
      // Back faces are culled: only an outward-facing side can be hit.
      for (final direction in [
        Vector3(1, 0, 0),
        Vector3(-1, 0, 0),
        Vector3(0, -1, 0),
      ]) {
        final hit = batcher.raycast(
          Ray.originDirection(direction * -5, direction),
        );
        expect(hit, isNotNull, reason: '$direction');
        expect(hit!.worldNormal.dot(direction), lessThan(-0.99));
      }
    });

    test('keeps surfaces of different vertex layouts apart', () {
      final material = SpatialMaterial();
      final standard = CuboidMesh(size: Vector3.all(1), material: material);
      final tangents = CuboidMesh(size: Vector3.all(1), material: material);
      tangents.surfaces.single.computeTangents();
      final batcher = StaticMeshBatcher3D()
        ..addStaticInstance(mesh: standard, transform: Matrix4.identity())
        ..addStaticInstance(
          mesh: tangents,
          transform: Matrix4.translationValues(3, 0, 0),
        );
      batcher.bakeDirtyChunks();
      expect(batcher.surfaceBatchCount, 2);
      for (final x in [0.0, 3.0]) {
        expect(
          batcher.raycast(
            Ray.originDirection(Vector3(x, 5, 0), Vector3(0, -1, 0)),
          ),
          isNotNull,
        );
      }
    });

    test('refuses surfaces that are not triangle lists', () {
      final lines = Mesh()
        ..addSurface(
          Surface.fromBuffers(
            vertices: Float32List(2 * VertexLayout.standard.strideInFloats),
            indices: Uint16List.fromList([0, 1, 1, 0]),
            topology: PrimitiveTopology.lines,
          ),
        );
      final batcher = StaticMeshBatcher3D();
      expect(
        () => batcher.addStaticInstance(
          mesh: lines,
          transform: Matrix4.identity(),
        ),
        throwsArgumentError,
      );
      expect(batcher.activeSlotCount, 0);
    });

    test('hiding a slot uploads only its indices', () {
      final material = UnlitMaterial();
      final cube = CuboidMesh(size: Vector3.all(1), material: material);
      final batcher = StaticMeshBatcher3D();
      final slots = [
        for (var i = 0; i < 50; i++)
          batcher.addStaticInstance(
            mesh: cube,
            transform: Matrix4.translationValues(i * 2.0, 0, 0),
          ),
      ];
      final surface = batcher
          .raycast(Ray.originDirection(Vector3(0, 5, 0), Vector3(0, -1, 0)))!
          .surface;
      final buffer = surface.resource as FakeBuffer;
      final buffersBefore = backend.buffers.length;
      final writesBefore = buffer.writes.length;
      final bakesBefore = batcher.fullBakeCount;

      batcher.setSlotVisible(slots[10], visible: false);
      final hiddenRay = Ray.originDirection(
        Vector3(20, 5, 0),
        Vector3(0, -1, 0),
      );
      expect(batcher.raycast(hiddenRay), isNull);
      batcher.setSlotVisible(slots[10], visible: true);
      expect(batcher.raycast(hiddenRay), isNotNull);

      expect(backend.buffers.length, buffersBefore);
      expect(buffer.writes.length, writesBefore + 2);
      final indexBytes = cube.surfaces.single.indexCount * 2;
      for (final (_, bytes) in buffer.writes.skip(writesBefore)) {
        expect(bytes.length, lessThanOrEqualTo(indexBytes + 4));
      }
      expect(batcher.fullBakeCount, bakesBefore);
    });

    test('hidden slots do not add bounds at the origin', () {
      final material = UnlitMaterial();
      final cube = CuboidMesh(size: Vector3.all(1), material: material);
      final batcher = StaticMeshBatcher3D(chunkSize: 8);
      final near = batcher.addStaticInstance(
        mesh: cube,
        transform: Matrix4.translationValues(100, 0, 0),
      );
      batcher.addStaticInstance(
        mesh: cube,
        transform: Matrix4.translationValues(200, 0, 0),
      );
      batcher.bakeDirtyChunks();
      batcher.setSlotVisible(near, visible: false);
      final bounds = batcher.computeLocalAabb()!;
      expect(bounds.min.x, greaterThan(199));

      final all = StaticMeshBatcher3D();
      final only = all.addStaticInstance(
        mesh: cube,
        transform: Matrix4.translationValues(50, 0, 0),
      );
      all
        ..bakeDirtyChunks()
        ..setSlotVisible(only, visible: false);
      expect(all.computeLocalAabb(), isNull);
      expect(all.computeLocalAabb(), isNull);
    });
  });
}
