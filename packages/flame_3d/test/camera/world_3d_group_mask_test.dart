import 'dart:ui' show Size;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

class _Probe() extends Object3D {
  int draws = 0;

  @override
  void draw(RenderContext context) => draws++;
}

void main() {
  test("a group's cameraMask hides its subtree in offscreen passes", () {
    final device = GraphicsDevice(backend: FakeGpuBackend());
    final context = RenderContext3D(device);
    final probe = _Probe();
    final world = World3D(
      children: [
        Group3D(cameraMask: 0x02, children: [probe]),
      ],
    );
    void renderWith(int mask) {
      context.cameraMask = mask;
      device.begin();
      world
          .renderToImage(
            const Size(8, 8),
            view: Matrix4.identity(),
            projection: Matrix4.identity(),
            device: device,
            context: context,
          )
          .dispose();
      device.end();
    }

    renderWith(0x01);
    expect(probe.draws, 0);
    renderWith(0x03);
    expect(probe.draws, 1);
  });
}
