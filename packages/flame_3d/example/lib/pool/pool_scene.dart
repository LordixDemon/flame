import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d_example/pool/pool_meshes.dart';

/// The light of a [PoolScene]: the sun high at noon, or low and warm at dusk
/// with the lamps lit.
enum PoolLighting() {
  noon,
  dusk,
}

/// A shallow, clear pool inside a walled quay, in a world whose up axis is z,
/// with the water's surface at z = 0: a floor that deepens towards the
/// middle, a grid of slabs on columns that rise out of the water and sink
/// back, stepping stones, a floating crate, two lamps and pebbles that drop
/// in.
///
/// The water is one translucent [WaterMaterial] draw (caustics, sparkles, a
/// swell of the normals, a depth ramp, edge foam, [ripples] and [collars],
/// foam that follows the slabs and the crate), plus a narrow strip along the
/// far wall drawn with [rimWater], whose band of foam stands still (a rim of
/// dried salt) while the foam elsewhere laps; the floor, the walls and
/// everything under the water are [StylizedMaterial]s that the world's
/// [volume] tints with their depth, lights with the same caustics and rings
/// with foam where they cross the surface. At dusk, the foam keeps its white
/// under the warm sun ([WaterMaterial.foamLightTint],
/// [WaterVolumeSettings.waterlineLightTint]). Nothing needs the depth prepass
/// or the scene color grab. Splashes come from [ParticlePresets3D]:
/// a crown, foam and mist where the pebble lands, water running off the
/// slabs that rise out of the water and foam flooding over those that sink,
/// and every drop that falls back raises a small ring in [ripples].
///
/// Everything that moves is a function of the time given to [setTime], so a
/// frame can be rendered again exactly.
class PoolScene({PoolLighting lighting = PoolLighting.noon}) {
  /// Half the length and half the width of the water, in world units.
  static const double halfLength = 4;
  static const double halfWidth = 3;

  /// The height of the quay around the water.
  static const double quayHeight = 0.42;

  /// The height of the slabs' tops when sunk and when raised.
  static const double slabSunk = -0.5;
  static const double slabRaised = quayHeight;

  /// The up axis of the scene.
  static final Vector3 up = Vector3(0, 0, 1);

  /// The depth of the floor under the point (x, y) of the water.
  static double floorDepth(double x, double y) {
    final edge = math.min(halfLength - x.abs(), halfWidth - y.abs());
    return 0.42 + 0.68 * _smoothstep(0, 2.4, edge);
  }

  /// The ripples of the water, shared by its materials.
  final WaterRipples ripples = WaterRipples();

  /// The collars of foam around the slabs and the crate, shared by the
  /// water's materials: one slot per slab, then the crate's (13 of 16).
  final WaterFoamSources collars = WaterFoamSources(
    capacity: WaterFoamSources.maxCapacity,
  );

  /// The water's surface.
  late final WaterMaterial water = _water();

  /// The water of the strip along the far wall (y = -[halfWidth]): the same
  /// water, whose band of foam stands still.
  late final WaterMaterial rimWater = _water(edgeFoamMotion: 0);

  /// The width of the strip of [rimWater], in rows of the water's grid
  /// (twelfths of a unit).
  static const int _rimRows = 5;

  WaterMaterial _water({double edgeFoamMotion = 1}) => WaterMaterial(
    upAxis: up,
    shallowColor: const Color(0xFF86E3F0),
    deepColor: const Color(0xFF1B78B0),
    foamColor: const Color(0xF2FFFFFF),
    waveAmplitude: 0.012,
    waveFrequency: 2.2,
    waveSpeed: math.pi / 2,
    steepness: 0.3,
    rippleStrength: 0,
    foamThreshold: 1,
    fresnelPower: 4,
    specularStrength: 0.9,
    specularPower: 220,
    opacity: 0.8,
    depthRange: 0.75,
    shallowOpacity: 0.1,
    causticStrength: 0.25,
    causticScale: _causticScale,
    causticColor: const Color(0xFFE6FFFA),
    sparkleStrength: 1.2,
    sparkleScale: 0.32,
    detailStrength: 0.6,
    detailScale: 1.1,
    animationPeriod: _period,
    ripples: ripples,
    foamSources: collars,
    edgeFoamMotion: edgeFoamMotion,
  )..translucentOrder = -1; // under the splashes, whatever their distance

