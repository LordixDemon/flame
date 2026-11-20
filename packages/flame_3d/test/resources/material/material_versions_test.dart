import 'dart:io';
import 'dart:ui';

import 'package:flame/game.dart' show FlameGame, Game;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records the version of [target] and [Game.visualMutationCount], to tell
/// what a write changed.
class _Watch(final Versioned target) {
  int version = target.version;
  int mutations = Game.visualMutationCount;

  /// Whether the version changed since the last call (asserting that the
  /// game was woken exactly then), and resets.
  bool take() {
    final changed = target.version != version;
    final woke = Game.visualMutationCount != mutations;
    expect(woke, changed, reason: 'a change wakes the game, nothing else');
    expect(target.version, greaterThanOrEqualTo(version));
    version = target.version;
    mutations = Game.visualMutationCount;
    return changed;
  }
}

/// Expects that [change] changes [target] once and that writing the same
/// value again ([change] a second time) does not.
void _expectSetter(Versioned target, void Function() change) {
  final watch = _Watch(target);
  change();
  expect(watch.take(), isTrue, reason: 'the first write changes a value');
  change();
  expect(watch.take(), isFalse, reason: 'writing it again changes nothing');
}

const _red = Color(0xFFFF0000);
const _green = Color(0xFF00FF00);

FlameGame _game() => FlameGame(world: World3D());

