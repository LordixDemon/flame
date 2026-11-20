import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart'
    show Component, RectangleComponent, World;
import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

const _red = Color(0xFFE03020);
const _green = Color(0xFF20C040);

Scene3DProjection _isoProjection() => Scene3DProjection.affine(
  origin: Vector2(64, 72),
  xAxis: Vector2(20, 10),
  yAxis: Vector2(-20, 10),
  zAxis: Vector2(0, -24),
  towardsViewer: Vector3(1, 1, 1),
  near: -50,
  far: 50,
);

/// Turns a mesh built with `+y` up into the `+z`-up world of the tests.
final Quaternion _yUpToZUp = Quaternion.axisAngle(
  Vector3(1, 0, 0),
  math.pi / 2,
);

MeshComponent _box(Material material, {Vector3? position, double size = 1}) =>
    MeshComponent(
      mesh: CuboidMesh(size: Vector3.all(size), material: material),
      position: position ?? Vector3(0, 0, size / 2),
    );

/// An upright quad in the stylized layout, facing the viewer, whose top
/// vertices sway in the wind.
Mesh _swayingQuad(Material material) {
  const h = 0.6 * 0.7071;
  return Mesh()..addSurface(
    StylizedMaterial.buildSurface(
      positions: const [-h, h, 0, h, -h, 0, h, -h, 1.2, -h, h, 1.2],
      normals: [
        for (var i = 0; i < 4; i++) ...[0.7071, 0.7071, 0],
      ],
      sway: const [0, 0, 1, 1],
      indices: const [0, 1, 2, 2, 3, 0],
      material: material,
    ),
  );
}

/// A retained layer showing its objects under a sun and an ambient light, in a
/// 2D game with an animated 2D sibling so that Flutter paints every frame.
class _Scene(
  List<Component> objects, {
  List<Component> lights = const [],
  Scene3DCacheMode cacheMode = Scene3DCacheMode.retained,
  Color? background,
}) {
  this {
    layer.cacheMode = cacheMode;
    layer.world.addAll([
      if (lights.isEmpty) ...[
        LightComponent.ambient(intensity: 0.5),
        LightComponent.directional(direction: Vector3(0.4, -0.3, -1)),
      ] else
        ...lights,
      ...objects,
    ]);
    game = FlameGame(
      world: World(
        children: [
          if (background != null)
            RectangleComponent(
              size: Vector2.all(128),
              paint: Paint()..color = background,
            ),
          ticker2D,
          layer,
        ],
      ),
    );
    game.camera.viewfinder.position = Vector2(64, 64);
  }

  final Scene3DComponent layer = Scene3DComponent(
    projection: _isoProjection(),
  );

  // Toggles between two places on every frame, so Flutter paints them all.
  final RectangleComponent ticker2D = RectangleComponent(
    size: Vector2.all(2),
    paint: Paint()..color = const Color(0xFF202020),
  );

  late final FlameGame game;
  GlobalKey? _key;

  RenderStats get stats => layer.renderStats;

  Future<void> show(WidgetTester tester) async {
    tester.view
      ..physicalSize = const Size(128, 128)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = _key = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: key,
        child: GameWidget(game: game),
      ),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }

  /// Pumps one frame and returns its pixels.
  Future<Pixels> frame(WidgetTester tester) async {
    ticker2D.position.x = ticker2D.position.x == 0 ? 2 : 0;
    await tester.pump(const Duration(milliseconds: 16));
    final boundary =
        _key!.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final image = await boundary.toImage();
      final pixels = await readImage(image);
      image.dispose();
      return pixels;
    }))!;
  }

  /// Pumps frames until the layer reuses its image, and checks that it then
  /// keeps reusing it: nothing renders at rest.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 3; i++) {
      await frame(tester);
    }
    final hits = layer.cacheHitCount;
    await frame(tester);
    expect(stats.renderPasses, 0, reason: 'nothing renders at rest');
    expect(layer.cacheHitCount, hits + 1);
  }

  /// The pixels a layer without caching shows two frames later (the 2D
  /// sibling is then where it was), restoring the cache mode after.
  Future<Pixels> fresh(WidgetTester tester) async {
    layer.cacheMode = Scene3DCacheMode.none;
    await frame(tester);
    final pixels = await frame(tester);
    layer.cacheMode = Scene3DCacheMode.retained;
    return pixels;
  }
}