  /// The body of water the submerged surfaces honour.
  late final WaterVolumeSettings volume = WaterVolumeSettings(
    up: up,
    shallowColor: const Color(0xFFCDF6FF),
    deepColor: const Color(0xFF17669A),
    absorption: 1.05,
    causticStrength: 0.85,
    causticScale: _causticScale,
    animationPeriod: _period,
    waterlineWidth: 0.045,
    bounds: Aabb3.minMax(
      Vector3(-halfLength - 0.02, -halfWidth - 0.02, -5),
      Vector3(halfLength + 0.02, halfWidth + 0.02, 1),
    ),
  );

  static const double _causticScale = 0.62;
  static const double _period = 4;

  final StylizedMaterial _stone = StylizedMaterial(
    specularStrength: 0.12,
    rimStrength: 0.08,
  );
  final StylizedMaterial _lantern = StylizedMaterial(
    emissiveColor: const Color(0xFFFFD58A),
  );

  /// The slabs, 4 by 3, each a slab on a column.
  final List<MeshComponent> slabs = [];

  /// The crate floating on the water.
  late final MeshComponent crate;

  /// The pebble that drops in, see [dropPebble].
  late final MeshComponent pebble;

  /// The water's surface: one mesh, one draw.
  late final MeshComponent surface;

  /// The strip of water along the far wall, drawn with [rimWater]: one more
  /// draw.
  late final MeshComponent rimSurface;

  /// The droplets thrown up where the pebble lands; each one that falls
  /// back raises a small ring.
  late final ParticleSystem3D crown = ParticlePresets3D.splashCrown(
    up: up,
    size: 1.4,
    onGroundHit: _dropRing,
  );

  /// The foam spreading where the pebble lands.
  final ParticleSystem3D foam = ParticlePresets3D.foamBurst(up: up, size: 1.2);

  /// The mist over the pebble's splash.
  final ParticleSystem3D mist = ParticlePresets3D.mistPuff(up: up, size: 1.2);

  /// The foam that floods over a slab as it sinks under the surface.
  final ParticleSystem3D slabFoam = ParticlePresets3D.foamBurst(
    up: up,
    size: 2.4,
    capacity: 512,
  );

  /// The water running off each slab as it rises out of the water; each
  /// drop that falls back raises a small ring.
  final List<ParticleSystem3D> drips = [];

  late final LightComponent _sun;
  late final LightComponent _sky;
  final List<LightComponent> _lamps = [];
  final List<MeshComponent> _lanterns = [];

  /// How far the slabs are raised: `0` sunk, `1` at the height of the quay.
  /// Each slab follows a little after the one before it.
  double slabLift = 0;

  /// The lighting of the scene; assign it to change the time of day.
  PoolLighting get lighting => _lighting;
  PoolLighting _lighting = lighting;
  set lighting(PoolLighting value) {
    _lighting = value;
    _applyLighting();
  }

  double _time = 0;
  final List<double> _slabTops = [];
  double? _pebbleStart;
  final Vector3 _pebbleAt = Vector3.zero();
  bool _pebbleSplashed = false;
  int _crateBob = -1;
  double _lastDropRing = -1;
  final Vector3 _point = Vector3.zero();
  final Vector3 _axis = Vector3.zero();
  static final Vector3 _crateAxis = Vector3(1, 0.4, 0)..normalize();

