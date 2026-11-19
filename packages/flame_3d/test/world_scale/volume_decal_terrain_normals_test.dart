import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  setUp(FakeGpuBackend.new);

  test('decals on a non-uniformly scaled terrain get its true normals', () {
    // A plane rising 0.5 per unit along +x, stretched 3 times vertically:
    // in world space it rises 1.5 per unit, with normal (-1.5, 1, 0).
    const cols = 17;
    final heights = Float32List(cols * cols);
    for (var r = 0; r < cols; r++) {
      for (var c = 0; c < cols; c++) {
        heights[r * cols + c] = (c - 8) * 0.5;
      }
    }
    final terrain = ChunkedTerrain3D(
      heights: heights,
      gridColumns: cols,
      gridRows: cols,
      worldWidth: 16,
      worldDepth: 16,
      scale: Vector3(1, 3, 1),
    );
    final decals = VolumeDecalBatch3D()
      ..projectOntoTerrain([
        ProjectedDecalBox3D(
          center: Vector3.zero(),
          halfExtents: Vector3(2, 10, 2),
          normalAngleFadeCos: -1,
        ),
      ], terrain);
    final surface = decals.mergedSurface!;
    final layout = surface.layout;
    final offset = layout.offsetOf('vertexNormal')!;
    final stride = layout.strideInFloats;
    final expected = Vector3(-1.5, 1, 0)..normalize();
    expect(surface.vertexCount, greaterThan(0));
    for (var v = 0; v < surface.vertexCount; v++) {
      final o = v * stride + offset;
      final normal = Vector3(
        surface.vertexData[o],
        surface.vertexData[o + 1],
        surface.vertexData[o + 2],
      );
      expect(normal.dot(expected), greaterThan(0.999), reason: '$normal');
    }
    terrain.onRemove();
  });
}
