import 'dart:math' as math;
import 'dart:ui' show Canvas, Color, Paint, RRect, Radius, Rect;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/painting.dart' show Shadow, TextStyle;

/// A stone platform standing in a pool, in a 3D layer over 2D water: it
/// rises out of the water with drops running off its edges, a warm barrier
/// rises from its brass rim, is hit three times in different colors and
/// sinks back, and a block drops into the water with a splash. Tap to switch
/// the barrier's pattern.
///
/// The scene is played by [BarrierScene], which can also be driven step by
/// step (see [BarrierScene.autoPlay]).
class BarrierGame({
  /// Whether a line of statistics is shown in a corner.
  final bool showStats = true,
}) extends FlameGame with TapCallbacks {
  late final BarrierScene scene;
  final TextComponent _readout = TextComponent(
    position: Vector2.all(12),
    textRenderer: TextPaint(
      style: const TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 13,
        height: 1.35,
        shadows: [Shadow(blurRadius: 2)],
      ),
    ),
  );

  @override
  Color backgroundColor() => const Color(0xFF1C6F93);

  @override
  Future<void> onLoad() async {
    scene = BarrierScene();
    world.addAll([_WaterBackdrop(), scene]);
    camera.viewfinder.position = scene.layer.scenePointToLocal(
      Vector3(0, 0, 0.3),
    );
    if (showStats) {
      camera.viewport.add(_readout);
    }
  }

  double _sinceRefresh = double.infinity;

  @override
  void update(double dt) {
    super.update(dt);
    _sinceRefresh += dt;
    if (_sinceRefresh < 0.25) {
      return;
    }
    _sinceRefresh = 0;
    final stats = scene.layer.renderStats;
    _readout.text =
        'pattern ${scene.barrier.pattern.name} (tap to switch)\n'
        'draw calls ${stats.drawCalls}, particles ${stats.particles}';
  }

  @override
  void onTapUp(TapUpEvent event) {
    const patterns = BarrierPattern.values;
    final barrier = scene.barrier;
    barrier.pattern = patterns[(barrier.pattern.index + 1) % patterns.length];
  }
}

