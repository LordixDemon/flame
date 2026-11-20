import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart' show RectangleComponent, World;
import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey, RepaintBoundary;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// World3D.lightGrid: the point and spot lights of a pass beyond the 8 and 4
// of its blocks go into a grid of cells that every lit material reads.
//
// These tests render a board seen from above (z up) with each lit material:
// StylizedMaterial, SpatialMaterial (its full and its simpler shader),
// WaterMaterial and BillboardMaterial3D. Within the limits, every pixel is
// the one of the shaders of before the grid
// (test/gpu/shaders/reference/light_grid_*), with or without settings; the
// grid's lights are shaded as the blocks shade them; beyond the limits every
// light lights its pool, and the pixels no grid light reaches, the shadows
// and the draws do not change; and the lighting does not move with the
// camera, even where cells are full.

const _width = 200.0;
const _height = 150.0;

/// The lit materials: the built-in ones, and a custom shader that reads the
/// lights through `flame_3d/lights.glsl` and `flame_3d/light_grid.glsl`.
enum _Kind() {
  stylized,
  // StylizedMaterial with a base color texture, drawn with its textured
  // stages; its reference is itself without a grid.
  stylizedTextured,
  spatial,
  spatialSimple,
  water,
  billboard,
  custom,
}

/// A custom material reading the lights of the blocks and of the light grid
/// (test/gpu/shaders/light_grid_custom.frag).
class _CustomLitMaterial() extends Material {
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          'test/light_grid_custom.shaderbundle',
          slots: [RenderContext3D.cameraMatricesBlock],
        ),
        fragmentShader: FragmentShader.fromAsset(
          'test/light_grid_custom.shaderbundle',
          slots: [
            RenderContext3D.ambientLightBlock,
            RenderContext3D.lightsBlock,
            RenderContext3D.spotLightsBlock,
            RenderContext3D.lightGridBlock,
            RenderContext3D.lightGridSampler,
          ],
        ),
      );
}

/// A light of a scene, made into a fresh component for each render.
class _LightSpec(
  final Vector3 position, {
  final bool spot = false,
  final Color color = const Color(0xFFFFB060),
  final double intensity = 1.6,
  final double? range = 1.2,
  final ShadowSettings? shadows,
  final Vector3? direction,
}) {
  LightComponent build() => spot
      ? LightComponent.spot(
          position: position,
          direction: direction ?? Vector3(0.2, 0, -1),
          color: color,
          intensity: intensity,
          range: range,
          innerConeAngle: 0.35,
          outerConeAngle: 0.6,
          shadows: shadows,
        )
      : LightComponent.point(
          position: position,
          color: color,
          intensity: intensity,
          range: range,
          shadows: shadows,
        );
}

const _palette = [
  Color(0xFFFFB060),
  Color(0xFF80C0FF),
  Color(0xFFFF7090),
  Color(0xFFA0FF90),
  Color(0xFFFFF0C0),
];

/// [count] small lights in rows over the board, x from 0 to 5 and y from 0
/// to 4, every [spotEvery]-th one a spot light (none for 0).
List<_LightSpec> _lanterns(int count, {int spotEvery = 0, double z = 0.6}) {
  final columns = math.sqrt(count * 1.25).ceil();
  final rows = (count / columns).ceil();
  return [
    for (var i = 0; i < count; i++)
      _LightSpec(
        Vector3(
          (i % columns + 0.5) * 5 / columns,
          (i ~/ columns + 0.5) * 4 / rows,
          z,
        ),
        spot: spotEvery > 0 && i % spotEvery == spotEvery - 1,
        color: _palette[i % _palette.length],
        range: 0.9,
        intensity: spotEvery > 0 && i % spotEvery == spotEvery - 1 ? 3 : 1.4,
      ),
  ];
}

/// The lights of a scene within the limits: an ambient light, a sun casting
/// shadows, 3 point lights with a range and one without, a spot light with
/// a range and one casting shadows.
List<_LightSpec> get _withinLimits => [
  _LightSpec(Vector3(1, 1, 0.7)),
  _LightSpec(Vector3(3.8, 1.2, 0.6), color: const Color(0xFF80C0FF)),
  _LightSpec(Vector3(2.5, 3, 0.5), color: const Color(0xFFFF7090), range: 2),
  _LightSpec(Vector3(4, 3.4, 1.5), intensity: 0.8, range: null),
  _LightSpec(Vector3(1.2, 3, 1.4), spot: true, intensity: 3, range: 2.5),
  _LightSpec(
    Vector3(3.5, 2, 2.2),
    spot: true,
    intensity: 2,
    range: 4,
    shadows: ShadowSettings(color: const Color(0xFF203050), strength: 0.6),
  ),
];

