import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
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

// A board of several hundred still casters (tiles, houses, trees, fences)
// and a handful of moving ones (four tokens that take turns, two dice, a
// podium that keeps rising), played with and without
// ShadowSettings.cacheStillCasters.
//
// By default it plays a short game in a small view and checks the saving.
// With the environment variable FLAME3D_SHADOW_BENCH set to a directory, it
// plays a long game in a phone-sized view, three times for each mode in
// turn (FLAME3D_SHADOW_BENCH_ROUNDS), and writes there every other frame of
// the first round (PNG) and the statistics and timings of every frame
// (`bench.json`); add `--dart-define=FLAME_3D_PROFILE=true` for the CPU time
// of the shadow and main passes.

final String? _out = Platform.environment['FLAME3D_SHADOW_BENCH'];

// The rounds of the long game, 3 unless FLAME3D_SHADOW_BENCH_ROUNDS says.
final int _rounds =
    int.tryParse(Platform.environment['FLAME3D_SHADOW_BENCH_ROUNDS'] ?? '') ??
    3;

/// How the board is lit.
enum _Mode() {
  /// No shadows.
  none,

  /// Every caster in every frame.
  whole,

  /// ShadowSettings.cacheStillCasters.
  kept,
}

class _Board(final _Mode mode, final double width, final double height) {
  // The whole board in view, seen from above one corner.
  late final double _unit = width / 46;
  late final Scene3DComponent layer = Scene3DComponent(
    projection: Scene3DProjection.affine(
      origin: Vector2(width / 2, height * 0.53),
      xAxis: Vector2(_unit, _unit / 2),
      yAxis: Vector2(-_unit, _unit / 2),
      zAxis: Vector2(0, -_unit * 1.15),
      towardsViewer: Vector3(1, 1, 1.25),
      near: -80,
      far: 80,
    ),
  );

  final List<MeshComponent> tokens = [];
  final List<MeshComponent> dice = [];
  late final MeshComponent podium;
  int stillCasters = 0;

  static const double _half = 10;