void main() {
  group('Material setters raise the version on a change only', () {
    test('Material', () {
      final material = UnlitMaterial();
      _expectSetter(material, () => material.translucentOrder = -1);
      _expectSetter(material, () => material.depthPrepassGroup = 'group');
      _expectSetter(
        material,
        () => material.renderState = RenderState.additive,
      );
      _expectSetter(material, () => material.animated = true);
      final shader = VertexShader.fromAsset(
        'packages/flame_3d/assets/shaders/unlit_material.shaderbundle',
      );
      _expectSetter(material, () => material.vertexShader = shader);
      final watch = _Watch(material);
      material.markChanged();
      expect(watch.take(), isTrue);
    });

    test('SpatialMaterial', () {
      final material = SpatialMaterial();
      _expectSetter(material, () => material.albedoColor = _red);
      _expectSetter(material, () => material.metallic = 0.1);
      _expectSetter(material, () => material.roughness = 0.9);
      _expectSetter(material, () => material.emissiveStrength = 3);
      _expectSetter(material, () => material.ior = 1.33);
      _expectSetter(material, () => material.doubleSided = true);
      _expectSetter(material, () => material.albedoTexture = Texture.empty);
      _expectSetter(material, () => material.normalTexture = Texture.empty);
      // The UV vectors report changes in place, and assigning one copies it.
      _expectSetter(material, () => material.uvOffset.x = 0.25);
      _expectSetter(material, () => material.uvScale.setValues(2, 3));
      final scale = Vector2(4, 4);
      _expectSetter(material, () => material.uvScale = scale);
      scale.x = 5;
      expect(material.uvScale.x, 4);
    });

    test('StylizedMaterial, its palettes and vectors', () {
      final material = StylizedMaterial(accentPalette: const [_red]);
      _expectSetter(material, () => material.albedoColor = _green);
      _expectSetter(material, () => material.emissiveStrength = 0.4);
      _expectSetter(material, () => material.windSpace = WindSpace.model);
      _expectSetter(
        material,
        () => material.emissiveColorSource = EmissiveColorSource.accent,
      );
      _expectSetter(material, () => material.depthBias = 0.001);
      _expectSetter(material, () => material.matCapTexture = Texture.empty);
      _expectSetter(material, () => material.accentPalette[0] = _green);
      final watch = _Watch(material);
      material.accentPalette.add(_red);
      expect(watch.take(), isTrue);
      material.rimPalette.addAll(const [_red, _green]);
      expect(watch.take(), isTrue);
      material.rimPalette.removeLast();
      expect(watch.take(), isTrue);
      material.rimPalette.clear();
      expect(watch.take(), isTrue);
      material.rimPalette.clear();
      expect(watch.take(), isFalse);
      _expectSetter(material, () => material.windDirection.setValues(0, 0, 1));
      _expectSetter(material, () => material.windPhase.x = 0);
      _expectSetter(material, () => material.skyFillWeight = Vector3.all(2));
      _expectSetter(material, () => material.windGustDirection.y = 1);
      _expectSetter(material, () => material.windUpAxis.z = 1);
    });

    test('WaterMaterial, with its ripples and foam sources', () {
      final ripples = WaterRipples();
      final sources = WaterFoamSources();
      final material = WaterMaterial(ripples: ripples, foamSources: sources);
      _expectSetter(material, () => material.shallowColor = _red);
      _expectSetter(material, () => material.causticStrength = 0.5);
      _expectSetter(material, () => material.edgeFoamMotion = 0);
      _expectSetter(material, () => material.opacity = 0.5);
      _expectSetter(material, () => material.upAxis.setValues(0, 0, 1));

      final watch = _Watch(material);
      ripples.add(Vector3.zero(), time: 0);
      expect(watch.take(), isTrue);
      final slot = sources.addCircle(Vector3.zero(), radius: 0.5);
      expect(watch.take(), isTrue);
      sources.move(slot, Vector3(1, 0, 0));
      expect(watch.take(), isTrue);
      sources.move(slot, Vector3(1, 0, 0));
      expect(watch.take(), isFalse);
      ripples.clear();
      expect(watch.take(), isTrue);
      ripples.clear();
      expect(watch.take(), isFalse);

      // Replacing a state by one of a lower version still increases it.
      final fresh = WaterRipples();
      expect(fresh.version, lessThan(ripples.version));
      _expectSetter(material, () => material.ripples = fresh);
      _expectSetter(material, () => material.foamSources = null);
    });

    test('BarrierMaterial, its looks, impacts, pulses and near points', () {
      final material = BarrierMaterial();
      _expectSetter(material, () => material.intensity = 1.5);
      _expectSetter(material, () => material.footColor = _red);
      _expectSetter(material, () => material.patternColor = _green);
      _expectSetter(material, () => material.patternColor = null);
      _expectSetter(material, () => material.pattern = BarrierPattern.grid);
      _expectSetter(
        material,
        () => material.setNearPoint(0, Vector3(1, 2, 3)),
      );
      _expectSetter(material, () => material.clearNearPoint(0));
      _expectSetter(material, () => material.applyLook(BarrierLook.solidWall));
      _expectSetter(
        material,
        () => material.applyLookLerp(
          BarrierLook.solidWall,
          BarrierLook.standard,
          0.5,
        ),
      );
      final watch = _Watch(material);
      material.impact(Vector3.zero());
      expect(watch.take(), isTrue);
      material.clearImpacts();
      expect(watch.take(), isTrue);
      material.clearImpacts();
      expect(watch.take(), isFalse);
      material.pulse();
      expect(watch.take(), isTrue);
      material.clearPulse();
      expect(watch.take(), isTrue);
      material.clearPulse();
      expect(watch.take(), isFalse);
      // The reaction material follows the changes of its barrier.
      final reaction = material.reactionInFrontMaterial;
      final reactionWatch = _Watch(reaction);
      material.glintPower = 7;
      expect(reactionWatch.take(), isTrue);
    });

    test('the other materials', () {
      final unlit = UnlitMaterial();
      _expectSetter(unlit, () => unlit.albedoColor = _red);
      _expectSetter(unlit, () => unlit.albedoTexture = Texture.empty);
      final decal = DecalMaterial();
      _expectSetter(decal, () => decal.softness = 0.4);
      _expectSetter(decal, () => decal.texture = Texture.empty);
      final outline = OutlineMaterial();
      _expectSetter(outline, () => outline.thickness = 0.1);
      final catcher = ShadowCatcherMaterial();
      _expectSetter(catcher, () => catcher.color = _red);
      _expectSetter(catcher, () => catcher.nearestOnly = true);
      final billboard = BillboardMaterial3D();
      _expectSetter(billboard, () => billboard.shadeWeight = 0.2);
      _expectSetter(billboard, () => billboard.albedoTexture = Texture.empty);
      final particles = ParticleMaterial();
      _expectSetter(particles, () => particles.color = _red);
      _expectSetter(
        particles,
        () => particles.sprite = ParticleSprite.softBlob,
      );
      _expectSetter(particles, () => particles.axis.setValues(1, 0, 0));
      final ribbon = RibbonMaterial3D();
      _expectSetter(ribbon, () => ribbon.edgeSoftness = 0.1);
      final sky = SkyboxMaterial3D();
      _expectSetter(sky, () => sky.zenithColor = _red);
      _expectSetter(sky, () => sky.sunDirection.setValues(0, -1, 0));
      _expectSetter(sky, () => sky.upAxis = Vector3(0, 0, 1));
    });

    test('the time of an animation counts as an animation', () {
      final water = WaterMaterial();
      final stylized = StylizedMaterial();
      final barrier = BarrierMaterial();
      for (final (material, advance) in [
        (water, () => water.time += 0.5),
        (stylized, () => stylized.windTime += 0.5),
        (barrier, () => barrier.time += 0.5),
      ]) {
        final watch = _Watch(material);
        final animations = material.animationVersion;
        advance();
        expect(watch.take(), isTrue);
        expect(material.animationVersion, animations + 1);
      }
      final animations = water.animationVersion;
      final time = water.time;
      water.time = time;
      water.shallowColor = _red;
      expect(water.animationVersion, animations);
    });
  });

  group('Settings raise their version on a change only', () {
    test('fog, water volume, bloom and post-processing', () {
      final fog = FogSettings();
      _expectSetter(fog, () => fog.start = 2);
      _expectSetter(fog, () => fog.color = _red);
      _expectSetter(fog, () => fog.up.setValues(0, 0, 1));
      final volume = WaterVolumeSettings();
      _expectSetter(volume, () => volume.time = 1);
      _expectSetter(volume, () => volume.level = 0.5);
      _expectSetter(volume, () => volume.up.y = 2);
      final box = Aabb3();
      _expectSetter(volume, () => volume.bounds = box);
      final bloom = BloomSettings();
      _expectSetter(bloom, () => bloom.intensity = 1.2);
      _expectSetter(bloom, () => bloom.passes = 3);
      final post = PostProcessSettings();
      _expectSetter(post, () => post.exposure = 1.4);
      _expectSetter(post, () => post.toneMap = ToneMapMode.agx);
    });
  });

  group('World3D versions', () {
    testWithGame(
      'follow the fields of the world settings, not the shadow casters',
      _game,
      (game) async {
        final world = game.world as World3D;
        final fog = FogSettings();
        final volume = WaterVolumeSettings();
        world
          ..fog = fog
          ..waterVolume = volume
          ..bloom = BloomSettings()
          ..postProcess = PostProcessSettings();
        for (final change in <void Function()>[
          () => fog.end = 30,
          () => volume.time = 0.1,
          () => world.bloom!.radius = 2,
          () => world.postProcess!.contrast = 1.1,
        ]) {
          final scene = world.sceneVersion;
          final casters = world.castersVersion;
          final components = world.componentsVersion;
          change();
          expect(world.sceneVersion, greaterThan(scene));
          expect(world.castersVersion, casters);
          expect(world.componentsVersion, components);
          final after = world.sceneVersion;
          change();
          expect(world.sceneVersion, after);
        }

        // A replacement of a lower version still increases the version.
        final scene = world.sceneVersion;
        world.fog = FogSettings();
        expect(world.sceneVersion, greaterThan(scene));
        final settled = world.sceneVersion;
        fog.end = 40;
        expect(world.sceneVersion, settled, reason: 'the old fog is gone');
      },
    );

    testWithGame('do not change when a material is created', _game, (
      game,
    ) async {
      final world = game.world as World3D;
      final scene = world.sceneVersion;
      final casters = world.castersVersion;
      final materials = <Material>[
        SpatialMaterial(translucent: true),
        SpatialMaterial(doubleSided: true),
        StylizedMaterial(translucent: true),
        UnlitMaterial(),
        WaterMaterial(),
        BarrierMaterial(),
        DecalMaterial(),
        OutlineMaterial(),
        ShadowCatcherMaterial(nearestOnly: true),
        BillboardMaterial3D(translucent: true),
        ParticleMaterial(),
        RibbonMaterial3D(),
        SkyboxMaterial3D(),
      ];
      expect(materials, hasLength(13));
      expect(world.sceneVersion, scene);
      expect(world.castersVersion, casters);
    });

    testWithGame(
      'a render state that changes what casts shadows marks the casters',
      _game,
      (game) async {
        final world = game.world as World3D;
        var casters = world.castersVersion;
        final material = UnlitMaterial()..renderState = RenderState.opaque;
        expect(material.castsShadows, isTrue);
        expect(
          world.castersVersion,
          casters,
          reason: 'no shadow map holds a material no pass has drawn',
        );
        // As after a pass drew it.
        material.wasRecorded = true;
        casters = world.castersVersion;
        material.renderState = RenderState.alphaBlend;
        expect(material.castsShadows, isFalse);
        expect(world.castersVersion, greaterThan(casters));

        // Another translucent state casts nothing more.
        casters = world.castersVersion;
        material.renderState = RenderState.premultipliedAlphaBlend;
        expect(world.castersVersion, casters);

        // An explicit castsShadows does not follow the render state.
        material.castsShadows = false;
        casters = world.castersVersion;
        material.renderState = RenderState.opaque;
        expect(material.castsShadows, isFalse);
        expect(world.castersVersion, casters);
      },
    );

    testWithGame('follow the materials given to surfaces', _game, (
      game,
    ) async {
      final world = game.world as World3D;
      final opaque = UnlitMaterial()..renderState = RenderState.opaque;
      final surface = CuboidMesh(
        size: Vector3.all(1),
        material: opaque,
      ).surfaces.first;
      var scene = world.sceneVersion;
      var casters = world.castersVersion;
      final other = SpatialMaterial();
      surface.material = other;
      expect(world.sceneVersion, greaterThan(scene));
      expect(world.castersVersion, casters, reason: 'both cast shadows');

      scene = world.sceneVersion;
      surface.material = other;
      expect(world.sceneVersion, scene);

      casters = world.castersVersion;
      surface.material = UnlitMaterial();
      expect(world.castersVersion, greaterThan(casters));
    });
  });

  group('Every material and setting keeps its values behind setters', () {
    // The fields that a material or a setting class declares in its primary
    // constructor or body: a public field writable without a setter is a
    // change the engine cannot see.
    final files = [
      ...Directory('lib/src/resources/material')
          .listSync()
          .whereType<File>()
          .where((file) => file.path.endsWith('_material.dart')),
      File('lib/src/particles/particle_material.dart'),
      File('lib/src/particles/ribbon_material_3d.dart'),
      File('lib/src/components/skybox_component_3d.dart'),
      File('lib/src/resources/light/fog_settings.dart'),
      File('lib/src/resources/light/water_volume_settings.dart'),
      File('lib/src/graphics/bloom_settings.dart'),
      File('lib/src/graphics/post_process_settings.dart'),
    ];
    final publicVar = RegExp(r'^  var [^=,]+ [a-z]\w*( = .*)?,?$');
    final publicField = RegExp(
      '^  (?!static |final |const |late final |@|return )'
      r'[A-Za-z][\w<>?, ]* (?!get |set )[a-z]\w*( = .*)?;$',
    );

    for (final file in files) {
      final name = file.path.split('/').last;
      test(name, () {
        final offending = <String>[];
        var inClass = false;
        for (final line in file.readAsLinesSync()) {
          if (line.startsWith('class ') || line.startsWith('abstract class')) {
            inClass = !line.contains('Mesh') && !line.contains('Component3D');
          }
          if (!inClass) {
            continue;
          }
          if (publicVar.hasMatch(line) || publicField.hasMatch(line)) {
            offending.add(line.trim());
          }
        }
        expect(offending, isEmpty);
      });
    }
  });
}