/// The slots of the fragment shaders of before the light grid.
List<String> _referenceSlots(_Kind kind) => switch (kind) {
  _Kind.stylized => [
    'matCapTexture',
    'gemMatCapTexture',
    'Material',
    RenderContext3D.stylizedPassBlock,
    RenderContext3D.shadowMapSampler,
  ],
  _Kind.spatial => [
    'albedoTexture',
    'normalTexture',
    'metallicRoughnessTexture',
    'occlusionTexture',
    'emissiveTexture',
    'environmentTexture',
    'lightmapTexture',
    RenderContext3D.brdfLutSampler,
    RenderContext3D.probeGridSampler,
    RenderContext3D.sceneColorSampler,
    RenderContext3D.shadowMapSampler,
    'Material',
    RenderContext3D.passOptionsBlock,
    ..._lightAndSceneBlocks,
  ],
  _Kind.spatialSimple => [
    'albedoTexture',
    'normalTexture',
    'metallicRoughnessTexture',
    'occlusionTexture',
    'emissiveTexture',
    'environmentTexture',
    RenderContext3D.shadowMapSampler,
    'Material',
    ..._lightAndSceneBlocks,
  ],
  _Kind.water => [
    'WaterMaterial',
    RenderContext3D.stylizedPassBlock,
    RenderContext3D.shadowMapSampler,
    RenderContext3D.depthNormalSampler,
    RenderContext3D.depthNormalBlock,
    RenderContext3D.sceneColorSampler,
    RenderContext3D.sceneColorBlock,
  ],
  _Kind.custom || _Kind.stylizedTextured => const [],
  _Kind.billboard => [
    'albedoTexture',
    'BillboardLook',
    RenderContext3D.ambientLightBlock,
    RenderContext3D.lightsBlock,
    RenderContext3D.directionalLightsBlock,
    RenderContext3D.spotLightsBlock,
    RenderContext3D.hemisphereLightBlock,
    RenderContext3D.cameraBlock,
    RenderContext3D.fogBlock,
  ],
};

const _lightAndSceneBlocks = [
  RenderContext3D.ambientLightBlock,
  RenderContext3D.lightsBlock,
  RenderContext3D.directionalLightsBlock,
  RenderContext3D.spotLightsBlock,
  RenderContext3D.hemisphereLightBlock,
  RenderContext3D.cameraBlock,
  RenderContext3D.shadowsBlock,
  RenderContext3D.fogBlock,
];

const _simpleBundle =
    'packages/flame_3d/assets/shaders/spatial_material.shaderbundle';

/// The material of [kind]; with [reference], drawing with the shaders of
/// before the light grid.
Material _material(_Kind kind, {required bool reference}) {
  String test(String name) => 'test/light_grid_${name}_reference.shaderbundle';
  switch (kind) {
    case _Kind.stylized:
      final material = StylizedMaterial(albedoColor: const Color(0xFFD8D0C0));
      if (reference) {
        material.fragmentShader = FragmentShader.fromAsset(
          test('stylized'),
          slots: _referenceSlots(kind),
        );
      }
      return material;
    case _Kind.spatial:
      final material = SpatialMaterial(
        albedoColor: const Color(0xFFD8D0C0),
        roughness: 0.55,
      );
      if (reference) {
        material.fragmentShader = FragmentShader.fromAsset(
          test('spatial'),
          slots: _referenceSlots(kind),
        );
      }
      return material;
    case _Kind.spatialSimple:
      final material = _SimpleSpatialMaterial(
        albedoColor: const Color(0xFFD8D0C0),
        roughness: 0.55,
      );
      final bundle = reference ? test('spatial_simple') : _simpleBundle;
      material
        ..vertexShader = VertexShader.fromAsset(
          bundle,
          slots: [
            RenderContext3D.cameraMatricesBlock,
            RenderContext3D.jointMatricesBlock,
          ],
        )
        ..fragmentShader = FragmentShader.fromAsset(
          bundle,
          slots: [
            ..._referenceSlots(kind),
            if (!reference) ...[
              RenderContext3D.lightGridBlock,
              RenderContext3D.lightGridSampler,
            ],
          ],
        );
      return material;
    case _Kind.water:
      final material = WaterMaterial(
        opacity: 1,
        waveAmplitude: 0.02,
        upAxis: Vector3(0, 0, 1),
        shallowColor: const Color(0xFF406878),
        deepColor: const Color(0xFF203848),
      );
      if (reference) {
        material.fragmentShader = FragmentShader.fromAsset(
          test('water'),
          slots: _referenceSlots(kind),
        );
      }
      return material;
    case _Kind.custom:
      return _CustomLitMaterial();
    case _Kind.stylizedTextured:
      return StylizedMaterial(
        albedoColor: const Color(0xFFD8D0C0),
        baseColorTexture: Texture(
          ByteData.sublistView(
            Uint8List.fromList([
              ...[255, 240, 220, 255],
              ...[220, 230, 255, 255],
              ...[230, 255, 220, 255],
              ...[255, 255, 255, 255],
            ]),
          ),
          width: 2,
          height: 2,
        ),
      );
    case _Kind.billboard:
      final material = BillboardMaterial3D(
        albedoColor: const Color(0xFFD8D0C0),
        shadeWeight: 1,
      );
      if (reference) {
        material
          ..vertexShader = VertexShader.fromAsset(
            test('billboard'),
            slots: [RenderContext3D.cameraMatricesBlock, 'BillboardFrame'],
          )
          ..fragmentShader = FragmentShader.fromAsset(
            test('billboard'),
            slots: _referenceSlots(kind),
          );
      }
      return material;
  }
}