  void build() {
    final world = layer.world;
    StylizedMaterial paint(int color) =>
        StylizedMaterial(albedoColor: Color(color));
    final shadows = mode == _Mode.none
        ? null
        : ShadowSettings(
            fit: ShadowFit.scene,
            bounds: Aabb3.minMax(
              Vector3(-_half, -_half, 0),
              Vector3(_half, _half, 0),
            ),
            strength: 0.8,
            color: const Color(0xFF2E3A66),
            cacheStillCasters: mode == _Mode.kept,
          );
    world.addAll([
      LightComponent.hemisphere(
        skyColor: const Color(0xFFB8D0F0),
        groundColor: const Color(0xFF8A7A60),
        up: Vector3(0, 0, 1),
        intensity: 0.55,
      ),
      LightComponent.directional(
        direction: Vector3(0.5, -0.35, -1),
        color: const Color(0xFFFFF2DC),
        intensity: 0.9,
        shadows: shadows,
      ),
      MeshComponent(
        mesh: PlaneMesh(
          size: Vector2.all(2 * _half + 2),
          material: paint(0xFF7FA35A),
        ),
        rotation: Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2),
      ),
    ]);
    final upright = Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2);
    final still = <MeshComponent>[];
    void put(Mesh mesh, double x, double y, double z, {bool up = false}) {
      still.add(
        MeshComponent(
          mesh: mesh,
          position: Vector3(x, y, z),
          rotation: up ? upright : null,
        ),
      );
    }

    // The ring of tiles the tokens walk on, two colors.
    final tiles = [
      for (final color in [0xFFE8DCC0, 0xFFD0B890])
        CuboidMesh(size: Vector3(1.9, 1.9, 0.2), material: paint(color)),
    ];
    for (var i = 0; i < 40; i++) {
      final (x, y) = _ring(i / 40);
      put(tiles[i % 2], x, y, 0.1);
    }
    // Houses on the tiles: bodies and roofs of a few sizes.
    final bodies = [
      for (final (h, color) in [
        (0.8, 0xFFC86450),
        (1.1, 0xFF5078C0),
        (1.4, 0xFF60A060),
        (1.0, 0xFFD8B040),
      ])
        CuboidMesh(size: Vector3(0.7, 0.7, h), material: paint(color)),
    ];
    final roof = ConeMesh(
      radius: 0.55,
      height: 0.5,
      segments: 4,
      material: paint(0xFF8A4030),
    );
    for (var i = 0; i < 40; i++) {
      final (x, y) = _ring(i / 40, inset: 1.6);
      for (var k = 0; k < 2; k++) {
        final body = bodies[(i + k) % 4];
        final h = body.aabb.max.z - body.aabb.min.z;
        final dx = (k - 0.5) * 0.8;
        put(body, x + dx, y - dx, h / 2 + 0.2);
        put(roof, x + dx, y - dx, h + 0.2, up: true);
      }
    }
    // A park in the middle: trees and fences.
    final trunk = CylinderMesh(
      radius: 0.08,
      height: 0.6,
      segments: 8,
      material: paint(0xFF6A4A30),
    );
    final crowns = [
      for (final color in [0xFF3A7A3A, 0xFF4E8F3A, 0xFF2F6A40])
        SphereMesh(radius: 0.32, segments: 12, material: paint(color)),
    ];
    final random = math.Random(7);
    for (var i = 0; i < 90; i++) {
      final x = -5.5 + random.nextDouble() * 11;
      final y = -5.5 + random.nextDouble() * 11;
      if (x.abs() < 1.6 && y.abs() < 1.6) {
        continue;
      }
      put(trunk, x, y, 0.3, up: true);
      put(crowns[i % 3], x, y, 0.8);
    }
    final fence = CuboidMesh(
      size: Vector3(0.5, 0.06, 0.3),
      material: paint(0xFFEFE6D0),
    );
    for (var i = 0; i < 48; i++) {
      final t = i / 48;
      final (x, y) = _ring(t, inset: 3.2);
      put(fence, x, y, 0.15);
    }
    world.addAll(still);
    stillCasters = still.length;

    // The moving casters.
    for (var k = 0; k < 4; k++) {
      final token = MeshComponent(
        mesh: CylinderMesh(
          radius: 0.28,
          height: 0.7,
          material: paint(
            const [0xFFE04040, 0xFF4060E0, 0xFF40C060, 0xFFE0C040][k],
          ),
        ),
        rotation: upright,
      );
      tokens.add(token);
    }
    for (var k = 0; k < 2; k++) {
      dice.add(
        MeshComponent(
          mesh: CuboidMesh(
            size: Vector3.all(0.45),
            material: paint(0xFFF4F0E8),
          ),
        ),
      );
    }
    podium = MeshComponent(
      mesh: CylinderMesh(
        radius: 0.9,
        height: 1,
        segments: 24,
        material: paint(0xFFE8C860),
      ),
      rotation: upright,
    );
    world
      ..addAll(tokens)
      ..addAll(dice)
      ..add(podium);
    play(0);
  }

  /// Where a point at [t] (0 to 1) around the ring of tiles is.
  static (double, double) _ring(double t, {double inset = 0}) {
    final side = (t * 4).floor() % 4;
    final f = t * 4 - (t * 4).floor();
    final r = _half - 1 - inset;
    return switch (side) {
      0 => (-r + 2 * r * f, -r),
      1 => (r, -r + 2 * r * f),
      2 => (r - 2 * r * f, r),
      _ => (-r, r - 2 * r * f),
    };
  }

  /// Places the moving casters for [frame]: each turn of 60 frames, the dice
  /// tumble for 25 frames, then the token of the turn hops 3 tiles; the
  /// podium keeps rising.
  void play(int frame) {
    final turn = frame ~/ 60;
    final inTurn = frame % 60;
    for (var k = 0; k < 4; k++) {
      // Tiles walked before this frame: 3 per earlier turn of this token.
      final turns = (turn - k + 3) ~/ 4;
      var tile = k * 10 + 3.0 * math.max(0, turns);
      var hop = 0.0;
      if (turn % 4 == k && inTurn >= 25 && inTurn < 55) {
        final walked = (inTurn - 25) / 10;
        tile += walked;
        final f = walked - walked.floor();
        hop = 4 * f * (1 - f) * 0.6;
      }
      final (x, y) = _ring((tile % 40) / 40);
      tokens[k].position.setValues(x, y, 0.55 + hop);
    }
    for (var k = 0; k < 2; k++) {
      final roll = math.min(inTurn, 25) / 25;
      final spin = (1 - roll) * (1 - roll);
      dice[k]
        ..position.setValues(
          -0.5 + k * 1.0 + (1 - roll) * 1.5,
          0.8 - k * 1.2 + (1 - roll) * 0.8,
          0.225 + 1.2 * spin * (0.5 + 0.5 * math.cos(roll * 12)).abs(),
        )
        ..rotation.setFrom(
          Quaternion.euler(
            (turn + k) * 1.1 + (1 - roll) * 7,
            (turn * 2 + k) * 0.7 + (1 - roll) * 5,
            0,
          ),
        );
    }
    podium.position.setValues(0, 0, -0.5 + math.min(frame, 600) / 600 * 1.4);
  }
}

