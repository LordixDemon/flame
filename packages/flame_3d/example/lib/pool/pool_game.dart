import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d_example/pool/pool_scene.dart';

/// A 2D game whose 3D layer is a [PoolScene]: a clear pool in a walled quay,
/// seen through an isometric-like projection at 30° down (a mirrored affine
/// `Scene3DProjection`, as the 2D art of a board would be drawn).
///
/// With [autoPlay] the slabs rise out of the water and sink back every 12
/// seconds and a pebble drops in every few seconds. A tap goes from noon to
/// dusk, to a still winter day and back.
class PoolGame({
  var bool autoPlay = true,
  PoolLighting lighting = PoolLighting.noon,
}) extends FlameGame with TapCallbacks {
  /// Pixels per world unit of the projection.
  static const double scale = 54;

  /// An isometric-like projection at 30° down, z up: the scene point
  /// (x, y, z) lands at `((x - y) * 0.707, (x + y) * 0.354 - z * 0.866)`
  /// times [scale]. It mirrors the scene compared with a camera.
  static final Scene3DProjection projection = Scene3DProjection.affine(
    xAxis: Vector2(0.7071, 0.3536) * scale,
    yAxis: Vector2(-0.7071, 0.3536) * scale,
    zAxis: Vector2(0, -0.8660) * scale,
    towardsViewer: Vector3(0.6124, 0.6124, 0.5),
    near: -30,
    far: 30,
  );

  /// The scene in the layer.
  final PoolScene scene = PoolScene(lighting: lighting);

  /// The 3D layer.
  late final Scene3DComponent layer;

  double _time = 0;
  int _drops = 0;

  @override
  Color backgroundColor() => const Color(0xFF6E9E54);

  @override
  Future<void> onLoad() async {
    layer = Scene3DComponent(projection: projection, msaa: Msaa.sample4);
    scene.install(layer.world);
    world.add(layer);
    camera.viewfinder.position = Vector2(0, -0.45 * scale);
  }

  /// Moves the scene to [time], in seconds (see [PoolScene.setTime]).
  void setTime(double time) {
    _time = time;
    scene.setTime(time);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!autoPlay) {
      return;
    }
    _time += dt;
    final cycle = _time % 12;
    scene.slabLift = cycle < 2
        ? 0
        : cycle < 6
        ? (cycle - 2) / 4
        : cycle < 8
        ? 1
        : math.max(0, 1 - (cycle - 8) / 3);
    final drops = (_time / 3.3).floor();
    if (drops != _drops) {
      _drops = drops;
      final random = math.Random(drops);
      scene.dropPebble(
        (random.nextDouble() - 0.5) * 2 * (PoolScene.halfLength - 0.8),
        (random.nextDouble() - 0.5) * 2 * (PoolScene.halfWidth - 0.8),
        _time,
      );
    }
    scene.setTime(_time);
  }

  @override
  void onTapUp(TapUpEvent event) {
    const looks = PoolLighting.values;
    scene.lighting = looks[(scene.lighting.index + 1) % looks.length];
  }
}
