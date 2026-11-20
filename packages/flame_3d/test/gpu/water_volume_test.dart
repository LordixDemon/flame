import 'dart:ui';

import 'package:flame/game.dart' show GameWidget;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/widgets.dart' show ObjectKey;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

// World3D.waterVolume: the parts of StylizedMaterial surfaces below its level
// are tinted and darkened with their depth, receive caustics where the sun
// reaches them, and foam in a band where they cross the level, without any
// depth buffer. Without a volume (or with one that changes nothing, or above
// it), every pixel must be the one the fragment shader of before drew
// (test/gpu/shaders/reference/stylized_water_volume_fragment.glsl). The
// stylized layout, skinned or not, the standard layout, instancing and
// palettes are all tinted alike.

const _size = 128;

const _wallColor = Color(0xFF8C7C64);

/// A wall in the plane z = 0, facing +z, from x = -1.5 to 1.5 and y = -2 to
/// 1, in [rows] bands.
Mesh _wall(Material material, {int rows = 12}) {
  final positions = <double>[];
  final normals = <double>[];
  final colors = <double>[];
  final indices = <int>[];
  for (var j = 0; j <= rows; j++) {
    final y = 1 - 3 * j / rows;
    for (final x in [-1.5, 1.5]) {
      positions.addAll([x, y, 0]);
      normals.addAll([0, 0, 1]);
      colors.addAll([_wallColor.r, _wallColor.g, _wallColor.b, 1]);
    }
    if (j < rows) {
      final a = j * 2;
      indices.addAll([a, a + 2, a + 3, a, a + 3, a + 1]);
    }
  }
  return Mesh()..addSurface(
    StylizedMaterial.buildSurface(
      positions: positions,
      normals: normals,
      colors: colors,
      indices: indices,
      material: material,
    ),
  );
}

/// A floor in the plane y = [height], facing +y, from x, z = -1.5 to 1.5.
Mesh _floor(Material material, {double height = -1}) {
  return Mesh()..addSurface(
    StylizedMaterial.buildSurface(
      positions: [
        -1.5, height, 1.5, //
        1.5, height, 1.5,
        1.5, height, -1.5,
        -1.5, height, -1.5,
      ],
      normals: const [0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0],
      colors: [
        for (var i = 0; i < 4; i++) ...[
          _wallColor.r,
          _wallColor.g,
          _wallColor.b,
          1.0,
        ],
      ],
      indices: const [0, 1, 2, 0, 2, 3],
      material: material,
    ),
  );
}

/// Looks at the wall head on: 128 pixels for 3.2 units, y = 1.1 at the top
/// row, so the level y = 0 is at row 44.
final Matrix4 _frontView = Matrix4.identity()
  ..setAsViewMatrix(Vector3(0, -0.5, 5), Vector3(0, -0.5, 0), Vector3(0, 1, 0));
final Matrix4 _frontProjection = Matrix4.identity()
  ..setAsOrthographic(3.2, 1, 0.1, 20);

/// The row of the front view where the height [y] lands.
int _row(double y) => ((1.1 - y) / 3.2 * _size).floor();

/// Looks straight down at the floor: x from -1.5 (left) to 1.5 (right).
final Matrix4 _topView = Matrix4.identity()
  ..setAsViewMatrix(Vector3(0, 5, 0), Vector3.zero(), Vector3(0, 0, -1));
final Matrix4 _topProjection = Matrix4.identity()
  ..setAsOrthographic(3, 1, 0.1, 20);

/// The column of the top view where [x] lands.
int _column(double x) => ((x + 1.5) / 3 * _size).floor();

Future<Frame> _render(
  WidgetTester tester,
  World3D world, {
  Matrix4? view,
  Matrix4? projection,
  Msaa msaa = Msaa.off,
}) async {
  // Mounted, so that the shadows are fitted to its components.
  final game = FlameGame3D(world: world);
  await tester.pumpWidget(GameWidget(key: ObjectKey(game), game: game));
  await tester.pump();
  return (await tester.runAsync(() async {
    final device = GraphicsDevice();
    final context = RenderContext3D(device);
    device.begin();
    final image = world.renderToImage(
      const Size(_size + 0.0, _size + 0.0),
      view: view ?? _frontView,
      projection: projection ?? _frontProjection,
      msaa: msaa,
      clearValue: const Color(0xFF000000),
      device: device,
      context: context,
    );
    device.end();
    final stats = RenderStats()..setFrom(device.lastFrameStats);
    final pixels = await readImage(image);
    image.dispose();
    return Frame(pixels, stats);
  }))!;
}

