import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/canvas3d.dart';
import 'package:flutter_test/flutter_test.dart';

const int _w = 1200;
const int _h = 900;
const double _ox = 600;
const double _oy = 400;

/// Renders [pool] and returns the alpha-weighted centroid (in the camera's
/// canvas coordinates) of the pixels accepted by [accept], or `null` when
/// none match. Pixels are premultiplied RGBA.
Future<Offset?> _centroid(
  ParticlePool3D pool,
  CameraRig3D camera, {
  bool Function(int r, int g, int b, int a)? accept,
}) async {
  final recorder = PictureRecorder();
  final canvas = Canvas(recorder)..translate(_ox, _oy);
  pool.render(canvas, camera);
  final picture = recorder.endRecording();
  final image = picture.toImageSync(_w, _h);
  picture.dispose();
  final data = await image.toByteData();
  image.dispose();
  final px = data!.buffer.asUint8List();
  var sumA = 0.0;
  var sumX = 0.0;
  var sumY = 0.0;
  for (var y = 0; y < _h; y++) {
    for (var x = 0; x < _w; x++) {
      final o = (y * _w + x) * 4;
      final a = px[o + 3];
      if (a == 0) {
        continue;
      }
      if (accept != null && !accept(px[o], px[o + 1], px[o + 2], a)) {
        continue;
      }
      sumA += a;
      sumX += a * (x + 0.5);
      sumY += a * (y + 0.5);
    }
  }
  if (sumA == 0) {
    return null;
  }
  return Offset(sumX / sumA - _ox, sumY / sumA - _oy);
}

ParticlePool3D _oneParticle({
  required double x,
  required double y,
  required double z,
  ParticleKind3D kind = ParticleKind3D.dust,
}) {
  return ParticlePool3D(capacity: 4)..spawn(
    x: x,
    y: y,
    z: z,
    vx: 0,
    vy: 0,
    vz: 0,
    gravity: 0,
    drag: 0,
    spin: 0,
    size: 8,
    life: 100,
    color: const Color(0xFFFFFFFF),
    kind: kind,
  );
}

int _impacts(
  double dt, {
  required double seconds,
  double z = 0.5,
  double vz = 0,
  double gravity = 8.4,
  double bounce = 0.24,
  List<double>? speeds,
}) {
  var impacts = 0;
  final pool =
      ParticlePool3D(
        capacity: 8,
        onGroundImpact: (x, y, speed) {
          impacts++;
          speeds?.add(speed);
        },
      )..spawn(
        x: 0,
        y: 0,
        z: z,
        vx: 0,
        vy: 0,
        vz: vz,
        gravity: gravity,
        bounce: bounce,
        drag: 0.75,
        life: 60,
        color: const Color(0xFFFFFFFF),
        kind: ParticleKind3D.waterDrop,
      );
  final steps = (seconds / dt).round();
  for (var i = 0; i < steps; i++) {
    pool.update(dt);
  }
  return impacts;
}

