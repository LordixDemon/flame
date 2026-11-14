import 'dart:ui';

import 'package:flame/canvas3d.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SceneEnvironment3D, PointLight3D, Fog & 3D LOD (#18,#20)', () {
    test(
      'MeshLodChain3D selects progressive tiers and BatchMeshRenderer3D culls '
      'micro-triangles (#18)',
      () {
        final camera = CameraRig3D();
        final high = Mesh3D.uvSphere(radius: 0.6);
        final medium = Mesh3D.uvSphere(radius: 0.6, segments: 8, rings: 6);
        final low = Mesh3D.box();

        final chain = MeshLodChain3D.progressive(
          high: high,
          medium: medium,
          low: low,
          highMinPixels: 90.0,
          mediumMinPixels: 36.0,
          cullBelowPixels: 6.0,
        );

        final batcher = BatchMeshRenderer3D();

        camera.update(camX: 0, camY: 0, zoom: 1.5);
        expect(
          batcher.enqueueLodMesh(chain, camera: camera, worldX: 0, worldY: 0),
          same(high),
        );

        camera.update(camX: 0, camY: 0, zoom: 0.7);
        expect(
          batcher.enqueueLodMesh(chain, camera: camera, worldX: 0, worldY: 0),
          same(medium),
        );

        camera.update(camX: 0, camY: 0, zoom: 0.2);
        expect(
          batcher.enqueueLodMesh(chain, camera: camera, worldX: 0, worldY: 0),
          same(low),
        );

        camera.update(camX: 0, camY: 0, zoom: 0.03);
        expect(
          batcher.enqueueLodMesh(chain, camera: camera, worldX: 0, worldY: 0),
          isNull,
        );

        // Sub-pixel micro-triangle culling when minTrianglePixelArea is active.
        camera.update(camX: 0, camY: 0, zoom: 0.15);
        final rec = PictureRecorder();
        batcher
          ..minTrianglePixelArea = 8.0
          ..beginBatch()
          ..enqueueMesh(high, camera: camera, worldX: 0, worldY: 0)
          ..flushBatch(Canvas(rec));
        rec.endRecording().dispose();
        expect(batcher.lastCulledMicroTriangles, greaterThan(0));
      },
    );

    test(
      'SceneEnvironment3D SoA PointLight3D, atmospheric fog, 3D frustum cull '
      'and StaticMeshChunk3D spatial light invalidation (#20)',
      () {
        final camera = CameraRig3D();
        final env = SceneEnvironment3D(
          fogEnabled: true,
          fogColor: const Color(0xFFAEC6DF),
          fogStartDepth: 6.0,
          fogEndDepth: 28.0,
          fogMaxOpacity: 0.80,
          heightFogDensity: 0.35,
          heightFogFalloff: 1.2,
        );

        // Near point has lower fog than far-horizon low-elevation point.
        final nearFog = env.computeFogFactor(cameraDistance: 3.0, worldZ: 3.0);
        final farLowFog = env.computeFogFactor(
          cameraDistance: 30.0,
          worldZ: 0.0,
        );
        expect(farLowFog, greaterThan(nearFog));
        expect(farLowFog, closeTo(0.80, 1e-3));

        // PointLight3D SoA pool illuminates nearby surface normals.
        env.addPointLight(
          x: 1.0,
          y: 0.0,
          z: 1.5,
          radius: 4.0,
          color: const Color(0xFFFF9800),
          intensity: 1.4,
        );
        final (litR, litG, _) = env.samplePointLights(
          wx: 0.0,
          wy: 0.0,
          wz: 0.5,
          nx: 1.0,
          ny: 0.0,
          nz: 0.0,
        );
        expect(litR, greaterThan(0.3));
        expect(litG, greaterThan(0.1));

        final (outR, outG, outB) = env.samplePointLights(
          wx: 20.0,
          wy: 20.0,
          wz: 0.0,
          nx: 0.0,
          ny: 0.0,
          nz: 1.0,
        );
        expect(outR + outG + outB, 0.0);

        // 3D bounding-sphere frustum culling skips off-screen dynamic & static
        // meshes before vertex transformation.
        final batcher = BatchMeshRenderer3D(
          environment: env,
          cullScreenBounds: const Rect.fromLTRB(-200, -200, 200, 200),
        )..applyGraphicsProfile(GraphicsProfile.high);

        final box = Mesh3D.box(sizeX: 0.8, sizeY: 0.8);
        final rec1 = PictureRecorder();
        batcher
          ..beginBatch()
          ..enqueueMesh(box, camera: camera, worldX: 0, worldY: 0)
          ..enqueueMesh(box, camera: camera, worldX: 50, worldY: -50)
          ..flushBatch(Canvas(rec1));
        rec1.endRecording().dispose();
        expect(batcher.lastFrustumCulledMeshes, 1);

        // StaticMeshChunk3D spatial light signature: moving a distant light
        // outside the chunk's AABB does NOT trigger a geometry re-bake!
        final chunk = StaticMeshChunk3D()
          ..addInstance(
            StaticMeshInstance3D(
              mesh: box,
              worldX: 0.0,
              worldY: 0.0,
              castGroundShadow: true,
            ),
          );

        void drawChunk() {
          final rec = PictureRecorder();
          batcher
            ..beginBatch()
            ..enqueueStaticChunk(chunk, camera: camera)
            ..flushBatch(Canvas(rec));
          rec.endRecording().dispose();
        }

        drawChunk();
        expect(chunk.geometryBakeCount, 1);

        // Add/move a distant light at (30, 30, 1) radius 3 (far from chunk at
        // origin) -> chunk geometryBakeCount stays 1!
        env.addPointLight(x: 30.0, y: 30.0, z: 1.0, radius: 3.0);
        drawChunk();
        expect(chunk.geometryBakeCount, 1);

        // Move a light INTO the chunk's AABB at (0.2, 0.2, 1.2) -> chunk
        // automatically invalidates and re-bakes vertex colors!
        env.addPointLight(x: 0.2, y: 0.2, z: 1.2, radius: 3.5);
        drawChunk();
        expect(chunk.geometryBakeCount, 2);

        // Low graphics profile disables 3D shadows cleanly.
        batcher.applyGraphicsProfile(GraphicsProfile.low);
        drawChunk();
        expect(batcher.lastFlushShadowTriangles, 0);
      },
    );
  });
}
