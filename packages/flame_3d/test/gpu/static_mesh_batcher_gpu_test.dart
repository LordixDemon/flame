import 'dart:ui' show Color;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

void main() {
  setUpGpu();

  testGpuEngine('StaticMeshBatcher3D draws merged pieces with their instance '
      'data', () async {
    // `instanceData.w` fades a SpatialMaterial out: with an alpha cutoff, a
    // fully faded piece is discarded.
    final material = SpatialMaterial(
      emissiveColor: const Color(0xFFFFFFFF),
      alphaCutoff: 0.5,
    );
    final cube = CuboidMesh(size: Vector3.all(0.6), material: material);
    final batcher = StaticMeshBatcher3D()
      ..addStaticInstance(
        mesh: cube,
        transform: Matrix4.translationValues(-0.5, 0, -5),
        instanceData: Vector4(0, 0, 0, 1),
      )
      ..addStaticInstance(
        mesh: cube,
        transform: Matrix4.translationValues(0.5, 0, -5),
      );
    final frame = await renderFrame(draw: batcher.draw);
    final (fadedX, fadedY) = pixelAt(-0.5, 0);
    final (shownX, shownY) = pixelAt(0.5, 0);
    expect(frame.pixels.isClear(fadedX, fadedY), isTrue);
    expect(frame.pixels.isClear(shownX, shownY), isFalse);
  });
}
