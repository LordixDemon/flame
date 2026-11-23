import 'dart:typed_data';
import 'dart:ui' show Color, Size;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

Texture _flatNormalTexture() {
  return Texture(
    ByteData.sublistView(Uint8List.fromList([128, 128, 255, 255])),
    width: 1,
    height: 1,
  );
}

void main() {
  setUpGpu();

  testGpuEngine(
    'SpatialMaterial switches between basic and full PBR fragment shaders',
    () async {
      final device = GraphicsDevice();
      final context = RenderContext3D(device);

      final basicMat = SpatialMaterial(metallic: 0.0, roughness: 0.8);
      final basicShader = basicMat.fragmentShaderFor(
        context,
        VertexLayout.pbrStandard,
      );
      expect(identical(basicShader, basicMat.fragmentShader), isFalse);
      expect(basicShader.slots, isNot(contains('environmentMap')));
      expect(
        basicShader.slots,
        isNot(contains(RenderContext3D.sceneColorSampler)),
      );

      final fullMat = SpatialMaterial(
        metallic: 0.0,
        roughness: 0.8,
        normalTexture: _flatNormalTexture(),
      );
      final fullShader = fullMat.fragmentShaderFor(
        context,
        VertexLayout.pbrStandard,
      );
      expect(identical(fullShader, fullMat.fragmentShader), isTrue);

      final light = [
        Light(
          position: Vector3.zero(),
          source: DirectionalLight(
            direction: Vector3(0, 0, -1),
            intensity: 2.0,
          ),
        ),
      ];
      final basicCube = CuboidMesh(size: Vector3.all(1.0), material: basicMat);
      final fullCube = CuboidMesh(size: Vector3.all(1.0), material: fullMat);

      final basicFrame = await renderFrame(
        device: device,
        context: context,
        lights: light,
        draw: (c) => c.drawMesh(
          basicCube,
          transform: Matrix4.translationValues(0, 0, -4),
        ),
      );
      final fullFrame = await renderFrame(
        device: device,
        context: context,
        lights: light,
        draw: (c) => c.drawMesh(
          fullCube,
          transform: Matrix4.translationValues(0, 0, -4),
        ),
      );

      final (cx, cy) = pixelAt(0, 0);
      expect(basicFrame.pixels.isClear(cx, cy), isFalse);
      expect(fullFrame.pixels.isClear(cx, cy), isFalse);
    },
  );

  testGpuEngine(
    'SpatialPass updates lights across multiple passes within a single GPU '
    'frame',
    () async {
      final device = GraphicsDevice();
      final context = RenderContext3D(device);
      final mat = SpatialMaterial(metallic: 0.0, roughness: 0.8);
      final cube = CuboidMesh(size: Vector3.all(1.2), material: mat);

      final redLight = [
        Light(
          position: Vector3.zero(),
          source: DirectionalLight(
            direction: Vector3(0, 0, -1),
            color: const Color(0xFFFF1010),
            intensity: 3.0,
          ),
        ),
      ];
      final blueLight = [
        Light(
          position: Vector3.zero(),
          source: DirectionalLight(
            direction: Vector3(0, 0, -1),
            color: const Color(0xFF1010FF),
            intensity: 3.0,
          ),
        ),
      ];

      device.begin();

      context
        ..lights = redLight
        ..setCamera(defaultView, defaultProjection);
      device.beginPass(const Size(64, 64), frontFace: context.frontFace);
      context.drawMesh(cube, transform: Matrix4.translationValues(0, 0, -4));
      context.flush();
      final imgRed = device.endPass();

      context
        ..lights = blueLight
        ..setCamera(defaultView, defaultProjection);
      device.beginPass(const Size(64, 64), frontFace: context.frontFace);
      context.drawMesh(cube, transform: Matrix4.translationValues(0, 0, -4));
      context.flush();
      final imgBlue = device.endPass();

      device.end();

      final redPixels = await readImage(imgRed);
      final bluePixels = await readImage(imgBlue);
      imgRed.dispose();
      imgBlue.dispose();

      final (cx, cy) = pixelAt(0, 0);
      final (r1, _, b1, a1) = redPixels.at(cx, cy);
      final (r2, _, b2, a2) = bluePixels.at(cx, cy);

      expect(a1, 255);
      expect(a2, 255);
      expect(r1, greaterThan(b1 + 60));
      expect(b2, greaterThan(r2 + 60));
    },
  );

  testGpuEngine(
    'SpatialPass updates fog options across multiple passes in a single GPU '
    'frame',
    () async {
      final device = GraphicsDevice();
      final context = RenderContext3D(device);
      final mat = SpatialMaterial(
        albedoColor: const Color(0xFFCC2020),
        metallic: 0.0,
        roughness: 0.8,
      );
      final cube = CuboidMesh(size: Vector3.all(1.2), material: mat);
      final lights = [
        Light(
          position: Vector3.zero(),
          source: DirectionalLight(
            direction: Vector3(0, 0, -1),
            intensity: 2.0,
          ),
        ),
      ];
      final denseGreenFog = FogSettings(
        color: const Color(0xFF00FF00),
        start: 1.0,
        end: 3.0,
      );

      device.begin();

      context
        ..fog = null
        ..lights = lights
        ..setCamera(defaultView, defaultProjection);
      device.beginPass(const Size(64, 64), frontFace: context.frontFace);
      context.drawMesh(cube, transform: Matrix4.translationValues(0, 0, -5));
      context.flush();
      final imgClear = device.endPass();

      context
        ..fog = denseGreenFog
        ..lights = lights
        ..setCamera(defaultView, defaultProjection);
      device.beginPass(const Size(64, 64), frontFace: context.frontFace);
      context.drawMesh(cube, transform: Matrix4.translationValues(0, 0, -5));
      context.flush();
      final imgFog = device.endPass();

      device.end();

      final clearPixels = await readImage(imgClear);
      final fogPixels = await readImage(imgFog);
      imgClear.dispose();
      imgFog.dispose();

      final (cx, cy) = pixelAt(0, 0);
      final (r1, g1, _, a1) = clearPixels.at(cx, cy);
      final (r2, g2, _, a2) = fogPixels.at(cx, cy);

      expect(a1, 255);
      expect(a2, 255);
      expect(r1, greaterThan(g1 + 30));
      expect(g2, greaterThan(r2 + 60));
    },
  );
}