/// A material family: what draws it, a change of one of its values (which
/// shows when [visible]), and the write of a value it already holds.
class _Family(
  final String name,
  final List<Component> Function() build,
  final void Function() change,
  final void Function() same, {
  final bool visible = true,
  final List<Component> lights = const [],
});

List<_Family> _families() {
  final spatial = SpatialMaterial(
    albedoColor: _red,
    metallic: 0,
    roughness: 1,
  );
  final unlit = opaqueUnlit(_red);
  final stylized = StylizedMaterial(albedoColor: _red);
  final water = WaterMaterial(upAxis: Vector3(0, 0, 1), opacity: 1);
  final barrier = BarrierMaterial(pattern: BarrierPattern.plain);
  final decal = DecalMaterial(albedoColor: _red, softness: 0);
  final outline = OutlineMaterial(color: _red, thickness: 0.12);
  final billboard = BillboardMaterial3D(albedoColor: _red, alphaCutoff: 0);
  final particles = ParticleMaterial(sprite: ParticleSprite.texture);
  final ribbon = RibbonMaterial3D(albedoColor: _red);
  final catcher = ShadowCatcherMaterial(color: const Color(0xE0200000));
  final sky = SkyboxMaterial3D(zenithColor: _red, horizonColor: _red);

  return [
    _Family(
      'SpatialMaterial',
      () => [_box(spatial)],
      () => spatial.albedoColor = _green,
      () => spatial.albedoColor = _green,
    ),
    _Family(
      'UnlitMaterial',
      () => [_box(unlit)],
      () => unlit.albedoColor = _green,
      () => unlit.albedoColor = _green,
    ),
    _Family(
      'StylizedMaterial',
      () => [_box(stylized)],
      () => stylized.albedoColor = _green,
      () => stylized.albedoColor = _green,
    ),
    _Family(
      'WaterMaterial',
      () => [_box(water, size: 1.5)],
      () => water
        ..shallowColor = _green
        ..deepColor = _green,
      () => water
        ..shallowColor = _green
        ..deepColor = _green,
    ),
    _Family(
      'BarrierMaterial',
      () => [
        MeshComponent(
          mesh: BarrierMesh.roundedRectangle(
            width: 2,
            depth: 2,
            height: 1,
            material: barrier,
          ),
          rotation: _yUpToZUp,
        ),
      ],
      () => barrier.footColor = const Color(0xFF40FF60),
      () => barrier.footColor = const Color(0xFF40FF60),
    ),
    _Family(
      'DecalMaterial',
      () => [
        DecalBatch3D(material: decal)
          ..addDecal(transform: Matrix4.diagonal3Values(2, 2, 1)),
      ],
      () => decal.albedoColor = _green,
      () => decal.albedoColor = _green,
    ),
    _Family(
      'OutlineMaterial',
      () => [_box(outline)],
      () => outline.color = _green,
      () => outline.color = _green,
    ),
    _Family(
      'BillboardMaterial3D',
      () => [
        BillboardBatch3D(material: billboard)
          ..addBillboard(position: Vector3.zero(), width: 1.5, height: 1.5),
      ],
      () => billboard.albedoColor = _green,
      () => billboard.albedoColor = _green,
    ),
    _Family(
      'ParticleMaterial',
      () => [
        ParticleSystem3D(capacity: 4, material: particles)
          ..paused = true
          ..spawn(position: Vector3(0, 0, 0.5), size: 1.2, color: _red),
      ],
      () => particles.color = _green,
      () => particles.color = _green,
    ),
    _Family(
      'RibbonMaterial3D',
      () => [
        StrokeBatch3D(material: ribbon)..addPolyline(
          [Vector3(-1.5, 0, 0.5), Vector3(1.5, 0, 0.5)],
          width: 0.6,
          endWidth: 0.6,
          endOpacity: 1,
        ),
      ],
      () => ribbon.albedoColor = _green,
      () => ribbon.albedoColor = _green,
    ),
    _Family(
      'ShadowCatcherMaterial',
      () => [
        MeshComponent(
          mesh: PlaneMesh(size: Vector2.all(5), material: catcher),
          rotation: _yUpToZUp,
        ),
        _box(opaqueUnlit(const Color(0xFF808080))),
      ],
      () => catcher.color = const Color(0xE0002000),
      () => catcher.color = const Color(0xE0002000),
      lights: [
        LightComponent.directional(
          direction: Vector3(0.6, -0.4, -1),
          shadows: ShadowSettings(),
        ),
      ],
    ),
    _Family(
      'SkyboxMaterial3D',
      () => [SkyboxComponent3D(material: sky), _box(opaqueUnlit(_red))],
      () => sky.zenithColor = _green,
      () => sky.zenithColor = _green,
      visible: false,
    ),
  ];
}

