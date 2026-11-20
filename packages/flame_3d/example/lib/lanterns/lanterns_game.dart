import 'dart:ui' show Color;

import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d_example/lanterns/lanterns_scene.dart';
import 'package:flame_3d_example/pool/pool_game.dart';
import 'package:flame_3d_example/pool/pool_scene.dart';

/// The pool of [PoolGame] at dusk, lit by [lights] small point lights (see
/// [LanternsScene]) through a light grid (`World3D.lightGrid`), seen from the
/// same fixed camera above the board.
///
/// Without [grid], the passes shade the first 8 point lights only, as without
/// a light grid. A tap turns the grid off and on.
class LanternsGame({
  final int lights = 64,

  /// How many of the [lights] to add (all by default), see
  /// [LanternsScene.keepLights].
  final int? keepLights,
  bool grid = true,
  var bool autoPlay = true,
}) extends FlameGame with TapCallbacks {
  /// The pool, at dusk.
  final PoolScene pool = PoolScene(lighting: PoolLighting.dusk);

  /// The lanterns, the windows and the floating lanterns.
  late final LanternsScene lanterns = LanternsScene(
    lights: lights,
    keepLights: keepLights,
  );

  /// The 3D layer.
  late final Scene3DComponent layer;

  /// The light grid of the layer's world while [grid] is on.
  static const LightGridSettings gridSettings = LightGridSettings();

  /// Whether the layer's world shades its lights through a light grid.
  bool get grid => _grid;
  bool _grid = grid;
  set grid(bool value) {
    _grid = value;
    if (isLoaded) {
      layer.world.lightGrid = value ? gridSettings : null;
    }
  }

  double _time = 0;

  @override
  Color backgroundColor() => const Color(0xFF2C3A30);

  @override
  Future<void> onLoad() async {
    layer = Scene3DComponent(
      projection: PoolGame.projection,
      msaa: Msaa.sample4,
    );
    pool.install(layer.world);
    _blueHour();
    layer.world
      ..addAll(lanterns.build())
      ..lightGrid = _grid ? gridSettings : null;
    world.add(layer);
    camera.viewfinder.position = Vector2(0, -0.45 * PoolGame.scale);
    setTime(0);
  }

  // Later than the pool's dusk: the sun has set, a dim blue sky, so that the
  // small lights make the light of the scene.
  void _blueHour() {
    for (final light in layer.world.children.whereType<LightComponent>()) {
      switch (light.source) {
        case final DirectionalLight sun:
          sun
            ..color = const Color(0xFFFF7A4A)
            ..intensity = 0.14;
        case final HemisphereLight sky:
          sky
            ..skyColor = const Color(0xFF4A5A9A)
            ..groundColor = const Color(0xFF2A2433)
            ..intensity = 0.3;
        // The two tall lamps of the pool, dimmer than at dusk.
        case final PointLight lamp:
          lamp.intensity = 0.5;
        case _:
      }
    }
    for (final water in [pool.water, pool.rimWater]) {
      water
        ..foamLightFloor = 0.2
        ..foamLightTint = 0.6;
    }
    pool.volume
      ..waterlineLightFloor = 0.15
      ..waterlineLightTint = 0.6;
  }

  /// Moves the scene to [time], in seconds.
  void setTime(double time) {
    _time = time;
    pool.setTime(time);
    lanterns.setTime(time);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (autoPlay) {
      setTime(_time + dt);
    }
  }

  @override
  void onTapUp(TapUpEvent event) => grid = !grid;
}