  /// The components of the scene, lights included, to add to a world whose
  /// [World3D.waterVolume] is [volume] (see [install]).
  List<Component3D> build() {
    _sun = LightComponent.directional(
      direction: Vector3(-0.3, -0.6, -1),
      shadows: ShadowSettings(
        strength: 0.75,
        color: const Color(0xFF2B3A66),
        softness: 2,
      ),
    );
    _sky = LightComponent.hemisphere(
      up: up,
      skyColor: const Color(0xFFBFE4FF),
      groundColor: const Color(0xFF8C7B62),
    );
    // On the far walls, so that the water in front of them reflects them.
    for (final corner in [Vector3(-4.35, -0.9, 0), Vector3(0.9, -3.35, 0)]) {
      _lamps.add(
        LightComponent.point(
          position: corner + Vector3(0, 0, 1.75),
          color: const Color(0xFFFFB45E),
          intensity: 0,
          range: 7,
        ),
      );
    }
    final components = <Component3D>[
      _sun,
      _sky,
      ..._lamps,
      MeshComponent(mesh: _quay().mesh(_stone)),
      MeshComponent(mesh: _floor().mesh(_stone)),
      MeshComponent(mesh: _stones().mesh(_stone)),
      surface = MeshComponent(mesh: _waterMesh(_rimRows, _rows, water)),
      rimSurface = MeshComponent(mesh: _waterMesh(0, _rimRows, rimWater)),
    ];

    final slabMesh = _slab().mesh(_stone);
    for (var j = 0; j < 3; j++) {
      for (var i = 0; i < 4; i++) {
        final slab = MeshComponent(
          mesh: slabMesh,
          position: Vector3(-1.65 + i * 1.1, -1.1 + j * 1.1, slabSunk),
        );
        slabs.add(slab);
        _slabTops.add(slabSunk);
        collars.addRectangle(
          slab.position,
          halfLength: 0.475,
          halfWidth: 0.475,
          strength: 0,
        );
        drips.add(
          ParticlePresets3D.runoffDrips(
            width: 0.95,
            depth: 0.95,
            up: up,
            capacity: 192,
            rate: 170,
            duration: 1.2,
            seed: 7 + slabs.length,
            onGroundHit: _dropRing,
          ),
        );
      }
    }
    components
      ..addAll(slabs)
      ..addAll(drips)
      ..addAll([crown, foam, mist, slabFoam]);

    crate = MeshComponent(
      mesh: _crate().mesh(_stone),
      position: Vector3(2.75, 1.8, 0),
    );
    _crateCollar = collars.addRectangle(
      crate.position,
      halfLength: 0.21,
      halfWidth: 0.21,
      cornerRadius: 0.04,
      width: 0.2,
      strength: 0.8,
    );
    pebble = MeshComponent(
      mesh: _pebble().mesh(_stone),
      position: Vector3(0, 0, -20),
    );
    final lanternMesh = _lamp().mesh(_lantern);
    for (final lamp in _lamps) {
      _lanterns.add(
        MeshComponent(
          mesh: lanternMesh,
          position: Vector3(lamp.position.x, lamp.position.y, quayHeight),
        ),
      );
    }
    components
      ..add(crate)
      ..add(pebble)
      ..addAll(_lanterns);
    _applyLighting();
    setTime(0);
    return components;
  }

  /// Adds the scene to [world] and makes [volume] its water volume.
  void install(World3D world) {
    world
      ..addAll(build())
      ..waterVolume = volume;
  }

  /// Drops the pebble at the point (x, y) of the water at [time]: it falls,
  /// raises a ripple where it lands, and sinks to the floor.
  void dropPebble(double x, double y, double time) {
    _pebbleStart = time;
    _pebbleAt.setValues(x, y, 0);
    _pebbleSplashed = false;
  }

  /// The time it takes a dropped pebble to reach the water.
  static const double pebbleFall = 0.55;

  late final int _crateCollar;

