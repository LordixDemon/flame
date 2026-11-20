import 'dart:math' as math;
import 'dart:ui' show Canvas, Color, Paint, Rect;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/painting.dart' show Shadow, TextStyle;

/// The ground drawn in 2D under a [BarrierGallery].
enum BarrierBackdrop(
  /// The color of the ground.
  final Color color,
) {
  /// Light, turquoise water.
  lightWater(Color(0xFF3FB4C4)),

  /// Deep, dark water.
  darkWater(Color(0xFF173E5C)),

  /// Pale stone.
  paleStone(Color(0xFFD9CDB4)),
}

/// One podium of a [BarrierGallery]: a [label] and the [look] of its wall,
/// with [setup] for what a look does not hold.
class BarrierStand(
  /// What the stand shows, in a few words.
  final String label,

  /// The look of the stand's wall.
  final BarrierLook look, {

  /// Whether a hit of the cube also pulses the wall.
  final bool pulseOnHit = false,

  /// Whether the cube lights the wall as it comes close.
  final bool nearGlow = true,

  /// Called once on the stand's material after the look is applied.
  final void Function(BarrierMaterial material)? setup,
});

/// A row of podiums of pale slabs, each walled by a [BarrierMaterial] with a
/// look of its own, in a 3D layer over 2D ground, seen from a corner 30
/// degrees above the horizon.
///
/// On each podium a cube slides into the far wall every [loopLength] seconds
/// and bounces back: the wall glows as the cube comes close
/// (`BarrierMaterial.setNearPoint`), is hit where it touches
/// (`BarrierMaterial.impact`), and pulses when the stand asks for it. The
/// stands play in step, so that a strip of them compares one setting at a
/// time; the named strips are [presets], [height], [profile], [density] and
/// [reaction].
class BarrierGallery({
  /// The podiums, from left to right on the screen.
  required final List<BarrierStand> stands,

  /// The ground under the layer.
  var BarrierBackdrop backdrop = BarrierBackdrop.lightWater,

  /// Whether the cubes play on their own; when `false`, only [setTime] moves
  /// them.
  var bool autoPlay = true,

  /// The pixels per scene unit of the layer's projection.
  final double pixelsPerUnit = 64,
}) extends Component {
  /// The length of the cubes' loop, in seconds.
  static const double loopLength = 3.2;

  /// The time in the loop at which the cube hits the far wall.
  static const double hitTime = 1.05;

  /// Half the width of a podium's wall.
  static const double halfWall = 1.65;

  /// The height of the wall's mesh: `heightScale` scales it.
  static const double wallHeight = 1;

  /// The height of a podium's top above the ground.
  static const double podiumTop = 0.3;

  /// The distance between the centers of two podiums along the screen.
  static const double spacing = 5.4;

  /// The edge of a cube.
  static const double cubeSize = 0.42;

  /// The stands of the named looks.
  static final List<BarrierStand> presets = [
    BarrierStand('standard', BarrierLook.standard),
    BarrierStand('soft veil', BarrierLook.softVeil),
    BarrierStand('solid wall', BarrierLook.solidWall, pulseOnHit: true),
    BarrierStand('low fence', BarrierLook.lowFence),
    BarrierStand('electric cage', BarrierLook.electricCage),
  ];

  /// The look the sweeps start from: a warm shield of medium density.
  static const BarrierLook sweepBase = BarrierLook(
    footColor: Color(0xFFFFB04A),
    topColor: Color(0xB3FFC878),
    intensity: 0.85,
    preserveHue: true,
    blend: BlendState.premultipliedAlpha,
    heightFalloff: 0.8,
    fadeStart: 0.25,
    topEdgeColor: Color(0xFFFFE2A8),
    topEdgeStrength: 0.7,
    fillColor: Color(0xFFD9822B),
    fillOpacity: 0.25,
    fillFade: 0.3,
    pattern: BarrierPattern.hexagons,
    patternScale: 3,
    patternRows: 3,
    patternHeight: 1,
    patternStrength: 0.5,
    patternColor: Color(0xFFFFE6B8),
    patternSpeed: 0.08,
    nearSideFade: 0.75,
    impactColor: Color(0xFFFFF4D6),
    impactRingCount: 2,
    impactRingStrength: 2,
    impactRingWidth: 0.09,
    impactFlashStrength: 1.6,
    reactionInFront: 1,
  );

  /// The wall's height at run time, one stand each: `heightScale` from 0.3
  /// to 1.6 of the mesh's height.
  static final List<BarrierStand> height = [
    for (final scale in const [0.3, 0.6, 1.0, 1.3, 1.6])
      BarrierStand(
        'heightScale $scale',
        sweepBase.copyWith(heightScale: scale),
      ),
  ];

  /// The profile up the wall: where the light fades, how it falls, and the
  /// top edge.
  static final List<BarrierStand> profile = [
    BarrierStand(
      'fade 0 to 0.4',
      sweepBase.copyWith(
        fadeStart: 0,
        fadeEnd: 0.4,
        heightFalloff: 1.6,
        topEdgeStrength: 0,
        fillOpacity: 0,
      ),
    ),
    BarrierStand(
      'fade 0 to 1, falloff 1.8',
      sweepBase.copyWith(
        fadeStart: 0,
        fadeEnd: 1,
        heightFalloff: 1.8,
        topEdgeStrength: 0,
      ),
    ),
    BarrierStand('fade 0.25 to 1, falloff 0.8', sweepBase),
    BarrierStand(
      'fade 0.6 to 1, falloff 0.5',
      sweepBase.copyWith(fadeStart: 0.6, heightFalloff: 0.5),
    ),
    BarrierStand(
      'top edge 1.4, width 0.06',
      sweepBase.copyWith(
        fadeStart: 0.6,
        heightFalloff: 0.5,
        topEdgeStrength: 1.4,
        topEdgeWidth: 0.06,
      ),
    ),
  ];

  /// How solid the wall is: the fill, the motifs, the noise.
  static final List<BarrierStand> density = [
    BarrierStand(
      'fill 0, plain',
      sweepBase.copyWith(fillOpacity: 0, pattern: BarrierPattern.plain),
    ),
    BarrierStand(
      'fill 0.2, 2 rows',
      sweepBase.copyWith(fillOpacity: 0.2, patternRows: 2),
    ),
    BarrierStand('fill 0.4, 3 rows', sweepBase.copyWith(fillOpacity: 0.4)),
    BarrierStand(
      'fill 0.6, 4 rows, noise 0.5',
      sweepBase.copyWith(
        fillOpacity: 0.6,
        patternRows: 4,
        patternLineWidth: 1.3,
        noiseStrength: 0.5,
      ),
    ),
    BarrierStand(
      'fill 0.85, 5 rows, noise 0.8',
      sweepBase.copyWith(
        fillOpacity: 0.85,
        patternRows: 5,
        patternLineWidth: 1.6,
        patternStrength: 0.7,
        noiseStrength: 0.8,
      ),
    ),
  ];

  /// What a hit does: rings, wobble, pulse, and the reaction over the cube.
  static final List<BarrierStand> reaction = [
    BarrierStand(
      '1 ring, hidden by the cube',
      sweepBase.copyWith(impactRingCount: 1, reactionInFront: 0),
      nearGlow: false,
    ),
    BarrierStand(
      '1 ring, in front',
      sweepBase.copyWith(impactRingCount: 1),
      nearGlow: false,
    ),
    BarrierStand(
      '3 rings, reach 1.6',
      sweepBase.copyWith(impactRingCount: 3, impactRingReach: 1.6),
      nearGlow: false,
    ),
    BarrierStand(
      '3 rings, wobble 0.07',
      sweepBase.copyWith(
        impactRingCount: 3,
        impactRingReach: 1.6,
        wobbleAmplitude: 0.07,
      ),
      nearGlow: false,
    ),
    BarrierStand(
      'wobble, pulse, near glow',
      sweepBase.copyWith(
        impactRingCount: 3,
        impactRingReach: 1.6,
        wobbleAmplitude: 0.07,
        pulseStrength: 0.6,
        proximityRadius: 1,
        proximityStrength: 2.5,
      ),
      pulseOnHit: true,
    ),
  ];

  late final Scene3DComponent layer = Scene3DComponent(
    projection: Scene3DProjection.affine(
      xAxis: Vector2(0.7071, 0.3536) * pixelsPerUnit,
      yAxis: Vector2(-0.7071, 0.3536) * pixelsPerUnit,
      zAxis: Vector2(0, -0.866) * pixelsPerUnit,
      towardsViewer: Vector3(0.6124, 0.6124, 0.5),
      near: -60,
      far: 60,
    ),
    msaa: Msaa.sample4,
  );

  /// The material of each stand's wall.
  late final List<BarrierMaterial> barriers = [
    for (final stand in stands)
      BarrierMaterial.fromLook(stand.look)..also(stand.setup),
  ];

  /// The wall mesh of each stand: fine enough for the wobble.
  late final List<BarrierMesh> walls = [
    for (final barrier in barriers)
      BarrierMesh.roundedRectangle(
        width: halfWall * 2,
        depth: halfWall * 2,
        height: wallHeight,
        cornerRadius: 0.12,
        heightSegments: 10,
        maxSegmentLength: 0.12,
        material: barrier,
      ),
  ];

  late final List<MeshComponent> _cubes = [
    for (var i = 0; i < stands.length; i++)
      MeshComponent(
        mesh: CuboidMesh(size: Vector3.all(cubeSize), material: _ivory),
        color: const Color(0xFFF4EFE6),
      ),
  ];

  static final Vector3 _up = Vector3(0, 0, 1);
  static final Quaternion _upright = Quaternion.axisAngle(
    Vector3(1, 0, 0),
    math.pi / 2,
  );
  static final StylizedMaterial _stone = StylizedMaterial(rimStrength: 0.08);
  static final StylizedMaterial _ivory = StylizedMaterial(
    specularStrength: 0.4,
    specularPower: 16,
  );

  double _time = 0;
  double _loopTime = 0;
  final Vector3 _point = Vector3.zero();
  final Vector3 _cubeAt = Vector3.zero();

  /// The center of stand [index] in the scene: the stands lie along the
  /// screen's horizontal, which is `(1, -1, 0)` in the scene.
  Vector3 standCenter(int index, [Vector3? out]) {
    final offset = (index - (stands.length - 1) / 2) * spacing / math.sqrt2;
    return (out ?? Vector3.zero())..setValues(offset, -offset, 0);
  }

  /// The scene point the camera should look at: the middle of the row.
  Vector3 get viewCenter => Vector3(0, 0, podiumTop + 0.5);

  @override
  Future<void> onLoad() async {
    layer.world.addAll([
      LightComponent.hemisphere(
        skyColor: const Color(0xFFD6ECFF),
        groundColor: const Color(0xFF7D6E58),
        up: _up,
      ),
      LightComponent.directional(
        direction: Vector3(0.45, -0.35, -0.82),
        intensity: 0.75,
        shadows: ShadowSettings(strength: 0.5),
      ),
    ]);
    final slab = CuboidMesh(size: Vector3(1, 1, 0.16), material: _stone);
    for (var i = 0; i < stands.length; i++) {
      final center = standCenter(i);
      final slabs = InstancedGroup3D(mesh: slab, initialCapacity: 9);
      final random = math.Random(5 + i);
      for (var a = 0; a < 3; a++) {
        for (var b = 0; b < 3; b++) {
          final shade = 0.9 + random.nextDouble() * 0.1;
          slabs.addInstance(
            transform: Matrix4.translationValues(
              (a - 1) * 1.05,
              (b - 1) * 1.05,
              -0.08,
            ),
            color: Color.from(
              alpha: 1,
              red: 0.84 * shade,
              green: 0.77 * shade,
              blue: 0.64 * shade,
            ),
          );
        }
      }
      layer.world.add(
        Group3D(
          position: Vector3(center.x, center.y, podiumTop),
          children: [
            MeshComponent(
              mesh: CuboidMesh(
                size: Vector3(halfWall * 2 + 0.1, halfWall * 2 + 0.1, 1.2),
                material: _stone,
              ),
              color: const Color(0xFFB4A286),
              position: Vector3(0, 0, -0.62),
            ),
            slabs,
            MeshComponent(
              mesh: walls[i],
              position: Vector3(0, 0, 0.01),
              rotation: _upright,
            ),
            _cubes[i],
            MeshComponent(
              mesh: CuboidMesh(size: Vector3.all(cubeSize), material: _ivory),
              color: const Color(0xFFE25B4B),
              position: Vector3(0.75, -0.55, cubeSize / 2),
              rotation: Quaternion.axisAngle(_up, 0.4),
            ),
          ],
        ),
      );
      barriers[i].fitPatternTo(walls[i].length, motifLength: 0.33);
      // Keep the look's own motif count where it asks for one.
      barriers[i].patternScale = _fit(stands[i].look.patternScale, walls[i]);
    }
    add(layer);
    _place(0);
  }

  static double _fit(double scale, BarrierMesh wall) {
    final count = math.max(1, (wall.length * scale).round());
    return count / wall.length;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (autoPlay) {
      setTime(_time + dt);
    }
  }

  /// Plays the gallery to [time] seconds: the walls' time, the cubes and the
  /// hits. Going back in time clears the impacts.
  void setTime(double time) {
    if (time < _time) {
      for (final barrier in barriers) {
        barrier
          ..clearImpacts()
          ..clearPulse();
      }
      _loopTime = 0;
      _time = 0;
    }
    while (_time < time) {
      final step = math.min(1 / 60, time - _time);
      _time += step;
      final previous = _loopTime;
      _loopTime = (_loopTime + step) % loopLength;
      final crossed =
          previous < hitTime && _loopTime >= hitTime ||
          (_loopTime < previous && hitTime > previous);
      for (final barrier in barriers) {
        barrier.time = _time;
      }
      if (crossed) {
        _hit();
      }
    }
    _place(_loopTime);
  }

  /// The cube of every stand at [t] seconds into the loop: it slides from
  /// the middle of the podium into the far wall, then back.
  void _place(double t) {
    final cubeAt = _cubeAt;
    const contact = -halfWall + cubeSize / 2 + 0.02;
    const startX = 0.55;
    if (t < hitTime) {
      final k = t / hitTime;
      final eased = k * k;
      cubeAt.setValues(startX + (contact - startX) * eased, 0.35, 0);
    } else if (t < hitTime + 0.9) {
      final k = (t - hitTime) / 0.9;
      final eased = 1 - (1 - k) * (1 - k);
      cubeAt.setValues(contact + (0.1 - contact) * eased, 0.35 - 0.2 * k, 0);
    } else {
      final k = math.min(
        1.0,
        (t - hitTime - 0.9) / (loopLength - hitTime - 0.9),
      );
      cubeAt.setValues(0.1 + (startX - 0.1) * k, 0.15 + 0.2 * k, 0);
    }
    // A small hop on the way back.
    final hop = t > hitTime && t < hitTime + 0.5
        ? math.sin((t - hitTime) / 0.5 * math.pi) * 0.18
        : 0.0;
    for (var i = 0; i < stands.length; i++) {
      final cube = _cubes[i];
      cube.position.setValues(cubeAt.x, cubeAt.y, cubeSize / 2 + hop);
      cube.rotation.setAxisAngle(_up, 0.3 + cubeAt.x * 0.8);
      if (stands[i].nearGlow) {
        standCenter(i, _point)
          ..x += cubeAt.x - cubeSize / 2
          ..y += cubeAt.y
          ..z = podiumTop + cubeSize / 2 + hop;
        barriers[i].setNearPoint(0, _point);
      }
    }
  }

  void _hit() {
    for (var i = 0; i < stands.length; i++) {
      standCenter(i, _point)
        ..x -= halfWall
        ..y += 0.35
        ..z = podiumTop + cubeSize * 0.55;
      barriers[i].impact(_point);
      if (stands[i].pulseOnHit) {
        barriers[i].pulse();
      }
    }
  }
}