List<Component3D> _lights({ShadowSettings? shadows, Vector3? sun}) => [
  LightComponent.ambient(intensity: 0.35),
  LightComponent.hemisphere(
    skyColor: const Color(0xFFB0D0FF),
    groundColor: const Color(0xFF605040),
    intensity: 0.4,
  ),
  LightComponent.directional(
    direction: sun ?? Vector3(0.2, -0.4, -1),
    intensity: 0.8,
    shadows: shadows,
  ),
];

/// The squared distance between the colors of two pixels.
int _distance((int, int, int, int) a, (int, int, int, int) b) {
  final dr = a.$1 - b.$1;
  final dg = a.$2 - b.$2;
  final db = a.$3 - b.$3;
  return dr * dr + dg * dg + db * db;
}

/// The number of pixels of the rows [from] to [to] (excluded) of [a] and
/// [b] that differ by more than [tolerance] in a channel.
int _differingRows(Pixels a, Pixels b, int from, int to, {int tolerance = 0}) {
  var count = 0;
  for (var y = from; y < to; y++) {
    for (var x = 0; x < _size; x++) {
      final p = a.at(x, y);
      final q = b.at(x, y);
      if ((p.$1 - q.$1).abs() > tolerance ||
          (p.$2 - q.$2).abs() > tolerance ||
          (p.$3 - q.$3).abs() > tolerance) {
        count++;
      }
    }
  }
  return count;
}