  /// Moves everything to [time], in seconds: the water, the slabs (to
  /// [slabLift]), the crate and the pebble; raises the ripples of what
  /// crossed the water since the last call.
  void setTime(double time) {
    final previous = _time;
    _time = time;
    water.time = time;
    rimWater.time = time;
    volume.time = time;

    for (var k = 0; k < slabs.length; k++) {
      final delay = k / (slabs.length - 1) * 0.35;
      final lift = _smoothstep(delay, delay + 0.65, slabLift);
      final top = slabSunk + (slabRaised - slabSunk) * lift;
      final before = _slabTops[k];
      final slab = slabs[k];
      if ((before < 0) != (top < 0) && time >= previous) {
        _point.setValues(slab.position.x, slab.position.y, 0);
        ripples.add(
          _point,
          time: time,
          strength: 0.7,
          radius: 0.42,
          speed: 0.75,
          wavelength: 0.26,
          lifetime: 1.6,
        );
        if (top >= 0) {
          // Out of the water: it runs off the edges.
          drips[k].start();
        } else {
          // Under it: the water floods over the top.
          slabFoam.burst(14, at: _point);
        }
      }
      _slabTops[k] = top;
      slab.position.z = top;
      // The drops fall from the edges of the top, wherever it is.
      drips[k].position.setValues(slab.position.x, slab.position.y, top);
      _slabCollar(k, top);
    }

    // The crate bobs and rolls a little on the water, and nudges a faint
    // ring out every bob.
    final bob = math.sin(time * math.pi);
    crate.position.z = -0.1 + 0.025 * bob;
    crate.rotation.setAxisAngle(
      _crateAxis,
      0.05 * math.sin(time * math.pi * 0.5 + 0.7),
    );
    collars.move(
      _crateCollar,
      crate.position,
      axis: crate.rotation.rotate(_axis..setValues(1, 0, 0)),
    );
    final cycle = (time / 2).floor();
    if (cycle != _crateBob && time >= previous) {
      _crateBob = cycle;
      _point.setValues(crate.position.x, crate.position.y, 0);
      ripples.add(
        _point,
        time: time,
        strength: 0.22,
        radius: 0.24,
        speed: 0.45,
        wavelength: 0.2,
        lifetime: 1.8,
      );
    }

    final start = _pebbleStart;
    if (start != null && time >= start) {
      final age = time - start;
      double z;
      if (age < pebbleFall) {
        final k = age / pebbleFall;
        z = 1.8 * (1 - k * k);
      } else {
        // Sinks to the floor, slowing down.
        final sinking = age - pebbleFall;
        final floor = -floorDepth(_pebbleAt.x, _pebbleAt.y) + 0.06;
        z = floor * (1 - math.exp(-sinking * 2.2));
        if (!_pebbleSplashed) {
          _pebbleSplashed = true;
          ripples.add(
            _pebbleAt,
            time: start + pebbleFall,
            strength: 1.1,
            speed: 0.85,
            wavelength: 0.2,
            trail: 4,
            lifetime: 2.6,
          );
          crown.burst(52, at: _pebbleAt);
          foam.burst(16, at: _pebbleAt);
          mist.burst(12, at: _pebbleAt);
        }
      }
      pebble.position.setValues(_pebbleAt.x, _pebbleAt.y, z);
    }
  }

  /// The collar of foam of the slab [k] whose top is at [top]: none while
  /// it is under the water, around its top while the top crosses the
  /// surface, closing in on its column once the top is out.
  void _slabCollar(int k, double top) {
    const plate = 0.16; // the thickness of the top
    final out = _smoothstep(plate, plate + 0.1, top);
    collars.setRectangle(
      k,
      slabs[k].position,
      halfLength: 0.475 + (0.17 - 0.475) * out,
      halfWidth: 0.475 + (0.17 - 0.475) * out,
      cornerRadius: 0.035 + (0.015 - 0.035) * out,
      width: 0.3 + (0.2 - 0.3) * out,
      strength: _smoothstep(-0.03, 0.04, top) * (1 - 0.15 * out),
    );
  }

