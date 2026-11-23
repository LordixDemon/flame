import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/game.dart' show FlameGame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

class _FakeGame3D() extends FlameGame with Game3D {
  final FakeGpuBackend backend = FakeGpuBackend();

  @override
  late final GraphicsDevice device = GraphicsDevice(backend: backend);
}

class _FakeCanvas() implements Canvas {
  final Float64List _identity = Float64List.fromList([
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ]);

  @override
  Float64List getTransform() => _identity;

  @override
  Rect getDestinationClipBounds() => const Rect.fromLTWH(0, 0, 128, 128);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class _TwoWorldsGame() extends FlameGame {
  final World3D lender = World3D();
  final World3D borrower = World3D();

  @override
  void onLoad() {
    world.addAll([lender, borrower]);
  }
}

Surface _triangleSurface() {
  return Surface(
    vertices: [
      Vertex(
        position: Vector3(0, 0, 0),
        texCoord: Vector2(0, 0),
        normal: Vector3(0, 0, 1),
      ),
      Vertex(
        position: Vector3(2, 0, 0),
        texCoord: Vector2(1, 0),
        normal: Vector3(0, 0, 1),
      ),
      Vertex(
        position: Vector3(0, 2, 0),
        texCoord: Vector2(0, 1),
        normal: Vector3(0, 0, 1),
      ),
    ],
    indices: [0, 1, 2],
    morphTargets: [
      MorphTargetData(
        name: 'lift',
        positionDeltas: Float32List.fromList([
          0,
          0,
          3,
          0,
          0,
          3,
          0,
          0,
          3,
        ]),
      ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Wave 3.2 encapsulation', () {
    testWithGame(
      'World3D lightsFrom maintains monotonic versions across borrow lifecycle',
      _TwoWorldsGame.new,
      (game) async {
        final sun = LightComponent.directional(direction: Vector3(0, -1, 0));
        await game.lender.ensureAdd(sun);

        var prevScene = game.borrower.sceneVersion;
        var prevCasters = game.borrower.castersVersion;
        game.borrower.lightsFrom = game.lender;
        expect(game.borrower.sceneVersion, greaterThan(prevScene));
        expect(game.borrower.castersVersion, greaterThan(prevCasters));
        expect(game.borrower.lights, [sun.light]);

        // Unmounting the lender updates the borrower cleanly and drops its
        // shadow casters while remembering the lender.
        prevScene = game.borrower.sceneVersion;
        prevCasters = game.borrower.castersVersion;
        game.lender.removeFromParent();
        await game.ready();
        expect(game.borrower.sceneVersion, greaterThan(prevScene));
        expect(game.borrower.castersVersion, greaterThan(prevCasters));
        expect(game.borrower.lights, isEmpty);

        // Self-borrowing and borrowing chains remain rejected.
        expect(
          () => game.borrower.lightsFrom = game.borrower,
          throwsArgumentError,
        );
        await game.world.ensureAdd(game.lender);
        final third = World3D();
        await game.world.ensureAdd(third);
        expect(() => third.lightsFrom = game.borrower, throwsArgumentError);
      },
    );

    test(
      'World3D gathers unmounted lights for offscreen snapshot only once',
      () {
        final lender = World3D(
          children: [LightComponent.directional(direction: Vector3(0, 0, -1))],
        );
        final borrower = World3D(children: [LightComponent.ambient()])
          ..lightsFrom = lender;
        final backend = FakeGpuBackend();
        final device = GraphicsDevice(backend: backend);

        final image = borrower.renderToImage(
          const Size(32, 32),
          view: Matrix4.identity(),
          projection: Matrix4.identity(),
          device: device,
        );
        image.dispose();
        // Unmounted worlds return to an empty mounted light list after render.
        expect(borrower.lights, isEmpty);
        expect(lender.lights, isEmpty);
        expect(borrower.reflectionProbes, isEmpty);
      },
    );

    test('CameraStack3D orders quad slots, picks rays, and reuses targets', () {
      final world = World3D(
        children: [MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)))],
      );
      CameraComponent3D makeCam(Vector3 pos) =>
          CameraComponent3D(position: pos, target: Vector3.zero());
      final topLeft = CameraViewportSlot3D(
        camera: makeCam(Vector3(0, 0, 5)),
        normalizedViewport: const Rect.fromLTWH(0, 0, 0.5, 0.5),
        priority: 2,
        label: 'tl',
      );
      final bottomRight = CameraViewportSlot3D(
        camera: makeCam(Vector3(5, 0, 5)),
        normalizedViewport: const Rect.fromLTWH(0.5, 0.5, 0.5, 0.5),
        priority: 1,
        label: 'br',
      );
      final stack = CameraStack3D(slots: [topLeft, bottomRight]);

      final pickBr = stack.pickSlotAndRay(
        Vector2(150, 150),
        const Size(200, 200),
      );
      expect(pickBr, isNotNull);
      expect(pickBr!.slot.label, 'br');
      expect(pickBr.worldRay.direction.length, closeTo(1.0, 1e-5));

      final backend = FakeGpuBackend();
      final device = GraphicsDevice(backend: backend);
      for (var i = 0; i < 2; i++) {
        final recorder = PictureRecorder();
        final rendered = stack.render(
          Canvas(recorder),
          const Size(200, 200),
          defaultWorld: world,
          device: device,
          manageDeviceFrame: true,
        );
        recorder.endRecording().dispose();
        expect(rendered, 2);
      }
      expect(backend.renderTargets, [(100, 100, 1), (100, 100, 1)]);
    });

    test('Surface and SurfaceBvh raycast modes behave consistently', () {
      final surface = _triangleSurface();
      final originalBvh = surface.bvh;

      // Exact boundary at t = 2.0: raycast uses strict `< bestT`, whereas
      // raycastAll uses inclusive `<= maxDistance`.
      final ray = Ray.originDirection(
        Vector3(0.25, 0.25, 2.0),
        Vector3(0, 0, -1),
      );
      expect(originalBvh.raycast(ray, maxDistance: 2.0), isNull);
      final allAtExact = <SurfaceRayHit>[];
      originalBvh.raycastAll(ray, allAtExact, maxDistance: 2.0);
      expect(allAtExact, hasLength(1));
      expect(allAtExact.single.distance, closeTo(2.0, 1e-6));

      // Positive det on +Z hit: backFace keeps it, frontFace culls it.
      expect(
        originalBvh.raycast(
          ray,
          maxDistance: 5.0,
          cullMode: CullMode.backFace,
        ),
        isNotNull,
      );
      expect(
        originalBvh.raycast(
          ray,
          maxDistance: 5.0,
          cullMode: CullMode.frontFace,
        ),
        isNull,
      );

      // Compute tangents upgrades layout cleanly to pbrStandard.
      final tangents = surface.computeTangents();
      expect(tangents, hasLength(12));
      expect(surface.layout, equals(VertexLayout.pbrStandard));

      // Morph weights update vertexData & AABB in place and invalidate BVH.
      surface.applyMorphWeights([1.0]);
      expect(surface.aabb.min.z, closeTo(3.0, 1e-5));
      expect(surface.aabb.max.z, closeTo(3.0, 1e-5));
      final rebuiltBvh = surface.bvh;
      expect(identical(rebuiltBvh, originalBvh), isFalse);
      final hitAfterMorph = rebuiltBvh.raycast(
        Ray.originDirection(Vector3(0.25, 0.25, 5.0), Vector3(0, 0, -1)),
      );
      expect(hitAfterMorph, isNotNull);
      expect(hitAfterMorph!.distance, closeTo(2.0, 1e-5));
    });

    testWithGame(
      'Scene3DComponent encapsulates retained cache lifecycle and invalidation',
      _FakeGame3D.new,
      (game) async {
        final layer = Scene3DComponent(
          projection: Scene3DProjection.affine(
            origin: Vector2(64, 64),
            xAxis: Vector2(24, 12),
            yAxis: Vector2(-24, 12),
            zAxis: Vector2(0, -28),
            towardsViewer: Vector3(1, 1, 1),
            near: -100,
            far: 100,
          ),
          cacheMode: Scene3DCacheMode.retained,
          size: Vector2(128, 128),
          world: World3D(
            children: [MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)))],
          ),
        );
        game.camera.viewfinder.position = Vector2(64, 64);
        await game.world.ensureAdd(layer);
        await game.ready();

        final canvas = _FakeCanvas();
        void drawFrame() => layer.render(canvas);

        // First render populates retained cache target.
        drawFrame();
        expect(layer.debugRetainedTarget, isNotNull);
        expect(layer.cacheHitCount, 0);

        // Unchanged second frame hits retained cache without new GPU pass.
        drawFrame();
        expect(layer.cacheHitCount, 1);

        // markDirty invalidates cache; frame after that hits again.
        layer.markDirty();
        drawFrame();
        expect(layer.cacheHitCount, 1);
        drawFrame();
        expect(layer.cacheHitCount, 2);

        // Switching to Scene3DCacheMode.none disposes the retained target.
        layer.cacheMode = Scene3DCacheMode.none;
        expect(layer.debugRetainedTarget, isNull);

        layer.removeFromParent();
        await game.ready();
        expect(layer.debugRetainedTarget, isNull);
      },
    );
  });
}
