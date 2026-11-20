import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart' show RectangleComponent, World;
import 'package:flame/game.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// Every test runs a script of frames twice, keeping the still casters
// (ShadowSettings.cacheStillCasters) and rendering every caster in every
// frame, and compares the frames pixel for pixel.

const _width = 160.0;
const _height = 120.0;

Scene3DProjection _projection() => Scene3DProjection.affine(
  origin: Vector2(80, 40),
  xAxis: Vector2(12, 6),
  yAxis: Vector2(-12, 6),
  zAxis: Vector2(0, -14),
  towardsViewer: Vector3(1, 1, 1.2),
  near: -60,
  far: 60,
);

/// The lights of a test.
enum _Lights() {
  /// A sun with one map.
  sun,

  /// A spot light alone, with one map.
  spot,

  /// A sun with two cascades and a spot light: the atlas.
  cascadesAndSpot,

  /// A sun and a point light: the atlas with two paraboloid tiles.
  sunAndPoint,
}

/// How the scene of a test is lit and shadowed.
class const _Setup({
  final _Lights lights = _Lights.sun,
  final ShadowMapEncoding encoding = ShadowMapEncoding.auto,
  final ShadowFit fit = ShadowFit.scene,
  final Aabb3? bounds,
  final bool group = false,
});

/// A scene of still casters on a ground, and casters a script moves.
///
/// With [_Setup.group], the movers and half of the still casters are in the
/// world of a second layer that borrows the lights and shares the shadow map
/// of the first one.
class _Scene(final _Setup setup, {required final bool keep}) {
  late final Scene3DComponent layer = Scene3DComponent(
    projection: _projection(),
  );
  late final Scene3DComponent second = Scene3DComponent(
    projection: _projection(),
  );
  World3D get world => layer.world;
  World3D get moversWorld => setup.group ? second.world : layer.world;
  late final FlameGame game;

  final List<MeshComponent> still = [];
  final List<MeshComponent> movers = [];
  late final LightComponent sun;
  late final ShadowSettings settings;

  ShadowSettings _settings({int resolution = 256}) => ShadowSettings(
    resolution: resolution,
    fit: setup.fit,
    bounds: setup.bounds,
    encoding: setup.encoding,
    cacheStillCasters: keep,
    stillCasterFrames: 3,
    cascades: setup.lights == _Lights.cascadesAndSpot ? 2 : 1,
  );

  void build() {
    final lights = setup.lights;
    final ground = MeshComponent(
      mesh: PlaneMesh(
        size: Vector2.all(12),
        material: StylizedMaterial(albedoColor: const Color(0xFFD8D0C0)),
      ),
      rotation: Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2),
    );
    settings = _settings();
    sun = LightComponent.directional(
      direction: Vector3(0.45, -0.3, -1),
      intensity: 0.8,
      shadows: lights == _Lights.spot ? null : settings,
    );
    world.addAll([
      LightComponent.ambient(intensity: 0.35),
      sun,
      if (lights == _Lights.spot || lights == _Lights.cascadesAndSpot)
        LightComponent.spot(
          position: Vector3(-2, -2, 6),
          direction: Vector3(0.3, 0.3, -1),
          intensity: 3,
          range: 14,
          outerConeAngle: 0.9,
          shadows: lights == _Lights.spot ? settings : _settings(),
        ),
      if (lights == _Lights.sunAndPoint)
        LightComponent.point(
          position: Vector3(0.5, 0.5, 2.6),
          intensity: 4,
          range: 8,
          shadows: _settings(),
        ),
      ground,
    ]);
    if (setup.group) {
      final shadows = ShadowGroup();
      world.shadowGroup = shadows;
      second.world
        ..shadowGroup = shadows
        ..lightsFrom = world;
    }
    final materials = [
      for (final color in const [
        Color(0xFFC05040),
        Color(0xFF4070C0),
        Color(0xFF50A050),
      ])
        StylizedMaterial(albedoColor: color),
    ];
    for (var i = 0; i < 5; i++) {
      for (var j = 0; j < 5; j++) {
        final height = 0.4 + ((i * 7 + j * 3) % 5) * 0.25;
        final mesh = (i + j).isEven
            ? CuboidMesh(
                size: Vector3(0.6, 0.6, height),
                material: materials[(i + j) % 3],
              )
            : CylinderMesh(
                radius: 0.3,
                height: height,
                material: materials[(i * j) % 3],
              );
        final caster = MeshComponent(
          mesh: mesh,
          position: Vector3(-4 + i * 2.0, -4 + j * 2.0, height / 2),
          rotation: mesh is CylinderMesh
              ? Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2)
              : null,
        );
        still.add(caster);
      }
    }
    for (var k = 0; k < 2; k++) {
      movers.add(
        MeshComponent(
          mesh: CuboidMesh(
            size: Vector3(0.5, 0.5, 1.2),
            material: StylizedMaterial(albedoColor: const Color(0xFFE0B030)),
          ),
          position: Vector3(-3 + k * 3.0, -1, 0.6),
        ),
      );
    }
    for (final (i, caster) in still.indexed) {
      (setup.group && i.isOdd ? moversWorld : world).add(caster);
    }
    moversWorld.addAll(movers);
  }
}

