import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/canvas3d.dart';
import 'package:flame/game.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Mesh3D & BatchMeshRenderer3D', () {
    test('procedural Mesh3D builders construct valid normals and bounds', () {
      final box = Mesh3D.box(sizeX: 20, sizeY: 30, sizeZ: 40, centerZ: 20);
      expect(box.vertexCount, 24);
      expect(box.triangleCount, 12);
      expect(box.minX, closeTo(-10, 1e-4));
      expect(box.maxZ, closeTo(40, 1e-4));

      final pyramid = Mesh3D.pyramid(baseX: 16, baseY: 16, height: 24);
      expect(pyramid.triangleCount, 6);
      expect(pyramid.maxZ, closeTo(24, 1e-4));

      final crystal = Mesh3D.octahedron(radiusXY: 10, halfHeight: 18);
      expect(crystal.triangleCount, 8);
      expect(crystal.boundingRadius, closeTo(18, 1e-4));

      final prism = Mesh3D.prism(radius: 12, height: 30);
      expect(prism.triangleCount, 24);
      expect(prism.maxZ, closeTo(30, 1e-4));

      final custom = Mesh3D.fromRaw(
        positions: Float32List.fromList([
          0,
          0,
          0,
          10,
          0,
          0,
          0,
          10,
          0,
        ]),
        indices: Uint16List.fromList([0, 1, 2]),
      );
      expect(custom.normals[2], closeTo(1.0, 1e-4));
    });

    test(
      'batches multiple 3D meshes + projected shadows into minimal '
      'drawVertices calls with backface culling and MatCap support',
      () {
        final rig = CameraRig3D()
          ..update(
            camX: 0,
            camY: 0,
            zoom: 1.0,
            orbitYawDelta: 0.12,
            pitchDelta: 0.05,
          );

        final renderer = BatchMeshRenderer3D()..beginBatch();
        final crystal = Mesh3D.octahedron(radiusXY: 0.4, halfHeight: 0.7);
        final pedestal = Mesh3D.prism(radius: 0.45, height: 0.6);

        for (var i = 0; i < 6; i++) {
          renderer.enqueueMesh(
            pedestal,
            camera: rig,
            worldX: (i - 3) * 1.4,
            worldY: 0,
            tint: const Color(0xFFD8B878),
            castGroundShadow: true,
          );
          renderer.enqueueMesh(
            crystal,
            camera: rig,
            worldX: (i - 3) * 1.4,
            worldY: 0,
            worldZ: 1.1,
            yawRad: i * 0.4,
            pitchRad: 0.15,
            tint: const Color(0xFF55E6FF),
            castGroundShadow: true,
          );
        }

        expect(renderer.activeEnqueuedMeshes, 12);

        final telemetry = RenderFrameTelemetry()..beginRenderFrame();
        final recorder = PictureRecorder();
        final rawCanvas = Canvas(recorder);
        final tracked = TelemetryCanvas()..bind(rawCanvas, telemetry);

        renderer.flushBatch(tracked);
        tracked.unbind();
        telemetry.endRenderFrame();
        recorder.endRecording().dispose();

        // Back-face culling discards ~half of closed convex polyhedron faces!
        const unculledTotal = 6 * (24 + 8);
        expect(renderer.lastFlushTriangles, lessThan(unculledTotal));
        expect(renderer.lastFlushTriangles, greaterThan(40));

        // 1 drawVertices for all shadows + 1 drawVertices for all 12 3D meshes!
        expect(renderer.lastFlushDrawCalls, 2);
        expect(telemetry.verticesCalls, 2);
        expect(renderer.lastFlushShadowTriangles, greaterThan(0));
        expect(renderer.activeEnqueuedMeshes, 0);

        // Also verify MatCap flush path
        final matCap = MatCapShader3D()..ensureInitialized();
        addTearDown(matCap.dispose);
        renderer
          ..beginBatch()
          ..enqueueMesh(
            crystal,
            camera: rig,
            worldX: 0,
            worldY: 0,
            worldZ: 1.0,
          );
        final rec2 = PictureRecorder();
        renderer.flushBatch(
          Canvas(rec2),
          matCapShader: matCap,
          matCapPreset: MatCapPreset3D.metallicGold,
        );
        rec2.endRecording().dispose();
        expect(renderer.lastFlushDrawCalls, 1);
      },
    );
  });
}