class _Frame(
  final RenderStats stats,
  final int pumpMicros,
  final int rasterMicros,
);

class _Played(
  final List<_Frame> frames,
  final List<Pixels> pixels,
  final double shadowCpuMicros,
  final double mainCpuMicros,
  final Map<String, double> shadowPhases,
  final int stillCasters,
);

Future<_Played> _play(
  WidgetTester tester, {
  required _Mode mode,
  required int frames,
  required double width,
  required double height,
  required bool keepPixels,
  String? writeTo,
}) async {
  final board = _Board(mode, width, height)..build();
  final game = FlameGame(
    world: World(
      children: [
        RectangleComponent(
          size: Vector2(width, height),
          paint: Paint()..color = const Color(0xFF1E2A3A),
        ),
        board.layer,
      ],
    ),
  );
  game.camera.viewfinder.position = Vector2(width / 2, height / 2);
  tester.view
    ..physicalSize = Size(width, height)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  await tester.pumpWidget(
    RepaintBoundary(
      key: key,
      child: GameWidget(game: game),
    ),
  );
  final profile = kProfileRender ? RenderProfile() : null;
  final played = <_Frame>[];
  final pixels = <Pixels>[];
  final clock = Stopwatch();
  for (var frame = 0; frame < frames; frame++) {
    board.play(frame);
    if (frame == 40) {
      RenderProfile.active = profile;
    }
    clock
      ..reset()
      ..start();
    await tester.pump(const Duration(milliseconds: 16));
    final pump = clock.elapsedMicroseconds;
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = (await tester.runAsync(() async {
      clock
        ..reset()
        ..start();
      final image = await boundary.toImage();
      final out = await readImage(image);
      final micros = clock.elapsedMicroseconds;
      if (writeTo != null && frame.isEven) {
        final png = await image.toByteData(format: ImageByteFormat.png);
        File(
          '$writeTo/${mode.name}_${frame.toString().padLeft(4, '0')}.png',
        ).writeAsBytesSync(png!.buffer.asUint8List());
      }
      image.dispose();
      return (out, micros);
    }))!;
    played.add(
      _Frame(RenderStats()..setFrom(board.layer.renderStats), pump, image.$2),
    );
    if (keepPixels) {
      pixels.add(image.$1);
    }
  }
  RenderProfile.active = null;
  var shadowCpu = 0.0;
  var mainCpu = 0.0;
  final measured = math.max(1, frames - 40);
  final phases = <String, double>{};
  if (profile != null) {
    for (final phase in RenderPhase.values) {
      final shadow = profile.microseconds(phase, shadow: true);
      shadowCpu += shadow;
      mainCpu += profile.microseconds(phase);
      phases[phase.name] = shadow / measured;
    }
  }
  await tester.pumpWidget(const RepaintBoundary());
  return _Played(
    played,
    pixels,
    shadowCpu / measured,
    mainCpu / measured,
    phases,
    board.stillCasters,
  );
}

double _mean(Iterable<num> values) {
  var sum = 0.0;
  var count = 0;
  for (final value in values) {
    sum += value;
    count++;
  }
  return count == 0 ? 0 : sum / count;
}

