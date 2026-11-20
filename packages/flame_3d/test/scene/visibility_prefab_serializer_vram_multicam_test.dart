import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Canvas, Color, PictureRecorder, Rect, Size;

import 'package:flame/game.dart' show GameWidget;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/scene.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  group('Component3D visibility, worldTransformVersion, tags3D & clone', () {
    test('hierarchical visible flag toggles subtree isEffectivelyVisible', () {
      final leaf = MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(1)),
        position: Vector3(1, 2, 3),
      );
      final middle = Group3D(children: [leaf]);
      final root = Group3D(children: [middle]);
      final world = World3D(children: [root]);

      expect(root.visible, isTrue);
      expect(leaf.visible, isTrue);
      expect(leaf.isEffectivelyVisible, isTrue);

      final frustum = CameraComponent3D(
        position: Vector3(0, 0, 10),
        target: Vector3.zero(),
      ).frustum;
      expect(leaf.isVisible(frustum), isTrue);
      expect(leaf.shouldCull(frustum), isFalse);

      root.visible = false;
      expect(root.visible, isFalse);
      expect(middle.visible, isTrue);
      expect(leaf.visible, isTrue);
      expect(middle.isEffectivelyVisible, isFalse);
      expect(leaf.isEffectivelyVisible, isFalse);
      expect(leaf.isVisible(frustum), isFalse);
      expect(leaf.shouldCull(frustum), isTrue);
      expect(world.children.contains(root), isTrue);

      root.visible = true;
      expect(leaf.isEffectivelyVisible, isTrue);
      expect(leaf.shouldCull(frustum), isFalse);
    });

    testWithFlameGame(
      'toggling visible marks mounted World3D dirty and skips draws & shadows',
      (game) async {
        final backend = FakeGpuBackend(textureTargets: true);
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);

        final cube = MeshComponent(
          mesh: CuboidMesh(
            size: Vector3.all(1),
            material: SpatialMaterial(),
          ),
        );
        final group = Group3D(children: [cube]);
        final sun = LightComponent.directional(
          direction: Vector3(0, -1, -1),
          shadows: ShadowSettings(resolution: 256),
        );
        final world = World3D(children: [group, sun]);
        await game.ensureAdd(world);

        final cam = CameraComponent3D(
          position: Vector3(0, 2, 5),
          target: Vector3.zero(),
        )..onGameResize(Vector2(200, 200));

        device.begin();
        final img1 = world.renderToImage(
          const Size(64, 64),
          view: cam.viewMatrix,
          projection: cam.projectionMatrix,
          device: device,
          context: context,
        );
        img1.dispose();
        device.end();
        expect(device.lastFrameStats.triangles, greaterThan(0));

        final vBefore = world.sceneVersion;
        final cBefore = world.castersVersion;
        group.visible = false;
        expect(world.sceneVersion, greaterThan(vBefore));
        expect(world.castersVersion, greaterThan(cBefore));

        // Direct bind call also skips when hidden.
        cube.bind(context);

        device.begin();
        final img2 = world.renderToImage(
          const Size(64, 64),
          view: cam.viewMatrix,
          projection: cam.projectionMatrix,
          device: device,
          context: context,
        );
        img2.dispose();
        device.end();
        expect(device.lastFrameStats.triangles, 0);

        group.visible = true;
        device.begin();
        final img3 = world.renderToImage(
          const Size(64, 64),
          view: cam.viewMatrix,
          projection: cam.projectionMatrix,
          device: device,
          context: context,
        );
        img3.dispose();
        device.end();
        expect(device.lastFrameStats.triangles, greaterThan(0));
      },
    );

    test(
      'worldTransformVersion increments across subtree on TRS mutations',
      () {
        final leaf = Group3D(position: Vector3(0, 1, 0));
        final parent = Group3D(children: [leaf]);

        final p0 = parent.worldTransformVersion;
        final l0 = leaf.worldTransformVersion;
        expect(parent.worldTransformVersion, p0);

        // Mutate twice WITHOUT reading worldTransformMatrix in between.
        parent.position.x = 3;
        final p1 = parent.worldTransformVersion;
        final l1 = leaf.worldTransformVersion;
        expect(p1, greaterThan(p0));
        expect(l1, greaterThan(l0));

        parent.rotation.setAxisAngle(Vector3(0, 1, 0), 0.4);
        final p2 = parent.worldTransformVersion;
        final l2 = leaf.worldTransformVersion;
        expect(p2, greaterThan(p1));
        expect(l2, greaterThan(l1));

        // Mutating leaf only bumps leaf, not parent.
        leaf.scale.setValues(2, 2, 2);
        expect(parent.worldTransformVersion, p2);
        expect(leaf.worldTransformVersion, greaterThan(l2));
      },
    );

    test('tags3D and deep/shallow clone preserve all properties & hooks', () {
      final mesh = CuboidMesh(size: Vector3(1, 2, 3));
      final childMesh =
          MeshComponent(
              mesh: mesh,
              position: Vector3(2, 0, -1),
              color: const Color(0xFF00FF88),
              instanceData: Vector4(0.1, 0.2, 0.3, 0.4),
              castsShadows: false,
              cameraMask: 0x04,
            )
            ..visible = false
            ..addTag3D('prop')
            ..addTag3D('destructible');
      final childLight = LightComponent.point(
        position: Vector3(0, 4, 0),
        color: const Color(0xFFFFAA00),
        intensity: 3.5,
        range: 12,
        lightMask: 0x02,
      );
      final customChild = _CustomBeaconNode(
        beaconCode: 'alpha-7',
        position: Vector3(-1, 0, 2),
      )..addTag3D('beacon');

      final root = Group3D(
        position: Vector3(10, 20, 30),
        rotation: Quaternion.axisAngle(Vector3(0, 1, 0), math.pi / 4),
        scale: Vector3(1.5, 1, 0.5),
        cameraMask: 0x0F,
        tags3D: const ['squad'],
        prefabId: 'unit_squad',
        children: [childMesh, childLight, customChild],
      );

      expect(root.hasTag3D('squad'), isTrue);
      expect(root.addTag3D('leader'), isTrue);
      expect(root.addTag3D('leader'), isFalse);
      expect(root.removeTag3D('leader'), isTrue);
      expect(() => root.tags3D.add('illegal'), throwsUnsupportedError);

      final shallow = root.clone(includeChildren: false);
      expect(shallow.hasChildren, isFalse);
      expect(shallow.position, closeToVector3(Vector3(10, 20, 30)));
      expect(shallow.cameraMask, 0x0F);
      expect(shallow.tags3D, contains('squad'));
      expect(shallow.prefabId, 'unit_squad');

      final deep = root.clone();
      expect(deep.children.length, 3);
      final clonedMesh = deep.children.whereType<MeshComponent>().single;
      expect(identical(clonedMesh, childMesh), isFalse);
      expect(clonedMesh.mesh, same(mesh));
      expect(clonedMesh.color, const Color(0xFF00FF88));
      expect(clonedMesh.instanceData.z, closeTo(0.3, 1e-6));
      expect(clonedMesh.castsShadows, isFalse);
      expect(clonedMesh.visible, isFalse);
      expect(clonedMesh.cameraMask, 0x04);
      expect(clonedMesh.tags3D, containsAll(['prop', 'destructible']));

      final clonedLight = deep.children.whereType<LightComponent>().single;
      expect(clonedLight.lightMask, 0x02);
      expect((clonedLight.source as PointLight).range, 12);

      final clonedBeacon = deep.children.whereType<_CustomBeaconNode>().single;
      expect(clonedBeacon.beaconCode, 'alpha-7');
      expect(clonedBeacon.hasTag3D('beacon'), isTrue);

      // Mutating deep clone does not affect original.
      deep.position.x = 999;
      clonedMesh.instanceData.x = 99;
      expect(root.position.x, 10);
      expect(childMesh.instanceData.x, closeTo(0.1, 1e-6));
    });
  });

  group('Prefab3D, PrefabRegistry3D & SceneSerializer3D', () {
    test('PrefabRegistry3D instantiates blueprints with typed overrides', () {
      final registry = PrefabRegistry3D();
      final crateMesh = CuboidMesh(size: Vector3.all(1));

      registry.registerBuilder(
        'crate',
        (overrides) {
          final sizeScale = overrides.prop<double>('sizeScale') ?? 1.0;
          return MeshComponent(
            mesh: crateMesh,
            scale: Vector3.all(sizeScale),
          )..addTag3D('crate_base');
        },
        defaultProps: const {'sizeScale': 1.25},
      );

      expect(registry.contains('crate'), isTrue);
      expect(
        () => registry.registerBuilder('crate', (_) => Group3D()),
        throwsStateError,
      );

      final defaultCrate = registry.instantiate('crate');
      expect(defaultCrate.prefabId, 'crate');
      expect(defaultCrate.scale, closeToVector3(Vector3.all(1.25)));
      expect(defaultCrate.hasTag3D('crate_base'), isTrue);

      final overridden = registry.instantiate(
        'crate',
        PrefabOverrides3D(
          position: Vector3(4, 1, -2),
          rotation: Quaternion.axisAngle(Vector3(0, 1, 0), 0.5),
          scale: Vector3(2, 3, 2),
          color: const Color(0xFFFF3366),
          visible: false,
          cameraMask: 0x02,
          tags: const {'loot'},
          customProps: const {'sizeScale': 2.0},
        ),
      ) as MeshComponent;

      expect(overridden.position, closeToVector3(Vector3(4, 1, -2)));
      expect(overridden.scale, closeToVector3(Vector3(2, 3, 2)));
      expect(overridden.color, const Color(0xFFFF3366));
      expect(overridden.visible, isFalse);
      expect(overridden.cameraMask, 0x02);
      expect(overridden.tags3D, containsAll(['crate_base', 'loot']));

      final proto = Group3D(
        position: Vector3(1, 0, 0),
        tags3D: const ['turret'],
        children: [MeshComponent(mesh: crateMesh)],
      );
      registry.registerPrototype('turret_proto', proto);
      final instProto = registry.instantiate(
        'turret_proto',
        PrefabOverrides3D(
          tags: const {'replaced_only'},
          replaceTags: true,
        ),
      );
      expect(instProto.tags3D, equals({'replaced_only'}));
      expect(instProto.children.whereType<MeshComponent>().length, 1);
    });

    test('SceneSerializer3D round-trips JSON and F3DS CRC32 binary', () {
      FakeGpuBackend();
      final registry = PrefabRegistry3D();
      final sharedAssetMesh = CuboidMesh(size: Vector3(2, 0.5, 2));
      final sharedTex = ColorTexture(const Color(0xFF33AAFF));

      registry.registerBuilder(
        'pillar',
        (_) => MeshComponent(
          mesh: CylinderMesh(radius: 0.4, height: 3),
        )..addTag3D('architecture'),
      );

      final serializer = SceneSerializer3D(prefabRegistry: registry)
        ..registerMesh('platform_asset', sharedAssetMesh)
        ..registerTexture('blue_tex', sharedTex)
        ..registerNodeCodec<_CustomBeaconNode>(
          SceneNodeCodec3D<_CustomBeaconNode>(
            typeId: 'beacon_node',
            encode: (node) => {'code': node.beaconCode},
            decode: (data) => _CustomBeaconNode(
              beaconCode: data['code']! as String,
            ),
          ),
        );

      final sourceWorld = World3D(
        renderScale: 0.75,
        spatialIndex3DEnabled: true,
        prioritizeNearestLights: true,
        lightGrid: const LightGridSettings(
          cellSize: 0.5,
          maxPointLightsPerCell: 12,
          beyondLimitsOnly: false,
        ),
        depthPrepassEnabled: true,
        fog: FogSettings(
          color: const Color(0xFFAABBCC),
          start: 8,
          end: 45,
          density: 0.02,
        ),
        bloom: BloomSettings(
          threshold: 0.7,
          intensity: 0.85,
          passes: 3,
        ),
        postProcess: PostProcessSettings(
          toneMap: ToneMapMode.acesFilmic,
          exposure: 1.2,
          fxaa: true,
          ssaoIntensity: 0.4,
        ),
        children: [
          LightComponent.ambient(intensity: 0.25),
          LightComponent.hemisphere(
            skyColor: const Color(0xFF99CCFF),
            groundColor: const Color(0xFF443322),
            intensity: 0.6,
          ),
          LightComponent.directional(
            direction: Vector3(-0.3, -1, -0.5),
            intensity: 1.4,
            shadows: ShadowSettings(
              resolution: 512,
              cascades: 2,
              cascadeSplitRatio: 0.3,
            ),
          ),
          LightComponent.point(
            position: Vector3(3, 2, 1),
            color: const Color(0xFFFF8800),
            intensity: 4,
            range: 9,
          ),
          LightComponent.spot(
            position: Vector3(-2, 5, 2),
            direction: Vector3(0, -1, 0),
            innerConeAngle: 0.25,
            outerConeAngle: 0.6,
            range: 15,
          ),
          Group3D(
            position: Vector3(5, 0, -3),
            visible: false,
            cameraMask: 0x03,
            tags3D: const ['sector_a'],
            children: [
              MeshComponent(
                mesh: sharedAssetMesh,
                color: const Color(0xFFAAFFCC),
              ),
              MeshComponent(
                mesh: SphereMesh(
                  radius: 0.75,
                  segments: 12,
                  material: SpatialMaterial(
                    albedoColor: const Color(0xFFEE4422),
                    albedoTexture: sharedTex,
                    metallic: 0.35,
                    roughness: 0.45,
                    doubleSided: true,
                  ),
                ),
                position: Vector3(0, 2, 0),
              ),
              MeshComponent(
                mesh: ConeMesh(
                  radius: 0.6,
                  height: 1.8,
                  segments: 16,
                  material: UnlitMaterial(
                    albedoColor: const Color(0xFF11FF22),
                  ),
                ),
              ),
              MeshComponent(
                mesh: PlaneMesh(
                  size: Vector2(6, 4),
                  material: StylizedMaterial(
                    albedoColor: const Color(0xFFDDDDFF),
                    rimStrength: 0.25,
                  ),
                ),
              ),
              MeshComponent(mesh: CapsuleMesh(radius: 0.3, height: 1.4)),
              MeshComponent(
                mesh: TorusMesh(majorRadius: 0.9, minorRadius: 0.2),
              ),
            ],
          ),
          registry.instantiate(
            'pillar',
            PrefabOverrides3D(
              position: Vector3(-4, 0, 4),
              color: const Color(0xFFCCCCCC),
              tags: const {'west_pillar'},
            ),
          ),
          _CustomBeaconNode(
            beaconCode: 'omega-42',
            position: Vector3(7, 1, -2),
          )..addTag3D('custom_tag'),
        ],
      );

      final mainCam = CameraComponent3D(
        position: Vector3(0, 6, 12),
        target: Vector3(0, 1, 0),
        fovY: 55,
        cameraMask: 0x07,
      );

      // 1. JSON round-trip.
      final jsonStr = serializer.encodeJson(
        sourceWorld,
        cameras: [mainCam],
        pretty: true,
      );
      final jsonTarget = World3D();
      final jsonCams = serializer.decodeJsonInto(jsonStr, jsonTarget);

      _verifyRestoredWorld(jsonTarget, jsonCams, sharedAssetMesh, sharedTex);

      // 2. Binary F3DS + CRC32 round-trip.
      final binary = serializer.encodeBinary(sourceWorld, cameras: [mainCam]);
      expect(binary.sublist(0, 4), equals([0x46, 0x33, 0x44, 0x53]));

      final binTarget = World3D();
      final binCams = serializer.decodeBinaryInto(binary, binTarget);
      _verifyRestoredWorld(binTarget, binCams, sharedAssetMesh, sharedTex);

      // 3. Corruption detection (CRC32 mismatch, bad magic, truncation).
      final corruptedPayload = Uint8List.fromList(binary);
      corruptedPayload[corruptedPayload.length - 3] ^= 0x5A;
      expect(
        () => serializer.decodeBinaryInto(corruptedPayload, World3D()),
        throwsFormatException,
      );

      final badMagic = Uint8List.fromList(binary)..[0] = 0x00;
      expect(
        () => serializer.decodeBinaryInto(badMagic, World3D()),
        throwsFormatException,
      );

      expect(
        () => serializer.decodeBinaryInto(binary.sublist(0, 10), World3D()),
        throwsFormatException,
      );

      expect(
        () => serializer.decodeJsonInto('{"schemaVersion": 99}', World3D()),
        throwsFormatException,
      );
    });
  });

  group('CameraStack3D & FlameGame3D multi-camera compositor', () {
    test('split-screen and PiP overlay slot picking & raycast isolation', () {
      final camLeft = CameraComponent3D(
        position: Vector3(-10, 0, 5),
        target: Vector3(-10, 0, 0),
        cameraMask: 0x01,
      );
      final camRight = CameraComponent3D(
        position: Vector3(10, 0, 5),
        target: Vector3(10, 0, 0),
        cameraMask: 0x02,
      );
      final camMinimap = CameraComponent3D(
        projection: CameraProjection.orthographic,
        orthographicHeight: 20,
        position: Vector3(0, 20, 0),
        target: Vector3.zero(),
        up: Vector3(0, 0, -1),
        cameraMask: 0x04,
      );

      final stack = CameraStack3D.splitHorizontal(camLeft, camRight)
        ..addSlot(
          CameraViewportSlot3D(
            camera: camMinimap,
            normalizedViewport: const Rect.fromLTWH(0.72, 0.04, 0.25, 0.25),
            priority: 10,
            clearColor: const Color(0xFF0F172A),
            borderColor: const Color(0xFF38BDF8),
            label: 'minimap',
          ),
        );

      const canvasSize = Size(800, 600);

      // Center of left split (200, 300).
      final pickLeft = stack.pickSlotAndRay(Vector2(200, 300), canvasSize)!;
      expect(pickLeft.camera, same(camLeft));
      expect(pickLeft.localViewportPoint, closeToVector(Vector2(200, 300)));
      expect(
        pickLeft.worldRay.direction,
        closeToVector3(Vector3(0, 0, -1), 1e-9),
      );

      // Center of right split outside minimap (600, 300).
      final pickRight = stack.pickSlotAndRay(Vector2(600, 300), canvasSize)!;
      expect(pickRight.camera, same(camRight));
      expect(pickRight.localViewportPoint, closeToVector(Vector2(200, 300)));

      // Inside PiP minimap at top-right (650, 80) -> hits higher-priority slot!
      final pickMini = stack.pickSlotAndRay(Vector2(650, 80), canvasSize)!;
      expect(pickMini.camera, same(camMinimap));
      expect(pickMini.slot.label, 'minimap');

      // Raycast layer mask + visibility filtering.
      final leftCube = MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(2)),
        position: Vector3(-10, 0, 0),
        cameraMask: 0x01,
      );
      final rightCube = MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(2)),
        position: Vector3(10, 0, 0),
        cameraMask: 0x02,
      );
      final world = World3D(children: [leftCube, rightCube]);

      final (_, leftHit) = stack.raycastAt(
        Vector2(200, 300),
        canvasSize,
        defaultWorld: world,
      )!;
      expect(leftHit?.object, same(leftCube));

      rightCube.visible = false;
      final (_, rightHiddenHit) = stack.raycastAt(
        Vector2(600, 300),
        canvasSize,
        defaultWorld: world,
      )!;
      expect(rightHiddenHit, isNull);
    });

    testWithFlameGame(
      'CameraStack3D renders exact viewport dimensions & depthOnly weapon pass',
      (game) async {
        final backend = FakeGpuBackend();
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);

        final worldCube = MeshComponent(
          mesh: CuboidMesh(
            size: Vector3.all(1),
            material: UnlitMaterial()..renderState = RenderState.opaque,
          ),
          cameraMask: 0x01,
        );
        final weaponMesh = MeshComponent(
          mesh: CuboidMesh(
            size: Vector3.all(0.3),
            material: UnlitMaterial()..renderState = RenderState.opaque,
          ),
          cameraMask: 0x02,
        );
        final world = World3D(children: [worldCube, weaponMesh]);
        await game.ensureAdd(world);

        final mainCam = CameraComponent3D(
          position: Vector3(0, 0, 5),
          target: Vector3.zero(),
          cameraMask: 0x01,
        );
        final weaponCam = CameraComponent3D(
          position: Vector3(0, 0, 2),
          target: Vector3.zero(),
          cameraMask: 0x02,
        );
        final minimapCam = CameraComponent3D(
          position: Vector3(0, 8, 0),
          target: Vector3.zero(),
          up: Vector3(0, 0, -1),
          cameraMask: 0x01,
        );

        final stack = CameraStack3D(
          slots: [
            CameraViewportSlot3D(
              camera: mainCam,
            ),
            CameraViewportSlot3D(
              camera: weaponCam,
              priority: 5,
              clearMode: CameraClearMode3D.depthOnly,
            ),
            CameraViewportSlot3D(
              camera: minimapCam,
              normalizedViewport: const Rect.fromLTWH(0.75, 0.05, 0.2, 0.2),
              priority: 10,
              clearColor: const Color(0xFF101828),
              borderColor: const Color(0xFFFFFFFF),
            ),
          ],
        );

        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        final renderedSlots = stack.render(
          canvas,
          const Size(400, 300),
          defaultWorld: world,
          device: device,
          context: context,
          manageDeviceFrame: true,
        );
        recorder.endRecording().dispose();

        expect(renderedSlots, 3);
        expect(stack.lastRenderedSlotCount, 3);
        expect(
          backend.renderTargets,
          containsAll(<(int, int, int)>[(400, 300, 1), (80, 60, 1)]),
        );

        // FlameGame3D default single-camera constructor stays 100% compatible.
        final game3dDefault = FlameGame3D();
        expect(game3dDefault.cameraStack, isNull);
        final game3dStacked = FlameGame3D(cameraStack: stack);
        expect(game3dStacked.cameraStack, same(stack));
      },
    );

    testWidgets(
      'FlameGame3D cameraStack renders split-screen & depthOnly pixels on GPU',
      skip: !GpuBackend.isAvailable,
      (tester) async {
        await GpuBackend.initialize();
        Texture.standard.dispose();
        Texture.empty.dispose();
        tester.view
          ..physicalSize = const Size(200, 100)
          ..devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        // Left viewport sees red cube (-10, 0, 0); right viewport has a nearer
        // blue wall at z = 3 (layer 0x02) AND a farther green overlay weapon at
        // z = 0 (layer 0x04) drawn on top via CameraClearMode3D.depthOnly!
        final world = World3D(
          children: [
            MeshComponent(
              position: Vector3(-10, 0, 0),
              cameraMask: 0x01,
              mesh: CuboidMesh(
                size: Vector3.all(4),
                material: UnlitMaterial(albedoColor: const Color(0xFFFF0000))
                  ..renderState = RenderState.opaque,
              ),
            ),
            MeshComponent(
              position: Vector3(10, 0, 3),
              cameraMask: 0x02,
              mesh: CuboidMesh(
                size: Vector3.all(4),
                material: UnlitMaterial(albedoColor: const Color(0xFF0000FF))
                  ..renderState = RenderState.opaque,
              ),
            ),
            MeshComponent(
              position: Vector3(10, 0, 0),
              cameraMask: 0x04,
              mesh: CuboidMesh(
                size: Vector3.all(1.5),
                material: UnlitMaterial(albedoColor: const Color(0xFF00FF00))
                  ..renderState = RenderState.opaque,
              ),
            ),
          ],
        );

        final leftCam = CameraComponent3D(
          position: Vector3(-10, 0, 6),
          target: Vector3(-10, 0, 0),
          cameraMask: 0x01,
        );
        final rightCam = CameraComponent3D(
          position: Vector3(10, 0, 6),
          target: Vector3(10, 0, 0),
          cameraMask: 0x02,
        );
        final overlayWeaponCam = CameraComponent3D(
          position: Vector3(10, 0, 6),
          target: Vector3(10, 0, 0),
          cameraMask: 0x04,
        );

        final stack = CameraStack3D.splitHorizontal(leftCam, rightCam)
          ..addSlot(
            CameraViewportSlot3D(
              camera: overlayWeaponCam,
              normalizedViewport: const Rect.fromLTWH(0.5, 0, 0.5, 1),
              priority: 5,
              clearMode: CameraClearMode3D.depthOnly,
            ),
          );

        final game = FlameGame3D(world: world, cameraStack: stack);
        final key = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: key,
            child: GameWidget(game: game),
          ),
        );
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }

        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final bytes = (await tester.runAsync(() async {
          final img = await boundary.toImage();
          final data = await img.toByteData();
          img.dispose();
          return data!;
        }))!;

        int chan(int x, int y, int shift) {
          final rgba = bytes.getUint32((y * 200 + x) * 4);
          return (rgba >> shift) & 0xFF;
        }

        // Left half center (50, 50) -> red!
        expect(chan(50, 50, 24), greaterThan(200));
        expect(chan(50, 50, 16), lessThan(40));

        // Right half center (150, 50) -> green weapon overlay on top of blue
        // wall thanks to CameraClearMode3D.depthOnly!
        expect(chan(150, 50, 16), greaterThan(200));
        expect(chan(150, 50, 8), lessThan(40));

        // Right half off-center (125, 50) -> blue wall still visible around it!
        expect(chan(125, 50, 8), greaterThan(200));
        expect(chan(125, 50, 16), lessThan(40));
      },
    );
  });

  group('GpuResourceManager3D & GpuDeviceLossRecovery3D', () {
    test('ref-counting, LRU VRAM budget eviction, pinning & leak audit', () {
      FakeGpuBackend();
      final manager = GpuResourceManager3D(maxVramBytes: 1000);

      Texture makeTex(Color c) {
        final t = ColorTexture(c, width: 8, height: 8);
        t.resource; // Materialize GPU texture handle.
        return t;
      }

      final leaseA1 = manager.acquire(
        'tex_a',
        () => makeTex(const Color(0xFFFF0000)),
        estimatedBytes: 400,
      );
      final leaseA2 = manager.acquire(
        'tex_a',
        () => makeTex(const Color(0xFFFF0000)),
      );
      expect(leaseA2.resource, same(leaseA1.resource));
      expect(manager.refCountOf('tex_a'), 2);
      expect(manager.estimatedTotalBytes, 400);

      final leaseB = manager.acquire(
        'tex_b',
        () => makeTex(const Color(0xFF00FF00)),
        estimatedBytes: 400,
      );
      expect(manager.estimatedTotalBytes, 800);

      // Release A completely first (oldest in zero-ref LRU), then release B.
      leaseA1.release();
      leaseA1.release(); // Idempotent second call on same lease!
      expect(manager.refCountOf('tex_a'), 1);
      leaseA2.release();
      expect(manager.refCountOf('tex_a'), 0);

      leaseB.release();
      expect(manager.refCountOf('tex_b'), 0);
      expect(manager.lruCount, 2);

      // Acquiring C (400 bytes) pushes total to 1200 > 1000 -> evicts oldest
      // zero-ref ('tex_a') while keeping newer 'tex_b' and active 'tex_c'!
      final leaseC = manager.acquire(
        'tex_c',
        () => makeTex(const Color(0xFF0000FF)),
        estimatedBytes: 400,
      );
      expect(manager.containsKey('tex_a'), isFalse);
      expect(leaseA1.resource.hasResource, isFalse);
      expect(manager.containsKey('tex_b'), isTrue);
      expect(leaseB.resource.hasResource, isTrue);
      expect(manager.estimatedTotalBytes, 800);
      expect(manager.evictionCount, 1);

      // Pin 'tex_b' so even purgeUnreferenced() never disposes it!
      manager.setPinned('tex_b', pinned: true);
      expect(manager.purgeUnreferenced(), 0);
      expect(leaseB.resource.hasResource, isTrue);

      // Leak audit detects active un-released 'tex_c'.
      final report = manager.auditLeaks();
      expect(report.hasLeaks, isTrue);
      expect(report.leakedKeys, equals(['tex_c']));
      expect(report.totalLeakedBytes, 400);

      leaseC.release();
      expect(manager.auditLeaks().hasLeaks, isFalse);

      // Unpin 'tex_b' and purge all unreferenced.
      manager.setPinned('tex_b', pinned: false);
      expect(manager.purgeUnreferenced(), 2);
      expect(manager.estimatedTotalBytes, 0);
    });

    test('GpuDeviceLossRecovery3D recreates GPU buffers & textures', () {
      final backend = FakeGpuBackend();
      final manager = GpuResourceManager3D();

      final mesh = CuboidMesh(size: Vector3.all(1));
      for (final s in mesh.surfaces) {
        s.resource;
      }
      final leaseMesh = manager.acquire('hero_mesh', () => mesh);
      expect(mesh.surfaces.single.hasResource, isTrue);

      final customTex = ColorTexture(
        const Color(0xFF123456),
        width: 4,
        height: 4,
      )..resource;
      var customRebuilds = 0;
      var callbackRuns = 0;

      manager.deviceLossRecovery
        ..registerResource(
          'lut_tex',
          customTex,
          onRebuild: (_) => customRebuilds++,
        )
        ..registerCallback('procedural_sky', () => callbackRuns++);

      final buffersBefore = backend.buffers.length;
      final texturesBefore = backend.textures.length;

      // Simulate context loss and recover!
      manager.deviceLossRecovery.markResourcesLost();
      expect(customTex.hasResource, isFalse);

      final recovered = manager.recoverAfterDeviceLoss();
      expect(recovered, greaterThanOrEqualTo(3));
      expect(customRebuilds, 1);
      expect(callbackRuns, 1);
      expect(customTex.hasResource, isTrue);
      expect(leaseMesh.resource.surfaces.single.hasResource, isTrue);
      expect(backend.buffers.length, greaterThan(buffersBefore));
      expect(backend.textures.length, greaterThan(texturesBefore));

      leaseMesh.release();
      manager.disposeAll();
    });
  });
}