/// What a script does before frame `frame` of [_Scene].
typedef _Step = void Function(_Scene scene, int frame);

/// The pixels and statistics of each frame of a script.
class _Run(final List<Pixels> frames, final List<RenderStats> stats);

Future<_Run> _run(
  WidgetTester tester, {
  required bool keep,
  required int frames,
  required _Step step,
  required _Setup setup,
}) async {
  final scene = _Scene(setup, keep: keep)..build();
  final game = scene.game = FlameGame(
    world: World(
      children: [
        RectangleComponent(
          size: Vector2(_width, _height),
          paint: Paint()..color = const Color(0xFF203040),
        ),
        scene.layer,
        if (setup.group) scene.second,
      ],
    ),
  );
  game.camera.viewfinder
    ..position = Vector2(_width / 2, _height / 2)
    ..zoom = 1;
  tester.view
    ..physicalSize = const Size(_width, _height)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: GameWidget(game: game),
    ),
  );
  final pixels = <Pixels>[];
  final stats = <RenderStats>[];
  for (var frame = 0; frame < frames; frame++) {
    step(scene, frame);
    await tester.pump(const Duration(milliseconds: 16));
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    pixels.add(
      (await tester.runAsync(() async {
        final image = await boundary.toImage();
        final out = await readImage(image);
        image.dispose();
        return out;
      }))!,
    );
    stats.add(RenderStats()..setFrom(scene.layer.renderStats));
  }
  await tester.pumpWidget(const RepaintBoundary());
  return _Run(pixels, stats);
}

/// Runs [step] with and without keeping the still casters, expects the same
/// pixels in every frame, and returns both runs.
Future<(_Run, _Run)> _compare(
  WidgetTester tester, {
  required int frames,
  required _Step step,
  _Setup setup = const _Setup(),
}) async {
  final kept = await _run(
    tester,
    keep: true,
    frames: frames,
    step: step,
    setup: setup,
  );
  final whole = await _run(
    tester,
    keep: false,
    frames: frames,
    step: step,
    setup: setup,
  );
  for (var frame = 0; frame < frames; frame++) {
    expect(
      differingPixels(kept.frames[frame], whole.frames[frame], tolerance: 0),
      0,
      reason: 'frame $frame: ${kept.stats[frame]}',
    );
  }
  return (kept, whole);
}

/// A box of side `0.5` and height `1.2` whose upper vertices follow joint 1
/// and lower ones joint 0.
Surface _skinnedBox(Material material) {
  final vertices = <Vertex>[];
  final indices = <int>[];
  // Four sides of two triangles each, top and bottom left open: enough to
  // cast.
  const corners = [(-0.25, -0.25), (0.25, -0.25), (0.25, 0.25), (-0.25, 0.25)];
  for (var side = 0; side < 4; side++) {
    final (x0, y0) = corners[side];
    final (x1, y1) = corners[(side + 1) % 4];
    final base = vertices.length;
    for (final (x, y, z) in [
      (x0, y0, 0.0),
      (x1, y1, 0.0),
      (x1, y1, 1.2),
      (x0, y0, 1.2),
    ]) {
      vertices.add(
        Vertex(
          position: Vector3(x, y, z),
          texCoord: Vector2.zero(),
          joints: Vector4(z > 0.6 ? 1 : 0, 0, 0, 0),
          weights: Vector4(1, 0, 0, 0),
        ),
      );
    }
    indices.addAll([base, base + 1, base + 2, base + 2, base + 3, base]);
  }
  return Surface(vertices: vertices, indices: indices, material: material);
}