  /// A faint, short ring where a drop falls back into the water, at most
  /// one every 45 ms: the rings take each other's places in [ripples]
  /// rather than those of the slabs and the pebble (see [WaterRipples.add]).
  void _dropRing(Vector3 position, double speed) {
    if (_time - _lastDropRing < 0.045 && _time >= _lastDropRing) {
      return;
    }
    _lastDropRing = _time;
    ripples.add(
      position,
      time: _time,
      strength: 0.18,
      speed: 0.32,
      wavelength: 0.07,
      trail: 2,
      lifetime: 0.7,
    );
  }

  void _applyLighting() {
    final dusk = _lighting == PoolLighting.dusk;
    final sun = _sun.source as DirectionalLight;
    // At dusk the sun is low behind the pool, so its glints cross the water
    // towards the viewer.
    sun
      ..direction = dusk ? Vector3(0.5, 0.78, -0.42) : Vector3(-0.3, -0.6, -1)
      ..color = dusk ? const Color(0xFFFF9C5C) : const Color(0xFFFFF4E2)
      ..intensity = dusk ? 0.55 : 0.62;
    (_sky.source as HemisphereLight)
      ..skyColor = dusk ? const Color(0xFF7180B8) : const Color(0xFFBFE4FF)
      ..groundColor = dusk ? const Color(0xFF3E3040) : const Color(0xFF8C7B62)
      ..intensity = dusk ? 0.42 : 0.5;
    for (final lamp in _lamps) {
      (lamp.source as PointLight).intensity = dusk ? 1.0 : 0;
    }
    _lantern.emissiveStrength = dusk ? 1 : 0.25;
    // The foam scatters the warm light of dusk and stays white, with a trace
    // of warmth.
    final tint = dusk ? 0.25 : 1.0;
    water.foamLightTint = tint;
    rimWater.foamLightTint = tint;
    volume.waterlineLightTint = tint;
  }

  PoolMeshBuilder _quay() {
    const hx = halfLength;
    const hy = halfWidth;
    const top = quayHeight;
    const wall = Color(0xFFD3C7B1);
    const coping = Color(0xFFF0E9DA);
    const paving = Color(0xFFDCD2BE);
    const grass = Color(0xFF86B85F);
    final b = PoolMeshBuilder();
    // The inner faces of the walls, from below the floor to the coping.
    const bottom = -1.4;
    for (final (min, max) in [
      (Vector3(-hx - 0.6, hy, bottom), Vector3(hx + 0.6, hy + 0.6, top)),
      (Vector3(-hx - 0.6, -hy - 0.6, bottom), Vector3(hx + 0.6, -hy, top)),
      (Vector3(hx, -hy, bottom), Vector3(hx + 0.6, hy, top)),
      (Vector3(-hx - 0.6, -hy, bottom), Vector3(-hx, hy, top)),
    ]) {
      b.box(min, max, wall, top: paving, footShade: 0.55);
    }
    // Coping stones along the rim, overhanging the water a little.
    const c = 0.55;
    const o = 0.07;
    for (var i = 0; i < 16; i++) {
      final x0 = -hx - c + i * (2 * hx + 2 * c) / 16;
      final x1 = x0 + (2 * hx + 2 * c) / 16 - 0.02;
      b
        ..bevelledBox(
          Vector3(x0, hy - o, top),
          Vector3(x1, hy + c - o, top + 0.08),
          0.025,
          wall,
          top: coping,
        )
        ..bevelledBox(
          Vector3(x0, -hy - c + o, top),
          Vector3(x1, -hy + o, top + 0.08),
          0.025,
          wall,
          top: coping,
        );
    }
    for (var i = 0; i < 12; i++) {
      final y0 = -hy + o + i * (2 * hy - 2 * o) / 12;
      final y1 = y0 + (2 * hy - 2 * o) / 12 - 0.02;
      b
        ..bevelledBox(
          Vector3(hx - o, y0, top),
          Vector3(hx + c - o, y1, top + 0.08),
          0.025,
          wall,
          top: coping,
        )
        ..bevelledBox(
          Vector3(-hx - c + o, y0, top),
          Vector3(-hx + o, y1, top + 0.08),
          0.025,
          wall,
          top: coping,
        );
    }
    // The paving around, and grass beyond.
    for (final (min, max) in [
      (Vector3(-7, hy + 0.6, -0.4), Vector3(7, 6, top)),
      (Vector3(-7, -6, -0.4), Vector3(7, -hy - 0.6, top)),
      (Vector3(hx + 0.6, -hy - 0.6, -0.4), Vector3(7, hy + 0.6, top)),
      (Vector3(-7, -hy - 0.6, -0.4), Vector3(-hx - 0.6, hy + 0.6, top)),
    ]) {
      b.box(min, max, paving, top: paving);
    }
    for (final (min, max) in [
      (Vector3(-14, 6, -0.4), Vector3(14, 14, top - 0.03)),
      (Vector3(-14, -14, -0.4), Vector3(14, -6, top - 0.03)),
      (Vector3(7, -6, -0.4), Vector3(14, 6, top - 0.03)),
      (Vector3(-14, -6, -0.4), Vector3(-7, 6, top - 0.03)),
    ]) {
      b.box(min, max, grass, top: grass);
    }
    return b;
  }