/// A SpatialMaterial that draws with the simpler shader (as on devices that
/// cannot run the full one) or a copy of it.
class _SimpleSpatialMaterial({super.albedoColor, super.roughness})
    extends SpatialMaterial {
  @override
  bool get usesSimpleShader => true;
}

/// A box of [size] centered at its origin.
Mesh _box(Material material, Vector3 size) =>
    CuboidMesh(size: size, material: material);

/// The objects of the board of [kind].
List<Component3D> _board(_Kind kind, Material material) {
  switch (kind) {
    case _Kind.stylized ||
        _Kind.stylizedTextured ||
        _Kind.spatial ||
        _Kind.spatialSimple ||
        _Kind.custom:
      return [
        MeshComponent(
          mesh: _box(material, Vector3(6, 5, 0.1)),
          position: Vector3(2.5, 2, -0.05),
        ),
        for (final (x, y) in const [(1.5, 1.6), (3.2, 2.4), (2.0, 3.3)])
          MeshComponent(
            mesh: _box(material, Vector3(0.4, 0.4, 0.5)),
            position: Vector3(x, y, 0.25),
            rotation: Quaternion.axisAngle(Vector3(0, 0, 1), x * 0.4),
          ),
      ];
    case _Kind.water:
      return [
        MeshComponent(
          mesh: TerrainMesh3D(
            columns: 40,
            rows: 32,
            width: 6,
            depth: 5,
            heights: Float32List(40 * 32),
            upAxis: TerrainUpAxis.z,
            material: material,
          ),
          position: Vector3(2.5, 2, 0),
        ),
      ];
    case _Kind.billboard:
      final batch = BillboardBatch3D(material: material as BillboardMaterial3D);
      for (var y = 0; y < 10; y++) {
        for (var x = 0; x < 12; x++) {
          batch.addBillboard(
            position: Vector3(-0.25 + x * 0.5, -0.25 + y * 0.5, 0.01),
            width: 0.5,
            height: 0.5,
            orientation: BillboardOrientation3D.fixed,
            upAxis: Vector3(0, 1, 0),
            rightAxis: Vector3(1, 0, 0),
            anchorY: 0,
          );
        }
      }
      return [batch];
  }
}

/// A rendered frame and the draws of its layer.
typedef _Frame = ({Pixels pixels, int draws, LightGridStats stats});

