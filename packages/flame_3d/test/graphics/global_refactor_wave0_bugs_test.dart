import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/input.dart';
import 'package:flame_3d/parser.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/scene.dart';
import 'package:flame_3d/ui3d.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

class _TapDragTarget({required super.mesh})
    extends MeshComponent
    with TapCallbacks3D, DragCallbacks3D {
  int tapCancelCount = 0;
  int dragEndCount = 0;
  bool lastDragCancelled = false;

  @override
  void onTapCancel3D(TapCancelEvent3D event) {
    tapCancelCount++;
  }

  @override
  void onDragEnd3D(DragEndEvent3D event) {
    dragEndCount++;
    lastDragCancelled = event.wasCancelled;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Global Refactor Wave 0 latent bug fixes', () {
    test('GraphicsDevice supports >32 unique texture and uniform slots without '
        'exponential array growth', () {
      final backend = FakeGpuBackend();
      final device = GraphicsDevice(backend: backend);
      final bytes = ByteData(16);

      device.begin();
      device.beginPass(const ui.Size(16, 16));
      for (var i = 0; i < 40; i++) {
        device.bindTexture(FakeSamplerSlot('tex_${i}Texture'), Texture.empty);
        device.bindUniform(FakeUniformSlot('Block$i', 16), bytes);
      }
      device.endPass().dispose();
      device.end();

      expect(backend.textureBindings.length, 40);
      expect(backend.uniformBindings.length, 40);
    });

    test('RenderGraph3D evicts pooled targets across device loss and backend '
        'switches', () async {
      final backendA = FakeGpuBackend(textureTargets: true);
      final deviceA = GraphicsDevice(backend: backendA);
      final contextA = RenderContext3D(deviceA);

      final graph = RenderGraph3D();
      final tmp = graph.createTexture(
        'tmp',
        const RenderGraphTextureDesc3D(width: 64, height: 64),
      );
      final out = graph.createTexture(
        'out',
        const RenderGraphTextureDesc3D(width: 64, height: 64),
      );
      graph
        ..addPass(
          RenderGraphPass3D(
            name: 'p1',
            writes: [tmp],
            execute: (ctx) => ctx.targetOf(tmp),
          ),
        )
        ..addPass(
          RenderGraphPass3D(
            name: 'p2',
            reads: [tmp],
            writes: [out],
            execute: (ctx) => ctx.textureOf(tmp),
          ),
        )
        ..markOutput(out);

      deviceA.begin();
      graph.execute(deviceA, contextA);
      deviceA.end();
      expect(backendA.textureTargetsCreated.length, 2);

      // Same backend + same generation reuses pooled targets (0 new targets).
      deviceA.begin();
      graph.execute(deviceA, contextA);
      deviceA.end();
      expect(backendA.textureTargetsCreated.length, 2);

      // Device loss bumps GpuBackend.deviceGeneration -> must recreate targets.
      await backendA.debugSimulateDeviceLoss();
      deviceA.begin();
      graph.execute(deviceA, contextA);
      deviceA.end();
      expect(backendA.textureTargetsCreated.length, 4);

      // Switching backend must create targets on backendB instead of reusing A.
      final backendB = FakeGpuBackend(textureTargets: true);
      final deviceB = GraphicsDevice(backend: backendB);
      final contextB = RenderContext3D(deviceB);
      deviceB.begin();
      graph.execute(deviceB, contextB);
      deviceB.end();
      expect(backendB.textureTargetsCreated.length, 2);
    });

    test('SurfaceBvh.raycast and raycastAll handle deep trees safely', () {
      const triCount = 512;
      final verts = Float32List(
        triCount * 3 * VertexLayout.standard.strideInFloats,
      );
      final indices = Uint16List(triCount * 3);
      for (var t = 0; t < triCount; t++) {
        final z = -t * 0.25;
        final b = t * 3;
        for (var k = 0; k < 3; k++) {
          final vIdx = b + k;
          indices[vIdx] = vIdx;
          final o = vIdx * VertexLayout.standard.strideInFloats;
          verts[o] = k == 1 ? 1.0 : (k == 2 ? -1.0 : 0.0);
          verts[o + 1] = k == 0 ? 1.0 : -1.0;
          verts[o + 2] = z;
        }
      }
      final surface = Surface.fromBuffers(
        vertices: verts,
        indices: indices,
      );
      final bvh = SurfaceBvh.build(surface, maxLeafTriangles: 1);
      final ray = Ray.originDirection(Vector3(0, 0, 5), Vector3(0, 0, -1));
      final closest = bvh.raycast(ray);
      expect(closest, isNotNull);
      expect(closest!.triangleIndex, 0);

      final hits = <SurfaceRayHit>[];
      bvh.raycastAll(ray, hits);
      expect(hits.length, triCount);
    });

    testWithGame<FlameGame3D>(
      'WidgetSurface3D remount clears disposed texture and reuses button '
      'TextPainter',
      () {
        FakeGpuBackend();
        return FlameGame3D(camera: CameraComponent3D());
      },
      (game) async {
        final btn = SurfaceButton2D(
          bounds: const ui.Rect.fromLTWH(8, 8, 80, 32),
          label: 'Play',
        );
        final panel = WidgetSurface3D(controls: [btn]);
        await game.world.ensureAdd(panel);
        panel
          ..markDirty()
          ..flushDirty();
        expect(panel.uploadCount, 2);

        // Paint twice with same label to exercise cached TextPainter reuse.
        final rec = ui.PictureRecorder();
        final canvas = ui.Canvas(rec);
        btn.paint(canvas);
        btn.paint(canvas);
        rec.endRecording().dispose();

        // Remove clears dangling disposed texture; re-mount refreshes cleanly.
        panel.removeFromParent();
        game.update(0);
        expect(panel.material.albedoTexture, same(Texture.empty));

        await game.world.ensureAdd(panel);
        expect(panel.uploadCount, 3);
        expect(panel.material.albedoTexture, isNot(same(Texture.empty)));
        panel.removeFromParent();
        game.update(0);
      },
    );

    testWithGame<FlameGame3D>(
      'VolumeDecalBatch3D remount keeps CPU geometry intact and re-draws',
      () {
        FakeGpuBackend();
        return FlameGame3D(camera: CameraComponent3D());
      },
      (game) async {
        final surface = CuboidMesh(
          size: Vector3.all(4),
          material: SpatialMaterial(),
        ).surfaces.first;
        final decals = VolumeDecalBatch3D()
          ..projectOntoSurfaces(
            [
              ProjectedDecalBox3D(
                center: Vector3(0, 2, 0),
                halfExtents: Vector3(1.5, 1.5, 1.5),
              ),
            ],
            [VolumeDecalTarget3D(surface: surface)],
          );
        expect(decals.generatedTriangleCount, greaterThan(0));

        await game.world.ensureAdd(decals);
        decals.removeFromParent();
        game.update(0);

        expect(decals.computeLocalAabb(), isNotNull);

        final backend = FakeGpuBackend();
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);
        device.begin();
        device.beginPass(const ui.Size(16, 16));
        decals.draw(context);
        context.flush();
        device.endPass().dispose();
        device.end();
        expect(backend.countCommands('drawIndexed'), greaterThan(0));
      },
    );

    test('Material.visitTextures and AssetScope3D track Stylized & Spatial '
        'lightmap textures cleanly', () {
      Texture solidTex() => Texture(
        ByteData.sublistView(Uint8List.fromList([255, 255, 255, 255])),
        width: 1,
        height: 1,
      );

      final lm = solidTex();
      final mc = solidTex();
      final gm = solidTex();
      final bc = solidTex();
      final spatial = SpatialMaterial(lightmapTexture: lm);
      final stylized = StylizedMaterial(
        matCapTexture: mc,
        gemMatCapTexture: gm,
        baseColorTexture: bc,
      );

      final s1 = CuboidMesh(
        size: Vector3.all(1),
        material: spatial,
      ).surfaces.first;
      final s2 = CuboidMesh(
        size: Vector3.all(1),
        material: stylized,
      ).surfaces.first;
      final scope = AssetScope3D()
        ..retain(
          Mesh()
            ..addSurface(s1)
            ..addSurface(s2),
        );

      // 2 surfaces + lm + mc + gm + bc = 6 unique tracked resources.
      expect(scope.trackedResourceCount, 6);
      scope.disposeAll();
      expect(scope.trackedResourceCount, 0);
    });

    test(
      'GpuResourceManager3D.dispose detaches device-loss listener',
      () async {
        final backend = FakeGpuBackend();
        var recoverCalls = 0;
        final mgr = GpuResourceManager3D();
        final tex = Texture(
          ByteData.sublistView(Uint8List.fromList([255, 0, 0, 255])),
          width: 1,
          height: 1,
        );
        mgr
          ..deviceLossRecovery.registerCallback('cb', () => recoverCalls++)
          ..acquire('k', () => tex)
          ..dispose();

        await backend.debugSimulateDeviceLoss();
        expect(recoverCalls, 0);
      },
    );

    testWithGame<FlameGame3D>(
      'PointerRouter3D.onRemove cancels active taps and drags cleanly',
      () {
        FakeGpuBackend();
        return FlameGame3D(
          camera: CameraComponent3D(
            position: Vector3(0, 0, 5),
            target: Vector3.zero(),
            viewport: FixedSizeViewport(200, 200),
          ),
        );
      },
      (game) async {
        final target = _TapDragTarget(
          mesh: CuboidMesh(size: Vector3.all(2), material: SpatialMaterial()),
        );
        await game.world.ensureAdd(target);
        final router = PointerRouter3D.forCamera(
          world: game.world,
          camera: game.camera,
          size: Vector2(200, 200),
        );
        await game.world.ensureAdd(router);
        game.update(0.016);

        final tapOk = router.dispatchTapDown(Vector2(100, 100), pointerId: 1);
        final dragOk = router.dispatchDragStart(
          Vector2(100, 100),
          pointerId: 2,
        );
        expect(tapOk, isTrue);
        expect(dragOk, isTrue);

        router.removeFromParent();
        game.update(0);
        expect(target.tapCancelCount, 1);
        expect(target.dragEndCount, 1);
        expect(target.lastDragCancelled, isTrue);
      },
    );

    test('LightComponent unmounted and SceneSerializer3D lossy warnings', () {
      // Unattached LightComponent must not throw StateError on lifecycle calls.
      final light = LightComponent.point();
      expect(() {
        light.onMount();
        light.onRemove();
      }, returnsNormally);

      final world = World3D(
        waterVolume: WaterVolumeSettings(),
        occlusionCuller: OcclusionCuller3D(),
      );
      final serializer = SceneSerializer3D(allowLossy: true);
      final issues = serializer.findIssues(world);
      expect(
        issues.map((i) => i.path),
        containsAll(['world.waterVolume', 'world.occlusionCuller']),
      );
    });
  });
}
