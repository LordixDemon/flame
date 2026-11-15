import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/canvas3d.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('VolumetricFogVolume3D & Camera-Approaching Billowing Clouds', () {
    test(
      'approaching wavefront rolls toward perspective camera, swells in '
      'pixel radius, and recycles seamlessly in 1 drawRawAtlas call',
      () {
        VolumetricFogVolume3D.clearAtlasCache();
        final camera = CameraRig3D(
          projectionMode: CameraProjectionMode3D.perspective,
          fovYRad: math.pi / 3.0,
        )..update(camX: 640.0, camY: 420.0, zoom: 1.0);

        final sun = DirectionalLight3D(
          sunDirX: -0.4,
          sunDirY: -0.5,
          sunDirZ: 0.75,
          diffuseIntensity: 0.85,
        );

        final fog =
            VolumetricFogVolume3D(
              capacity: 256,
              density: 0.72,
              curlStrength: 0.9,
              billowRollSpeed: 0.55,
              nearFadeStart: 0.5,
              farFadeStart: 28.0,
              farSpawnDepth: 36.0,
            )..spawnApproachingWavefront(
              camera,
              count: 200,
              startCamDepth: 19.0,
              thickness: 8.0,
              approachSpeed: 5.5,
            );

        void renderStep() {
          final rec = PictureRecorder();
          fog.render(
            Canvas(rec),
            camera,
            sunLight: sun,
            viewportSize: const Size(1280, 800),
          );
          rec.endRecording().dispose();
        }

        renderStep();
        final d0 = fog.nearestParcelCameraDepth;
        final r0 = fog.maxScreenRadiusPx;
        expect(fog.lastDrawCalls, 1);
        expect(fog.lastRenderedParcelCount, greaterThan(100));
        expect(d0, greaterThan(15.0));

        // Advance 1.5s: clouds roll closer to the lens!
        for (var i = 0; i < 90; i++) {
          fog.update(1 / 60, camera: camera);
        }
        renderStep();
        final d1 = fog.nearestParcelCameraDepth;
        final r1 = fog.maxScreenRadiusPx;
        expect(d1, lessThan(d0 - 4.0));
        expect(r1, greaterThan(r0 * 1.35));
        expect(fog.lastDrawCalls, 1);

        // Advance another 2.0s: leading billows reach the lens (`camZ < 4.5`),
        // swell across the viewport, and softly recycle behind `nearFadeStart`.
        for (var i = 0; i < 120; i++) {
          fog.update(1 / 60, camera: camera);
        }
        renderStep();
        final d2 = fog.nearestParcelCameraDepth;
        final r2 = fog.maxScreenRadiusPx;
        expect(d2, lessThan(d1));
        expect(r2, greaterThan(r0 * 2.5));
        expect(fog.screenCenterCoverageEstimate, greaterThan(0.15));
        expect(fog.lastDrawCalls, 1);

        // Continue 5 more seconds of continuous recycling — zero NaNs or leaks!
        for (var i = 0; i < 300; i++) {
          fog.update(1 / 60, camera: camera);
        }
        renderStep();
        expect(fog.activeParcelCount, 200);
        expect(fog.lastDrawCalls, 1);
      },
    );

    test(
      'PointLight3D in SceneEnvironment3D illuminates nearby fog parcels '
      'from within',
      () {
        final camera = CameraRig3D(
          projectionMode: CameraProjectionMode3D.perspective,
          cameraDistance: 16.0,
          fovYRad: math.pi / 3.2,
        )..update(camX: 400.0, camY: 300.0, zoom: 1.0);

        final (tx, ty) = camera.screenToGrid(const Offset(400.0, 300.0));
        final fogDark = VolumetricFogVolume3D(
          capacity: 4,
          baseColor: const Color(0xFF405060),
          highlightColor: const Color(0xFF506070),
          shadowColor: const Color(0xFF202830),
          density: 0.85,
        )..spawnParcel(x: tx, y: ty, z: 0.8, radius: 2.0, parcelDensity: 0.9);

        final fogLit = VolumetricFogVolume3D(
          capacity: 4,
          baseColor: const Color(0xFF405060),
          highlightColor: const Color(0xFF506070),
          shadowColor: const Color(0xFF202830),
          density: 0.85,
        )..spawnParcel(x: tx, y: ty, z: 0.8, radius: 2.0, parcelDensity: 0.9);

        final env = SceneEnvironment3D()
          ..addPointLight(
            x: tx,
            y: ty,
            z: 0.9,
            radius: 6.0,
            color: const Color(0xFFFF9800),
            intensity: 2.2,
          );

        Future<int> sampleCenterRed(
          VolumetricFogVolume3D v,
          SceneEnvironment3D? e,
        ) async {
          final rec = PictureRecorder();
          final c = Canvas(rec)
            ..drawRect(
              const Rect.fromLTWH(0, 0, 800, 600),
              Paint()..color = const Color(0xFF000000),
            );
          v.render(
            c,
            camera,
            environment: e,
            viewportSize: const Size(800, 600),
          );
          final pic = rec.endRecording();
          final img = pic.toImageSync(800, 600);
          pic.dispose();
          final bd = await img.toByteData();
          img.dispose();
          // Sample pixel `(400, 275)` near projected parcel center:
          const idx = (275 * 800 + 400) * 4;
          return bd!.getUint8(idx);
        }

        expect(
          sampleCenterRed(fogLit, env),
          completion(greaterThan(60)),
        );
        expect(
          Future.wait(<Future<int>>[
            sampleCenterRed(fogDark, null),
            sampleCenterRed(fogLit, env),
          ]).then((vals) => vals[1] > vals[0] + 25),
          completion(isTrue),
        );
      },
    );
  });
}