  PoolMeshBuilder _floor() {
    final b = PoolMeshBuilder();
    b.heightField(
      -halfLength,
      halfLength,
      -halfWidth,
      halfWidth,
      80,
      60,
      height: (x, y) => -floorDepth(x, y),
      color: (x, y) {
        // Large pale tiles with soft joints.
        final gx = (x + halfLength) / 1.0;
        final gy = (y + halfWidth) / 1.0;
        final jx = (gx - gx.roundToDouble()).abs();
        final jy = (gy - gy.roundToDouble()).abs();
        final joint = 1 - _smoothstep(0.0, 0.07, math.min(jx, jy));
        final tile = (gx.floor() * 7 + gy.floor() * 13) % 5 / 5.0;
        final shade = 0.94 + 0.06 * tile - 0.14 * joint;
        return Color.from(
          alpha: 1,
          red: 0.93 * shade,
          green: 0.89 * shade,
          blue: 0.78 * shade,
        );
      },
      occlusion: (x, y) {
        final edge = math.min(halfLength - x.abs(), halfWidth - y.abs());
        return 0.72 + 0.28 * _smoothstep(0, 0.5, edge);
      },
    );
    return b;
  }

  /// The stepping stones and a rock: (x, y, radius, top).
  static const List<(double, double, double, double)> stepping = [
    (-3.25, 2.3, 0.3, 0.07),
    (-2.55, 1.95, 0.28, 0.03),
    (-3.1, 1.2, 0.3, -0.04),
    (-3.3, 0.4, 0.27, 0.09),
    (3.15, -1.95, 0.46, 0.16),
  ];

  PoolMeshBuilder _stones() {
    final b = PoolMeshBuilder();
    for (final (i, (x, y, r, top)) in stepping.indexed) {
      final bottom = -floorDepth(x, y) - 0.05;
      b.prism(
        Vector3(x, y, bottom),
        r,
        top - bottom,
        i == 4 ? const Color(0xFF9C978E) : const Color(0xFFB2ADA2),
        top: i == 4 ? const Color(0xFFB5B0A6) : const Color(0xFFCFCAC0),
        sides: i == 4 ? 7 : 9,
        bevel: 0.05,
        phase: i * 0.7,
      );
    }
    return b;
  }

  PoolMeshBuilder _slab() {
    const h = 0.475;
    final b = PoolMeshBuilder()
      ..bevelledBox(
        Vector3(-h, -h, -0.16),
        Vector3(h, h, 0),
        0.035,
        const Color(0xFFBDAE8F),
        top: const Color(0xFFE2D4B4),
        edge: const Color(0xFFEDE2C8),
      )
      ..box(
        Vector3(-0.16, -0.16, -2.6),
        Vector3(0.16, 0.16, -0.16),
        const Color(0xFFB4A586),
        footShade: 1,
      );
    return b;
  }