/// The 3D layer of [BarrierGame] and what plays in it.
///
/// The scene has z up and is measured in slabs: the platform holds 5 by 5
/// slabs of 1 unit. Its projection looks down at 30 degrees from a corner,
/// [pixelsPerUnit] pixels per unit.
class BarrierScene({
  /// Whether the scene plays its loop on its own; when `false`, nothing
  /// happens but what its methods start.
  var bool autoPlay = true,
  final double pixelsPerUnit = 64,
}) extends Component {
  /// The height of the top of the platform above the water when it is up.
  static const double platformTop = 0.32;

  /// Half the size of the platform, rim included.
  static const double halfSize = 2.75;

  /// The scale of the splashes: scene units per meter.
  static const double unitsPerMeter = 2.5;

  /// The length of the loop [autoPlay] plays, in seconds.
  static const double loopLength = 8;

  late final Scene3DComponent layer = Scene3DComponent(
    projection: Scene3DProjection.affine(
      xAxis: Vector2(0.7071, 0.3536) * pixelsPerUnit,
      yAxis: Vector2(-0.7071, 0.3536) * pixelsPerUnit,
      zAxis: Vector2(0, -0.866) * pixelsPerUnit,
      towardsViewer: Vector3(0.6124, 0.6124, 0.5),
      near: -30,
      far: 30,
    ),
    msaa: Msaa.sample4,
  );

  /// The barrier's material.
  final BarrierMaterial barrier = BarrierMaterial(appear: 0);

  /// The barrier's wall: a band around the platform's rim.
  late final BarrierMesh wall = BarrierMesh.roundedRectangle(
    width: halfSize * 2 - 0.1,
    depth: halfSize * 2 - 0.1,
    height: 0.75,
    cornerRadius: 0.16,
    material: barrier,
  );

  late final Group3D platform = Group3D(
    position: Vector3(0, 0, platformTop),
  );
  late final MeshComponent _wallComponent = MeshComponent(
    mesh: wall,
    position: Vector3(0, 0, 0.08),
    rotation: _upright,
  );

  final ParticleSystem3D crown = ParticlePresets3D.splashCrown(
    up: _up,
    scale: unitsPerMeter,
  );
  late final ParticleSystem3D drips = ParticlePresets3D.runoffDrips(
    width: halfSize * 2,
    depth: halfSize * 2,
    up: _up,
    scale: unitsPerMeter,
    onGroundHit: _ripple,
  );
  final ParticleSystem3D foam = ParticlePresets3D.foamBurst(
    up: _up,
    scale: unitsPerMeter,
  );
  final ParticleSystem3D mist = ParticlePresets3D.mistPuff(
    up: _up,
    scale: unitsPerMeter,
  );

  /// Small rings where drops fall back into the water.
  final ParticleSystem3D ripples = ParticleSystem3D(
    capacity: 256,
    material: ParticleMaterial(
      billboard: ParticleBillboard.flat,
      axis: _up,
    ),
    sizeOverLife: ParticleCurve(0.3, 1.6),
    opacityOverLife: ParticleCurve(0.35, 0),
  );

  late final MeshComponent _block = MeshComponent(
    mesh: CuboidMesh(size: Vector3.all(0.5), material: _stone),
    color: const Color(0xFF3F8F8A),
    position: Vector3(3.7, -0.4, -2),
  );

  static final Vector3 _up = Vector3(0, 0, 1);
  static final Quaternion _upright = Quaternion.axisAngle(
    Vector3(1, 0, 0),
    math.pi / 2,
  );
  static final StylizedMaterial _stone = StylizedMaterial(rimStrength: 0.08);
  static final StylizedMaterial _brass = StylizedMaterial(
    specularStrength: 0.9,
    specularPower: 24,
  );

  double _time = 0;
  double _appearFrom = 0;
  double _appearTo = 0;
  double _appearStart = 0;
  double _appearLength = 0;
  double _blockVelocity = 0;
  bool _blockFalling = false;
  final Vector3 _point = Vector3.zero();

  @override
  Future<void> onLoad() async {
    final slab = CuboidMesh(size: Vector3(1, 1, 0.22), material: _stone);
    final slabs = InstancedGroup3D(mesh: slab, initialCapacity: 25);
    final random = math.Random(3);
    for (var i = 0; i < 5; i++) {
      for (var j = 0; j < 5; j++) {
        final shade = 0.9 + random.nextDouble() * 0.1;
        slabs.addInstance(
          transform: Matrix4.translationValues(
            (i - 2) * 1.06,
            (j - 2) * 1.06,
            -0.11,
          ),
          color: Color.from(
            alpha: 1,
            red: 0.82 * shade,
            green: 0.75 * shade,
            blue: 0.62 * shade,
          ),
        );
      }
    }
    final bar = CuboidMesh(
      size: Vector3(halfSize * 2, 0.1, 0.08),
      material: _brass,
    );
    platform.addAll([
      MeshComponent(
        mesh: CuboidMesh(
          size: Vector3(halfSize * 2, halfSize * 2, 1.2),
          material: _stone,
        ),
        color: const Color(0xFFAE9C80),
        position: Vector3(0, 0, -0.66),
      ),
      slabs,
      for (final (x, y, turn) in [
        (0.0, halfSize - 0.05, 0.0),
        (0.0, -halfSize + 0.05, 0.0),
        (halfSize - 0.05, 0.0, math.pi / 2),
        (-halfSize + 0.05, 0.0, math.pi / 2),
      ])
        MeshComponent(
          mesh: bar,
          color: const Color(0xFFD9A441),
          position: Vector3(x, y, 0.04),
          rotation: Quaternion.axisAngle(Vector3(0, 0, 1), turn),
        ),
      MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(0.5), material: _stone),
        color: const Color(0xFFE0614F),
        position: Vector3(-0.8, 0.5, 0.25),
        rotation: Quaternion.axisAngle(Vector3(0, 0, 1), 0.5),
      ),
      MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(0.5), material: _stone),
        color: const Color(0xFF2E7F9A),
        position: Vector3(0.7, -0.6, 0.25),
        rotation: Quaternion.axisAngle(Vector3(0, 0, 1), -0.3),
      ),
      _wallComponent,
    ]);

    layer.world.addAll([
      LightComponent.hemisphere(
        skyColor: const Color(0xFFD6ECFF),
        groundColor: const Color(0xFF7D6E58),
        intensity: 0.45,
        up: _up,
      ),
      LightComponent.directional(
        direction: Vector3(0.45, -0.35, -0.82),
        intensity: 0.7,
        shadows: ShadowSettings(strength: 0.6),
      ),
      platform,
      _block,
      // The surface of the water, over what is below it. It is drawn with
      // the opaque draws and writes depth, so that drops and foam above it
      // are never drawn under it.
      MeshComponent(
        mesh: PlaneMesh(
          size: Vector2.all(40),
          material: UnlitMaterial(albedoColor: const Color(0xC22C9FC4))
            ..renderState = const RenderState(
              blend: BlendState.alpha,
              translucent: false,
            )
            ..castsShadows = false,
        ),
        rotation: _upright,
      ),
      ripples,
      drips,
      crown,
      foam,
      mist,
    ]);
    barrier.fitPatternTo(wall.length, motifLength: 0.45);
    add(layer);
    _wallComponent.visible = false;
  }

  /// Sets the height of the top of the platform above the water.
  void setPlatformHeight(double height) {
    platform.position.z = height;
    drips.position.setValues(0, 0, height);
  }

  /// Raises the barrier from its foot over [seconds].
  void raise({double seconds = 0.35}) => _animateAppear(1, seconds);

  /// Lowers the barrier back to its foot over [seconds].
  void lower({double seconds = 0.4}) => _animateAppear(0, seconds);

  /// Shows the barrier fully raised, or not at all, at once.
  void setAppear(double value) {
    _appearLength = 0;
    barrier.appear = value;
    _wallComponent.visible = value > 0;
  }

  /// Hits the barrier at [along] units along its foot, [height] up it.
  void hit(double along, Color color, {double height = 0.3}) {
    wall.pointOnWall(along, height, _point);
    _wallComponent.worldTransformMatrix.transform3(_point);
    barrier.impact(_point, color: color);
  }

  /// A splash where something breaks the water at (x, y).
  void splash(double x, double y, {bool crown = true}) {
    _point.setValues(x, y, 0);
    if (crown) {
      this.crown.burst(40, at: _point);
    }
    foam.burst(14, at: _point);
    mist.burst(10, at: _point);
  }

  /// Drops the block into the water beside the platform.
  void dropBlock() {
    _block.position.setValues(3.7, -0.4, 2.2);
    _blockVelocity = 0;
    _blockFalling = true;
  }

  void _ripple(Vector3 position, double speed) {
    if (ripples.random.nextDouble() < 0.35) {
      ripples.spawn(
        position: position,
        size: 0.12,
        lifespan: 0.6,
        color: const Color(0xFFEAF6FF),
      );
    }
  }

  void _animateAppear(double to, double seconds) {
    _appearFrom = barrier.appear;
    _appearTo = to;
    _appearStart = _time;
    _appearLength = seconds;
    _wallComponent.visible = true;
  }

  double _loopTime = 0;

  @override
  void update(double dt) {
    super.update(dt);
    _time += dt;
    barrier.time = _time;

    if (_appearLength > 0) {
      final t = ((_time - _appearStart) / _appearLength).clamp(0.0, 1.0);
      final eased = 1 - (1 - t) * (1 - t);
      barrier.appear = _appearFrom + (_appearTo - _appearFrom) * eased;
      if (t >= 1) {
        _appearLength = 0;
        _wallComponent.visible = barrier.appear > 0;
      }
    }

    if (_blockFalling) {
      _blockVelocity -= 9.8 * unitsPerMeter * dt;
      final before = _block.position.z;
      _block.position.z += _blockVelocity * dt;
      if (before > 0 && _block.position.z <= 0) {
        splash(_block.position.x, _block.position.y);
        _blockVelocity *= 0.15;
      }
      if (_block.position.z < -2) {
        _blockFalling = false;
      }
    }

    if (autoPlay) {
      _play(dt);
    }
  }

  /// The loop: the platform rises, the barrier rises, is hit three times
  /// and sinks, a block drops into the water, the platform sinks.
  void _play(double dt) {
    final previous = _loopTime;
    _loopTime = (_loopTime + dt) % loopLength;
    bool crossed(double at) =>
        previous < at && _loopTime >= at ||
        (_loopTime < previous && (at > previous || at <= _loopTime));

    // The platform: up from 0 to 1.3 s, down from 6.6 to 7.8 s.
    final t = _loopTime;
    final double height;
    if (t < 1.3) {
      final k = 1 - math.pow(1 - t / 1.3, 3);
      height = -0.6 + (platformTop + 0.6) * k;
    } else if (t < 6.6) {
      height = platformTop;
    } else {
      final k = math.min(1.0, (t - 6.6) / 1.2);
      height = platformTop - (platformTop + 0.6) * k * k;
    }
    setPlatformHeight(height);

    if (crossed(0.55)) {
      drips.start();
    }
    if (crossed(1.6)) {
      raise();
    }
    if (crossed(2.3)) {
      hit(wall.length * 0.12, const Color(0xFFFFF0C8));
    }
    if (crossed(2.8)) {
      hit(wall.length * 0.62, const Color(0xFF7FD4FF), height: 0.2);
    }
    if (crossed(3.3)) {
      hit(wall.length * 0.37, const Color(0xFFFF8A70), height: 0.35);
    }
    if (crossed(4.2)) {
      lower();
    }
    if (crossed(4.9)) {
      dropBlock();
    }
  }
}

/// Deep water drawn in 2D below the 3D layer, with a few lighter swells.
class _WaterBackdrop() extends PositionComponent {
  this : super(position: Vector2.all(-2000), size: Vector2.all(4000));

  final Paint _deep = Paint()..color = const Color(0xFF1C6F93);
  final Paint _swell = Paint()..color = const Color(0x1AFFFFFF);

  @override
  void render(Canvas canvas) {
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), _deep);
    final random = math.Random(11);
    for (var i = 0; i < 90; i++) {
      final x = 1400 + random.nextDouble() * 1200;
      final y = 1600 + random.nextDouble() * 800;
      final w = 40 + random.nextDouble() * 120;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, w, 3 + random.nextDouble() * 3),
          const Radius.circular(3),
        ),
        _swell,
      );
    }
  }
}
