import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/canvas3d.dart';
import 'package:flutter_test/flutter_test.dart';

void _render(
  VolumetricFogVolume3D fog,
  CameraRig3D camera, {
  Size viewport = const Size(1280, 800),
}) {
  final rec = PictureRecorder();
  fog.render(Canvas(rec), camera, viewportSize: viewport);
  rec.endRecording().dispose();
}

int _visible(
  VolumetricFogVolume3D fog,
  CameraRig3D camera, {
  Size viewport = const Size(1280, 800),
}) {
  _render(fog, camera, viewport: viewport);
  return fog.lastRenderedParcelCount;
}

VolumetricFogVolume3D _oneParcel({
  required double x,
  required double y,
  double z = 0.1,
  double radius = 2.0,
}) {
  return VolumetricFogVolume3D(capacity: 4, curlStrength: 0)
    ..spawnParcel(x: x, y: y, z: z, radius: radius, parcelDensity: 1.0);
}

void main() {
  group('VolumetricFogVolume3D axonometric zoom', () {
    test('puff radius is the projected size of its world radius at every '
        'zoom (the canvas applies the zoom once)', () {
      // Canvas-pixel length of 2 world units along camera-right.
      double canvasPxFor2Units(CameraRig3D c) {
        final a = c.projectWorldPoint(0, 0, 0.1);
        final b = c.projectWorldPoint(2.0 * c.rightX, 2.0 * c.rightY, 0.1);
        return (b - a).distance;
      }

      final reference = CameraRig3D()..update(camX: 0, camY: -18, zoom: 1.0);
      final expectedPx = canvasPxFor2Units(reference);

      for (final zoom in <double>[0.345, 0.6, 1.0, 1.85]) {
        final camera = CameraRig3D()..update(camX: 0, camY: -18, zoom: zoom);
        expect(canvasPxFor2Units(camera), closeTo(expectedPx, 3.0));

        final fog = _oneParcel(x: 0, y: 0);
        _render(fog, camera);
        expect(fog.lastRenderedParcelCount, 1);
        // The radius "breathes" by up to 13%.
        expect(
          fog.maxScreenRadiusPx,
          inInclusiveRange(expectedPx * 0.85, expectedPx * 1.15),
          reason: 'zoom $zoom',
        );
      }
    });

    test('a narrow, zoomed-out view gets fog up to its edges', () {
      const viewport = Size(390, 844);
      const zoom = 0.345;
      final camera = CameraRig3D()..update(camX: 0, camY: -18, zoom: zoom);

      // Ground point 450 canvas px to the right of the camera centre
      // (gridToScreen: x = (gx - gy) * 44), i.e. 155 px on screen.
      const g = 450.0 / 88.0;
      final p = camera.projectWorldPoint(g, -g, 0.1);
      expect(
        ((p.dx - camera.camWorldX) * zoom).abs(),
        lessThan(viewport.width / 2),
      );
      expect(
        ((p.dy - camera.camWorldY) * zoom).abs(),
        lessThan(viewport.height / 2),
      );

      final fog = _oneParcel(x: g, y: -g, radius: 1.0);
      expect(_visible(fog, camera, viewport: viewport), 1);
    });

    test('a zoomed-in view still culls parcels far outside it', () {
      final camera = CameraRig3D()..update(camX: 0, camY: -18, zoom: 2.0);
      // 1200 canvas px to the right: 2400 px on screen at zoom 2, far beyond
      // a 1280 px wide viewport.
      const g = 1200.0 / 88.0;
      final fog = _oneParcel(x: g, y: -g, radius: 1.0);
      expect(_visible(fog, camera), 0);
      // The same parcel is on screen once the view zooms out.
      camera.update(camX: 0, camY: -18, zoom: 0.5);
      expect(_visible(fog, camera), 1);
    });

    test('a zero-size viewport does not throw in perspective mode', () {
      final camera = CameraRig3D(
        projectionMode: CameraProjectionMode3D.perspective,
      )..update(camX: 0, camY: -18, zoom: 1.0);
      final (tx, ty) = camera.screenToGrid(const Offset(0, -18));
      final fog = _oneParcel(x: tx, y: ty, z: 0.5);
      expect(() => _render(fog, camera, viewport: Size.zero), returnsNormally);
    });
  });

  group('VolumetricFogVolume3D recycling corridor', () {
    test('an ambient bank (no approach speed) stays in view for a long '
        'session', () {
      final camera = CameraRig3D()..update(camX: 0, camY: -18, zoom: 1.0);
      final fog = VolumetricFogVolume3D(capacity: 96, density: 0.22)
        ..populateCorridor(
          camera,
          count: 48,
          minCamDepth: 11.5,
          maxCamDepth: 22.0,
          halfWidth: 8.5,
        );
      expect(fog.corridorMinDepth, 11.5);
      expect(fog.corridorMaxDepth, 22.0);
      expect(fog.corridorHalfWidth, 8.5);

      final atStart = _visible(fog, camera);
      expect(atStart, greaterThanOrEqualTo(40));

      // 12 minutes at 30 fps, sampled every minute.
      final history = <int>[];
      for (var minute = 0; minute < 12; minute++) {
        for (var i = 0; i < 60 * 30; i++) {
          fog.update(1 / 30, camera: camera);
        }
        history.add(_visible(fog, camera));
      }
      expect(fog.activeParcelCount, 48);
      expect(
        history.reduce(math.min),
        greaterThanOrEqualTo((atStart * 0.75).round()),
        reason: 'visible parcels per minute: $history',
      );
      // The bank stays around the depth it was populated at.
      expect(fog.nearestParcelCameraDepth, greaterThan(11.5 - 5.0));
    });

    test('a parcel that drifts out sideways fades out, respawns inside the '
        'corridor and fades back in', () {
      final camera = CameraRig3D()..update(camX: 0, camY: -18, zoom: 1.0);
      final (tx, ty) = camera.screenToGrid(const Offset(0, -18));
      // 30 units to the camera's right of a corridor that is 4 units wide.
      final fog =
          VolumetricFogVolume3D(
              capacity: 4,
              curlStrength: 0,
              corridorHalfWidth: 4,
            )
            ..corridorMinDepth = 14
            ..corridorMaxDepth = 20
            ..spawnParcel(
              x: tx + camera.rightX * 30,
              y: ty + camera.rightY * 30,
              z: 0.5,
              parcelDensity: 1.0,
            );
      // A viewport that only shows the corridor (4 units = 249 canvas px).
      const viewport = Size(360, 800);
      expect(_visible(fog, camera, viewport: viewport), 0);

      // Fading out takes about a second, then it is moved inside.
      var framesUntilVisible = -1;
      for (var i = 0; i < 300; i++) {
        fog.update(1 / 60, camera: camera);
        if (_visible(fog, camera, viewport: viewport) == 1) {
          framesUntilVisible = i;
          break;
        }
      }
      expect(framesUntilVisible, greaterThan(20));
      expect(fog.activeParcelCount, 1);
      expect(fog.nearestParcelCameraDepth, inInclusiveRange(13.0, 21.0));
    });

    test('an approaching bank keeps wrapping from the lens to the far end '
        'and keeps every parcel', () {
      final camera = CameraRig3D(
        projectionMode: CameraProjectionMode3D.perspective,
        fovYRad: math.pi / 3.0,
      )..update(camX: 640.0, camY: 420.0, zoom: 1.0);
      final fog = VolumetricFogVolume3D(capacity: 128, farSpawnDepth: 36.0)
        ..spawnApproachingWavefront(
          camera,
          count: 100,
          startCamDepth: 19.0,
          thickness: 8.0,
          approachSpeed: 5.5,
        );
      // A wavefront does not redefine where an ambient bank lives.
      expect(fog.corridorMinDepth, isNull);
      expect(fog.corridorMaxDepth, isNull);

      // Sample the leading edge four times a second for 20 seconds: it must
      // reach the lens, jump back to the far end and come in again.
      final nearest = <double>[];
      for (var sample = 0; sample < 80; sample++) {
        for (var i = 0; i < 15; i++) {
          fog.update(1 / 60, camera: camera);
        }
        _render(fog, camera);
        nearest.add(fog.nearestParcelCameraDepth);
      }
      expect(fog.activeParcelCount, 100);
      final firstArrival = nearest.indexWhere((d) => d < 4.0);
      expect(firstArrival, greaterThan(0), reason: 'reaches the lens');
      final wrap = nearest.indexWhere((d) => d > 15.0, firstArrival);
      expect(wrap, greaterThan(firstArrival), reason: 'wraps to the far end');
      final secondArrival = nearest.indexWhere((d) => d < 4.0, wrap);
      expect(secondArrival, greaterThan(wrap), reason: 'rolls in again');
    });

    test('without recycling, parcels carried behind the lens are dropped '
        'instead of being simulated for ever', () {
      final camera = CameraRig3D(
        projectionMode: CameraProjectionMode3D.perspective,
        fovYRad: math.pi / 3.0,
      )..update(camX: 640.0, camY: 420.0, zoom: 1.0);
      final fog =
          VolumetricFogVolume3D(
            capacity: 64,
            recycleLoop: false,
            curlStrength: 0.4,
          )..spawnApproachingWavefront(
            camera,
            count: 40,
            startCamDepth: 10.0,
            thickness: 4.0,
            approachSpeed: 6.0,
          );
      expect(fog.activeParcelCount, 40);
      for (var i = 0; i < 6 * 60; i++) {
        fog.update(1 / 60, camera: camera);
      }
      expect(fog.activeParcelCount, 0);
      expect(_visible(fog, camera), 0);
    });

    test('without recycling and without an approach speed nothing is '
        'removed or moved, wherever the parcels are', () {
      final camera = CameraRig3D()..update(camX: 0, camY: -18, zoom: 1.0);
      final (tx, ty) = camera.screenToGrid(const Offset(0, -18));
      final fog =
          VolumetricFogVolume3D(
              capacity: 8,
              recycleLoop: false,
              curlStrength: 0,
              corridorHalfWidth: 2,
            )
            ..spawnParcel(x: tx + 40, y: ty - 40, z: 0.5)
            ..spawnParcel(x: tx, y: ty, z: 0.5);
      for (var i = 0; i < 600; i++) {
        fog.update(1 / 60, camera: camera);
      }
      expect(fog.activeParcelCount, 2);
      _render(fog, camera);
      // The parcel at the look-at target has not moved.
      expect(
        fog.nearestParcelCameraDepth,
        closeTo(camera.cameraDistance - 0.5 * camera.viewZ, 1e-3),
      );
    });

    test('update without a camera only advects', () {
      final fog = VolumetricFogVolume3D(capacity: 8, curlStrength: 0)
        ..advectVx = 100
        ..spawnParcel(x: 0, y: 0, z: 0.5);
      for (var i = 0; i < 600; i++) {
        fog.update(1 / 60);
      }
      expect(fog.activeParcelCount, 1);
    });
  });

  group('VolumetricFogVolume3D approach headroom', () {
    test('ceilingZ is raised for the approach and put back when the '
        'approach speed returns to zero', () {
      final camera = CameraRig3D()..update(camX: 0, camY: -18, zoom: 1.0);
      final fog = VolumetricFogVolume3D(capacity: 8);
      expect(fog.ceilingZ, 3.6);

      fog.setApproachSpeedTowardCamera(camera, 4.4);
      final raised = fog.ceilingZ;
      expect(raised, greaterThan(8.0));
      // A second surge does not forget the original ceiling.
      fog.setApproachSpeedTowardCamera(camera, 5.0);
      expect(fog.ceilingZ, raised);

      fog.setApproachSpeedTowardCamera(camera, 0.0);
      expect(fog.ceilingZ, 3.6);
      expect(fog.advectVx, 0.0);
      expect(fog.advectVy, 0.0);
      expect(fog.advectVz, 0.0);
    });

    test('a ceiling changed by hand during the approach is kept', () {
      final camera = CameraRig3D()..update(camX: 0, camY: -18, zoom: 1.0);
      final fog = VolumetricFogVolume3D(capacity: 8)
        ..setApproachSpeedTowardCamera(camera, 4.4)
        ..ceilingZ = 6.0
        ..setApproachSpeedTowardCamera(camera, 0.0);
      expect(fog.ceilingZ, 6.0);
    });

    test('a parcel left above a lowered ceiling sinks back smoothly', () {
      final camera = CameraRig3D()..update(camX: 0, camY: -18, zoom: 1.0);
      final (tx, ty) = camera.screenToGrid(const Offset(0, -18));
      final fog = VolumetricFogVolume3D(capacity: 4, curlStrength: 0)
        ..spawnParcel(x: tx, y: ty, z: 9.0, parcelDensity: 1.0);
      // At the look-at target `camZ = cameraDistance - z * viewZ`.
      double height() {
        _render(fog, camera);
        return (camera.cameraDistance - fog.nearestParcelCameraDepth) /
            camera.viewZ;
      }

      expect(height(), closeTo(9.0, 1e-3));
      fog.update(1 / 60);
      final afterOneFrame = height();
      expect(afterOneFrame, lessThan(9.0));
      expect(afterOneFrame, greaterThan(8.9), reason: 'no teleport');
      for (var i = 0; i < 600; i++) {
        fog.update(1 / 60);
      }
      expect(height(), lessThanOrEqualTo(3.6 + 1e-3));
      expect(height(), greaterThan(3.0));
    });
  });
}