void main() {
  setUpGpu();

  testGpu('a board of still casters and a few movers: the kept layers draw a '
      'fraction of the shadow pass, with the same pixels', (tester) async {
    final out = _out;
    final long = out != null;
    final frames = long ? 240 : 75;
    final width = long ? 1170.0 : 260.0;
    final height = long ? 540.0 : 120.0;
    final results = <_Mode, _Played>{};
    // The timings of the long game: the modes take turns over three rounds,
    // on a machine whose load varies.
    final rasterRounds = <_Mode, List<double>>{};
    final pumpRounds = <_Mode, List<double>>{};
    for (var round = 0; round < (long ? _rounds : 1); round++) {
      for (final mode in long ? _Mode.values : [_Mode.whole, _Mode.kept]) {
        final played = await _play(
          tester,
          mode: mode,
          frames: frames,
          width: width,
          height: height,
          keepPixels: !long,
          writeTo: long && round == 0 && mode != _Mode.none ? out : null,
        );
        results[mode] ??= played;
        double median(Iterable<int> values) {
          final sorted = values.toList()..sort();
          return sorted[sorted.length ~/ 2] / 1000;
        }

        final measuredFrames = played.frames.skip(40);
        (rasterRounds[mode] ??= []).add(
          median(measuredFrames.map((f) => f.rasterMicros)),
        );
        (pumpRounds[mode] ??= []).add(
          median(measuredFrames.map((f) => f.pumpMicros)),
        );
      }
    }
    final whole = results[_Mode.whole]!;
    final kept = results[_Mode.kept]!;
    expect(whole.stillCasters, greaterThan(300));

    // The same pixels in every frame.
    if (!long) {
      for (var frame = 0; frame < frames; frame++) {
        expect(
          differingPixels(
            whole.pixels[frame],
            kept.pixels[frame],
            tolerance: 0,
          ),
          0,
          reason: 'frame $frame',
        );
      }
    }

    // After the first turn, far fewer shadow draws and triangles.
    final measured = [for (var f = 40; f < frames; f++) f];
    double average(_Played played, int Function(RenderStats) value) =>
        _mean(measured.map((f) => value(played.frames[f].stats)));
    final wholeDraws = average(whole, (s) => s.shadowDrawCalls);
    final keptDraws = average(kept, (s) => s.shadowDrawCalls);
    final wholeTriangles = average(whole, (s) => s.shadowTriangles);
    final keptTriangles = average(kept, (s) => s.shadowTriangles);
    expect(keptDraws, lessThan(wholeDraws * 0.5));
    expect(keptTriangles, lessThan(wholeTriangles * 0.3));

    if (out != null) {
      Map<String, Object> summary(_Played played) => {
        'shadowDrawCalls': average(played, (s) => s.shadowDrawCalls),
        'shadowTriangles': average(played, (s) => s.shadowTriangles),
        'shadowPasses': average(played, (s) => s.shadowPasses),
        'shadowLayersRendered': average(
          played,
          (s) => s.shadowLayersRendered,
        ),
        'shadowReusedDrawCalls': average(
          played,
          (s) => s.shadowReusedDrawCalls,
        ),
        'shadowReusedTriangles': average(
          played,
          (s) => s.shadowReusedTriangles,
        ),
        'drawCalls': average(played, (s) => s.drawCalls),
        'triangles': average(played, (s) => s.triangles),
        'pumpMicros': _mean(measured.map((f) => played.frames[f].pumpMicros)),
        'rasterMicros': _mean(
          measured.map((f) => played.frames[f].rasterMicros),
        ),
        'shadowCpuMicros': played.shadowCpuMicros,
        'mainCpuMicros': played.mainCpuMicros,
        'shadowPhases': played.shadowPhases,
        'perFrame': [
          for (final frame in played.frames)
            [
              frame.stats.shadowPasses,
              frame.stats.shadowDrawCalls,
              frame.stats.shadowTriangles,
              frame.stats.shadowLayersRendered,
              frame.pumpMicros,
              frame.rasterMicros,
            ],
        ],
      };
      File('$out/bench.json').writeAsStringSync(
        const JsonEncoder.withIndent(' ').convert({
          'width': width,
          'height': height,
          'frames': frames,
          'stillCasters': whole.stillCasters,
          'profiled': kProfileRender,
          'medianRasterMillisPerRound': {
            for (final entry in rasterRounds.entries)
              entry.key.name: entry.value,
          },
          'medianPumpMillisPerRound': {
            for (final entry in pumpRounds.entries) entry.key.name: entry.value,
          },
          for (final entry in results.entries)
            entry.key.name: summary(entry.value),
        }),
      );
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
