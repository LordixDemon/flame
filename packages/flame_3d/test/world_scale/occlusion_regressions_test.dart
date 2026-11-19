import 'dart:math' as math;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart'
    show makePerspectiveMatrix, makeViewMatrix;

Matrix4 _viewProjection(Vector3 eye, Vector3 target) {
  return makePerspectiveMatrix(math.pi / 2, 2, 0.1, 200)
    ..multiply(makeViewMatrix(eye, target, Vector3(0, 1, 0)));
}

/// A camera room (0) looking through windows in its wall at z = 0 into a hall
/// (1), and a room (2) behind the hall seen through a narrow door at z = -10
/// that lines up only with the middle window.
PortalOcclusionGraph3D _hallGraph(List<String> windowOrder) {
  final graph = PortalOcclusionGraph3D()
    ..addRoom(
      OcclusionRoom3D(
        id: 0,
        bounds: Aabb3.minMax(Vector3(-10, 0, 0), Vector3(10, 4, 10)),
      ),
    )
    ..addRoom(
      OcclusionRoom3D(
        id: 1,
        bounds: Aabb3.minMax(Vector3(-10, 0, -10), Vector3(10, 4, 0)),
      ),
    )
    ..addRoom(
      OcclusionRoom3D(
        id: 2,
        bounds: Aabb3.minMax(Vector3(-10, 0, -20), Vector3(10, 4, -10)),
      ),
    );
  final windows = {
    'L': (-4.0, -3.0),
    'M': (-0.5, 0.5),
    'R': (3.0, 4.0),
  };
  for (final name in windowOrder) {
    final (x0, x1) = windows[name]!;
    graph.addPortal(
      OcclusionPortal3D.rect(
        roomA: 0,
        roomB: 1,
        bottomStart: Vector3(x0, 1, 0),
        bottomEnd: Vector3(x1, 1, 0),
        height: 1,
      ),
    );
  }
  graph.addPortal(
    OcclusionPortal3D.rect(
      roomA: 1,
      roomB: 2,
      bottomStart: Vector3(-0.25, 1, -10),
      bottomEnd: Vector3(0.25, 1, -10),
      height: 1,
    ),
  );
  return graph;
}

void main() {
  group('PortalOcclusionGraph3D', () {
    test('finds a room seen through one of several portals in any order', () {
      final eye = Vector3(0, 1.5, 8);
      final vp = _viewProjection(eye, Vector3(0, 1.5, -10));
      for (final order in const [
        ['L', 'M', 'R'],
        ['L', 'R', 'M'],
        ['M', 'L', 'R'],
        ['R', 'L', 'M'],
      ]) {
        final graph = _hallGraph(order)
          ..evaluateVisibility(
            cameraPosition: eye,
            viewProjection: vp,
            cameraRoomId: 0,
          );
        expect(graph.isRoomVisible(1), isTrue, reason: '$order');
        expect(graph.isRoomVisible(2), isTrue, reason: '$order');
      }
    });
  });

  group('OcclusionCuller3D is conservative', () {
    test('a sliver between the edge of a pixel and an occluder stays '
        'visible', () {
      final culler = OcclusionCuller3D()
        // With an identity view-projection, world coordinates are clip
        // coordinates: the occluder covers x >= 0.0015625 at depth 0.5, the
        // right fifth of the pixel column starting at x = 0.
        ..addQuad(
          OccluderQuad3D(
            v0: Vector3(0.0015625, -1, 0.5),
            v1: Vector3(1, -1, 0.5),
            v2: Vector3(1, 1, 0.5),
            v3: Vector3(0.0015625, 1, 0.5),
          ),
        )
        ..rasterizeOccluders(Matrix4.identity());
      final identity = Matrix4.identity();
      // Left of the occluder's edge, behind it: nothing covers it.
      final sliver = Aabb3.minMax(
        Vector3(0.0001, -0.5, 0.8),
        Vector3(0.0015, 0.5, 0.9),
      );
      expect(culler.isAabbVisible(sliver, identity), isTrue);
      // Fully behind the occluder: culled.
      final hidden = Aabb3.minMax(
        Vector3(0.2, -0.5, 0.8),
        Vector3(0.5, 0.5, 0.9),
      );
      expect(culler.isAabbVisible(hidden, identity), isFalse);
    });

    test('a narrow gap between two occluders stays visible', () {
      final culler = OcclusionCuller3D()
        ..addQuad(
          OccluderQuad3D(
            v0: Vector3(-1, -1, 0.5),
            v1: Vector3(0.0012, -1, 0.5),
            v2: Vector3(0.0012, 1, 0.5),
            v3: Vector3(-1, 1, 0.5),
          ),
        )
        ..addQuad(
          OccluderQuad3D(
            v0: Vector3(0.0028, -1, 0.5),
            v1: Vector3(1, -1, 0.5),
            v2: Vector3(1, 1, 0.5),
            v3: Vector3(0.0028, 1, 0.5),
          ),
        )
        ..rasterizeOccluders(Matrix4.identity());
      final behindGap = Aabb3.minMax(
        Vector3(0.0014, -0.2, 0.8),
        Vector3(0.0026, 0.2, 0.9),
      );
      expect(culler.isAabbVisible(behindGap, Matrix4.identity()), isTrue);
    });

    test('box occluders cull behind their silhouette, not beside it', () {
      final eye = Vector3(0, 2, 10);
      final vp = _viewProjection(eye, Vector3(0, 2, 0));
      final culler = OcclusionCuller3D()
        ..addBox(
          OccluderBox3D(
            center: Vector3(0, 2, 0),
            halfExtents: Vector3(2, 2, 1),
            rotation: Quaternion.axisAngle(Vector3(0, 1, 0), 0.6),
          ),
        )
        ..rasterizeOccluders(vp);
      // Straight behind the box, smaller than its silhouette.
      final hidden = Aabb3.minMax(
        Vector3(-0.3, 1.5, -6),
        Vector3(0.3, 2.5, -5),
      );
      expect(culler.isAabbVisible(hidden, vp), isFalse);
      // Beside the box.
      final beside = Aabb3.minMax(Vector3(6, 1.5, -6), Vector3(7, 2.5, -5));
      expect(culler.isAabbVisible(beside, vp), isTrue);
      // Behind it but sticking out above its top.
      final above = Aabb3.minMax(Vector3(-0.3, 1.5, -6), Vector3(0.3, 9, -5));
      expect(culler.isAabbVisible(above, vp), isTrue);
    });
  });
}