  PoolMeshBuilder _crate() {
    const h = 0.19;
    final b = PoolMeshBuilder()
      ..bevelledBox(
        Vector3(-h, -h, -h),
        Vector3(h, h, h),
        0.03,
        const Color(0xFFA8703F),
        top: const Color(0xFFC08850),
        footShade: 0.85,
      );
    return b;
  }

  PoolMeshBuilder _pebble() {
    final b = PoolMeshBuilder()
      ..prism(
        Vector3(0, 0, -0.04),
        0.07,
        0.08,
        const Color(0xFF7D7A75),
        top: const Color(0xFF96928B),
        sides: 6,
        bevel: 0.02,
      );
    return b;
  }

  PoolMeshBuilder _lamp() {
    final b = PoolMeshBuilder()
      ..box(
        Vector3(-0.07, -0.07, 0),
        Vector3(0.07, 0.07, 1.55),
        const Color(0xFF3A3F4B),
      )
      ..box(
        Vector3(-0.14, -0.14, 1.55),
        Vector3(0.14, 0.14, 1.85),
        const Color(0xFFFFE6B0),
        emissive: 1,
      )
      ..box(
        Vector3(-0.17, -0.17, 1.85),
        Vector3(0.17, 0.17, 1.92),
        const Color(0xFF3A3F4B),
      );
    return b;
  }

  static const int _columns = 96;
  static const int _rows = 72;

  /// The rows [from] to [to] of the water's surface over the pool, in
  /// [WaterMaterial.vertexLayout], drawn with [material]: each vertex knows
  /// the depth of the floor under it, foams along the walls and around the
  /// stones that break the surface, and calms down near the walls.
  Mesh _waterMesh(int from, int to, WaterMaterial material) {
    const columns = _columns;
    final rows = to - from;
    final positions = Float32List((columns + 1) * (rows + 1) * 3);
    final depths = Float32List((columns + 1) * (rows + 1));
    final foam = Float32List((columns + 1) * (rows + 1));
    final calm = Float32List((columns + 1) * (rows + 1));
    var k = 0;
    for (var j = from; j <= to; j++) {
      for (var i = 0; i <= columns; i++) {
        final x = -halfLength + 2 * halfLength * i / columns;
        final y = -halfWidth + 2 * halfWidth * j / _rows;
        positions
          ..[k * 3] = x
          ..[k * 3 + 1] = y
          ..[k * 3 + 2] = 0;
        depths[k] = floorDepth(x, y);
        final edge = math.min(halfLength - x.abs(), halfWidth - y.abs());
        var mask = 1 - _smoothstep(0, 0.45, edge);
        for (final (sx, sy, r, top) in stepping) {
          if (top > 0) {
            final d = math.sqrt((x - sx) * (x - sx) + (y - sy) * (y - sy)) - r;
            mask = math.max(mask, 1 - _smoothstep(0, 0.32, d));
          }
        }
        foam[k] = mask;
        calm[k] = 0.85 * (1 - _smoothstep(0, 0.6, edge));
        k++;
      }
    }
    final indices = <int>[];
    for (var j = 0; j < rows; j++) {
      for (var i = 0; i < columns; i++) {
        final a = j * (columns + 1) + i;
        indices.addAll([a, a + 1, a + columns + 2, a, a + columns + 2]);
        indices.add(a + columns + 1);
      }
    }
    return Mesh()..addSurface(
      WaterMaterial.buildSurface(
        positions: positions,
        depths: depths,
        foam: foam,
        calm: calm,
        indices: indices,
        material: material,
      ),
    );
  }

  static double _smoothstep(double edge0, double edge1, double x) {
    final t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
    return t * t * (3 - 2 * t);
  }
}
