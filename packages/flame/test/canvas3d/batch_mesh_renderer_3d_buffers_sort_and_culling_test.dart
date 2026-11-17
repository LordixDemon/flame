import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/canvas3d.dart';
import 'package:flutter_test/flutter_test.dart';

const _flat = Material3D.unshaded();

/// Flushes [renderer] into a `width x height` image whose centre shows the
/// canvas point [centre], on an opaque black background.
Future<ByteData> _rasterize(
  BatchMeshRenderer3D renderer,
  Offset centre, {
  int width = 200,
  int height = 200,
}) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder)
    ..drawColor(const Color(0xFF000000), BlendMode.src)
    ..translate(width / 2 - centre.dx, height / 2 - centre.dy);
  renderer.flushBatch(canvas);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(width, height);
  final bytes = await image.toByteData();
  image.dispose();
  picture.dispose();
  return bytes!;
}

int _litPixels(ByteData bytes) {
  var lit = 0;
  for (var i = 0; i < bytes.lengthInBytes; i += 4) {
    if (bytes.getUint8(i) > 40 ||
        bytes.getUint8(i + 1) > 40 ||
        bytes.getUint8(i + 2) > 40) {
      lit++;
    }
  }
  return lit;
}

void main() {
  group('BatchMeshRenderer3D pooled buffers', () {
    test('flushShadows draws every queued shadow triangle when the triangle '
        'buffers grow after the shadow buffers did', () {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      // Default capacities (512 triangles / 512 shadow triangles).
      final renderer = BatchMeshRenderer3D()..beginBatch();
      // 96 triangles; 16 of them are zero-area pole triangles, so 40 are
      // visible after back-face culling while a double-sided shadow keeps 96.
      final sphere = Mesh3D.uvSphere(radius: 0.3, segments: 8, rings: 6);
      for (var i = 0; i < 12; i++) {
        renderer.enqueueMesh(
          sphere,
          camera: rig,
          worldX: i.toDouble(),
          worldY: 0,
          worldZ: 1,
          castGroundShadow: true,
          doubleSidedShadow: true,
        );
      }
      // The shadow buffer has outgrown the triangle buffer (2048 vs 1024).
      expect(renderer.pendingGeometryTriangleCount, 480);
      expect(renderer.pendingShadowTriangleCount, 1152);

      final recorder = PictureRecorder();
      addTearDown(() => recorder.endRecording().dispose());
      final canvas = Canvas(recorder);
      expect(() => renderer.flushShadows(canvas), returnsNormally);
      expect(renderer.lastFlushShadowTriangles, 1152);
      expect(() => renderer.flushGeometry(canvas), returnsNormally);
      expect(renderer.lastFlushTriangles, 480);
    });

    test('grows from zero initial capacities', () {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      final renderer = BatchMeshRenderer3D(
        initialVertexCapacity: 0,
        initialTriangleCapacity: 0,
      )..beginBatch();
      renderer.enqueueMesh(
        Mesh3D.box(),
        camera: rig,
        worldX: 0,
        worldY: 0,
        worldZ: 1,
        castGroundShadow: true,
      );
      expect(renderer.pendingGeometryTriangleCount, 6);
      expect(renderer.pendingShadowTriangleCount, greaterThan(0));

      final recorder = PictureRecorder();
      addTearDown(() => recorder.endRecording().dispose());
      expect(() => renderer.flushBatch(Canvas(recorder)), returnsNormally);
      expect(renderer.lastFlushDrawCalls, 2);
    });
  });

  group('BatchMeshRenderer3D depth sort', () {
    /// Draws a red quad, then a blue quad at exactly the same place, plus
    /// [fillers] unrelated quads far away. Returns `true` when blue is on top.
    Future<bool> blueOnTop(int fillers) async {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      final quad = Mesh3D.plane();
      final renderer = BatchMeshRenderer3D(shadowsEnabled: false)..beginBatch();
      for (var f = 0; f < fillers; f++) {
        renderer.enqueueMesh(
          quad,
          camera: rig,
          worldX: 6 + f * 0.1,
          worldY: -6 + (f % 7) * 0.33,
          tint: const Color(0xFF00FF00),
          emissive: 1,
          material: _flat,
        );
      }
      renderer
        ..enqueueMesh(
          quad,
          camera: rig,
          worldX: 0,
          worldY: 0,
          tint: const Color(0xFFFF0000),
          emissive: 1,
          material: _flat,
        )
        ..enqueueMesh(
          quad,
          camera: rig,
          worldX: 0,
          worldY: 0,
          tint: const Color(0xFF0000FF),
          emissive: 1,
          material: _flat,
        );
      final bytes = await _rasterize(renderer, rig.gridToScreen(0, 0));
      const o = (100 * 200 + 100) * 4;
      return bytes.getUint8(o + 2) > bytes.getUint8(o);
    }

    test('triangles with equal sortOrder and depth keep submission order, '
        'whatever else shares the batch', () async {
      for (var fillers = 0; fillers <= 12; fillers++) {
        expect(
          await blueOnTop(fillers),
          isTrue,
          reason: 'later submission must stay on top with $fillers fillers',
        );
      }
    });

    test('sortOrder still outranks submission order on a tie', () async {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      final quad = Mesh3D.plane();
      final renderer = BatchMeshRenderer3D(shadowsEnabled: false)
        ..beginBatch()
        ..enqueueMesh(
          quad,
          camera: rig,
          worldX: 0,
          worldY: 0,
          tint: const Color(0xFFFF0000),
          emissive: 1,
          material: _flat,
          sortOrder: 1,
        )
        ..enqueueMesh(
          quad,
          camera: rig,
          worldX: 0,
          worldY: 0,
          tint: const Color(0xFF0000FF),
          emissive: 1,
          material: _flat,
        );
      final bytes = await _rasterize(renderer, rig.gridToScreen(0, 0));
      const o = (100 * 200 + 100) * 4;
      expect(bytes.getUint8(o), greaterThan(bytes.getUint8(o + 2)));
    });
  });

  group('BatchMeshRenderer3D bounding-sphere frustum culling', () {
    test('perspective: keeps a mesh close to the eye that overlaps the cull '
        'rect, and drops one that is clear of it', () {
      final rig = CameraRig3D(
        projectionMode: CameraProjectionMode3D.perspective,
      )..update(camX: 0, camY: 0, zoom: 1);
      final mesh = Mesh3D.box();
      // 80 % of the way from the look-at target to the eye: the box is drawn
      // five times larger than at the target.
      final k = rig.cameraDistance * 0.8;
      final wx = rig.viewX * k;
      final wy = rig.viewY * k;
      final wz = rig.viewZ * k;
      var maxX = double.negativeInfinity;
      for (var v = 0; v < mesh.vertexCount; v++) {
        final s = rig.projectWorldPoint(
          wx + mesh.positions[v * 3],
          wy + mesh.positions[v * 3 + 1],
          wz + mesh.positions[v * 3 + 2],
        );
        maxX = math.max(maxX, s.dx);
      }
      expect(maxX, greaterThan(200)); // the box spans about -205..205 px

      final overlapping = BatchMeshRenderer3D(
        cullScreenBounds: Rect.fromLTRB(maxX - 40, -2000, maxX + 2000, 2000),
      )..beginBatch();
      overlapping.enqueueMesh(
        mesh,
        camera: rig,
        worldX: wx,
        worldY: wy,
        worldZ: wz,
      );
      expect(overlapping.activeEnqueuedMeshes, 1);

      final clear = BatchMeshRenderer3D(
        cullScreenBounds: Rect.fromLTRB(maxX + 600, -2000, maxX + 2000, 2000),
      )..beginBatch();
      clear.enqueueMesh(mesh, camera: rig, worldX: wx, worldY: wy, worldZ: wz);
      expect(clear.activeEnqueuedMeshes, 0);

      // Entirely behind the near plane: nothing of it can be drawn.
      final behind = BatchMeshRenderer3D(
        cullScreenBounds: const Rect.fromLTRB(-2000, -2000, 2000, 2000),
      )..beginBatch();
      final far = rig.cameraDistance * 1.5;
      behind.enqueueMesh(
        mesh,
        camera: rig,
        worldX: rig.viewX * far,
        worldY: rig.viewY * far,
        worldZ: rig.viewZ * far,
      );
      expect(behind.activeEnqueuedMeshes, 0);
    });

    test('axonometric: keeps a pitched mesh whose bottom edge is inside the '
        'cull rect', () {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      // The body lives at local z 2..4; pitched by pi it hangs at world
      // z 1..3, far from where an unrotated mesh would be.
      final mesh = Mesh3D.prism(radius: 0.2, height: 2, baseZ: 2);
      const worldZ = 5.0;
      const pitch = math.pi;
      final rot = Float32List(9);
      Quaternion3D.writeEulerMatrix3(
        yawRad: 0,
        pitchRad: pitch,
        rollRad: 0,
        out: rot,
      );
      final anchor = rig.gridToScreen(0, 0);
      var maxY = double.negativeInfinity;
      for (var v = 0; v < mesh.vertexCount; v++) {
        final lx = mesh.positions[v * 3];
        final ly = mesh.positions[v * 3 + 1];
        final lz = mesh.positions[v * 3 + 2];
        final (_, sy) = rig.projectAnchored(
          anchorWorld: anchor,
          canvasOrigin: Offset.zero,
          rx: rot[0] * lx + rot[1] * ly + rot[2] * lz,
          ry: rot[3] * lx + rot[4] * ly + rot[5] * lz,
          rz: rot[6] * lx + rot[7] * ly + rot[8] * lz + worldZ,
        );
        maxY = math.max(maxY, sy);
      }

      final renderer = BatchMeshRenderer3D(
        cullScreenBounds: Rect.fromLTRB(-5000, maxY - 30, 5000, maxY + 5000),
      )..beginBatch();
      renderer.enqueueMesh(
        mesh,
        camera: rig,
        worldX: 0,
        worldY: 0,
        worldZ: worldZ,
        pitchRad: pitch,
      );
      expect(renderer.activeEnqueuedMeshes, 1);
    });

    test('axonometric: never drops a mesh that reaches into the cull rect, '
        'under any rotation, height or camera state', () {
      final rnd = math.Random(5);
      final rot = Float32List(9);
      for (var iter = 0; iter < 1500; iter++) {
        final rig = CameraRig3D()
          ..update(
            camX: rnd.nextDouble() * 400 - 200,
            camY: rnd.nextDouble() * 400 - 200,
            zoom: 1 + rnd.nextDouble() * 2,
            orbitYawDelta: rnd.nextDouble() * 0.8 - 0.4,
            pitchDelta: rnd.nextDouble() * 0.4 - 0.2,
          );
        final mesh = switch (rnd.nextInt(3)) {
          0 => Mesh3D.box(
            sizeX: 0.2 + rnd.nextDouble(),
            sizeY: 0.2 + rnd.nextDouble(),
            sizeZ: 0.2 + rnd.nextDouble() * 4,
            centerZ: rnd.nextDouble() * 3,
          ),
          1 => Mesh3D.prism(
            radius: 0.1 + rnd.nextDouble() * 0.5,
            height: 0.2 + rnd.nextDouble() * 5,
            baseZ: rnd.nextDouble() * 2,
          ),
          _ => Mesh3D.pyramid(
            baseX: 0.3,
            baseY: 0.3,
            height: 3 + rnd.nextDouble() * 3,
          ),
        };
        final wx = rnd.nextDouble() * 12 - 6;
        final wy = rnd.nextDouble() * 12 - 6;
        final wz = rnd.nextDouble() * 3;
        final yaw = rnd.nextDouble() * 6;
        final pitch = rnd.nextDouble() * 6;
        final roll = rnd.nextDouble() * 6;
        Quaternion3D.writeEulerMatrix3(
          yawRad: yaw,
          pitchRad: pitch,
          rollRad: roll,
          out: rot,
        );
        final anchor = rig.gridToScreen(wx, wy);
        var minX = double.infinity;
        var maxX = double.negativeInfinity;
        var minY = double.infinity;
        var maxY = double.negativeInfinity;
        for (var v = 0; v < mesh.vertexCount; v++) {
          final lx = mesh.positions[v * 3];
          final ly = mesh.positions[v * 3 + 1];
          final lz = mesh.positions[v * 3 + 2];
          final (sx, sy) = rig.projectAnchored(
            anchorWorld: anchor,
            canvasOrigin: Offset.zero,
            rx: rot[0] * lx + rot[1] * ly + rot[2] * lz,
            ry: rot[3] * lx + rot[4] * ly + rot[5] * lz,
            rz: rot[6] * lx + rot[7] * ly + rot[8] * lz + wz,
          );
          minX = math.min(minX, sx);
          maxX = math.max(maxX, sx);
          minY = math.min(minY, sy);
          maxY = math.max(maxY, sy);
        }
        // A cull rect that the true screen bounds reach into by 2 px.
        final rect = switch (rnd.nextInt(4)) {
          0 => Rect.fromLTRB(maxX - 2, -1e5, 1e5, 1e5),
          1 => Rect.fromLTRB(-1e5, -1e5, minX + 2, 1e5),
          2 => Rect.fromLTRB(-1e5, maxY - 2, 1e5, 1e5),
          _ => Rect.fromLTRB(-1e5, -1e5, 1e5, minY + 2),
        };
        final renderer = BatchMeshRenderer3D(
          cullScreenBounds: rect,
          backfaceCulling: false,
        )..beginBatch();
        renderer.enqueueMesh(
          mesh,
          camera: rig,
          worldX: wx,
          worldY: wy,
          worldZ: wz,
          yawRad: yaw,
          pitchRad: pitch,
          rollRad: roll,
        );
        expect(renderer.activeEnqueuedMeshes, 1, reason: 'iteration $iter');
      }
    });

    test('still drops far-away meshes and chunks, and keeps a mesh whose '
        'ground shadow is the only part in view', () {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      final box = Mesh3D.box(sizeX: 0.8, sizeY: 0.8);
      const view = Rect.fromLTRB(-200, -200, 200, 200);

      final renderer = BatchMeshRenderer3D(cullScreenBounds: view)
        ..beginBatch()
        ..enqueueMesh(box, camera: rig, worldX: 0, worldY: 0)
        ..enqueueMesh(box, camera: rig, worldX: 50, worldY: -50);
      expect(renderer.activeEnqueuedMeshes, 1);

      final farChunk = StaticMeshChunk3D()
        ..addInstance(
          StaticMeshInstance3D(mesh: box, worldX: 50, worldY: -50),
        );
      renderer.enqueueStaticChunk(farChunk, camera: rig);
      expect(renderer.activeEnqueuedMeshes, 1);
      expect(farChunk.geometryBakeCount, 0);

      // A box floating 12 units up is far above the view, but the sun drops
      // its shadow back onto the ground inside it.
      final centre = rig.projectWorldPoint(0, 0, 12);
      expect(centre.dy, lessThan(view.top - 200));
      final shadowOnly = BatchMeshRenderer3D(cullScreenBounds: view)
        ..beginBatch()
        ..enqueueMesh(
          box,
          camera: rig,
          worldX: 0,
          worldY: 0,
          worldZ: 12,
          castGroundShadow: true,
        );
      expect(shadowOnly.activeEnqueuedMeshes, 1);
      expect(shadowOnly.pendingShadowTriangleCount, greaterThan(0));

      final noShadow = BatchMeshRenderer3D(cullScreenBounds: view)
        ..beginBatch()
        ..enqueueMesh(box, camera: rig, worldX: 0, worldY: 0, worldZ: 12);
      expect(noShadow.activeEnqueuedMeshes, 0);

      final floatingChunk = StaticMeshChunk3D()
        ..addInstance(
          StaticMeshInstance3D(
            mesh: box,
            worldX: 0,
            worldY: 0,
            worldZ: 12,
            castGroundShadow: true,
          ),
        );
      final chunkRenderer = BatchMeshRenderer3D(cullScreenBounds: view)
        ..beginBatch()
        ..enqueueStaticChunk(floatingChunk, camera: rig);
      expect(chunkRenderer.pendingShadowTriangleCount, greaterThan(0));
    });
  });

  group('BatchMeshRenderer3D.minTrianglePixelArea', () {
    Future<(int lit, int culled, int queued)> drawSphere({
      required double radius,
      required double minTrianglePixelArea,
      double zoom = 1,
    }) async {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: zoom);
      final renderer = BatchMeshRenderer3D(
        shadowsEnabled: false,
        minTrianglePixelArea: minTrianglePixelArea,
      )..beginBatch();
      renderer.enqueueMesh(
        Mesh3D.uvSphere(radius: radius),
        camera: rig,
        worldX: 0,
        worldY: 0,
        tint: const Color(0xFFFF0000),
        emissive: 1,
      );
      final queued = renderer.pendingGeometryTriangleCount;
      final bytes = await _rasterize(
        renderer,
        rig.projectWorldPoint(0, 0, 0),
        width: 100,
        height: 100,
      );
      return (_litPixels(bytes), renderer.lastCulledMicroTriangles, queued);
    }

    test('a densely tessellated mesh that is still a dozen pixels wide keeps '
        'its silhouette', () async {
      // Default 16 x 12 sphere, 12.4 px across: every triangle is smaller
      // than 1.5 px^2, yet together they cover about 120 pixels.
      final (full, _, fullQueued) = await drawSphere(
        radius: 0.1,
        minTrianglePixelArea: 0,
      );
      final (kept, culled, keptQueued) = await drawSphere(
        radius: 0.1,
        minTrianglePixelArea: 1.5,
      );
      expect(full, greaterThan(90));
      expect(kept, full);
      expect(culled, 0);
      expect(keptQueued, fullQueued);
    });

    test(
      'a mesh smaller than the threshold in total is dropped whole',
      () async {
        // 1.2 px across: its entire silhouette is below 1.5 px^2.
        final (lit, culled, queued) = await drawSphere(
          radius: 0.01,
          minTrianglePixelArea: 1.5,
        );
        expect(queued, 0);
        expect(culled, greaterThan(100));
        expect(lit, 0);
      },
    );

    test('isolated micro-triangles of a mostly large mesh are dropped', () {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      // One 2 x 2 quad plus a sliver of about 0.4 px^2 next to it.
      final mesh = Mesh3D.fromRaw(
        positions: Float32List.fromList([
          -1, -1, 0, //
          1, -1, 0,
          1, 1, 0,
          -1, 1, 0,
          1.5, 0, 0,
          1.52, 0, 0,
          1.52, 0.02, 0,
        ]),
        indices: Uint16List.fromList([0, 1, 2, 0, 2, 3, 4, 5, 6]),
      );
      final renderer = BatchMeshRenderer3D(
        shadowsEnabled: false,
        minTrianglePixelArea: 1.5,
      )..beginBatch();
      renderer.enqueueMesh(mesh, camera: rig, worldX: 0, worldY: 0);
      expect(renderer.pendingGeometryTriangleCount, 2);

      final chunk = StaticMeshChunk3D()
        ..addInstance(StaticMeshInstance3D(mesh: mesh, worldX: 0, worldY: 0))
        ..prepare(
          camera: rig,
          light: DirectionalLight3D(),
          minTrianglePixelArea: 1.5,
        );
      expect(chunk.visibleTriCount, 2);
      expect(chunk.lastCulledMicroTriangles, 1);

      final recorder = PictureRecorder();
      addTearDown(() => recorder.endRecording().dispose());
      renderer.flushBatch(Canvas(recorder));
      expect(renderer.lastCulledMicroTriangles, 1);
    });

    test(
      'the threshold is in screen pixels: it follows the 2D camera zoom',
      () async {
        // 6.2 canvas units across. At zoom 1 that is 6 px (30 px^2, kept); at
        // zoom 0.2 it is 1.2 px on screen and below the 1.5 px^2 threshold.
        final (_, culledAtZoom1, queuedAtZoom1) = await drawSphere(
          radius: 0.05,
          minTrianglePixelArea: 1.5,
        );
        expect(culledAtZoom1, 0);
        expect(queuedAtZoom1, greaterThan(100));

        final (_, culledZoomedOut, queuedZoomedOut) = await drawSphere(
          radius: 0.05,
          minTrianglePixelArea: 1.5,
          zoom: 0.2,
        );
        expect(queuedZoomedOut, 0);
        expect(culledZoomedOut, greaterThan(100));
      },
    );

    test('a static chunk judges each instance like a dynamic mesh', () {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      final light = DirectionalLight3D();
      final dense = Mesh3D.uvSphere(radius: 0.1);
      final speck = Mesh3D.uvSphere(radius: 0.01);

      final reference = StaticMeshChunk3D()
        ..addInstance(StaticMeshInstance3D(mesh: dense, worldX: 0, worldY: 0))
        ..prepare(camera: rig, light: light);
      final chunk = StaticMeshChunk3D()
        ..addInstance(StaticMeshInstance3D(mesh: dense, worldX: 0, worldY: 0))
        ..addInstance(StaticMeshInstance3D(mesh: speck, worldX: 2, worldY: 0))
        ..prepare(camera: rig, light: light, minTrianglePixelArea: 1.5);

      // The dense sphere is intact, the speck is gone.
      expect(chunk.visibleTriCount, reference.visibleTriCount);
      expect(chunk.lastCulledMicroTriangles, greaterThan(100));
    });
  });
}
