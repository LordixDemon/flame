import 'dart:ui' show Color;

import 'package:flame/game.dart' show FlameGame, Game;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

FlameGame _game() => FlameGame(world: World3D());

/// Records the versions of [world] and of [Game.visualMutationCount], to
/// tell what a change bumped.
class _Versions(final World3D world) {
  int scene = world.sceneVersion;
  int casters = world.castersVersion;
  int mutations = Game.visualMutationCount;

  /// Whether the scene version changed since the last call, and resets.
  ({bool scene, bool casters, bool woke}) take() {
    final result = (
      scene: world.sceneVersion != scene,
      casters: world.castersVersion != casters,
      woke: Game.visualMutationCount != mutations,
    );
    scene = world.sceneVersion;
    casters = world.castersVersion;
    mutations = Game.visualMutationCount;
    return result;
  }
}

const _nothing = (scene: false, casters: false, woke: false);
const _sceneOnly = (scene: true, casters: false, woke: true);
const _sceneAndShadows = (scene: true, casters: true, woke: true);

class _CustomObject() extends Object3D {
  @override
  void draw(RenderContext context) {}
}

void main() {
  group('World3D versions follow the public setters', () {
    testWithGame('MeshComponent.color, instanceData and joints', _game, (
      game,
    ) async {
      final world = game.world as World3D;
      final mesh = MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)));
      await world.ensureAdd(mesh);
      final versions = _Versions(world);

      mesh.color = const Color(0xFF00FF00);
      expect(versions.take(), _sceneOnly);
      mesh.color = const Color(0xFF00FF00);
      expect(versions.take(), _nothing);

      mesh.instanceData.x = 0.5;
      expect(versions.take(), _sceneOnly);
      mesh.instanceData.setValues(0.5, 0, 0, 0);
      expect(versions.take(), _nothing);
      mesh.instanceData.wz = Vector2(1, 2);
      expect(versions.take(), _sceneOnly);

      final joints = {
        0: [Matrix4.identity()],
      };
      mesh.jointTransforms = joints;
      expect(versions.take(), _sceneAndShadows);
      mesh.jointTransforms = joints;
      expect(versions.take(), _nothing);

      // Joints written in place are reported by hand.
      joints[0]![0].setTranslationRaw(1, 0, 0);
      expect(versions.take(), _nothing);
      mesh.markDrawDirty();
      expect(versions.take(), _sceneAndShadows);
      mesh.markDrawDirty(shadows: false);
      expect(versions.take(), _sceneOnly);

      // A mesh that casts no shadows does not touch the casters.
      mesh.castsShadows = false;
      expect(versions.take(), _sceneAndShadows);
      mesh.jointTransforms = null;
      expect(versions.take(), _sceneOnly);
      mesh.castsShadows = false;
      expect(versions.take(), _nothing);
    });

    testWithGame('ModelComponent and LodMeshComponent', _game, (game) async {
      final world = game.world as World3D;
      final cube = CuboidMesh(size: Vector3.all(1));
      final model = ModelComponent(
        model: Model(
          nodes: {
            0: ModelNode(
              name: 'root',
              nodeIndex: 0,
              parentNodeIndex: null,
              transform: Matrix4.identity(),
              mesh: cube,
              joints: const {},
            ),
          },
          animations: const [],
        ),
      );
      final lod = LodMeshComponent(levels: [MeshLodLevel(mesh: cube)]);
      await world.ensureAddAll([model, lod]);
      final versions = _Versions(world);

      model.color = const Color(0xFF102030);
      expect(versions.take(), _sceneOnly);
      model.instanceData.y = 1;
      expect(versions.take(), _sceneOnly);

      lod.color = const Color(0xFF102030);
      expect(versions.take(), _sceneOnly);
      lod.instanceData.y = 1;
      expect(versions.take(), _sceneOnly);
      lod.shadowMesh = cube;
      expect(versions.take(), _sceneAndShadows);
      lod.lowestLodInShadowPass = true;
      expect(versions.take(), _sceneAndShadows);
    });

    testWithGame(
      'custom Object3D reports its draws with markDrawDirty',
      _game,
      (
        game,
      ) async {
        final world = game.world as World3D;
        final custom = _CustomObject();
        await world.ensureAdd(custom);
        final versions = _Versions(world);

        custom.markDrawDirty(shadows: false);
        expect(versions.take(), _sceneOnly);
        custom.markDrawDirty();
        expect(versions.take(), _sceneAndShadows);
      },
    );

    testWithGame('castsShadows of objects and materials', _game, (game) async {
      final world = game.world as World3D;
      final material = SpatialMaterial();
      final mesh = MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(1), material: material),
      );
      await world.ensureAdd(mesh);
      final versions = _Versions(world);

      mesh.castsShadows = false;
      expect(versions.take(), _sceneAndShadows);
      mesh.castsShadows = true;
      expect(versions.take(), _sceneAndShadows);

      material.castsShadows = false;
      expect(versions.take(), _sceneAndShadows);
      material.castsShadows = false;
      expect(versions.take(), _nothing);
      material.castsShadows = null;
      expect(versions.take(), _sceneAndShadows);
    });

    testWithGame('a ShadowGroup sees material changes', _game, (game) async {
      final world = game.world as World3D;
      final group = ShadowGroup();
      world.shadowGroup = group;
      final material = SpatialMaterial();
      await world.ensureAdd(
        MeshComponent(
          mesh: CuboidMesh(size: Vector3.all(1), material: material),
        ),
      );
      final before = group.castersVersion;
      material.castsShadows = false;
      expect(group.castersVersion, isNot(before));
    });

    testWithGame('cameraMask, visibility and world settings', _game, (
      game,
    ) async {
      final world = game.world as World3D;
      final group = Group3D();
      await world.ensureAdd(group);
      final versions = _Versions(world);

      group.cameraMask = 0x02;
      expect(versions.take(), _sceneAndShadows);
      group.cameraMask = 0x02;
      expect(versions.take(), _nothing);

      world.depthPrepassEnabled = true;
      expect(versions.take(), _sceneOnly);
      world.depthPrepassEnabled = true;
      expect(versions.take(), _nothing);

      world.prioritizeNearestLights = true;
      expect(versions.take().scene, isTrue);
    });

    testWithGame('light source fields', _game, (game) async {
      final world = game.world as World3D;
      final sun = DirectionalLight(
        direction: Vector3(0, -1, 0),
        shadows: ShadowSettings(),
      );
      final light = LightComponent(source: sun);
      final lamp = SpotLight();
      final point = PointLight(color: const Color(0xFFFFFFFF), intensity: 1);
      final sky = HemisphereLight();
      await world.ensureAddAll([
        light,
        LightComponent(source: lamp),
        LightComponent(source: point),
        LightComponent(source: sky),
      ]);
      final versions = _Versions(world);

      sun.color = const Color(0xFFFFEEDD);
      expect(versions.take(), _sceneOnly);
      sun.intensity = 2;
      expect(versions.take(), _sceneOnly);
      sun.intensity = 2;
      expect(versions.take(), _nothing);
      sun.specular = 0.5;
      expect(versions.take(), _sceneOnly);
      sun.direction = Vector3(1, -1, 0);
      expect(versions.take(), _sceneAndShadows);
      sun.shadows = ShadowSettings(resolution: 512);
      expect(versions.take(), _sceneAndShadows);

      // In-place changes are reported by hand.
      sun.direction!.setValues(0, -1, 1);
      expect(versions.take(), _nothing);
      sun.markChanged();
      expect(versions.take(), _sceneAndShadows);
      sun.markChanged(shadows: false);
      expect(versions.take(), _sceneOnly);

      // A light without shadows moves no shadow.
      lamp.direction = Vector3(0, 0, -1);
      expect(versions.take(), _sceneOnly);
      lamp.innerConeAngle = 0.2;
      expect(versions.take(), _sceneOnly);
      lamp.outerConeAngle = 0.6;
      expect(versions.take(), _sceneOnly);
      lamp.range = 5;
      expect(versions.take(), _sceneOnly);
      lamp.shadows = ShadowSettings();
      expect(versions.take(), _sceneAndShadows);
      lamp.range = 6;
      expect(versions.take(), _sceneAndShadows);

      point.range = 3;
      expect(versions.take(), _sceneOnly);
      sky.groundColor = const Color(0xFF203040);
      expect(versions.take(), _sceneOnly);
      sky.up = Vector3(0, 0, 1);
      expect(versions.take(), _sceneOnly);

      light.lightMask = 0x02;
      expect(versions.take(), _sceneOnly);

      // A removed light no longer reaches the world.
      light.removeFromParent();
      await game.ready();
      versions.take();
      sun.color = const Color(0xFF000000);
      expect(versions.take(), _nothing);
    });

    testWithGame(
      'moves reach the casters only when they can move shadows',
      _game,
      (
        game,
      ) async {
        final world = game.world as World3D;
        final lamp = LightComponent.point(position: Vector3(1, 1, 1));
        final spot = LightComponent.spot(shadows: ShadowSettings());
        final sun = LightComponent.directional(shadows: ShadowSettings());
        final caster = MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)));
        final nonCaster = MeshComponent(
          mesh: CuboidMesh(size: Vector3.all(1)),
          castsShadows: false,
        );
        final probe = Group3D();
        final parent = Group3D(
          children: [MeshComponent(mesh: CuboidMesh(size: Vector3.all(1)))],
        );
        await world.ensureAddAll([
          lamp,
          spot,
          sun,
          caster,
          nonCaster,
          probe,
          parent,
        ]);
        final versions = _Versions(world);

        lamp.position.x = 2;
        expect(versions.take(), _sceneOnly);
        nonCaster.position.x = 2;
        expect(versions.take(), _sceneOnly);
        probe.position.x = 2;
        expect(versions.take(), _sceneOnly);

        spot.position.x = 2;
        expect(versions.take(), _sceneAndShadows);
        sun.rotation.setAxisAngle(Vector3(1, 0, 0), 0.3);
        expect(versions.take(), _sceneAndShadows);
        caster.position.x = 2;
        expect(versions.take(), _sceneAndShadows);
        parent.position.x = 2;
        expect(versions.take(), _sceneAndShadows);

        // Rewriting the same positions every update costs nothing.
        for (var i = 0; i < 3; i++) {
          lamp.position.setValues(2, 1, 1);
          spot.position.x = 2;
          caster.position = Vector3(2, 0, 0);
        }
        expect(versions.take(), _nothing);
      },
    );

    testWithGame('writing an unchanged transform marks nothing', _game, (
      game,
    ) async {
      final world = game.world as World3D;
      final mesh = MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(1)),
        position: Vector3(1, 2, 3),
      );
      await world.ensureAdd(mesh);
      final versions = _Versions(world);

      mesh.position.setValues(1, 2, 3);
      mesh.position = Vector3(1, 2, 3);
      mesh.scale.setFrom(Vector3.all(1));
      mesh.rotation.setFrom(Quaternion.identity());
      mesh.transform.setFrom(mesh.transform.clone());
      expect(versions.take(), _nothing);

      mesh.position.x = 4;
      expect(versions.take(), _sceneAndShadows);
    });

    testWithGame('particles spawned or cleared outside update', _game, (
      game,
    ) async {
      final world = game.world as World3D;
      final billboards = ParticleSystem3D(material: ParticleMaterial());
      final meshes = ParticleSystem3D(mesh: CuboidMesh(size: Vector3.all(1)));
      await world.ensureAddAll([billboards, meshes]);
      final versions = _Versions(world);

      // Nothing spawned, nothing to clear.
      expect(billboards.burst(0), 0);
      billboards.clear();
      expect(versions.take(), _nothing);

      // Billboards cast no shadows.
      expect(billboards.burst(3), 3);
      expect(versions.take(), _sceneOnly);
      expect(billboards.spawn(position: Vector3.zero()), isTrue);
      expect(versions.take(), _sceneOnly);
      billboards.clear();
      expect(versions.take(), _sceneOnly);
      billboards.prewarm(0.1);
      expect(versions.take(), _sceneOnly);

      // Mesh particles that cast shadows move the casters too.
      meshes.burst(2);
      expect(versions.take(), _sceneAndShadows);
      meshes.reset();
      expect(versions.take(), _sceneAndShadows);
      meshes.castsShadows = false;
      versions.take();
      meshes.spawn(position: Vector3.zero());
      expect(versions.take(), _sceneOnly);
    });

    testWithGame('the size and orientation of a Text3DComponent', _game, (
      game,
    ) async {
      final world = game.world as World3D;
      final label = Text3DComponent(text: 'label');
      await world.ensureAdd(label);
      final versions = _Versions(world);
      final height = label.aabb.max.y - label.aabb.min.y;

      label.worldHeight = 1.1;
      expect(versions.take(), _sceneOnly);
      expect(label.aabb.max.y - label.aabb.min.y, closeTo(height * 2, 1e-5));
      label.worldHeight = 1.1;
      expect(versions.take(), _nothing);

      label.orientation = BillboardOrientation3D.cylindrical;
      expect(versions.take(), _sceneOnly);
      label.orientation = BillboardOrientation3D.cylindrical;
      expect(versions.take(), _nothing);
    });

    testWithGame('the vertices a cloth and a rope write', _game, (game) async {
      final world = game.world as World3D;
      final cloth = XpbdCloth3D(columns: 4, rows: 4, autoStep: false);
      final rope = XpbdRope3D(
        startPoint: Vector3.zero(),
        endPoint: Vector3(0, -1, 0),
        segmentCount: 4,
        autoStep: false,
      );
      await world.ensureAddAll([cloth, rope]);
      final versions = _Versions(world);

      cloth.step(1 / 60);
      expect(versions.take(), _sceneAndShadows);
      rope.step(1 / 60);
      expect(versions.take(), _sceneAndShadows);
    });
  });

  group('CameraComponent3D wakes on-demand rendering', () {
    testWithGame(
      'a mounted camera is polled by its game',
      () => FlameGame(
        world: World3D(),
        camera: CameraComponent3D(
          position: Vector3(0, 0, 5),
          target: Vector3.zero(),
        ),
      ),
      (game) async {
        final camera = game.camera as CameraComponent3D;
        expect(game.dirtyVersionSourceCount, 1);
        // ignore: invalid_use_of_internal_member
        game.onFrameRendered();
        // ignore: invalid_use_of_protected_member
        expect(game.pollSceneDirtyForRender(), isFalse);

        camera.position.x = 1;
        // ignore: invalid_use_of_protected_member
        expect(game.pollSceneDirtyForRender(), isTrue);
        // ignore: invalid_use_of_internal_member
        game.onFrameRendered();
        // ignore: invalid_use_of_protected_member
        expect(game.pollSceneDirtyForRender(), isFalse);

        camera.removeFromParent();
        await game.ready();
        expect(game.dirtyVersionSourceCount, 0);
      },
    );

    test('a camera of a stack slot notifies when it moved', () {
      final camera = CameraComponent3D(
        position: Vector3(0, 0, 5),
        target: Vector3.zero(),
      );
      final stack = CameraStack3D(
        slots: [CameraViewportSlot3D(camera: camera)],
      )..update(0);
      final before = Game.visualMutationCount;
      stack.update(0.016);
      expect(Game.visualMutationCount, before);

      camera.target.x = 1;
      stack.update(0.016);
      expect(Game.visualMutationCount, greaterThan(before));
    });
  });
}
