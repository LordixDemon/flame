import 'package:flame_3d/core.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LightClusterGrid3D.packClusterDataRgba8', () {
    LightClusterGrid3D assigned(int lights) {
      final grid = LightClusterGrid3D(
        clustersX: 2,
        clustersY: 2,
        clustersZ: 2,
        maxLights: lights,
        maxLightsPerCluster: lights,
      );
      for (var i = 0; i < lights; i++) {
        grid.addLight(
          ClusterLightEntry3D.point(position: Vector3(0, 0, -5), range: 3),
        );
      }
      grid.assignLights(
        Matrix4.identity(),
        Matrix4.identity()..setAsPerspective(60, 1, 0.5, 20),
        near: 0.5,
        far: 20,
      );
      return grid;
    }

    test('packs grids whose values fit in its bytes', () {
      final grid = assigned(8);
      final packed = grid.packClusterDataRgba8();
      expect(packed.length, grid.totalClusters * 4);
      var counted = 0;
      for (var c = 0; c < grid.totalClusters; c++) {
        expect(packed[c * 4 + 2], grid.clusterCounts[c]);
        counted += packed[c * 4 + 2];
      }
      expect(counted, grid.totalAssignedLightRefs);
    });

    test('refuses values that do not fit instead of wrapping them', () {
      // 300 lights in one place: clusters hold more than 255 lights, and
      // light indices above 255.
      final grid = assigned(300);
      expect(grid.clusterCounts.reduce((a, b) => a > b ? a : b), 300);
      expect(grid.packClusterDataRgba8, throwsStateError);
    });
  });
}
