import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  setUp(FakeGpuBackend.new);

  test('markHeightsChanged rebuilds chunks and bounds from edited heights', () {
    const cols = 33;
    final terrain = ChunkedTerrain3D(
      heights: Float32List(cols * cols),
      gridColumns: cols,
      gridRows: cols,
      worldWidth: 32,
      worldDepth: 32,
      maxHeight: 10,
    );
    final eye = Vector3(0, 20, 0);
    final before = terrain.selectVisibleChunks(cameraPosition: eye);
    expect(before, isNotEmpty);
    expect(terrain.computeLocalAabb()!.max.y, 0);

    terrain.heights.fillRange(0, terrain.heights.length, 6);
    terrain.markHeightsChanged();
    expect(terrain.computeLocalAabb()!.max.y, 6);
    final after = terrain.selectVisibleChunks(cameraPosition: eye);
    final surface = after.first.surface;
    expect(identical(surface, before.first.surface), isFalse);
    // The top vertices come first; skirts hang below them.
    final stride = surface.layout.strideInFloats;
    expect(surface.vertexData[1], 6);
    expect(surface.vertexData[stride + 1], 6);
    terrain.onRemove();
  });
}