/// Renders the board of [kind] lit by an ambient light, a sun casting
/// shadows (unless [sun] is false) and [lights], with [grid] (or none).
///
/// [pan] moves the camera by whole pixels; with [reference], the material
/// draws with the shaders of before the light grid.
Future<_Frame> _render(
  WidgetTester tester, {
  required _Kind kind,
  required List<_LightSpec> lights,
  LightGridSettings? grid,
  bool reference = false,
  bool sun = true,
  (double, double) pan = (0, 0),
}) async {
  final material = _material(kind, reference: reference);
  final layer = Scene3DComponent(
    projection: Scene3DProjection.affine(
      origin: Vector2(-60 + pan.$1, 30 + pan.$2),
      xAxis: Vector2(36, 9),
      yAxis: Vector2(-14, -26),
      zAxis: Vector2(0, -30),
      towardsViewer: Vector3(0.3, -0.5, 0.8),
      near: -100,
      far: 100,
    ),
    priority: 1,
  );
  layer.world
    ..lightGrid = grid
    ..addAll([
      LightComponent.ambient(color: const Color(0xFFB0B8D0), intensity: 0.25),
      if (sun)
        LightComponent.directional(
          direction: Vector3(0.5, -0.3, -0.8),
          color: const Color(0xFFFFE0C0),
          intensity: 0.35,
          shadows: ShadowSettings(
            color: const Color(0xFF203050),
            strength: 0.7,
          ),
        ),
      for (final light in lights) light.build(),
      ..._board(kind, material),
    ]);
  final game = FlameGame(
    world: World(
      children: [
        RectangleComponent(
          position: Vector2.all(-5000),
          size: Vector2.all(10000),
          paint: Paint()..color = const Color(0xFF808080),
        ),
        layer,
      ],
    ),
  );
  game.camera.viewfinder.position = Vector2(0, 0);

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
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final pixels = (await tester.runAsync(() async {
    final image = await boundary.toImage();
    final pixels = await readImage(image);
    image.dispose();
    return pixels;
  }))!;
  final s = layer.context.lightGridStats;
  final stats = LightGridStats()
    ..active = s.active
    ..pointLights = s.pointLights
    ..spotLights = s.spotLights
    ..entries = s.entries
    ..droppedEntries = s.droppedEntries
    ..cellsX = s.cellsX
    ..cellsY = s.cellsY
    ..cellsZ = s.cellsZ;
  return (
    pixels: pixels,
    draws: layer.renderStats.drawCalls,
    stats: stats,
  );
}

/// Writes [pixels] as raw RGBA into the directory of the environment
/// variable LIGHT_GRID_DUMP, when set, to look at.
void _dump(String name, Pixels pixels) {
  final dir = Platform.environment['LIGHT_GRID_DUMP'];
  if (dir != null) {
    File(
      '$dir/$name.${pixels.width}x${pixels.height}.rgba',
    ).writeAsBytesSync(pixels.rgba);
  }
}

/// The largest difference of a channel between [a] and [b].
int _maxDifference(Pixels a, Pixels b) {
  var most = 0;
  for (var i = 0; i < a.rgba.length; i++) {
    most = math.max(most, (a.rgba[i] - b.rgba[i]).abs());
  }
  return most;
}

/// The number of pixels at least [by] brighter (summed over the color
/// channels) in [a] than in [b].
int _brighter(Pixels a, Pixels b, {int by = 12}) {
  var count = 0;
  for (var i = 0; i < a.rgba.length; i += 4) {
    final da =
        a.rgba[i] +
        a.rgba[i + 1] +
        a.rgba[i + 2] -
        b.rgba[i] -
        b.rgba[i + 1] -
        b.rgba[i + 2];
    if (da >= by) {
      count++;
    }
  }
  return count;
}