void _verifyRestoredWorld(
  World3D target,
  List<CameraComponent3D> cameras,
  Mesh expectedAssetMesh,
  Texture expectedTex,
) {
  expect(target.renderScale, closeTo(0.75, 1e-6));
  expect(target.spatialIndex3DEnabled, isTrue);
  expect(target.prioritizeNearestLights, isTrue);
  expect(
    target.lightGrid,
    const LightGridSettings(
      cellSize: 0.5,
      maxPointLightsPerCell: 12,
      beyondLimitsOnly: false,
    ),
  );
  expect(target.depthPrepassEnabled, isTrue);
  expect(target.fog?.start, closeTo(8, 1e-6));
  expect(target.bloom?.passes, 3);
  expect(target.postProcess?.toneMap, ToneMapMode.acesFilmic);
  expect(target.postProcess?.fxaa, isTrue);

  expect(cameras.length, 1);
  expect(cameras.single.fovY, closeTo(55, 1e-6));
  expect(cameras.single.cameraMask, 0x07);

  final lights = target.children.whereType<LightComponent>().toList();
  expect(lights.length, 5);

  final sectorGroup = target.children.whereType<Group3D>().single;
  expect(sectorGroup.visible, isFalse);
  expect(sectorGroup.cameraMask, 0x03);
  expect(sectorGroup.hasTag3D('sector_a'), isTrue);

  final sectorMeshes = sectorGroup.children.whereType<MeshComponent>().toList();
  expect(sectorMeshes.length, 6);
  expect(sectorMeshes[0].mesh, same(expectedAssetMesh));
  expect(sectorMeshes[0].isEffectivelyVisible, isFalse);

  final sphereMat =
      sectorMeshes[1].mesh.surfaces.first.material as SpatialMaterial;
  expect(sphereMat.albedoTexture, same(expectedTex));
  expect(sphereMat.metallic, closeTo(0.35, 1e-6));
  expect(sphereMat.doubleSided, isTrue);

  final pillar = target.children.whereType<MeshComponent>().firstWhere(
    (m) => m.prefabId == 'pillar',
  );
  expect(pillar.position, closeToVector3(Vector3(-4, 0, 4)));
  expect(pillar.tags3D, contains('west_pillar'));

  final beacon = target.children.whereType<_CustomBeaconNode>().single;
  expect(beacon.beaconCode, 'omega-42');
  expect(beacon.position, closeToVector3(Vector3(7, 1, -2)));
  expect(beacon.hasTag3D('custom_tag'), isTrue);
}

class _CustomBeaconNode({
  required final String beaconCode,
  super.position,
}) extends Component3D {
  @override
  Component3D cloneSelf() => _CustomBeaconNode(beaconCode: beaconCode);
}