void main() {
  setUpGpu();

  group('ShadowSettings.cacheStillCasters', () {
    /// A mover in every frame; a still caster that rises in frames 6 to 9;
    /// a caster added, one removed, one hidden and shown again, one that
    /// stops casting; then the sun turns and the map is resized.
    void script(_Scene scene, int frame) {
      scene.movers[0].position.x = -3 + frame * 0.2;
      if (frame >= 6 && frame < 10) {
        scene.still[7].position.z += 0.05;
      }
      switch (frame) {
        case 13:
          scene.world.add(
            MeshComponent(
              mesh: CuboidMesh(
                size: Vector3.all(0.8),
                material: StylizedMaterial(
                  albedoColor: const Color(0xFF8060C0),
                ),
              ),
              position: Vector3(1, 1, 0.4),
            ),
          );
        case 15:
          scene.still[3].removeFromParent();
        case 17:
          scene.still[10].visible = false;
        case 19:
          scene.still[10].visible = true;
        case 21:
          scene.still[12].castsShadows = false;
        case 23:
          (scene.sun.source as DirectionalLight).direction = Vector3(
            0.3,
            -0.45,
            -1,
          );
        case 26:
          scene.settings.resolution = 384;
      }
    }

    for (final (lights, encoding) in [
      (_Lights.sun, ShadowMapEncoding.auto),
      (_Lights.sun, ShadowMapEncoding.rgba8),
      (_Lights.spot, ShadowMapEncoding.auto),
      (_Lights.cascadesAndSpot, ShadowMapEncoding.auto),
      (_Lights.cascadesAndSpot, ShadowMapEncoding.rgba8),
      (_Lights.sunAndPoint, ShadowMapEncoding.auto),
    ]) {
      testGpu('${lights.name}, ${encoding.name}: the same pixels as rendering '
          'every caster, through moves, additions, removals, light and map '
          'changes', (tester) async {
        const frames = 30;
        final (kept, whole) = await _compare(
          tester,
          frames: frames,
          step: script,
          setup: _Setup(lights: lights, encoding: encoding),
        );
        final views = switch (lights) {
          _Lights.sun || _Lights.spot => 1,
          _Lights.cascadesAndSpot => 3,
          _Lights.sunAndPoint => 3,
        };
        final k = kept.stats;
        // Frame 0 renders every caster (the views are new), frame 1 renders
        // the layers (every caster is new, so they hold nothing), and the
        // casters that stood still since join them in frame 4.
        expect(k[0].shadowLayersRendered, 0);
        expect(k[1].shadowLayersRendered, views);
        expect(k[4].shadowLayersRendered, views);
        // Then one mover over the layers: a copy and a draw per view.
        expect(k[5].shadowLayersReused, views);
        expect(k[5].shadowLayersRendered, 0);
        expect(k[5].shadowDrawCalls, lessThanOrEqualTo(2 * views));
        expect(k[5].shadowReusedDrawCalls, greaterThan(15 * views));
        expect(
          k[5].shadowTriangles,
          lessThan(whole.stats[5].shadowTriangles ~/ 10),
        );
        // A still caster starts moving: the layers are rendered again
        // without it; it is drawn over them while it moves.
        expect(k[6].shadowLayersRendered, views);
        expect(k[8].shadowLayersRendered, 0);
        expect(k[8].shadowDrawCalls, lessThanOrEqualTo(3 * views));
        // Hidden, a still caster leaves the layers; shown again, it is
        // drawn over them.
        expect(k[17].shadowLayersRendered, views);
        expect(k[19].shadowLayersRendered, 0);
        // The sun turns: its views are rendered whole, then their layers
        // once they hold still.
        if (lights != _Lights.spot) {
          expect(k[23].shadowLayersReused, lessThan(views));
          expect(k[24].shadowLayersRendered, greaterThan(0));
        }
        // Over the script, far fewer triangles than rendering every caster.
        var keptTriangles = 0;
        var wholeTriangles = 0;
        for (var frame = 0; frame < frames; frame++) {
          keptTriangles += k[frame].shadowTriangles;
          wholeTriangles += whole.stats[frame].shadowTriangles;
        }
        expect(keptTriangles, lessThan(wholeTriangles * 0.7));
      }, timeout: const Timeout(Duration(minutes: 3)));
    }

    testGpu('the map is reused whole while nothing changes', (tester) async {
      final (kept, _) = await _compare(
        tester,
        frames: 10,
        step: (scene, frame) {
          if (frame < 6) {
            scene.movers[0].position.x = -3 + frame * 0.2;
          }
        },
      );
      for (final frame in [7, 8, 9]) {
        final stats = kept.stats[frame];
        expect(stats.shadowPasses, 0, reason: 'frame $frame');
        expect(stats.shadowDrawCalls, 0, reason: 'frame $frame');
        expect(stats.shadowLayersReused, 1, reason: 'frame $frame');
        expect(stats.shadowReusedDrawCalls, greaterThan(25));
      }
    }, timeout: const Timeout(Duration(minutes: 3)));

    testGpu('skinned casters and instanced groups move and stop', (
      tester,
    ) async {
      late List<Matrix4> joints;
      late MeshComponent skinned;
      late InstancedGroup3D group;
      final transform = Matrix4.identity();
      final (kept, _) = await _compare(
        tester,
        frames: 16,
        step: (scene, frame) {
          if (frame == 0) {
            joints = [Matrix4.identity(), Matrix4.identity()];
            skinned = MeshComponent(
              mesh: Mesh()
                ..addSurface(
                  _skinnedBox(
                    StylizedMaterial(albedoColor: const Color(0xFF30C0C0)),
                  ),
                ),
              position: Vector3(2.2, -2.8, 0),
              jointTransforms: {0: joints},
            );
            group = InstancedGroup3D(
              mesh: SphereMesh(
                radius: 0.3,
                segments: 12,
                material: StylizedMaterial(
                  albedoColor: const Color(0xFFC030C0),
                ),
              ),
            );
            for (var i = 0; i < 6; i++) {
              group.addInstance(
                transform: Matrix4.translationValues(-4.8 + i, 3.4, 0.3),
              );
            }
            scene.world.addAll([skinned, group]);
          }
          if (frame >= 6 && frame < 10) {
            // The top of the box leans, written in place and reported.
            joints[1].setTranslationRaw(0.12 * (frame - 5), 0, 0);
            skinned.markDrawDirty();
            transform.setTranslationRaw(-4.8, 3.4, 0.3 + 0.15 * (frame - 5));
            group.setInstance(0, transform: transform);
          }
        },
      );
      // The skinned box and the group join the layers, leave them while they
      // move, and join them again.
      expect(kept.stats[5].shadowLayersReused, 1);
      expect(kept.stats[6].shadowLayersRendered, 1);
      expect(kept.stats[8].shadowLayersReused, 1);
      expect(kept.stats[8].shadowDrawCalls, 3);
      expect(kept.stats[15].shadowLayersReused, 1);
      expect(kept.stats[15].shadowDrawCalls, 0);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testGpu('ShadowCasterMotion: moving for changes the engine cannot see, '
        'still for casters kept whatever they do', (tester) async {
      late MeshComponent wave;
      late Float32List rest;
      final (kept, whole) = await _compare(
        tester,
        frames: 12,
        step: (scene, frame) {
          if (frame == 0) {
            wave = MeshComponent(
              mesh: CuboidMesh(
                size: Vector3(0.4, 0.4, 1.6),
                material: StylizedMaterial(
                  albedoColor: const Color(0xFFE0E0E0),
                ),
              ),
              position: Vector3(1, -2.8, 0.8),
            )..shadowMotion = ShadowCasterMotion.moving;
            rest = Float32List.fromList(
              wave.mesh.surfaces.first.vertexData,
            );
            scene.still[18].shadowMotion = ShadowCasterMotion.still;
            scene.world.add(wave);
          }
          // Vertices written in place in every frame, never reported.
          final surface = wave.mesh.surfaces.first;
          final data = surface.vertexData;
          final stride = surface.layout.strideInFloats;
          for (var v = 0; v < data.length ~/ stride; v++) {
            final z = rest[v * stride + 2];
            data[v * stride] =
                rest[v * stride] + (z > 0 ? 0.08 * (frame % 5) : 0);
          }
          surface.updateVertices(data);
          if (frame == 8) {
            scene.still[18].position.y += 0.4;
          }
        },
      );
      // The waving caster keeps the map from being reused whole, and is
      // drawn over the layer in every frame.
      for (final frame in [5, 6, 7, 9, 10, 11]) {
        expect(kept.stats[frame].shadowPasses, greaterThan(0));
        expect(
          kept.stats[frame].shadowDrawCalls,
          lessThan(whole.stats[frame].shadowDrawCalls ~/ 4),
        );
      }
      // The caster kept whatever it does has the layer rendered again when
      // it moves.
      expect(kept.stats[8].shadowLayersRendered, 1);
      expect(kept.stats[9].shadowLayersRendered, 0);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testGpu('a shadow group keeps the still casters of every world', (
      tester,
    ) async {
      final (kept, whole) = await _compare(
        tester,
        frames: 12,
        setup: const _Setup(group: true),
        step: (scene, frame) {
          scene.movers[0].position.x = -3 + frame * 0.2;
          if (frame == 8) {
            // A still caster of the second world starts moving.
            scene.still[5].position.y += 0.5;
          }
        },
      );
      expect(kept.stats[6].shadowLayersReused, 1);
      expect(kept.stats[6].shadowDrawCalls, 2);
      expect(kept.stats[8].shadowLayersRendered, 1);
      expect(kept.stats[9].shadowDrawCalls, 3);
      expect(whole.stats[9].shadowDrawCalls, greaterThan(25));
    }, timeout: const Timeout(Duration(minutes: 3)));

    testGpu('a map that follows a panning camera is rendered whole, without '
        'rendering its layer, until the camera stops', (tester) async {
      final (kept, whole) = await _compare(
        tester,
        frames: 14,
        setup: const _Setup(fit: ShadowFit.view),
        step: (scene, frame) {
          scene.movers[0].position.x = -3 + frame * 0.2;
          if (frame >= 6 && frame < 10) {
            scene.game.camera.viewfinder.position.x += 7;
          }
        },
      );
      for (var frame = 6; frame < 10; frame++) {
        final stats = kept.stats[frame];
        expect(stats.shadowPasses, 1, reason: 'frame $frame');
        expect(stats.shadowLayersRendered, 0, reason: 'frame $frame');
        expect(
          stats.shadowDrawCalls,
          whole.stats[frame].shadowDrawCalls,
          reason: 'frame $frame',
        );
      }
      expect(kept.stats[10].shadowLayersRendered, 1);
      expect(kept.stats[12].shadowLayersReused, 1);
      expect(kept.stats[12].shadowDrawCalls, 2);
    }, timeout: const Timeout(Duration(minutes: 3)));

    testGpu('with ShadowSettings.bounds, a caster that rises above the others '
        'keeps the map and its layer', (tester) async {
      final (kept, whole) = await _compare(
        tester,
        frames: 14,
        setup: _Setup(
          bounds: Aabb3.minMax(Vector3(-6, -6, 0), Vector3(6, 6, 0)),
        ),
        step: (scene, frame) {
          if (frame >= 5) {
            // A podium rises well above the tallest caster.
            scene.movers[1].position.z = 0.6 + (frame - 4) * 0.25;
          }
        },
      );
      for (var frame = 6; frame < 14; frame++) {
        expect(kept.stats[frame].shadowLayersReused, 1, reason: '$frame');
        expect(
          kept.stats[frame].shadowDrawCalls,
          lessThan(whole.stats[frame].shadowDrawCalls ~/ 5),
          reason: '$frame',
        );
      }
    }, timeout: const Timeout(Duration(minutes: 3)));
  });
}
