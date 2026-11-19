import 'dart:ui';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

CameraComponent3D _camera() =>
    CameraComponent3D(position: Vector3(0, 0, 5), target: Vector3.zero());

void main() {
  group('CameraStack3D', () {
    late FakeGpuBackend backend;
    late GraphicsDevice device;

    setUp(() {
      backend = FakeGpuBackend();
      device = GraphicsDevice(backend: backend);
    });

    int render(CameraStack3D stack, World3D world, Size size) {
      final recorder = PictureRecorder();
      final rendered = stack.render(
        Canvas(recorder),
        size,
        defaultWorld: world,
        device: device,
        manageDeviceFrame: true,
      );
      recorder.endRecording().dispose();
      return rendered;
    }

    test('keeps one render target per slot across frames', () {
      final world = World3D(
        children: [MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)))],
      );
      final stack = CameraStack3D.splitHorizontal(_camera(), _camera());

      for (var frame = 0; frame < 3; frame++) {
        expect(render(stack, world, const Size(200, 100)), 2);
      }
      expect(backend.renderTargets, [(100, 100, 1), (100, 100, 1)]);

      // A new size makes new targets, once.
      for (var frame = 0; frame < 2; frame++) {
        render(stack, world, const Size(300, 100));
      }
      expect(backend.renderTargets, hasLength(4));
      expect(backend.renderTargets.last, (150, 100, 1));
    });

    test('renderOffscreen renders into targets of its own', () {
      final world = World3D();
      final stack = CameraStack3D(
        slots: [CameraViewportSlot3D(camera: _camera())],
      );
      stack
          .renderOffscreen(
            const Size(32, 32),
            defaultWorld: world,
            device: device,
          )
          .dispose();
      stack
          .renderOffscreen(
            const Size(32, 32),
            defaultWorld: world,
            device: device,
          )
          .dispose();
      expect(backend.renderTargets, hasLength(2));
    });

    test('orders slots by priority, then insertion, as priorities change', () {
      final a = CameraViewportSlot3D(camera: _camera(), label: 'a');
      final b = CameraViewportSlot3D(camera: _camera(), label: 'b');
      final c = CameraViewportSlot3D(camera: _camera(), label: 'c');
      final stack = CameraStack3D(slots: [a, b, c]);
      expect(stack.slots, [a, b, c]);

      a.priority = 2;
      expect(stack.slots, [b, c, a]);
      c.priority = -1;
      expect(stack.slots, [c, b, a]);
      a.priority = 0;
      c.priority = 0;
      expect(stack.slots, [a, b, c]);

      // The topmost slot under a point is the last one in that order.
      b.priority = 5;
      final pick = stack.pickSlotAndRay(Vector2(10, 10), const Size(100, 100));
      expect(pick!.slot, same(b));
    });
  });
}