void main() {
  setUpGpu();

  group('A retained layer follows the materials it shows', () {
    for (final family in _families()) {
      testGpu('${family.name}: renders again after a change, not after an '
          'unchanged write', (tester) async {
        final scene = _Scene(family.build(), lights: family.lights);
        await scene.show(tester);
        await scene.settle(tester);
        final before = await scene.frame(tester);
        expect(scene.stats.renderPasses, 0);

        family.change();
        final after = await scene.frame(tester);
        expect(scene.stats.renderPasses, isNot(0));
        expect(scene.stats.updatedMaterials, 1);
        expect(scene.stats.animatedMaterials, 0);
        if (family.visible) {
          expect(differingPixels(before, after), greaterThan(20));
        }
        // The retained image is what a layer without caching shows.
        expect(
          differingPixels(after, await scene.fresh(tester), tolerance: 0),
          0,
        );

        await scene.settle(tester);
        family.same();
        await scene.frame(tester);
        expect(scene.stats.renderPasses, 0, reason: 'nothing changed');
      });
    }
  });

  group('Animation time', () {
    final water = WaterMaterial(upAxis: Vector3(0, 0, 1), opacity: 1);
    final stylized = StylizedMaterial(
      albedoColor: _red,
      windAmplitude: 0.3,
      windDirection: Vector3(1, -1, 0),
    );
    final barrier = BarrierMaterial(patternSpeed: 2);
    for (final (name, objects, advance) in [
      (
        'WaterMaterial.time',
        () => [_box(water, size: 1.5)],
        () {
          water.time += 0.25;
        },
      ),
      (
        'StylizedMaterial.windTime',
        () => [
          MeshComponent(mesh: _swayingQuad(stylized)),
        ],
        () {
          stylized.windTime += 0.25;
        },
      ),
      (
        'BarrierMaterial.time',
        () => [
          MeshComponent(
            mesh: BarrierMesh.roundedRectangle(
              width: 2,
              depth: 2,
              height: 1,
              material: barrier,
            ),
            rotation: _yUpToZUp,
          ),
        ],
        () {
          barrier.time += 0.25;
        },
      ),
    ]) {
      testGpu('$name renders every frame it advances, and holds still '
          'otherwise', (tester) async {
        final scene = _Scene(objects());
        await scene.show(tester);
        await scene.settle(tester);
        var previous = await scene.frame(tester);
        for (var i = 0; i < 3; i++) {
          advance();
          final pixels = await scene.frame(tester);
          expect(scene.stats.renderPasses, isNot(0));
          expect(scene.stats.animatedMaterials, 1);
          expect(scene.stats.updatedMaterials, 0);
          expect(differingPixels(previous, pixels), greaterThan(0));
          previous = pixels;
        }
        await scene.frame(tester);
        expect(scene.stats.renderPasses, 0);
      });
    }
  });

  group('A retained layer', () {
    testGpu('does not render again for a material it does not draw', (
      tester,
    ) async {
      final shown = opaqueUnlit(_red);
      final hidden = opaqueUnlit(_red);
      final elsewhere = opaqueUnlit(_red);
      final scene = _Scene([
        _box(shown),
        _box(hidden, position: Vector3(1.5, 0, 0.5))..visible = false,
      ]);
      final other = Scene3DComponent(
        projection: _isoProjection(),
        cacheMode: Scene3DCacheMode.retained,
      );
      other.world.add(_box(elsewhere));
      scene.game.world.add(other);
      await scene.show(tester);
      await scene.settle(tester);

      hidden.albedoColor = _green;
      elsewhere.albedoColor = _green;
      await scene.frame(tester);
      expect(scene.stats.renderPasses, 0);
      expect(other.renderStats.renderPasses, isNot(0));
      expect(other.renderStats.updatedMaterials, 1);

      shown.albedoColor = _green;
      await scene.frame(tester);
      expect(scene.stats.renderPasses, isNot(0));
      expect(other.renderStats.renderPasses, 0);
    });

    testGpu('renders again for the state its materials read', (tester) async {
      final ripples = WaterRipples();
      final sources = WaterFoamSources();
      final water = WaterMaterial(
        upAxis: Vector3(0, 0, 1),
        opacity: 1,
        ripples: ripples,
        foamSources: sources,
      );
      final stylized = StylizedMaterial(
        albedoColor: _red,
        accentPalette: const [_red],
      );
      final barrier = BarrierMaterial();
      final scene = _Scene([
        _box(water, size: 1.5),
        _box(stylized, position: Vector3(-1.5, 1.5, 0.5)),
        MeshComponent(
          mesh: BarrierMesh.roundedRectangle(
            width: 4,
            depth: 4,
            height: 0.5,
            material: barrier,
          ),
          rotation: _yUpToZUp,
        ),
      ]);
      await scene.show(tester);
      await scene.settle(tester);

      final slot = sources.addCircle(Vector3(0.5, 0, 0.75), radius: 0.2);
      for (final (what, action, renders) in [
        ('a ripple added', () => ripples.add(Vector3.zero(), time: 0), true),
        (
          'a foam source moved',
          () => sources.move(slot, Vector3(0.6, 0, 0.75)),
          true,
        ),
        (
          'a foam source moved where it is',
          () => sources.move(slot, Vector3(0.6, 0, 0.75)),
          false,
        ),
        ('a palette entry', () => stylized.accentPalette[0] = _green, true),
        (
          'a palette entry written again',
          () => stylized.accentPalette[0] = _green,
          false,
        ),
        ('an impact', () => barrier.impact(Vector3(2, 0, 0.25)), true),
        ('a look', () => barrier.applyLook(BarrierLook.solidWall), true),
        (
          'the same look again',
          () => barrier.applyLook(BarrierLook.solidWall),
          false,
        ),
        (
          'a near point',
          () => barrier.setNearPoint(0, Vector3(2, 0, 0.25)),
          true,
        ),
        (
          'the same near point',
          () => barrier.setNearPoint(0, Vector3(2, 0, 0.25)),
          false,
        ),
      ]) {
        action();
        await scene.frame(tester);
        expect(
          scene.stats.renderPasses,
          renders ? isNot(0) : 0,
          reason: what,
        );
        await scene.frame(tester);
        expect(scene.stats.renderPasses, 0, reason: 'after $what');
      }
    });

    testGpu('renders again for the fields of its fog and water volume', (
      tester,
    ) async {
      final fog = FogSettings(
        start: 0,
        end: 0.01,
        maxOpacity: 0.8,
        up: Vector3(0, 0, 1),
      );
      final volume = WaterVolumeSettings(
        level: 0.3,
        up: Vector3(0, 0, 1),
        absorption: 2,
        causticStrength: 1,
      );
      final scene = _Scene([_box(StylizedMaterial(albedoColor: _red))]);
      scene.layer.world
        ..fog = fog
        ..waterVolume = volume;
      await scene.show(tester);
      await scene.settle(tester);

      var before = await scene.frame(tester);
      fog.color = _green;
      var after = await scene.frame(tester);
      expect(scene.stats.renderPasses, isNot(0));
      expect(differingPixels(before, after), greaterThan(20));
      await scene.frame(tester);
      fog.color = _green;
      await scene.frame(tester);
      expect(scene.stats.renderPasses, 0);

      before = after;
      volume.time += 1.3;
      after = await scene.frame(tester);
      expect(scene.stats.renderPasses, isNot(0));
      expect(differingPixels(before, after), greaterThan(0));
    });

    testGpu('renders again when a surface gets another material', (
      tester,
    ) async {
      final mesh = CuboidMesh(
        size: Vector3.all(1),
        material: opaqueUnlit(_red),
      );
      final scene = _Scene([
        MeshComponent(mesh: mesh, position: Vector3(0, 0, 0.5)),
      ]);
      await scene.show(tester);
      await scene.settle(tester);
      final before = await scene.frame(tester);
      final green = opaqueUnlit(_green);
      mesh.surfaces.first.material = green;
      final after = await scene.frame(tester);
      expect(scene.stats.renderPasses, isNot(0));
      expect(differingPixels(before, after), greaterThan(20));
      await scene.frame(tester);
      mesh.surfaces.first.material = green;
      await scene.frame(tester);
      expect(scene.stats.renderPasses, 0);
    });

    testGpu('renders every frame while it draws a material marked animated', (
      tester,
    ) async {
      final material = opaqueUnlit(_red);
      final box = _box(material);
      final scene = _Scene([box]);
      await scene.show(tester);
      await scene.settle(tester);

      material.animated = true;
      for (var i = 0; i < 4; i++) {
        await scene.frame(tester);
        expect(scene.stats.renderPasses, isNot(0), reason: 'frame $i');
        expect(scene.stats.animatedMaterials, 1);
      }

      // Hidden, it is no longer drawn: the layer settles.
      box.visible = false;
      await scene.frame(tester);
      await scene.frame(tester);
      expect(scene.stats.renderPasses, 0);

      box.visible = true;
      await scene.frame(tester);
      await scene.frame(tester);
      expect(scene.stats.renderPasses, isNot(0));
      material.animated = false;
      await scene.frame(tester);
      await scene.frame(tester);
      expect(scene.stats.renderPasses, 0);
    });
  });

  group('Cached shadow maps', () {
    for (final still in [false, true]) {
      final mode = still ? 'cacheStillCasters' : 'cacheWhenStatic';
      testGpu('$mode: kept when a material changes, rendered again when '
          'what casts changes', (tester) async {
        final casterMaterial = StylizedMaterial(albedoColor: _red);
        final scene = _Scene(
          [
            MeshComponent(
              mesh: PlaneMesh(
                size: Vector2.all(5),
                material: ShadowCatcherMaterial(color: const Color(0xE0000000)),
              ),
              rotation: _yUpToZUp,
            ),
            _box(casterMaterial),
          ],
          lights: [
            LightComponent.ambient(intensity: 0.5),
            LightComponent.directional(
              direction: Vector3(0.6, -0.4, -1),
              shadows: ShadowSettings(
                cacheWhenStatic: !still,
                cacheStillCasters: still,
              ),
            ),
          ],
          background: const Color(0xFF90A090),
        );
        await scene.show(tester);
        await scene.settle(tester);
        int dark(Pixels pixels) =>
            pixels.count((r, g, b, a) => a > 200 && r < 40 && g < 40 && b < 40);
        final shadowed = dark(await scene.frame(tester));
        expect(shadowed, greaterThan(40));

        casterMaterial.albedoColor = _green;
        final pixels = await scene.frame(tester);
        expect(scene.stats.renderPasses, isNot(0));
        expect(scene.stats.shadowPasses, 0);
        expect(scene.stats.shadowLayersRendered, 0);
        expect(dark(pixels), shadowed);

        // Translucent, the caster no longer casts by default.
        casterMaterial.renderState = StylizedMaterial.translucentRenderState;
        final unshadowed = await scene.frame(tester);
        expect(scene.stats.shadowPasses, isNot(0));
        expect(dark(unshadowed), lessThan(shadowed ~/ 4));
      });
    }
  });

  testGpu('a game that paints only changed frames wakes up for a material '
      'change, and not for an unchanged write', (tester) async {
    final material = opaqueUnlit(_red);
    final scene = _Scene([_box(material)]);
    scene.game.idleRenderMode = IdleRenderMode.onDemand;
    await scene.show(tester);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    Future<bool> painted() async {
      final frames = scene.game.executedRenderFrames;
      await tester.pump(const Duration(milliseconds: 16));
      return scene.game.executedRenderFrames != frames;
    }

    expect(await painted(), isFalse);
    material.albedoColor = _green;
    expect(await painted(), isTrue);
    expect(await painted(), isFalse);
    material.albedoColor = _green;
    expect(await painted(), isFalse);
  });
}