void main() {
  group('ParticlePool3D projection follows the camera rig', () {
    test('rest pose: a particle is drawn at projectWorldPoint', () async {
      final camera = CameraRig3D()..update(camX: 0, camY: -18, zoom: 1);
      final drawn = await _centroid(_oneParticle(x: 6, y: 2, z: 0), camera);
      final expected = camera.projectWorldPoint(6, 2, 0);
      expect(drawn, isNotNull);
      expect((drawn! - expected).distance, lessThan(1.5));
      // The classic 2:1 grid position, i.e. unchanged by the anchoring fix.
      expect(expected.dx, closeTo((6 - 2) * 44.0, 1e-9));
      expect(expected.dy, closeTo((6 + 2) * 22.0 - 18.0, 1e-9));
    });

    test('orbit and pitch deltas move a particle exactly like a mesh '
        'anchored at the same world point', () async {
      const cases = <(double yaw, double pitch, double zoom, double z)>[
        (0.3, 0.2, 1.0, 0.0),
        (-0.24, -0.1, 1.0, 0.0),
        (-0.065, -0.105, 0.6, 1.5),
        (0.45, 0.28, 1.8, 2.5),
        (0.0, 0.0, 1.4, 2.0),
      ];
      for (final (yaw, pitch, zoom, z) in cases) {
        final camera = CameraRig3D()
          ..update(
            camX: 40,
            camY: 10,
            zoom: zoom,
            orbitYawDelta: yaw,
            pitchDelta: pitch,
          );
        final drawn = await _centroid(_oneParticle(x: 6, y: 2, z: z), camera);
        final expected = camera.projectWorldPoint(6, 2, z);
        expect(drawn, isNotNull);
        expect(
          (drawn! - expected).distance,
          lessThan(1.5),
          reason:
              'yaw=$yaw pitch=$pitch zoom=$zoom z=$z: drawn=$drawn '
              'expected=$expected',
        );
      }
    });

    test('the ground shadow lands under the particle for every camera '
        'delta', () async {
      final camera = CameraRig3D()
        ..update(
          camX: 0,
          camY: -18,
          zoom: 1,
          orbitYawDelta: 0.3,
          pitchDelta: 0.2,
        );
      // A coin casts a contact shadow; one unit up keeps the two apart.
      final pool = _oneParticle(x: 6, y: 2, z: 1, kind: ParticleKind3D.coin);

      final coin = await _centroid(
        pool,
        camera,
        accept: (r, g, b, a) => r > 120,
      );
      final shadow = await _centroid(
        pool,
        camera,
        accept: (r, g, b, a) => r < 40,
      );
      expect(coin, isNotNull);
      expect(shadow, isNotNull);
      expect(
        (coin! - camera.projectWorldPoint(6, 2, 1)).distance,
        lessThan(1.5),
      );
      expect(
        (shadow! - camera.projectWorldPoint(6, 2, 0)).distance,
        lessThan(1.5),
      );
    });

    test('perspective mode also matches projectWorldPoint', () async {
      final camera =
          CameraRig3D(projectionMode: CameraProjectionMode3D.perspective)
            ..update(
              camX: 0,
              camY: -18,
              zoom: 1,
              orbitYawDelta: 0.2,
              pitchDelta: -0.1,
            );
      final drawn = await _centroid(_oneParticle(x: 3, y: 1, z: 0.5), camera);
      final expected = camera.projectWorldPoint(3, 1, 0.5);
      expect(drawn, isNotNull);
      expect((drawn! - expected).distance, lessThan(1.5));
    });
  });

  group('ParticlePool3D ground contact', () {
    test('a dropped particle reports the same few impacts at every frame '
        'rate', () {
      // Restitution 0.24 from a height of 0.5 under gravity 8.4: lands at
      // about 2.9 units/s, rebounds at 0.70, then 0.17 (below the 0.18 rest
      // speed): two real impacts.
      for (final fps in <double>[20, 30, 45, 60, 120]) {
        final speeds = <double>[];
        final count = _impacts(1 / fps, seconds: 3, speeds: speeds);
        expect(
          count,
          inInclusiveRange(1, 3),
          reason: 'at $fps fps: $count impacts ($speeds)',
        );
        expect(speeds.first, closeTo(math.sqrt(2 * 8.4 * 0.5), 0.45));
      }
    });

    test('a particle lying on the ground never reports an impact', () {
      for (final fps in <double>[20, 30, 60]) {
        expect(_impacts(1 / fps, seconds: 3, z: 0), 0, reason: '$fps fps');
      }
    });

    test('impact speed is the contact speed, restitution scales the '
        'rebound', () {
      final speeds = <double>[];
      _impacts(
        1 / 240,
        seconds: 4,
        z: 2,
        gravity: 9,
        bounce: 0.5,
        speeds: speeds,
      );
      expect(speeds.length, greaterThanOrEqualTo(3));
      expect(speeds[0], closeTo(6.0, 0.2));
      expect(speeds[1], closeTo(3.0, 0.2));
      expect(speeds[2], closeTo(1.5, 0.2));
    });
  });

  group('ParticlePool3D edge cases', () {
    test('a zero-capacity pool ignores spawns', () {
      final pool = ParticlePool3D(capacity: 0);
      expect(
        () => pool
          ..burstImpact(0, 0, color: const Color(0xFFFFFFFF))
          ..update(1 / 60),
        returnsNormally,
      );
      expect(pool.activeCount, 0);
    });

    test('a NaN time step is ignored and particles still expire', () {
      final pool = ParticlePool3D(capacity: 8)
        ..burstDust(0, 0)
        ..update(double.nan);
      expect(pool.activeCount, 6);
      for (var i = 0; i < 60; i++) {
        pool.update(1 / 60);
      }
      expect(pool.activeCount, 0);
    });

    test('a full pool overwrites slots instead of dropping a burst', () {
      final pool = ParticlePool3D(capacity: 8);
      for (var i = 0; i < 5; i++) {
        pool.burstDust(0, 0);
      }
      expect(pool.activeCount, 8);
    });
  });
}
