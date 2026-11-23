import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame/game.dart' show FlameGame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/prefixed_uniform_block.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart'
    show Frustum, makePerspectiveMatrix, makeViewMatrix;

import '../_fakes/fake_gpu_backend.dart';

void main() {
  group('PrefixedUniformBlock dirty propagation', () {
    late FakeUniformSlot slot;
    late UniformBlock parent;
    late PrefixedUniformBlock view;

    setUp(() {
      slot = FakeUniformSlot('SpatialPass', 8 * 1024);
      parent = UniformBlock(slot);
      view = PrefixedUniformBlock(parent, 'Lights_');
    });

    void clearDirty() {
      parent.markUploaded(0, FakeBuffer(16), 0);
      expect(parent.isDirty, isFalse);
      expect(view.isDirty, isFalse);
    }

    test('all direct write*At helpers mark parent dirty', () {
      final offA = parent.memberOffset('Lights_a')!;
      final offB = parent.memberOffset('Lights_b')!;
      final offC = parent.memberOffset('Lights_c')!;
      final offD = parent.memberOffset('Lights_d')!;
      final offE = parent.memberOffset('Lights_e')!;
      final offF = parent.memberOffset('Lights_f')!;
      final offG = parent.memberOffset('Lights_g')!;

      clearDirty();
      view.writeAt(offA, Float32List.fromList([1.25, 2.5]));
      expect(parent.isDirty, isTrue);
      expect(view.isDirty, isTrue);
      expect(parent.data.sublist(offA, offA + 2), [1.25, 2.5]);

      clearDirty();
      view.writeFloatAt(offB, 7.5);
      expect(parent.isDirty, isTrue);
      expect(view.isDirty, isTrue);
      expect(parent.data[offB], 7.5);

      clearDirty();
      view.writeVec2ValuesAt(offC, 3.0, 4.0);
      expect(parent.isDirty, isTrue);
      expect(view.isDirty, isTrue);
      expect(parent.data.sublist(offC, offC + 2), [3.0, 4.0]);

      clearDirty();
      view.writeVec3ValuesAt(offD, 5.0, 6.0, 7.0);
      expect(parent.isDirty, isTrue);
      expect(view.isDirty, isTrue);
      expect(parent.data.sublist(offD, offD + 3), [5.0, 6.0, 7.0]);

      clearDirty();
      view.writeVec4ValuesAt(offE, 8.0, 9.0, 10.0, 11.0);
      expect(parent.isDirty, isTrue);
      expect(view.isDirty, isTrue);
      expect(parent.data.sublist(offE, offE + 4), [8.0, 9.0, 10.0, 11.0]);

      clearDirty();
      view.writeColorAt(
        offF,
        const Color.from(alpha: 1.0, red: 0.25, green: 0.5, blue: 0.75),
      );
      expect(parent.isDirty, isTrue);
      expect(view.isDirty, isTrue);
      expect(parent.data[offF], closeTo(0.25, 1e-4));
      expect(parent.data[offF + 1], closeTo(0.5, 1e-4));
      expect(parent.data[offF + 2], closeTo(0.75, 1e-4));
      expect(parent.data[offF + 3], closeTo(1.0, 1e-4));

      clearDirty();
      final m = Matrix4.translationValues(2.0, 3.0, 4.0);
      view.writeMatrix4At(offG, m);
      expect(parent.isDirty, isTrue);
      expect(view.isDirty, isTrue);
      expect(parent.data.sublist(offG + 12, offG + 15), [2.0, 3.0, 4.0]);
    });

    test('high-level set* methods propagate dirtiness to parent', () {
      clearDirty();
      view.setFloat('count', 3);
      expect(parent.isDirty, isTrue);

      clearDirty();
      view.setVector3('dir', Vector3(0, -1, 0));
      expect(parent.isDirty, isTrue);

      clearDirty();
      view.setVector4('tint', Vector4(1, 0.5, 0.25, 1));
      expect(parent.isDirty, isTrue);

      clearDirty();
      view.setColor('ambient', const Color(0xFFFFFFFF));
      expect(parent.isDirty, isTrue);

      clearDirty();
      view.setMatrix4('xf', Matrix4.identity());
      expect(parent.isDirty, isTrue);
    });
  });

  group('RenderContext3D.lights invalidates options cache', () {
    test('direct lights assignment resets synced light revision', () {
      final backend = FakeGpuBackend();
      final device = GraphicsDevice(backend: backend);
      final context = RenderContext3D(device);

      final sunA = [
        Light(
          position: Vector3.zero(),
          source: DirectionalLight(direction: Vector3(0, -1, 0)),
        ),
      ];
      final sunB = [
        Light(
          position: Vector3.zero(),
          source: DirectionalLight(
            direction: Vector3(1, -1, 0),
            color: const Color(0xFFFF0000),
          ),
        ),
      ];

      expect(
        context.needsSyncOptions(
          lights: sunA,
          lightsVersion: 1,
          fog: null,
          waterVolume: null,
          renderDebugMode: RenderDebugMode3D.none,
          lightProbeGrid: null,
          reflectionProbes: const [],
          prioritizeNearestLights: false,
          lightGrid: null,
          lightGridBounds: null,
          hdrEnabled: false,
        ),
        isTrue,
      );
      context.setWorldLights(sunA, 1);

      // Identical options and revision short-circuit sync.
      expect(
        context.needsSyncOptions(
          lights: sunA,
          lightsVersion: 1,
          fog: null,
          waterVolume: null,
          renderDebugMode: RenderDebugMode3D.none,
          lightProbeGrid: null,
          reflectionProbes: const [],
          prioritizeNearestLights: false,
          lightGrid: null,
          lightGridBounds: null,
          hdrEnabled: false,
        ),
        isFalse,
      );

      // Setting context.lights directly resets the synced revision so a world
      // re-syncing its cached lightsVersion still updates the context.
      context.lights = sunB;
      expect(
        context.needsSyncOptions(
          lights: sunA,
          lightsVersion: 1,
          fog: null,
          waterVolume: null,
          renderDebugMode: RenderDebugMode3D.none,
          lightProbeGrid: null,
          reflectionProbes: const [],
          prioritizeNearestLights: false,
          lightGrid: null,
          lightGridBounds: null,
          hdrEnabled: false,
        ),
        isTrue,
      );
    });
  });

  group('RenderGraph3D caching', () {
    test('caches compiled plan and Texture wrappers across executions', () {
      final backend = FakeGpuBackend(textureTargets: true);
      final device = GraphicsDevice(backend: backend);
      final context = RenderContext3D(device);
      final graph = RenderGraph3D();

      const desc = RenderGraphTextureDesc3D(width: 32, height: 32);
      final intermediate = graph.createTexture('intermediate', desc);
      final output = graph.createTexture('output', desc);
      graph.markOutput(output);

      final seenLinear = <Texture>[];
      final seenNearest = <Texture>[];

      graph
        ..addPass(
          RenderGraphPass3D(
            name: 'producer',
            writes: [intermediate],
            execute: (passContext) {
              expect(passContext.targetOf(intermediate).width, 32);
            },
          ),
        )
        ..addPass(
          RenderGraphPass3D(
            name: 'consumer',
            reads: [intermediate],
            writes: [output],
            hasSideEffects: true,
            execute: (passContext) {
              seenLinear.add(passContext.textureOf(intermediate));
              seenNearest.add(
                passContext.textureOf(
                  intermediate,
                  sampler: TextureSampler.nearest,
                ),
              );
            },
          ),
        );

      device.begin();
      graph.execute(device, context);
      device.end();
      expect(graph.compileCount, 1);

      device.begin();
      graph.execute(device, context);
      device.end();
      expect(graph.compileCount, 1);
      expect(seenLinear.length, 2);
      expect(identical(seenLinear[0], seenLinear[1]), isTrue);
      expect(seenNearest.length, 2);
      expect(identical(seenNearest[0], seenNearest[1]), isTrue);
      expect(identical(seenLinear[0], seenNearest[0]), isFalse);

      // Mutating the graph invalidates the cached plan and recompiles once.
      graph.addPass(
        RenderGraphPass3D(
          name: 'overlay',
          reads: [output],
          hasSideEffects: true,
          execute: (_) {},
        ),
      );
      device.begin();
      graph.execute(device, context);
      device.end();
      expect(graph.compileCount, 2);
    });
  });

  group('SceneSpatialIndex3D incremental BVH', () {
    Future<(FlameGame, World3D, List<MeshComponent>)> mountScene({
      required bool indexed,
    }) async {
      final world = World3D(spatialIndex3DEnabled: indexed);
      final game = FlameGame(world: world);
      final box = CuboidMesh(size: Vector3.all(1.0));
      final items = <MeshComponent>[
        for (var i = 0; i < 12; i++)
          MeshComponent(
            mesh: box,
            position: Vector3((i % 4) * 3.0, 0, (i ~/ 4) * 3.0),
            rotation: Quaternion.euler(0.25 * (i % 3), 0.4 * (i % 5), 0),
          ),
      ];
      world.addAll(items);
      game
        ..onGameResize(Vector2(128, 128))
        ..start();
      await game.ready();
      return (game, world, items);
    }

    List<Object3D> bruteAabb(World3D world, Aabb3 box) {
      return [
        for (final c in world.children.whereType<Object3D>())
          if (c.aabb.intersectsWithAabb3(box)) c,
      ];
    }

    List<Object3D> bruteFrustum(World3D world, Frustum frustum) {
      return [
        for (final c in world.children.whereType<Object3D>())
          if (c.isVisible(frustum)) c,
      ];
    }

    test(
      'updates incrementally on move, add, remove with tight AABB parity',
      () async {
        final (idxGame, idxWorld, idxItems) = await mountScene(indexed: true);
        final (refGame, refWorld, refItems) = await mountScene(indexed: false);
        final index = idxWorld.spatialIndex3D;

        expect(index.fullRebuildCount, 0);

        final initialBox = Aabb3.minMax(
          Vector3(-1, -1, -1),
          Vector3(4, 1, 4),
        );
        final idxHits0 = index.queryAabb(idxWorld, initialBox);
        final refHits0 = bruteAabb(refWorld, initialBox);
        expect(index.fullRebuildCount, 1);
        expect(index.indexedObjectCount, idxItems.length);
        expect(
          idxHits0.map((e) => idxItems.indexOf(e as MeshComponent)).toSet(),
          refHits0.map((e) => refItems.indexOf(e as MeshComponent)).toSet(),
        );

        // Move an existing rotated object, add a new one, and remove one.
        idxItems[0].position.setValues(20.0, 0.0, 20.0);
        idxItems[0].rotation.setEuler(0.3, 0.7, 0.1);
        refItems[0].position.setValues(20.0, 0.0, 20.0);
        refItems[0].rotation.setEuler(0.3, 0.7, 0.1);

        final extraMesh = CuboidMesh(size: Vector3.all(1.0));
        final extraIdx = MeshComponent(
          mesh: extraMesh,
          position: Vector3(-5.0, 0.0, -5.0),
        );
        final extraRef = MeshComponent(
          mesh: extraMesh,
          position: Vector3(-5.0, 0.0, -5.0),
        );
        idxWorld.add(extraIdx);
        refWorld.add(extraRef);
        idxItems[1].removeFromParent();
        refItems[1].removeFromParent();

        idxGame.update(0.016);
        refGame.update(0.016);

        // Querying forces only incremental updates; no second full rebuild!
        final movedQuery = Aabb3.minMax(
          Vector3(18.5, -2.0, 18.5),
          Vector3(21.5, 2.0, 21.5),
        );
        final idxMoved = index.queryAabb(idxWorld, movedQuery);
        final refMoved = bruteAabb(refWorld, movedQuery);
        expect(index.fullRebuildCount, 1);
        expect(index.incrementalUpdateCount, greaterThan(0));
        expect(index.indexedObjectCount, idxItems.length);
        expect(idxMoved.length, 1);
        expect(idxMoved.single, same(idxItems[0]));
        expect(refMoved.single, same(refItems[0]));

        // Removed object is gone; added object is found.
        final removedBox = Aabb3.minMax(
          Vector3(2.4, -1.0, -1.0),
          Vector3(3.6, 1.0, 1.0),
        );
        expect(index.queryAabb(idxWorld, removedBox), isEmpty);
        expect(bruteAabb(refWorld, removedBox), isEmpty);

        final addedBox = Aabb3.minMax(
          Vector3(-6.0, -1.0, -6.0),
          Vector3(-4.0, 1.0, -4.0),
        );
        expect(index.queryAabb(idxWorld, addedBox).single, same(extraIdx));
        expect(bruteAabb(refWorld, addedBox).single, same(extraRef));

        // Tight AABB verification inside fat BVH margin (~0.25 around object).
        final item0Box = idxItems[0].aabb;
        final nearMissBox = Aabb3.minMax(
          Vector3(item0Box.max.x + 0.05, item0Box.min.y, item0Box.min.z),
          Vector3(item0Box.max.x + 0.15, item0Box.max.y, item0Box.max.z),
        );
        expect(index.queryAabb(idxWorld, nearMissBox), isEmpty);
        expect(bruteAabb(refWorld, nearMissBox), isEmpty);

        // Frustum query parity.
        final view = makeViewMatrix(
          Vector3(4, 6, 12),
          Vector3(4, 0, 2),
          Vector3(0, 1, 0),
        );
        final proj = makePerspectiveMatrix(1.0, 1.0, 0.5, 40.0);
        final frustum = Frustum.matrix(proj..multiply(view));
        expect(
          index.queryFrustum(idxWorld, frustum).length,
          bruteFrustum(refWorld, frustum).length,
        );

        // Raycast and raycastAll parity (including near-miss grazing fat AABB).
        final ray = Ray.originDirection(
          Vector3(20.0, 0.0, 25.0),
          Vector3(0.0, 0.0, -1.0),
        );
        final idxRay = idxWorld.raycast(ray);
        final refRay = refWorld.raycast(ray);
        expect(idxRay?.object, same(idxItems[0]));
        expect(refRay?.object, same(refItems[0]));
        expect(idxRay!.distance, closeTo(refRay!.distance, 1e-4));

        final multiRay = Ray.originDirection(
          Vector3(0.0, 0.0, -1.0),
          Vector3(0.0, 0.0, 1.0),
        );
        expect(
          idxWorld.raycastAll(multiRay).length,
          refWorld.raycastAll(multiRay).length,
        );
        expect(index.fullRebuildCount, 1);
      },
    );
  });
}