/// The [BarrierGallery] strips one after the other: the presets, then sweeps
/// of the height, the profile, the density and the reaction. Tap to go to
/// the next strip; the ground changes with each round.
class BarrierGalleryGame({
  /// Whether the name of the strip and of each stand is shown.
  final bool showLabels = true,
}) extends FlameGame with TapCallbacks {
  /// The strips, by name.
  static final Map<String, List<BarrierStand>> strips = {
    'presets': BarrierGallery.presets,
    'height': BarrierGallery.height,
    'profile': BarrierGallery.profile,
    'density': BarrierGallery.density,
    'reaction': BarrierGallery.reaction,
  };

  int _strip = 0;
  int _round = 0;
  BarrierGallery? _gallery;

  /// The gallery shown.
  BarrierGallery get gallery => _gallery!;

  final TextComponent _title = TextComponent(
    position: Vector2.all(12),
    textRenderer: TextPaint(
      style: const TextStyle(
        color: Color(0xFFFFFFFF),
        fontSize: 14,
        height: 1.35,
        shadows: [Shadow(blurRadius: 2)],
      ),
    ),
  );

  @override
  Future<void> onLoad() async {
    world.add(_Ground(this));
    if (showLabels) {
      camera.viewport.add(_title);
    }
    _show();
  }

  void _show() {
    _gallery?.removeFromParent();
    final name = strips.keys.elementAt(_strip);
    final gallery = BarrierGallery(
      stands: strips[name]!,
      backdrop: BarrierBackdrop.values[_round % BarrierBackdrop.values.length],
    );
    _gallery = gallery;
    world.add(gallery);
    camera.viewfinder.position = gallery.layer.scenePointToLocal(
      gallery.viewCenter,
    );
    camera.viewfinder.zoom = math.min(
      1,
      size.x /
          (gallery.stands.length *
              BarrierGallery.spacing *
              gallery.pixelsPerUnit),
    );
    _title.text =
        '$name (tap for the next strip)\n'
        '${[for (final stand in gallery.stands) stand.label].join('  |  ')}';
  }

  /// The name of the strip shown.
  String get stripName => strips.keys.elementAt(_strip);

  /// Shows the next strip; after the last, the first again over the next
  /// ground.
  void nextStrip() {
    _strip++;
    if (_strip == strips.length) {
      _strip = 0;
      _round++;
    }
    _show();
  }

  @override
  void onTapUp(TapUpEvent event) => nextStrip();
}

/// The 2D ground under the gallery, in the color of its backdrop.
class _Ground(final BarrierGalleryGame _game) extends PositionComponent {
  this : super(position: Vector2.all(-4000), size: Vector2.all(8000));

  final Paint _paint = Paint();

  @override
  void render(Canvas canvas) {
    _paint.color =
        _game._gallery?.backdrop.color ?? BarrierBackdrop.lightWater.color;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.x, size.y), _paint);
  }
}

extension on BarrierMaterial {
  void also(void Function(BarrierMaterial material)? setup) =>
      setup?.call(this);
}
