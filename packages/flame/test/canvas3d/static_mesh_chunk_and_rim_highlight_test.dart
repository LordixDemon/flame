import 'dart:ui';

import 'package:flame/canvas3d.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StaticMeshChunk3D & Fresnel rim highlight (#10)', () {
    test(
      'StaticMeshChunk3D caches lighting across stationary and panned frames',
      () {
        final camera = CameraRig3D();
        final batcher = BatchMeshRenderer3D();
        final box = Mesh3D.box(
          sizeX: 0.8,
          sizeY: 0.8,
          sizeZ: 1.2,
          centerZ: 0.6,
        );

        final chunk = StaticMeshChunk3D()
          ..addInstance(
            StaticMeshInstance3D(
              mesh: box,
              worldX: -1.0,
              worldY: 0.0,
              tint: const Color(0xFFE57373),
              castGroundShadow: true,
            ),
          )
          ..addInstance(
            StaticMeshInstance3D(
              mesh: box,
              worldX: 1.0,
              worldY: 0.5,
              tint: const Color(0xFF64B5F6),
              castGroundShadow: true,
            ),
          );

        void drawFrame() {
          final recorder = PictureRecorder();
          batcher
            ..beginBatch()
            ..enqueueStaticChunk(chunk, camera: camera)
            ..flushBatch(Canvas(recorder));
          recorder.endRecording().dispose();
        }

        // Frame 1: initial bake of both geometry/lighting and projection.
        drawFrame();
        expect(chunk.geometryBakeCount, 1);
        expect(chunk.projectionBakeCount, 1);
        expect(batcher.lastFlushTriangles, greaterThan(0));
        expect(batcher.lastFlushShadowTriangles, greaterThan(0));

        // Frames 2..4 (stationary camera & light): zero re-bakes!
        drawFrame();
        drawFrame();
        drawFrame();
        expect(chunk.geometryBakeCount, 1);
        expect(chunk.projectionBakeCount, 1);

        // Pure 2D camera pan (basisVersion & light unchanged): projection
        // updates, but expensive world normals & lighting stay cached!
        camera.update(camX: 48.0, camY: -12.0, zoom: 1.15);
        drawFrame();
        expect(chunk.geometryBakeCount, 1);
        expect(chunk.projectionBakeCount, 2);

        // 3D camera orbit changes basisVersion -> triggers lighting/UV re-bake.
        final prevBasisVer = camera.basisVersion;
        camera.update(
          camX: 48.0,
          camY: -12.0,
          zoom: 1.15,
          orbitYawDelta: 0.2,
        );
        expect(camera.basisVersion, greaterThan(prevBasisVer));
        drawFrame();
        expect(chunk.geometryBakeCount, 2);
        expect(chunk.projectionBakeCount, 3);

        // Changing sun direction invalidates lighting signature -> re-bakes.
        batcher.light.setDirection(0.5, -0.4, 0.75);
        drawFrame();
        expect(chunk.geometryBakeCount, 3);
      },
    );

    testWidgets(
      'BatchMeshRenderer3D rimColor brightens silhouette vertices',
      (tester) async {
        final camera = CameraRig3D();
        final batcher = BatchMeshRenderer3D();
        final mesh = Mesh3D.octahedron(
          radiusXY: 0.9,
          halfHeight: 0.9,
          centerZ: 0.9,
        );

        Future<int> measureBrightChannelSum({
          Color? rimColor,
          double rimIntensity = 0.0,
        }) async {
          final recorder = PictureRecorder();
          final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, 96, 96));
          batcher
            ..beginBatch()
            ..enqueueMesh(
              mesh,
              camera: camera,
              worldX: 0,
              worldY: 0,
              canvasOrigin: const Offset(-48, -64),
              tint: const Color(0xFF203040),
              rimColor: rimColor,
              rimHighlightIntensity: rimIntensity,
            )
            ..flushBatch(canvas);
          final picture = recorder.endRecording();
          return (await tester.runAsync(() async {
            final img = picture.toImageSync(96, 96);
            try {
              final data = await img.toByteData();
              var sum = 0;
              for (var i = 0; i < data!.lengthInBytes; i += 4) {
                sum +=
                    data.getUint8(i) +
                    data.getUint8(i + 1) +
                    data.getUint8(i + 2);
              }
              return sum;
            } finally {
              img.dispose();
              picture.dispose();
            }
          }))!;
        }

        final baseSum = await measureBrightChannelSum();
        final rimSum = await measureBrightChannelSum(
          rimColor: const Color(0xFFFFEE88),
          rimIntensity: 0.95,
        );
        expect(rimSum, greaterThan(baseSum));
      },
    );
  });
}