void main() {
  setUpGpu();

  setUpAll(() async {
    if (gpuAvailable) {
      await registerTestShaders([
        'light_grid_stylized_reference',
        'light_grid_spatial_reference',
        'light_grid_spatial_simple_reference',
        'light_grid_water_reference',
        'light_grid_billboard_reference',
        'light_grid_custom',
      ]);
    }
  });

  group('World3D.lightGrid', () {
    for (final kind in _Kind.values) {
      if (kind != _Kind.custom) {
        testGpu('${kind.name}: within the limits, the pixels of before, with '
            'or without a grid', (tester) async {
          final reference = await _render(
            tester,
            kind: kind,
            lights: _withinLimits,
            reference: true,
          );
          final without = await _render(
            tester,
            kind: kind,
            lights: _withinLimits,
          );
          final withGrid = await _render(
            tester,
            kind: kind,
            lights: _withinLimits,
            grid: const LightGridSettings(),
          );
          // The board is drawn and lit.
          expect(
            reference.pixels.count((r, g, b, a) => r != g || g != b),
            greaterThan(_width * _height / 3),
          );
          expect(
            differingPixels(without.pixels, reference.pixels, tolerance: 0),
            0,
          );
          expect(
            differingPixels(withGrid.pixels, reference.pixels, tolerance: 0),
            0,
          );
          _dump('${kind.name}_within', withGrid.pixels);
          expect(withGrid.stats.active, isFalse);
          expect(withGrid.draws, reference.draws);
        });
      }

      testGpu('${kind.name}: the grid shades its lights as the blocks do', (
        tester,
      ) async {
        // 8 point and 4 spot lights: in the blocks without a grid, all in the
        // grid with beyondLimitsOnly false.
        final lights = _lanterns(12, spotEvery: 3);
        final blocks = await _render(tester, kind: kind, lights: lights);
        final grid = await _render(
          tester,
          kind: kind,
          lights: lights,
          grid: const LightGridSettings(beyondLimitsOnly: false),
        );
        expect(grid.stats.active, isTrue);
        expect(grid.stats.pointLights, 8);
        expect(grid.stats.spotLights, 4);
        expect(
          _maxDifference(grid.pixels, blocks.pixels),
          lessThanOrEqualTo(1),
        );
        expect(grid.draws, blocks.draws);
      });

      testGpu('${kind.name}: beyond the limits, every light lights its pool', (
        tester,
      ) async {
        final lights = _lanterns(40, spotEvery: 5);
        final without = await _render(tester, kind: kind, lights: lights);
        final withGrid = await _render(
          tester,
          kind: kind,
          lights: lights,
          grid: const LightGridSettings(),
        );
        _dump('${kind.name}_beyond_without', without.pixels);
        _dump('${kind.name}_beyond_with', withGrid.pixels);
        expect(withGrid.stats.pointLights, 32);
        expect(withGrid.stats.spotLights, 8);
        // Without a grid, 8 point and 4 spot lights light the board; with
        // it, the 28 others light their pools too.
        expect(
          _brighter(withGrid.pixels, without.pixels),
          greaterThan(_width * _height / 8),
        );
        // It never takes light away.
        expect(_brighter(without.pixels, withGrid.pixels, by: 3), 0);
        expect(withGrid.draws, without.draws);
      });
    }

    testGpu('the pixels no grid light reaches, and the shadows, do not '
        'change', (tester) async {
      // Lanterns over the left part of the board only, a spot light casting
      // shadows over the right part.
      List<_LightSpec> lights({required bool shadows}) => [
        for (final light in _lanterns(30))
          if (light.position.x < 2) light,
        // Left of the box at (3.2, 2.4), shining to the right of it.
        _LightSpec(
          Vector3(2.5, 2.4, 1.1),
          spot: true,
          intensity: 3,
          range: 5,
          direction: Vector3(1, 0, -0.7),
          shadows: shadows
              ? ShadowSettings(color: const Color(0xFF102040))
              : null,
        ),
      ];
      expect(lights(shadows: true).length, greaterThan(9));
      final without = await _render(
        tester,
        kind: _Kind.stylized,
        lights: lights(shadows: true),
      );
      final withGrid = await _render(
        tester,
        kind: _Kind.stylized,
        lights: lights(shadows: true),
        grid: const LightGridSettings(),
      );
      final unshadowed = await _render(
        tester,
        kind: _Kind.stylized,
        lights: lights(shadows: false),
        grid: const LightGridSettings(),
      );
      _dump('shadow_without', without.pixels);
      _dump('shadow_with', withGrid.pixels);
      _dump('shadow_unshadowed', unshadowed.pixels);
      expect(withGrid.stats.active, isTrue);
      // The right part of the picture (from x = 3 on the board on) is the
      // same, shadows and all.
      var same = 0;
      var compared = 0;
      for (var y = 0; y < _height; y++) {
        for (var x = 150; x < _width; x++) {
          compared++;
          if (without.pixels.at(x, y) == withGrid.pixels.at(x, y)) {
            same++;
          }
        }
      }
      expect(same, compared);
      // The spot light casts its shadows with the grid.
      expect(
        _brighter(unshadowed.pixels, withGrid.pixels, by: 30),
        greaterThan(150),
      );
    });

    testGpu('the lighting stays with the world as the camera moves, even in '
        'full cells', (tester) async {
      final lights = _lanterns(64, spotEvery: 7);
      const grid = LightGridSettings(
        cellSize: 0.5,
        maxPointLightsPerCell: 2,
        maxSpotLightsPerCell: 1,
      );
      // Without the sun, whose shadow map is fitted to the view.
      final a = await _render(
        tester,
        kind: _Kind.stylized,
        lights: lights,
        grid: grid,
        sun: false,
      );
      final b = await _render(
        tester,
        kind: _Kind.stylized,
        lights: lights,
        grid: grid,
        sun: false,
        pan: (17, -11),
      );
      // Cells are full: lights are left out of some.
      expect(a.stats.droppedEntries, greaterThan(0));
      // Where both frames see the board, the pixels are the same.
      var differing = 0;
      var compared = 0;
      for (var y = 20; y < _height - 20; y++) {
        for (var x = 20; x < _width - 30; x++) {
          final pa = a.pixels.at(x, y);
          final pb = b.pixels.at(x + 17, y - 11);
          compared++;
          if ((pa.$1 - pb.$1).abs() > 1 ||
              (pa.$2 - pb.$2).abs() > 1 ||
              (pa.$3 - pb.$3).abs() > 1) {
            differing++;
          }
        }
      }
      expect(compared, greaterThan(10000));
      expect(differing, 0);
    });
  });
}
