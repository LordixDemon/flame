import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

void main() {
  setUpGpu();

  testGpuEngine(
    'PaletteMeshBatch3D draws multi-colored parts in 1 draw call and supports '
    'O(1) transform and visibility updates',
    () async {
      final mat = opaqueUnlit(const Color(0xFFFFFFFF));
      final cube = CuboidMesh(size: Vector3.all(0.32), material: mat);
      final batch = PaletteMeshBatch3D(material: mat);

      final leftId = batch.addPart(
        mesh: cube,
        transform: Matrix4.translationValues(-0.55, 0, -5),
        color: const Color(0xFFFF1818),
      );
      final midId = batch.addPart(
        mesh: cube,
        transform: Matrix4.translationValues(0.0, 0, -5),
        color: const Color(0xFF18FF18),
      );
      final rightId = batch.addPart(
        mesh: cube,
        transform: Matrix4.translationValues(0.55, 0, -5),
        color: const Color(0xFF1818FF),
      );

      final frame1 = await renderFrame(draw: batch.draw);
      expect(batch.partCount, 3);
      expect(batch.visiblePartCount, 3);
      expect(batch.lastDrawnCalls, 1);
      expect(frame1.stats.drawCalls, 1);

      final (lx, ly) = pixelAt(-0.55, 0);
      final (mx, my) = pixelAt(0.0, 0);
      final (rx, ry) = pixelAt(0.55, 0);
      final (movedX, movedY) = pixelAt(-0.55, 0.55);

      final (rL, gL, bL, aL) = frame1.pixels.at(lx, ly);
      final (rM, gM, bM, aM) = frame1.pixels.at(mx, my);
      final (rR, gR, bR, aR) = frame1.pixels.at(rx, ry);
      expect(aL, 255);
      expect(rL, greaterThan(gL + 100));
      expect(rL, greaterThan(bL + 100));
      expect(aM, 255);
      expect(gM, greaterThan(rM + 100));
      expect(gM, greaterThan(bM + 100));
      expect(aR, 255);
      expect(bR, greaterThan(rR + 100));
      expect(bR, greaterThan(gR + 100));

      // O(1) transform move + hide middle part without rebuilding geometry.
      batch
        ..setPartTransform(leftId, Matrix4.translationValues(-0.55, 0.55, -5))
        ..setPartVisible(midId, visible: false);

      expect(batch.visiblePartCount, 2);
      expect(batch.isPartVisible(midId), isFalse);

      // Raycast respects updated transform and hidden part.
      final hitMoved = batch.raycast(
        Ray.originDirection(
          Vector3(-0.55, 0.55, 0),
          Vector3(0, 0, -1),
        ),
      );
      expect(hitMoved, isNotNull);
      expect(hitMoved!.instanceIndex, leftId);

      final hitHidden = batch.raycast(
        Ray.originDirection(Vector3(0, 0, 0), Vector3(0, 0, -1)),
      );
      expect(hitHidden, isNull);

      final hitRight = batch.raycast(
        Ray.originDirection(Vector3(0.55, 0, 0), Vector3(0, 0, -1)),
      );
      expect(hitRight, isNotNull);
      expect(hitRight!.instanceIndex, rightId);

      // AABB expands to include moved part vertically.
      final aabbMoved = batch.computeLocalAabb()!;
      expect(aabbMoved.max.y, greaterThan(0.6));

      final frame2 = await renderFrame(draw: batch.draw);
      expect(batch.lastDrawnCalls, 1);
      expect(frame2.stats.drawCalls, 1);
      expect(frame2.pixels.isClear(lx, ly), isTrue);
      expect(frame2.pixels.isClear(mx, my), isTrue);
      expect(frame2.pixels.isClear(rx, ry), isFalse);
      final (mr, mg, mb, ma) = frame2.pixels.at(movedX, movedY);
      expect(ma, 255);
      expect(mr, greaterThan(mg + 100));
      expect(mr, greaterThan(mb + 100));

      // Restoring visibility renders green part again.
      batch.setPartVisible(midId, visible: true);
      final frame3 = await renderFrame(draw: batch.draw);
      final (rrM, rgM, rbM, raM) = frame3.pixels.at(mx, my);
      expect(raM, 255);
      expect(rgM, greaterThan(rrM + 100));
      expect(rgM, greaterThan(rbM + 100));
    },
  );

  testGpuEngine(
    'PaletteMeshBatch3D renders lit SpatialMaterial parts in 1 draw call',
    () async {
      final mat = SpatialMaterial(metallic: 0.0, roughness: 0.8);
      final cube = CuboidMesh(size: Vector3.all(0.4), material: mat);
      final batch = PaletteMeshBatch3D(material: mat)
        ..addPart(
          mesh: cube,
          transform: Matrix4.translationValues(-0.4, 0, -5),
          color: const Color(0xFFFF4040),
        )
        ..addPart(
          mesh: cube,
          transform: Matrix4.translationValues(0.4, 0, -5),
          color: const Color(0xFF40FF40),
        );

      final frame = await renderFrame(
        lights: [
          Light(
            position: Vector3.zero(),
            source: DirectionalLight(
              direction: Vector3(0, 0, -1),
              intensity: 2.0,
            ),
          ),
        ],
        draw: batch.draw,
      );
      expect(batch.lastDrawnCalls, 1);
      expect(frame.stats.drawCalls, 1);

      final (lx, ly) = pixelAt(-0.4, 0);
      final (rx, ry) = pixelAt(0.4, 0);
      final (r1, g1, _, a1) = frame.pixels.at(lx, ly);
      final (r2, g2, _, a2) = frame.pixels.at(rx, ry);
      expect(a1, 255);
      expect(a2, 255);
      expect(r1, greaterThan(g1 + 50));
      expect(g2, greaterThan(r2 + 50));
    },
  );
}
