import 'dart:ui' show Canvas, Size;

import 'package:flame/game.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';

class FlameGame3D<W extends World3D, C extends CameraComponent3D>({
  super.children,
  W? world,
  C? camera,
  var CameraStack3D? cameraStack,
}) extends FlameGame<W> with Game3D {
  this
    : super(
        world: world ?? World3D() as W,
        camera: camera ?? CameraComponent3D() as C,
      );

  @override
  C get camera => super.camera as C;

  @override
  void update(double dt) {
    super.update(dt);
    cameraStack?.update(dt);
  }

  @override
  void renderTree(Canvas canvas) {
    final stack = cameraStack;
    if (stack == null || stack.isEmpty) {
      super.renderTree(canvas);
      return;
    }

    stack.render(
      canvas,
      Size(canvasSize.x, canvasSize.y),
      defaultWorld: world,
      device: device,
      context: context,
      pixelRatio: pixelRatio,
      msaa: msaa(),
    );

    final previousWorld = camera.world;
    camera.world = null;
    try {
      super.renderTree(canvas);
    } finally {
      camera.world = previousWorld;
    }
  }
}
