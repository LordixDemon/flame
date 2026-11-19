import 'dart:ui' show Canvas, Color, PictureRecorder;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Canvas3DFallbackComponent & EnvironmentProbe3D', () {
    test(
      'renders MeshComponent, InstancedGroup3D, and ModelComponent to 2D',
      () {
        final world = World3D();
        final mat = SpatialMaterial(albedoColor: const Color(0xFF38BDF8));
        final cube = CuboidMesh(size: Vector3.all(1.0), material: mat);

        world
          ..add(
            LightComponent.directional(
              direction: Vector3(-0.4, -0.4, -0.8),
              intensity: 2.0,
            ),
          )
          ..add(MeshComponent(mesh: cube, position: Vector3(0, 0, 0.5)));

        final group = InstancedGroup3D(mesh: cube)
          ..addInstance(transform: Matrix4.translationValues(-2, 0, 0.5))
          ..addInstance(transform: Matrix4.translationValues(2, 0, 0.5));
        world.add(group);

        final modelNode = ModelNode(
          name: 'Root',
          nodeIndex: 0,
          parentNodeIndex: null,
          transform: Matrix4.translationValues(0, 0, 1.8),
          mesh: SphereMesh(radius: 0.5, segments: 6, material: mat),
          joints: const {},
        );
        world.add(
          ModelComponent(
            model: Model(nodes: {0: modelNode}, animations: const []),
          ),
        );

        final fallback = Canvas3DFallbackComponent(
          world: world,
          size: Vector2(320, 200),
          camera: CameraComponent3D(
            position: Vector3(0, 5, 8),
            target: Vector3(0, 0.8, 0),
          ),
        );

        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        fallback.render(canvas);
        final picture = recorder.endRecording();
        addTearDown(picture.dispose);

        expect(fallback.lastTrianglesSubmitted, greaterThan(20));
      },
    );

    Canvas3DFallbackComponent fallbackFor(
      List<Component3D> children, {
      CameraComponent3D? camera,
    }) {
      return Canvas3DFallbackComponent(
        world: World3D(children: children),
        size: Vector2(200, 200),
        camera:
            camera ??
            CameraComponent3D(
              position: Vector3(0, 0, 5),
              target: Vector3.zero(),
              cameraMask: 0x01,
            ),
      );
    }

    int trianglesOf(Canvas3DFallbackComponent fallback) {
      final recorder = PictureRecorder();
      fallback.render(Canvas(recorder));
      recorder.endRecording().dispose();
      return fallback.lastTrianglesSubmitted;
    }

    test('skips hidden and masked-out components, and shadow catchers', () {
      final cube = CuboidMesh(size: Vector3.all(1));
      final hidden = MeshComponent(mesh: cube)..visible = false;
      final otherCamera = MeshComponent(mesh: cube, cameraMask: 0x02);
      final underHidden = Group3D(children: [MeshComponent(mesh: cube)])
        ..visible = false;
      final catcher = MeshComponent(
        mesh: PlaneMesh(
          size: Vector2.all(4),
          material: ShadowCatcherMaterial(),
        ),
        rotation: Quaternion.axisAngle(Vector3(1, 0, 0), 1.5707963267948966),
      );
      expect(
        trianglesOf(fallbackFor([hidden, otherCamera, underHidden, catcher])),
        0,
      );
      // Seen straight on, only the front face of the cube faces the camera.
      expect(trianglesOf(fallbackFor([MeshComponent(mesh: cube)])), 2);
    });

    test('keeps only what lies between the near and the far plane', () {
      final camera = CameraComponent3D(
        position: Vector3(0, 0, 5),
        target: Vector3.zero(),
        far: 10,
      );
      final cube = CuboidMesh(size: Vector3.all(1));
      expect(
        trianglesOf(
          fallbackFor([
            MeshComponent(mesh: cube, position: Vector3(0, 0, -8)),
          ], camera: camera),
        ),
        0,
      );
      expect(
        trianglesOf(fallbackFor([MeshComponent(mesh: cube)], camera: camera)),
        2,
      );
    });

    test(
      'an orthographic camera without orthographicHeight uses fovY',
      () async {
        final fallback = fallbackFor(
          [
            MeshComponent(
              mesh: CuboidMesh(
                size: Vector3.all(1),
                material: UnlitMaterial(albedoColor: const Color(0xFFFF0000)),
              ),
            ),
          ],
          camera: CameraComponent3D(
            position: Vector3(0, 0, 5),
            target: Vector3.zero(),
            projection: CameraProjection.orthographic,
            fovY: 2,
          ),
        );
        final recorder = PictureRecorder();
        fallback.render(Canvas(recorder));
        final picture = recorder.endRecording();
        final image = await picture.toImage(200, 200);
        final data = await image.toByteData();
        picture.dispose();
        image.dispose();
        var red = 0;
        for (var i = 0; i < data!.lengthInBytes; i += 4) {
          if (data.getUint8(i) > 200 && data.getUint8(i + 3) > 200) {
            red++;
          }
        }
        // A unit cube in a view 2 units tall covers half the height.
        expect(red, closeTo(100 * 100, 600));
      },
    );

    test('EnvironmentProbe3D.skyDome evaluates directional SH9 irradiance', () {
      final probe = EnvironmentProbe3D.skyDome(
        width: 64,
        height: 32,
        zenithColor: const Color(0xFF2563EB),
        horizonColor: const Color(0xFF93C5FD),
        groundColor: const Color(0xFF1E293B),
      );
      expect(probe.shCoefficients.length, 9);
      final skyIrr = probe.evaluateIrradiance(Vector3(0, 1, 0));
      final groundIrr = probe.evaluateIrradiance(Vector3(0, -1, 0));
      expect(skyIrr.z, greaterThan(groundIrr.z));
      expect(skyIrr.length, greaterThan(0.1));
    });

    test('ShadowSettings validates 1..4 cascades', () {
      final single = ShadowSettings();
      expect(single.cascades, 1);
      final dual = ShadowSettings(cascades: 2, cascadeSplitRatio: 0.3);
      expect(dual.cascades, 2);
      final quad = ShadowSettings(cascades: 4);
      expect(quad.cascades, 4);
      expect(() => ShadowSettings(cascades: 0), throwsArgumentError);
      expect(() => ShadowSettings(cascades: 5), throwsArgumentError);
    });
  });
}
