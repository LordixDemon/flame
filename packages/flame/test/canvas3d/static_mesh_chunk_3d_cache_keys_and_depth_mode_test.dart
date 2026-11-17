import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/canvas3d.dart';
import 'package:flutter_test/flutter_test.dart';

const _green = Color(0xFF00FF00);
const _red = Color(0xFFFF0000);
const _flat = Material3D.unshaded();

StaticMeshChunk3D _chunk(Mesh3D mesh, {bool shadow = false}) {
  return StaticMeshChunk3D()..addInstance(
    StaticMeshInstance3D(
      mesh: mesh,
      worldX: 2,
      worldY: 1,
      castGroundShadow: shadow,
    ),
  );
}

void main() {
  final mesh = Mesh3D.box(sizeX: 0.5, sizeY: 0.5, sizeZ: 0.5);
  final light = DirectionalLight3D();

  group('StaticMeshChunk3D.prepare cache keys', () {
    test('reuses both bakes while nothing changes, and only re-projects on a '
        '2D camera pan', () {
      final cam = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      final chunk = _chunk(mesh, shadow: true)
        ..prepare(camera: cam, light: light)
        ..prepare(camera: cam, light: light);
      expect(chunk.geometryBakeCount, 1);
      expect(chunk.projectionBakeCount, 1);

      cam.update(camX: 25, camY: -10, zoom: 1);
      chunk.prepare(camera: cam, light: light);
      expect(chunk.geometryBakeCount, 1);
      expect(chunk.projectionBakeCount, 2);

      cam.update(camX: 25, camY: -10, zoom: 1, orbitYawDelta: 0.1);
      chunk.prepare(camera: cam, light: light);
      expect(chunk.geometryBakeCount, 2);
    });

    test('re-bakes for a different CameraRig3D even when its basisVersion '
        'counter matches', () {
      final camA = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      // For example a rig rebuilt with another cell size after a layout change.
      final camB = CameraRig3D(cellHalfW: 60, cellHalfH: 30)
        ..update(camX: 0, camY: 0, zoom: 1);
      expect(camA.basisVersion, camB.basisVersion);

      final chunk = _chunk(mesh)
        ..prepare(camera: camA, light: light)
        ..prepare(camera: camB, light: light);
      final fresh = _chunk(mesh)..prepare(camera: camB, light: light);

      expect(chunk.geometryBakeCount, 2);
      for (var v = 0; v < chunk.vertexCount; v++) {
        expect(
          chunk.projectedVertX[v],
          closeTo(fresh.projectedVertX[v], 1e-3),
        );
        expect(
          chunk.projectedVertY[v],
          closeTo(fresh.projectedVertY[v], 1e-3),
        );
      }

      // Going back to the first rig is a change as well.
      chunk.prepare(camera: camA, light: light);
      final freshA = _chunk(mesh)..prepare(camera: camA, light: light);
      expect(chunk.projectedVertX[0], closeTo(freshA.projectedVertX[0], 1e-3));
    });

    test('re-projects when camZoom changes the perspective focal length', () {
      final cam = CameraRig3D(
        projectionMode: CameraProjectionMode3D.perspective,
        fovYRad: math.pi / 3,
      )..update(camX: 0, camY: 0, zoom: 0.5);
      final chunk = _chunk(mesh)..prepare(camera: cam, light: light);
      final focalBefore = cam.perspectiveFocalLengthPx;

      // Below zoom 1 `perspectiveStrength` is constant, the focal length not.
      cam.update(camX: 0, camY: 0, zoom: 0.9);
      expect(cam.perspectiveFocalLengthPx, isNot(closeTo(focalBefore, 1)));
      chunk.prepare(camera: cam, light: light);
      final fresh = _chunk(mesh)..prepare(camera: cam, light: light);

      expect(chunk.geometryBakeCount, 1);
      expect(chunk.projectionBakeCount, 2);
      expect(chunk.projectedVertX[0], closeTo(fresh.projectedVertX[0], 1e-3));
    });

    test('re-bakes shadows for every shadow setting, also when two of them '
        'change at once', () {
      final cam = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      final chunk = _chunk(mesh, shadow: true)
        ..prepare(camera: cam, light: light);
      expect(chunk.projectedShadowTriCount, 6);

      // Back-face shadow culling off together with a small falloff change.
      chunk.prepare(
        camera: cam,
        light: light,
        cullBackfaceShadows: false,
        shadowHeightFalloff: 0.002,
      );
      expect(chunk.projectedShadowTriCount, 12);
      expect(chunk.geometryBakeCount, 2);

      // Opacity multiplier up, falloff down by amounts that used to cancel
      // out in an additive signature.
      chunk.prepare(
        camera: cam,
        light: light,
        cullBackfaceShadows: false,
        shadowOpacityMultiplier: 1.014,
      );
      expect(chunk.geometryBakeCount, 3);

      chunk.prepare(camera: cam, light: light, shadowsEnabled: false);
      expect(chunk.projectedShadowTriCount, 0);
      expect(chunk.geometryBakeCount, 4);

      // With shadows off the other shadow settings cannot matter.
      chunk.prepare(
        camera: cam,
        light: light,
        shadowsEnabled: false,
        cullBackfaceShadows: false,
        shadowHeightFalloff: 0.5,
        shadowOpacityMultiplier: 0.3,
      );
      expect(chunk.geometryBakeCount, 4);
    });
  });

  group('StaticMeshChunk3D triangle depth', () {
    test('visibleTriDepth follows the depthMode it is prepared with', () {
      final cam = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      final ground = Mesh3D.plane(sizeX: 10, sizeY: 10);
      final chunk = StaticMeshChunk3D()
        ..addInstance(
          StaticMeshInstance3D(mesh: ground, worldX: 0, worldY: 0),
        )
        ..prepare(camera: cam, light: light);
      final centroid = chunk.visibleTriDepth[0];

      chunk.prepare(
        camera: cam,
        light: light,
        depthMode: TriangleDepthMode3D.farthestVertex,
      );
      final farthest = chunk.visibleTriDepth[0];
      chunk.prepare(
        camera: cam,
        light: light,
        depthMode: TriangleDepthMode3D.nearestVertex,
      );
      final nearest = chunk.visibleTriDepth[0];

      expect(chunk.geometryBakeCount, 1);
      expect(chunk.projectionBakeCount, 3);
      // The far corner (-5, -5) and the near corner (5, 5) of the quad.
      expect(farthest, closeTo(cam.viewDepth(-5, -5, 0), 1e-4));
      expect(nearest, closeTo(cam.viewDepth(5, 5, 0), 1e-4));
      expect(farthest, lessThan(centroid));
      expect(nearest, greaterThan(centroid));
    });

    /// Red channel of the pixel at the top of a small prop standing on the far
    /// part of a large green ground quad.
    Future<int> propPixelRed({
      required bool groundViaChunk,
      required TriangleDepthMode3D depthMode,
    }) async {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      final ground = Mesh3D.plane(sizeX: 10, sizeY: 10);
      final prop = Mesh3D.box(
        sizeX: 0.6,
        sizeY: 0.6,
        sizeZ: 0.6,
        centerZ: 0.3,
      );
      final renderer = BatchMeshRenderer3D(
        depthMode: depthMode,
        shadowsEnabled: false,
      )..beginBatch();

      if (groundViaChunk) {
        final chunk = StaticMeshChunk3D()
          ..addInstance(
            StaticMeshInstance3D(
              mesh: ground,
              worldX: 0,
              worldY: 0,
              tint: _green,
              emissive: 1,
              material: _flat,
            ),
          );
        renderer.enqueueStaticChunk(chunk, camera: rig);
      } else {
        renderer.enqueueMesh(
          ground,
          camera: rig,
          worldX: 0,
          worldY: 0,
          tint: _green,
          emissive: 1,
          material: _flat,
        );
      }
      renderer.enqueueMesh(
        prop,
        camera: rig,
        worldX: -3,
        worldY: -3,
        tint: _red,
        emissive: 1,
        material: _flat,
      );

      final topCentre = rig.projectWorldPoint(-3, -3, 0.6);
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder)
        ..translate(150 - topCentre.dx, 150 - topCentre.dy);
      renderer.flushBatch(canvas);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(300, 300);
      final bytes = await image.toByteData();
      image.dispose();
      picture.dispose();
      return bytes!.getUint8((150 * 300 + 150) * 4);
    }

    test('farthestVertex keeps a prop in front of the ground it stands on, '
        'whether the ground is a dynamic mesh or a static chunk', () async {
      const mode = TriangleDepthMode3D.farthestVertex;
      expect(
        await propPixelRed(groundViaChunk: false, depthMode: mode),
        greaterThan(200),
      );
      expect(
        await propPixelRed(groundViaChunk: true, depthMode: mode),
        greaterThan(200),
      );
    });

    test(
      'chunk and dynamic ground agree in the default centroid mode too',
      () async {
        const mode = TriangleDepthMode3D.centroid;
        expect(
          await propPixelRed(groundViaChunk: true, depthMode: mode),
          await propPixelRed(groundViaChunk: false, depthMode: mode),
        );
      },
    );
  });
}
