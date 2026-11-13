import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/camera.dart';
import 'package:flame/canvas3d.dart';
import 'package:flame/game.dart';
import 'package:flame/post_process.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

class _TelemetryGame() extends FlameGame with HasFrameTelemetry;

class _ProbePostProcess() extends PostProcess {
  int removeCalls = 0;
  int disposeCalls = 0;

  @override
  void onRemove() {
    removeCalls++;
    super.onRemove();
  }

  @override
  void dispose() {
    disposeCalls++;
    super.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('package:flame/canvas3d.dart & Studio Engine Upgrades', () {
    test(
      'CameraRig3D inverts ground coordinates and unprojects exact 3D rays',
      () {
        final cam = CameraRig3D()
          ..update(
            camX: 12.0,
            camY: -18.0,
            zoom: 1.25,
            orbitYawDelta: 0.08,
            pitchDelta: -0.06,
          );

        final screen = cam.gridToScreen(3.5, -2.25);
        final (gx, gy) = cam.screenToGrid(screen);
        expect(gx, closeTo(3.5, 1e-6));
        expect(gy, closeTo(-2.25, 1e-6));

        final (vx, vy, vz) = cam.worldNormalToView(0.0, 0.0, 1.0);
        final len = math.sqrt(vx * vx + vy * vy + vz * vz);
        expect(len, closeTo(1.0, 1e-5));
        expect(vy, greaterThan(0.5));

        final elevated = cam.projectWorldPoint(2.0, 1.0, 1.0);
        final ray = cam.unprojectWorldRay(elevated);
        final tAtZ1 = (1.0 - ray.oz) / ray.dz;
        final (hx, hy, hz) = ray.pointAt(tAtZ1);
        expect(hz, closeTo(1.0, 1e-5));
        expect(hx, closeTo(2.0, 0.25));
        expect(hy, closeTo(1.0, 0.25));
      },
    );

    test(
      'Raycaster3D intersects front-facing 3D triangles and picks closest hit',
      () {
        final positions = Float32List.fromList([
          -0.5,
          -0.5,
          0.0,
          0.5,
          -0.5,
          0.0,
          0.0,
          0.5,
          2.0,
        ]);
        final indices = Uint16List.fromList([0, 1, 2]);

        final nearCollider = MeshCollider3D(
          id: 7,
          positions: positions,
          indices: indices,
          minX: -0.5,
          minY: -0.5,
          minZ: 0.0,
          maxX: 0.5,
          maxY: 0.5,
          maxZ: 2.0,
          worldX: 0.0,
          worldY: 0.0,
        );
        final farCollider = MeshCollider3D(
          id: 9,
          positions: positions,
          indices: indices,
          minX: -0.5,
          minY: -0.5,
          minZ: 0.0,
          maxX: 0.5,
          maxY: 0.5,
          maxZ: 2.0,
          worldX: 0.0,
          worldY: 3.0,
        );

        const ray = Ray3D(
          ox: 0.0,
          oy: -4.0,
          oz: 0.8,
          dx: 0.0,
          dy: 1.0,
          dz: 0.0,
        );
        final hit = Raycaster3D.pickClosest(ray, [farCollider, nearCollider]);
        expect(hit, isNotNull);
        expect(hit!.id, equals(7));
        expect(hit.faceIndex, equals(0));
      },
    );

    test(
      'MatCapShader3D bakes procedural metallic & lacquer GPU ImageShaders',
      () {
        final matcap = MatCapShader3D();
        expect(matcap.isReady, isFalse);
        final gold = matcap.shaderFor(MatCapPreset3D.metallicGold);
        final lacquer = matcap.shaderFor(MatCapPreset3D.glossyLacquer);
        expect(matcap.isReady, isTrue);
        expect(identical(gold, lacquer), isFalse);
        matcap.dispose();
        expect(matcap.isReady, isFalse);
      },
    );

    test(
      'ParticlePool3D simulates elastic z=0 bounce and renders in <= 3 batches',
      () {
        final pool = ParticlePool3D(capacity: 128)
          ..burstCoins(1.0, -1.0, count: 12)
          ..burstCelebration(
            -1.0,
            1.0,
            color: const Color(0xFF4FC3F7),
            confetti: true,
          );
        expect(pool.activeCount, greaterThan(40));

        pool.update(0.04);
        pool.update(0.04);

        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..translate(120, 100);
        pool.render(canvas, CameraRig3D());
        recorder.endRecording().dispose();

        expect(pool.lastDrawCalls, inInclusiveRange(2, 3));

        for (var i = 0; i < 60; i++) {
          pool.update(0.04);
        }
        expect(pool.activeCount, equals(0));
      },
    );

    test(
      'TactileCameraController & Viewfinder update zoom/pan and spring back',
      () {
        final vf = Viewfinder()
          ..setPositionValues(42.0, -18.0)
          ..zoom = 1.5;
        expect(vf.position.x, closeTo(42.0, 1e-6));
        expect(vf.position.y, closeTo(-18.0, 1e-6));
        expect(vf.zoom, closeTo(1.5, 1e-6));

        final ctrl = TactileCameraController()
          ..panByWorld(999.0, -999.0)
          ..zoomByFactor(4.0);
        expect(ctrl.panX, closeTo(ctrl.maxPanX, 1e-6));
        expect(ctrl.panY, closeTo(-ctrl.maxPanY, 1e-6));
        expect(ctrl.zoomFactor, closeTo(ctrl.maxZoomFactor, 1e-6));
        expect(ctrl.hasManualOverride, isTrue);

        ctrl.reset();
        for (var i = 0; i < 90; i++) {
          ctrl.update(1 / 60);
        }
        expect(ctrl.hasManualOverride, isFalse);
      },
    );

    test(
      'PostProcessComponent forwards onRemove and PostProcessGroup disposes',
      () async {
        final childA = _ProbePostProcess();
        final childB = _ProbePostProcess();
        final group = PostProcessGroup(postProcesses: [childA, childB]);
        final comp = PostProcessComponent(
          postProcess: group,
          size: Vector2(64, 64),
        );
        final game = FlameGame()
          ..onGameResize(Vector2(64, 64))
          ..add(comp);
        await game.start();
        await game.ready();

        comp.removeFromParent();
        game.processLifecycleEvents();
        expect(childA.removeCalls, equals(1));
        expect(childB.removeCalls, equals(1));

        group.dispose();
        expect(childA.disposeCalls, equals(1));
        expect(childB.disposeCalls, equals(1));
      },
    );

    test(
      'FlameGame clamps maxDeltaTime spikes and HasFrameTelemetry tracks FPS',
      () async {
        final game = _TelemetryGame()
          ..maxDeltaTime = 0.105
          ..clampedDeltaTime = 0.05
          ..onGameResize(Vector2(320, 240));
        await game.ready();

        game.update(2.5);
        expect(game.lastEffectiveDt, closeTo(0.05, 1e-6));
        expect(game.clampedDeltaSpikes, equals(1));

        for (var i = 0; i < 20; i++) {
          game.update(1 / 120);
        }
        expect(game.telemetrySampleCount, equals(21));
        expect(game.smoothedFps, greaterThan(70.0));
      },
    );
  });
}
