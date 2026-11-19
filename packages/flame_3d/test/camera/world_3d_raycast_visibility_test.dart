import 'dart:ui' show Size;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

MeshComponent _cube({Vector3? position, int? cameraMask}) => MeshComponent(
  mesh: CuboidMesh(size: Vector3.all(1)),
  position: position,
  cameraMask: cameraMask,
);

/// A ray along -Z through the origin, from z = 10.
Ray _downZ() => Ray.originDirection(Vector3(0, 0, 10), Vector3(0, 0, -1));

void main() {
  for (final indexed in [false, true]) {
    final label = indexed ? 'with the spatial index' : 'tree walk';

    group('World3D raycasts honour visibility and camera masks ($label)', () {
      World3D worldWith(List<Component3D> children) =>
          World3D(children: children, spatialIndex3DEnabled: indexed);

      test('hidden objects are not hit unless includeHidden', () {
        final near = _cube(position: Vector3(0, 0, 2));
        final far = _cube(position: Vector3(0, 0, -2));
        final world = worldWith([near, far]);
        near.visible = false;

        expect(world.raycast(_downZ())!.object, same(far));
        expect(world.raycastAll(_downZ()).map((h) => h.object), [far]);

        expect(
          world.raycast(_downZ(), includeHidden: true)!.object,
          same(near),
        );
        expect(
          world.raycastAll(_downZ(), includeHidden: true).map((h) => h.object),
          [near, far],
        );
      });

      test('objects under a hidden ancestor are not hit', () {
        final inner = _cube(position: Vector3(0, 0, 2));
        final group = Group3D(children: [inner]);
        final world = worldWith([group]);
        group.visible = false;

        expect(world.raycast(_downZ()), isNull);
        expect(world.raycastAll(_downZ()), isEmpty);
        expect(
          world.raycast(_downZ(), includeHidden: true)!.object,
          same(inner),
        );
      });

      test('cameraMask selects what a camera with that mask draws', () {
        final layer2 = _cube(position: Vector3(0, 0, 2), cameraMask: 0x02);
        final never = _cube(position: Vector3(0, 0, 0), cameraMask: 0);
        final layer1 = _cube(position: Vector3(0, 0, -2), cameraMask: 0x01);
        final world = worldWith([layer2, never, layer1]);

        // By default every object some camera draws is a candidate.
        expect(
          world.raycastAll(_downZ()).map((h) => h.object),
          [layer2, layer1],
        );
        expect(world.raycast(_downZ(), cameraMask: 0x01)!.object, same(layer1));
        expect(world.raycast(_downZ(), cameraMask: 0x02)!.object, same(layer2));
        expect(world.raycast(_downZ(), cameraMask: 0x04), isNull);
        // includeHidden tests every object, masks included.
        expect(
          world.raycastAll(_downZ(), includeHidden: true).map((h) => h.object),
          [layer2, never, layer1],
        );
      });

      test("an ancestor's camera mask applies to its subtree", () {
        final inner = _cube(position: Vector3(0, 0, 2));
        final world = worldWith([
          Group3D(cameraMask: 0x02, children: [inner]),
        ]);

        expect(world.raycast(_downZ(), cameraMask: 0x01), isNull);
        expect(world.raycast(_downZ(), cameraMask: 0x02)!.object, same(inner));
      });

      test('the filter still applies', () {
        final near = _cube(position: Vector3(0, 0, 2));
        final far = _cube(position: Vector3(0, 0, -2));
        final world = worldWith([near, far]);

        expect(
          world.raycast(_downZ(), filter: (o) => o != near)!.object,
          same(far),
        );
      });
    });
  }

  test('Scene3DComponent.raycastLocal uses the layer mask by default', () {
    final layer = Scene3DComponent(
      projection: Scene3DProjection.affine(
        origin: Vector2.zero(),
        xAxis: Vector2(40, 20),
        yAxis: Vector2(-40, 20),
        zAxis: Vector2(0, -40),
        towardsViewer: Vector3(1, 1, 1),
        near: -50,
        far: 50,
      ),
      cameraMask: 0x01,
    );
    // Both on the line of sight through the origin, `other` nearer.
    final other = _cube(position: Vector3.all(2), cameraMask: 0x02);
    final mine = _cube(position: Vector3.all(-2), cameraMask: 0x01);
    layer.world.addAll([other, mine]);

    final point = layer.scenePointToLocal(Vector3.zero());
    expect(layer.raycastLocal(point)!.object, same(mine));
    expect(layer.raycastAllLocal(point).map((h) => h.object), [mine]);
    expect(
      layer.raycastLocal(point, cameraMask: 0x02)!.object,
      same(other),
    );

    mine.visible = false;
    expect(layer.raycastLocal(point), isNull);
    // includeHidden tests every object, whatever its visibility and mask.
    expect(
      layer.raycastAllLocal(point, includeHidden: true).map((h) => h.object),
      [other, mine],
    );
  });

  test("CameraStack3D.raycastAt honours an ancestor's camera mask", () {
    final inner = _cube(position: Vector3(0, 0, 2));
    final world = World3D(
      children: [
        Group3D(cameraMask: 0x02, children: [inner]),
      ],
    );
    final camera = CameraComponent3D(
      position: Vector3(0, 0, 10),
      target: Vector3.zero(),
      projection: CameraProjection.orthographic,
      orthographicHeight: 4,
      cameraMask: 0x01,
    );
    final stack = CameraStack3D(
      slots: [CameraViewportSlot3D(camera: camera, world: world)],
    );

    final result = stack.raycastAt(Vector2(50, 50), const Size(100, 100));
    expect(result, isNotNull);
    expect(result!.$2, isNull);

    camera.cameraMask = 0x03;
    expect(
      stack.raycastAt(Vector2(50, 50), const Size(100, 100))!.$2,
      isNotNull,
    );
  });
}