void main() {
  setUpGpu();

  group('World3D.waterVolume', () {
    setUpAll(() async {
      if (gpuAvailable) {
        await registerTestShaders(['stylized_volume_reference']);
      }
    });

    testGpu('changes no pixel when off, inactive or below everything', (
      tester,
    ) async {
      final matCap = Texture.standard;
      StylizedMaterial material({required bool before}) {
        final material = StylizedMaterial(
          accentPalette: const [Color(0xFFE04040), Color(0xFF4060E0)],
          rimPalette: const [Color(0xFFFFE080)],
          matCapTexture: matCap,
          specularStrength: 0.5,
        );
        if (before) {
          material.fragmentShader = FragmentShader.fromAsset(
            'test/stylized_volume_reference.shaderbundle',
            slots: [
              'matCapTexture',
              'gemMatCapTexture',
              'Material',
              RenderContext3D.stylizedPassBlock,
              RenderContext3D.shadowMapSampler,
            ],
          );
        }
        return material;
      }

      World3D scene(StylizedMaterial material, WaterVolumeSettings? volume) {
        return World3D(
          waterVolume: volume,
          fog: FogSettings(start: 3, end: 12),
          children: [
            ..._lights(shadows: ShadowSettings(resolution: 512)),
            LightComponent.point(
              position: Vector3(0.8, 0.5, 1.5),
              color: const Color(0xFFFFB060),
              intensity: 2,
              range: 4,
            ),
            LightComponent.spot(
              position: Vector3(-1, 1, 2),
              direction: Vector3(0.3, -0.4, -1),
              intensity: 3,
            ),
            MeshComponent(mesh: _wall(material)),
            // The standard layout.
            MeshComponent(
              mesh: SphereMesh(radius: 0.35, material: material),
              position: Vector3(-0.6, -0.3, 0.5),
              color: const Color(0xFF60C080),
            ),
            // The stylized layout, with a palette entry and a rim.
            MeshComponent(
              mesh: _floor(material, height: 0),
              scale: Vector3.all(0.2),
              position: Vector3(0.6, -0.5, 0.6),
              rotation: Quaternion.axisAngle(Vector3(1, 0, 0), 0.8),
              instanceData: Vector4(
                0,
                0,
                0,
                StylizedMaterial.packPaletteAndFade(accent: 1, rim: 0),
              ),
            ),
          ],
        );
      }

      final reference = await _render(
        tester,
        scene(material(before: true), null),
      );
      expect(
        reference.pixels.count((r, g, b, a) => r + g + b > 60),
        greaterThan(_size * _size ~/ 2),
      );
      for (final (name, volume) in [
        ('no volume', null),
        ('an inactive volume', WaterVolumeSettings(absorption: 0)),
        (
          'a volume below everything',
          WaterVolumeSettings(
            level: -50,
            causticStrength: 1,
            waterlineWidth: 0.2,
          ),
        ),
      ]) {
        for (final msaa in [Msaa.off, Msaa.sample4]) {
          final now = await _render(
            tester,
            scene(material(before: false), volume),
            msaa: msaa,
          );
          final before = msaa == Msaa.off
              ? reference
              : await _render(
                  tester,
                  scene(material(before: true), null),
                  msaa: msaa,
                );
          expect(
            differingPixels(now.pixels, before.pixels, tolerance: 0),
            0,
            reason: '$name, $msaa',
          );
        }
      }
    });

    testGpu('tints and darkens submerged surfaces more with depth', (
      tester,
    ) async {
      final material = StylizedMaterial(rimStrength: 0, specularStrength: 0);
      final dry = (await _render(
        tester,
        World3D(
          children: [
            ..._lights(),
            MeshComponent(mesh: _wall(material)),
          ],
        ),
      )).pixels;
      final wet = (await _render(
        tester,
        World3D(
          waterVolume: WaterVolumeSettings(
            deepColor: const Color(0xFF103050),
            absorption: 1.2,
          ),
          children: [
            ..._lights(),
            MeshComponent(mesh: _wall(material)),
          ],
        ),
      )).pixels;

      // Above the level, nothing changes.
      expect(_differingRows(wet, dry, 0, _row(0) - 1), 0);
      // Below it, the wall is ever closer to the deep color.
      const deep = (16, 48, 80, 255);
      var previous = 1 << 30;
      for (var y = _row(-0.05); y < _row(-1.9); y += 4) {
        final distance = _distance(wet.at(64, y), deep);
        expect(distance, lessThanOrEqualTo(previous + 3), reason: 'row $y');
        previous = distance;
      }
      final bottom = _row(-1.9);
      expect(
        _distance(wet.at(64, bottom), deep),
        lessThan(_distance(wet.at(64, _row(-0.1)), deep) ~/ 4),
      );
      expect(
        _distance(wet.at(64, bottom), dry.at(64, bottom)),
        greaterThan(3000),
      );
    });

    testGpu('draws a band of foam where a surface crosses the level', (
      tester,
    ) async {
      final material = StylizedMaterial(rimStrength: 0, specularStrength: 0);
      Future<Pixels> render(double width, {double time = 0}) async {
        return (await _render(
          tester,
          World3D(
            waterVolume: WaterVolumeSettings(
              absorption: 0,
              waterlineWidth: width,
              waterlineColor: const Color(0xFFFFFFFF),
              time: time,
            ),
            children: [
              ..._lights(),
              MeshComponent(mesh: _wall(material)),
            ],
          ),
        )).pixels;
      }

      final none = await render(0);
      final band = await render(0.1);
      // Foam on the level's rows: whiter than the wall.
      var whiter = 0;
      for (var y = _row(0.04); y <= _row(-0.04); y++) {
        for (var x = 0; x < _size; x++) {
          final (r, g, b, _) = band.at(x, y);
          final (r0, g0, b0, _) = none.at(x, y);
          if (r + g + b > r0 + g0 + b0 + 40) {
            whiter++;
          }
        }
      }
      final rows = _row(-0.04) - _row(0.04) + 1;
      expect(whiter, greaterThan(rows * _size ~/ 4));
      // Nothing farther than the band (and its lapping) from the level.
      expect(_differingRows(band, none, 0, _row(0.25)), 0);
      expect(_differingRows(band, none, _row(-0.25), _size), 0);
      // The band moves: another moment, other foam.
      final later = await render(0.1, time: 1.7);
      expect(
        _differingRows(band, later, _row(0.1), _row(-0.1)),
        greaterThan(20),
      );
    });

    testGpu('lights the submerged floor with caustics where the sun reaches', (
      tester,
    ) async {
      final material = StylizedMaterial(rimStrength: 0, specularStrength: 0);
      // A bar above the water, from x = -1.4 to -0.9 and y = 0.2 to 1.5,
      // whose shadow covers the floor from about x = -0.7 to 0.6.
      final bar = CuboidMesh(
        size: Vector3(0.5, 1.3, 3),
        material: StylizedMaterial(),
      );
      Future<Pixels> render(double caustics, {double time = 0}) async {
        return (await _render(
          tester,
          World3D(
            waterVolume: WaterVolumeSettings(
              absorption: 0,
              causticStrength: caustics,
              causticScale: 0.8,
              time: time,
            ),
            children: [
              ..._lights(
                sun: Vector3(0.6, -1, 0),
                shadows: ShadowSettings(),
              ),
              MeshComponent(mesh: _floor(material)),
              MeshComponent(mesh: bar, position: Vector3(-1.15, 0.85, 0)),
            ],
          ),
          view: _topView,
          projection: _topProjection,
        )).pixels;
      }

      final plain = await render(0);
      final lit = await render(1);
      var brighter = 0;
      var region = 0;
      for (var y = 8; y < _size - 8; y++) {
        for (var x = _column(0.85); x < _column(1.4); x++) {
          region++;
          final (r, g, b, _) = lit.at(x, y);
          final (r0, g0, b0, _) = plain.at(x, y);
          if (r + g + b > r0 + g0 + b0 + 30) {
            brighter++;
          }
        }
      }
      expect(brighter, greaterThan(region ~/ 20));
      expect(brighter, lessThan(region * 3 ~/ 4));
      // In the bar's shadow, no caustics.
      for (var y = 8; y < _size - 8; y++) {
        for (var x = _column(-0.45); x < _column(0.35); x++) {
          expect(lit.at(x, y), plain.at(x, y), reason: '$x, $y');
        }
      }
      // They move, and loop over their period (8 s by default).
      final moved = await render(1, time: 3);
      final looped = await render(1, time: 8);
      expect(differingPixels(lit, moved), greaterThan(100));
      expect(differingPixels(lit, looped, tolerance: 1), 0);
    });

    testGpu('tints skinned, instanced and palette draws as the others', (
      tester,
    ) async {
      final volume = WaterVolumeSettings(
        level: -0.4,
        absorption: 1,
        causticStrength: 0.8,
        causticScale: 0.4,
        waterlineWidth: 0.08,
        time: 0.7,
      );
      List<double> wallPositions() => [
        -0.5, 0.6, 0, 0.5, 0.6, 0, 0.5, -1.4, 0, -0.5, -1.4, 0, //
      ];
      const normals = <double>[0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1];
      const indices = [0, 3, 2, 0, 2, 1];
      Surface plain(Material m) => StylizedMaterial.buildSurface(
        positions: wallPositions(),
        normals: normals,
        accent: const [1, 1, 1, 1],
        indices: indices,
        material: m,
      );
      Surface skinned(Material m) => StylizedMaterial.buildSurface(
        positions: wallPositions(),
        normals: normals,
        accent: const [1, 1, 1, 1],
        joints: List.filled(16, 0.0),
        weights: [
          for (var i = 0; i < 4; i++) ...[1.0, 0, 0, 0],
        ],
        indices: indices,
        material: m,
      );

      Future<Pixels> render(
        List<Component3D> Function() objects, {
        WaterVolumeSettings? water,
      }) async {
        return (await _render(
          tester,
          World3D(
            waterVolume: water ?? volume,
            children: [..._lights(), ...objects()],
          ),
        )).pixels;
      }

      const accent = Color(0xFF3070E0);
      final palette = StylizedMaterial(
        accentPalette: const [Color(0xFFE03030), accent],
      );
      final single = StylizedMaterial(accentColor: accent);
      final positions = [Vector3(-0.9, 0, 0), Vector3(0.9, 0, 0)];

      // Two instances of one mesh, in one draw, with a palette entry...
      final paletteMesh = Mesh()..addSurface(plain(palette));
      final instanced = await render(
        () => [
          for (final p in positions)
            MeshComponent(
              mesh: paletteMesh,
              position: p,
              instanceData: Vector4(
                0,
                0,
                0,
                StylizedMaterial.packAccentAndFade(1),
              ),
            ),
        ],
      );
      // ...look like two skinned meshes of a material of that accent...
      final skinnedMeshes = await render(
        () => [
          for (final p in positions)
            MeshComponent(
              mesh: Mesh()..addSurface(skinned(single)),
              position: p,
              jointTransforms: {
                0: [Matrix4.identity()],
              },
            ),
        ],
      );
      expect(differingPixels(instanced, skinnedMeshes, tolerance: 0), 0);
      // ...and are submerged: without the volume they look otherwise below
      // the level and the same above its band.
      final dry = await render(
        () => [
          for (final p in positions)
            MeshComponent(mesh: Mesh()..addSurface(plain(single)), position: p),
        ],
        water: WaterVolumeSettings(absorption: 0),
      );
      expect(_differingRows(instanced, dry, 0, _row(-0.15)), 0);
      expect(
        _differingRows(instanced, dry, _row(-0.6), _size),
        greaterThan(1000),
      );
    });

    testGpu('stays inside its bounds and out of the shadow pass', (
      tester,
    ) async {
      final material = StylizedMaterial(rimStrength: 0, specularStrength: 0);
      // A box crossing the level, in front of the wall, casting its shadow
      // onto the wall above the water.
      final boxMesh = CuboidMesh(
        size: Vector3(0.4, 0.8, 0.4),
        material: material,
      );
      Future<Pixels> render(WaterVolumeSettings? water) async {
        return (await _render(
          tester,
          World3D(
            waterVolume: water,
            children: [
              ..._lights(
                sun: Vector3(-0.3, -0.2, -1),
                shadows: ShadowSettings(),
              ),
              MeshComponent(mesh: _wall(material)),
              MeshComponent(mesh: boxMesh, position: Vector3(0.6, 0.1, 0.8)),
            ],
          ),
        )).pixels;
      }

      final dry = await render(null);
      final bounded = await render(
        WaterVolumeSettings(
          absorption: 1.5,
          causticStrength: 1,
          bounds: Aabb3.minMax(Vector3(-2, -3, -1), Vector3(0, 0.5, 1)),
        ),
      );
      // The right half (x > 0) is outside the box: as dry.
      for (var y = 0; y < _size; y++) {
        for (var x = _size ~/ 2 + 1; x < _size; x++) {
          expect(bounded.at(x, y), dry.at(x, y), reason: '$x, $y');
        }
      }
      // The left half below the level is submerged.
      var changed = 0;
      for (var y = _row(-0.2); y < _size; y++) {
        for (var x = 0; x < _size ~/ 2 - 1; x++) {
          if (bounded.at(x, y) != dry.at(x, y)) {
            changed++;
          }
        }
      }
      expect(changed, greaterThan(2000));

      // The box's shadow on the dry wall is the same with the water.
      final wet = await render(WaterVolumeSettings(absorption: 1.5));
      expect(_differingRows(wet, dry, 0, _row(0) - 1), 0);
      expect(
        _differingRows(dry, await render(null), 0, _size),
        0,
        reason: 'renders are deterministic',
      );
    });

    testGpu('submerges surfaces in an HDR target too', (tester) async {
      final material = StylizedMaterial(rimStrength: 0, specularStrength: 0);
      Future<Pixels> render(WaterVolumeSettings? water) async {
        return (await _render(
          tester,
          World3D(
            hdrEnabled: true,
            waterVolume: water,
            children: [
              ..._lights(),
              MeshComponent(mesh: _wall(material)),
            ],
          ),
        )).pixels;
      }

      final dry = await render(null);
      final wet = await render(
        WaterVolumeSettings(
          absorption: 1,
          causticStrength: 1,
          waterlineWidth: 0.08,
          time: 0.4,
        ),
      );
      expect(_differingRows(wet, dry, 0, _row(0.3)), 0);
      expect(
        _differingRows(wet, dry, _row(-0.3), _row(-1.9)),
        greaterThan(_size * (_row(-1.9) - _row(-0.3)) * 9 ~/ 10),
      );
    });
  });
}
