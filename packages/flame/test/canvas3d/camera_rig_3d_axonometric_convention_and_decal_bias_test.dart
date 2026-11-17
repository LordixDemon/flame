import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/canvas3d.dart';
import 'package:flutter_test/flutter_test.dart';

double _distPointToRay(Ray3D r, double px, double py, double pz) {
  final vx = px - r.ox;
  final vy = py - r.oy;
  final vz = pz - r.oz;
  final t = vx * r.dx + vy * r.dy + vz * r.dz;
  final cx = r.ox + r.dx * t - px;
  final cy = r.oy + r.dy * t - py;
  final cz = r.oz + r.dz * t - pz;
  return math.sqrt(cx * cx + cy * cy + cz * cz);
}

void main() {
  // A small sway, as a cut-in camera would apply it.
  const orbitYaw = -0.065;
  const pitch = -0.105;

  CameraRig3D swayedRig({double yaw = orbitYaw, double pitchDelta = pitch}) {
    return CameraRig3D()..update(
      camX: 30,
      camY: -12,
      zoom: 1,
      orbitYawDelta: yaw,
      pitchDelta: pitchDelta,
    );
  }

  group('CameraRig3D axonometric convention', () {
    test('anchors stay on the fixed 2:1 lattice whatever the deltas are', () {
      final rest = CameraRig3D()..update(camX: 30, camY: -12, zoom: 1);
      final swayed = swayedRig(yaw: 0.4, pitchDelta: 0.25);
      for (final (gx, gy) in [(0.0, 0.0), (3.0, 0.0), (-2.5, 4.0)]) {
        expect(swayed.gridToScreen(gx, gy), rest.gridToScreen(gx, gy));
        expect(
          swayed.projectWorldPoint(gx, gy, 0),
          rest.projectWorldPoint(gx, gy, 0),
        );
        final anchor = swayed.gridToScreen(gx, gy);
        final (sx, sy) = swayed.projectAnchored(
          anchorWorld: anchor,
          canvasOrigin: Offset.zero,
          rx: 0,
          ry: 0,
          rz: 0,
        );
        expect(sx, closeTo(anchor.dx, 1e-9));
        expect(sy, closeTo(anchor.dy, 1e-9));
      }
    });

    test('the deltas turn offsets about the anchor: a tilt of each object, '
        'not an orbit of the scene', () {
      final rig = swayedRig();
      final anchor = rig.gridToScreen(0, 0);
      final (ex, ey) = rig.projectAnchored(
        anchorWorld: anchor,
        canvasOrigin: Offset.zero,
        rx: 3,
        ry: 0,
        rz: 0,
      );
      // The offset is measured in the rotated camera basis ...
      expect(ex - anchor.dx, closeTo(3 * rig.rightX * rig.focalScalePx, 1e-9));
      expect(ey - anchor.dy, closeTo(-3 * rig.upX * rig.focalScalePx, 1e-9));

      // ... so the end of a 3-unit mesh anchored at (0, 0) and the foot of a
      // prop anchored at (3, 0) are the same world point on different pixels.
      final prop = rig.gridToScreen(3, 0);
      final gap = math.sqrt(
        (ex - prop.dx) * (ex - prop.dx) + (ey - prop.dy) * (ey - prop.dy),
      );
      expect(gap, greaterThan(5.0));

      // At rest the two agree exactly.
      final rest = CameraRig3D()..update(camX: 30, camY: -12, zoom: 1);
      final (rx, ry) = rest.projectAnchored(
        anchorWorld: rest.gridToScreen(0, 0),
        canvasOrigin: Offset.zero,
        rx: 3,
        ry: 0,
        rz: 0,
      );
      expect(rx, closeTo(rest.gridToScreen(3, 0).dx, 1e-9));
      expect(ry, closeTo(rest.gridToScreen(3, 0).dy, 1e-9));
    });

    test('projectWorldPoint follows the pitch delta but not the yaw delta', () {
      final rest = CameraRig3D()..update(camX: 30, camY: -12, zoom: 1);
      final yawOnly = swayedRig(pitchDelta: 0);
      final pitched = swayedRig(yaw: 0);
      expect(
        yawOnly.projectWorldPoint(2, 1, 1.5),
        rest.projectWorldPoint(2, 1, 1.5),
      );
      expect(
        pitched.projectWorldPoint(2, 1, 1.5).dy,
        isNot(closeTo(rest.projectWorldPoint(2, 1, 1.5).dy, 1.0)),
      );
    });
  });

  group('CameraRig3D.unprojectWorldRay (axonometric)', () {
    test(
      'without an anchor it inverts projectWorldPoint under both deltas',
      () {
        for (final rig in [swayedRig(), swayedRig(yaw: 0.3, pitchDelta: 0.2)]) {
          for (final (wx, wy) in [(4.0, -3.0), (-1.5, 2.0), (0.0, 0.0)]) {
            for (final wz in [0.0, 1.0]) {
              final tap = rig.projectWorldPoint(wx, wy, wz);
              final ray = rig.unprojectWorldRay(tap);
              expect(_distPointToRay(ray, wx, wy, wz), lessThan(1e-6));
              expect(ray.dz, lessThan(0.0));
            }
            // Between and above the two exact heights the parallax bends the
            // true pre-image a little; the ray stays within a few hundredths.
            final tap = rig.projectWorldPoint(wx, wy, 2.0);
            final ray = rig.unprojectWorldRay(tap);
            expect(_distPointToRay(ray, wx, wy, 2.0), lessThan(0.05));
          }
        }
      },
    );

    test('with an anchor it inverts projectAnchored for that anchor under '
        'both deltas', () {
      for (final rig in [swayedRig(), swayedRig(yaw: 0.3, pitchDelta: 0.2)]) {
        final anchor = rig.gridToScreen(4, -3);
        for (final (rx, ry, rz) in [
          (0.45, 0.45, 1.0), // a roof corner
          (-0.45, 0.3, 1.0),
          (0.45, -0.45, 0.0), // a footprint corner
          (0.0, 0.0, 1.0),
        ]) {
          final (sx, sy) = rig.projectAnchored(
            anchorWorld: anchor,
            canvasOrigin: Offset.zero,
            rx: rx,
            ry: ry,
            rz: rz,
          );
          final tap = Offset(sx, sy);
          final anchored = rig.unprojectWorldRay(tap, anchorWorld: anchor);
          expect(
            _distPointToRay(anchored, 4 + rx, -3 + ry, rz),
            lessThan(1e-6),
          );
        }

        // A vertex half way up is still met within a hundredth of a unit.
        final (mx, my) = rig.projectAnchored(
          anchorWorld: anchor,
          canvasOrigin: Offset.zero,
          rx: 0.45,
          ry: 0.45,
          rz: 0.5,
        );
        final mid = rig.unprojectWorldRay(Offset(mx, my), anchorWorld: anchor);
        expect(_distPointToRay(mid, 4.45, -2.55, 0.5), lessThan(0.01));
      }
    });

    test('the anchorless ray misses an offset vertex of a turned object, '
        'which is what the anchor parameter is for', () {
      final rig = swayedRig(yaw: 0.3, pitchDelta: 0);
      final anchor = rig.gridToScreen(4, -3);
      final (sx, sy) = rig.projectAnchored(
        anchorWorld: anchor,
        canvasOrigin: Offset.zero,
        rx: 0.45,
        ry: 0.45,
        rz: 1.0,
      );
      final plain = rig.unprojectWorldRay(Offset(sx, sy));
      final anchored = rig.unprojectWorldRay(
        Offset(sx, sy),
        anchorWorld: anchor,
      );
      expect(_distPointToRay(plain, 4.45, -2.55, 1.0), greaterThan(0.1));
      expect(_distPointToRay(anchored, 4.45, -2.55, 1.0), lessThan(1e-6));
    });

    test('at rest the anchor makes no difference', () {
      final rig = CameraRig3D()..update(camX: 30, camY: -12, zoom: 1.4);
      const tap = Offset(140, 65);
      final plain = rig.unprojectWorldRay(tap);
      final anchored = rig.unprojectWorldRay(
        tap,
        anchorWorld: rig.gridToScreen(4, -3),
      );
      expect(anchored.ox, closeTo(plain.ox, 1e-9));
      expect(anchored.oy, closeTo(plain.oy, 1e-9));
      expect(anchored.oz, closeTo(plain.oz, 1e-9));
      expect(anchored.dx, closeTo(plain.dx, 1e-9));
      expect(anchored.dy, closeTo(plain.dy, 1e-9));
      expect(anchored.dz, closeTo(plain.dz, 1e-9));
    });

    test('in perspective mode the ray is the exact inverse of '
        'projectWorldPoint and the anchor is ignored', () {
      final rig =
          CameraRig3D(
            projectionMode: CameraProjectionMode3D.perspective,
            fovYRad: math.pi / 3,
          )..update(
            camX: 120,
            camY: -40,
            zoom: 0.6,
            orbitYawDelta: 0.3,
            pitchDelta: 0.2,
          );
      for (final (wx, wy, wz) in [(1.0, 2.0, 0.5), (-3.0, 4.0, 2.0)]) {
        final tap = rig.projectWorldPoint(wx, wy, wz);
        final ray = rig.unprojectWorldRay(tap);
        expect(_distPointToRay(ray, wx, wy, wz), lessThan(1e-9));
        final anchored = rig.unprojectWorldRay(
          tap,
          anchorWorld: rig.gridToScreen(9, 9),
        );
        expect(anchored.dx, ray.dx);
        expect(anchored.ox, ray.ox);
      }
    });
  });

  group('Decal3D.normalBias', () {
    /// Centroid of the lit pixels of [decal] in a 300 x 300 image centred on
    /// the canvas origin.
    Future<Offset> centroid(Decal3D decal) async {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      final renderer = BatchMeshRenderer3D(
        backfaceCulling: false,
        shadowsEnabled: false,
      )..beginBatch();
      decal.enqueue(renderer, camera: rig);
      final recorder = PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawColor(const Color(0xFF000000), BlendMode.src)
        ..translate(150, 150);
      renderer.flushBatch(canvas);
      final picture = recorder.endRecording();
      final image = picture.toImageSync(300, 300);
      final bytes = await image.toByteData();
      image.dispose();
      picture.dispose();
      var sumX = 0.0;
      var sumY = 0.0;
      var n = 0;
      for (var y = 0; y < 300; y++) {
        for (var x = 0; x < 300; x++) {
          if (bytes!.getUint8((y * 300 + x) * 4) > 60) {
            sumX += x;
            sumY += y;
            n++;
          }
        }
      }
      expect(n, greaterThan(100));
      return Offset(sumX / n - 150, sumY / n - 150);
    }

    Decal3D decal({required double pitchRad, required double normalBias}) {
      return Decal3D(
        worldX: 0,
        worldY: 0,
        worldZ: 0.5,
        pitchRad: pitchRad,
        normalBias: normalBias,
        emissive: 1,
        material: const Material3D.unshaded(),
      );
    }

    test('lifts a flat decal straight up', () async {
      final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
      final low = await centroid(decal(pitchRad: 0, normalBias: 0));
      final high = await centroid(decal(pitchRad: 0, normalBias: 1));
      expect(high.dx - low.dx, closeTo(0.0, 1.5));
      expect(high.dy - low.dy, closeTo(-rig.zPixelsPerCell, 2.5));
    });

    test(
      'lifts a decal standing on edge along its own normal, not up',
      () async {
        // Pitched a quarter turn about +Y the decal faces along world +X.
        final rig = CameraRig3D()..update(camX: 0, camY: 0, zoom: 1);
        final near = await centroid(
          decal(pitchRad: math.pi / 2, normalBias: 0),
        );
        final far = await centroid(decal(pitchRad: math.pi / 2, normalBias: 1));
        final unitX = rig.gridToScreen(1, 0) - rig.gridToScreen(0, 0);
        expect(far.dx - near.dx, closeTo(unitX.dx, 2.5));
        expect(far.dy - near.dy, closeTo(unitX.dy, 2.5));
      },
    );
  });
}
