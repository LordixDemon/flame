import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/parser.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  setUp(FakeGpuBackend.new);

  group('AsyncModelLoader3D BVHs', () {
    test('surfaces adopt the hierarchies built on the isolate', () async {
      final sphere = SphereMesh(radius: 1, segments: 12);
      final model = Model.simple(mesh: sphere);
      final surface = sphere.surfaces.single;

      final prepared = await AsyncModelLoader3D.buildSurfaceBvhsInIsolate(
        model,
      );

      expect(prepared, hasLength(1));
      final bvh = surface.bvh;
      expect(bvh.nodeCount, prepared.single.nodeCount);
      expect(bvh.triangleCount, surface.indexCount ~/ 3);
      final hit = bvh.raycast(
        Ray.originDirection(Vector3(0, 0, 5), Vector3(0, 0, -1)),
      );
      expect(hit, isNotNull);
      expect(hit!.distance, closeTo(4, 0.05));

      // The adopted hierarchy is used as is, and dropped like any cached one
      // when the vertices change.
      expect(identical(surface.bvh, bvh), isTrue);
      surface.updateVertices(surface.vertexData);
      expect(identical(surface.bvh, bvh), isFalse);
    });

    test('adoptBvh rejects a hierarchy built for another surface', () {
      final a = PlaneMesh(size: Vector2.all(1)).surfaces.single;
      final b = PlaneMesh(size: Vector2.all(1)).surfaces.single;
      final built = SurfaceBvh.build(a);
      b.adoptBvh(SurfaceBvh.build(b));
      expect(() => b.adoptBvh(built), throwsArgumentError);
      a.adoptBvh(built);
      expect(identical(a.bvh, built), isTrue);
    });

    test('fromPrepared checks the buffers against the surface', () {
      final surface = SphereMesh(radius: 1, segments: 8).surfaces.single;
      final reference = SurfaceBvh.build(surface);
      expect(
        () => SurfaceBvh.fromPrepared(
          surface: surface,
          nodeCount: reference.nodeCount,
          bounds: Float32List(0),
          leftOrFirst: Int32List(0),
          rightChild: Int32List(0),
          counts: Int32List(0),
          triangles: Int32List(0),
        ),
        throwsArgumentError,
      );
    });
  });
}
