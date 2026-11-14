import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/game/game.dart';
import 'package:flutter/painting.dart';

/// Visual & physical archetype for particles simulated by [ParticlePool3D].
enum ParticleKind3D() {
  /// Additive glowing diamond spark.
  spark,

  /// Tumbling 3D gold coin with specular flip modulation & ground bounce.
  coin,

  /// Fluttering celebratory confetti ribbon with high air drag & spin.
  confetti,

  /// Soft rising dust puff on footsteps and impacts.
  dust,
}

/// Zero-allocation Struct-of-Arrays (SoA) 3D particle engine simulating up to
/// [capacity] particles in `(x, y, z)` world coordinates with gravity, air
/// drag, elastic ground bounce on `z = 0`, contact micro-shadows, and batched
/// `Canvas.drawVertices` rendering.
class ParticlePool3D({
  this.capacity = 384,
  int randomSeed = 90210,
}) {
  /// Maximum number of simultaneous live 3D particles.
  final int capacity;

  late final Float32List _wx = Float32List(capacity);
  late final Float32List _wy = Float32List(capacity);
  late final Float32List _wz = Float32List(capacity);
  late final Float32List _vx = Float32List(capacity);
  late final Float32List _vy = Float32List(capacity);
  late final Float32List _vz = Float32List(capacity);
  late final Float32List _gravity = Float32List(capacity);
  late final Float32List _bounce = Float32List(capacity);
  late final Float32List _drag = Float32List(capacity);
  late final Float32List _size = Float32List(capacity);
  late final Float32List _age = Float32List(capacity);
  late final Float32List _life = Float32List(capacity);
  late final Float32List _angle = Float32List(capacity);
  late final Float32List _spin = Float32List(capacity);
  late final Int32List _argb = Int32List(capacity);
  late final Uint8List _kind = Uint8List(capacity);

  late final Float32List _shadowPos = Float32List(capacity * 12);
  late final Int32List _shadowCol = Int32List(capacity * 6);
  late final Float32List _alphaPos = Float32List(capacity * 12);
  late final Int32List _alphaCol = Int32List(capacity * 6);
  late final Float32List _addPos = Float32List(capacity * 12);
  late final Int32List _addCol = Int32List(capacity * 6);

  final Paint _alphaPaint = Paint()..isAntiAlias = true;
  final Paint _addPaint = Paint()
    ..isAntiAlias = true
    ..blendMode = BlendMode.plus;
  final math.Random _rng = math.Random(randomSeed);

  int _activeCount = 0;
  int _cursor = 0;

  /// Number of GPU `drawVertices` calls submitted during the last [render].
  int lastDrawCalls = 0;

  /// Current number of active 3D particles.
  int get activeCount => _activeCount;

  /// Clears all active particles immediately.
  void clear() {
    if (_activeCount > 0) {
      Game.notifyVisualMutation();
    }
    _activeCount = 0;
    _cursor = 0;
  }

  /// Spawns a single 3D particle in `(x, y, z)` world coordinates.
  void spawn({
    required double x,
    required double y,
    required double vx,
    required double vy,
    required double vz,
    required Color color,
    double z = 0.06,
    double gravity = 6.8,
    double bounce = 0.42,
    double drag = 1.2,
    double size = 3.2,
    double life = 0.75,
    double angle = 0.0,
    double spin = 4.0,
    ParticleKind3D kind = ParticleKind3D.spark,
  }) {
    final int slot;
    if (_activeCount < capacity) {
      slot = _activeCount++;
    } else {
      slot = _cursor;
      _cursor = (_cursor + 1) % capacity;
    }

    _wx[slot] = x;
    _wy[slot] = y;
    _wz[slot] = z;
    _vx[slot] = vx;
    _vy[slot] = vy;
    _vz[slot] = vz;
    _gravity[slot] = gravity;
    _bounce[slot] = bounce;
    _drag[slot] = drag;
    _size[slot] = size;
    _age[slot] = 0.0;
    _life[slot] = math.max(0.08, life);
    _angle[slot] = angle;
    _spin[slot] = spin;
    _argb[slot] = color.toARGB32();
    _kind[slot] = kind.index;
    Game.notifyVisualMutation();
  }

  /// Spawns a fountain of 3D tumbling gold coins that bounce on `z = 0`.
  void burstCoins(double x, double y, {int count = 14, double z = 0.14}) {
    for (var k = 0; k < count; k++) {
      final a =
          (k / math.max(1, count)) * math.pi * 2.0 +
          (_rng.nextDouble() - 0.5) * 0.45;
      final spd = 0.75 + _rng.nextDouble() * 1.35;
      spawn(
        x: x + (_rng.nextDouble() - 0.5) * 0.14,
        y: y + (_rng.nextDouble() - 0.5) * 0.14,
        z: z,
        vx: math.cos(a) * spd,
        vy: math.sin(a) * spd,
        vz: 2.35 + _rng.nextDouble() * 1.65,
        gravity: 7.8,
        bounce: 0.58,
        drag: 0.85,
        size: 3.1 + _rng.nextDouble() * 1.1,
        life: 0.95 + _rng.nextDouble() * 0.35,
        angle: _rng.nextDouble() * math.pi * 2.0,
        spin: 9.0 + _rng.nextDouble() * 7.0,
        color: k.isEven ? const Color(0xFFFFD54F) : const Color(0xFFFFF3C4),
        kind: ParticleKind3D.coin,
      );
    }
  }

  /// Spawns construction sparks + optional celebratory confetti ribbons.
  void burstCelebration(
    double x,
    double y, {
    required Color color,
    bool confetti = false,
  }) {
    final sparkCount = confetti ? 22 : 12;
    for (var k = 0; k < sparkCount; k++) {
      final a = _rng.nextDouble() * math.pi * 2.0;
      final spd = 0.55 + _rng.nextDouble() * (confetti ? 1.85 : 1.15);
      spawn(
        x: x + (_rng.nextDouble() - 0.5) * 0.32,
        y: y + (_rng.nextDouble() - 0.5) * 0.32,
        z: (confetti ? 0.45 : 0.22) + _rng.nextDouble() * 0.30,
        vx: math.cos(a) * spd,
        vy: math.sin(a) * spd,
        vz: 1.6 + _rng.nextDouble() * (confetti ? 2.4 : 1.4),
        gravity: 5.4,
        bounce: 0.44,
        drag: 1.35,
        size: 2.4 + _rng.nextDouble() * 1.6,
        life: 0.68 + _rng.nextDouble() * 0.38,
        angle: a,
        spin: 6.5,
        color: k.isEven ? color : const Color(0xFFFFE082),
      );
    }

    if (confetti) {
      const palette = <Color>[
        Color(0xFFFFD54F),
        Color(0xFF4FC3F7),
        Color(0xFFFF7043),
        Color(0xFF81C784),
      ];
      for (var k = 0; k < 18; k++) {
        final a = _rng.nextDouble() * math.pi * 2.0;
        final spd = 0.65 + _rng.nextDouble() * 1.55;
        spawn(
          x: x,
          y: y,
          z: 0.75 + _rng.nextDouble() * 0.35,
          vx: math.cos(a) * spd,
          vy: math.sin(a) * spd,
          vz: 1.8 + _rng.nextDouble() * 1.9,
          gravity: 2.6,
          bounce: 0.22,
          drag: 2.4,
          size: 3.0 + _rng.nextDouble() * 1.3,
          life: 1.25 + _rng.nextDouble() * 0.45,
          angle: _rng.nextDouble() * math.pi,
          spin: 8.0 - _rng.nextDouble() * 16.0,
          color: palette[k % palette.length],
          kind: ParticleKind3D.confetti,
        );
      }
    }
  }

  /// Spawns a radial 3D shock ring of sparks and dust on ground impact.
  void burstImpact(
    double x,
    double y, {
    required Color color,
    bool hard = true,
  }) {
    final count = hard ? 16 : 8;
    for (var k = 0; k < count; k++) {
      final a = (k / count) * math.pi * 2.0 + (_rng.nextDouble() - 0.5) * 0.28;
      final spd = (hard ? 1.35 : 0.75) + _rng.nextDouble() * 0.95;
      spawn(
        x: x,
        y: y,
        z: 0.05,
        vx: math.cos(a) * spd,
        vy: math.sin(a) * spd,
        vz: (hard ? 1.45 : 0.85) + _rng.nextDouble() * 0.95,
        gravity: 6.5,
        bounce: 0.46,
        drag: 1.8,
        size: (hard ? 2.8 : 2.1) + _rng.nextDouble() * 1.2,
        life: 0.48 + _rng.nextDouble() * 0.26,
        angle: a,
        spin: 7.0,
        color: color,
        kind: k % 3 == 0 ? ParticleKind3D.dust : ParticleKind3D.spark,
      );
    }
  }

  /// Spawns a miniature puff of golden dust under a stepping figurine.
  void burstDust(double x, double y) {
    for (var k = 0; k < 6; k++) {
      final a = (k / 6.0) * math.pi * 2.0 + _rng.nextDouble() * 0.4;
      final spd = 0.38 + _rng.nextDouble() * 0.42;
      spawn(
        x: x,
        y: y,
        z: 0.03,
        vx: math.cos(a) * spd,
        vy: math.sin(a) * spd,
        vz: 0.58 + _rng.nextDouble() * 0.45,
        gravity: 3.4,
        bounce: 0.18,
        drag: 2.6,
        size: 2.2 + _rng.nextDouble() * 0.9,
        life: 0.36 + _rng.nextDouble() * 0.14,
        angle: a,
        spin: 3.0,
        color: const Color(0xBBFFE082),
        kind: ParticleKind3D.dust,
      );
    }
  }

  /// Advances 3D particle trajectories, drag, and `z = 0` ground collisions.
  void update(double dt) {
    if (_activeCount == 0 || dt <= 0.0) {
      return;
    }
    Game.notifyVisualMutation();
    final step = dt.clamp(0.0, 0.05);

    var idx = 0;
    while (idx < _activeCount) {
      final nextAge = _age[idx] + step;
      if (nextAge >= _life[idx]) {
        final last = --_activeCount;
        if (idx != last) {
          _copySlot(last, idx);
        }
        continue;
      }

      _age[idx] = nextAge;
      final damp = math.max(0.0, 1.0 - _drag[idx] * step);
      var vx = _vx[idx] * damp;
      var vy = _vy[idx] * damp;
      var vz = _vz[idx] - _gravity[idx] * step;

      final wx = _wx[idx] + vx * step;
      final wy = _wy[idx] + vy * step;
      var wz = _wz[idx] + vz * step;

      if (wz < 0.0) {
        wz = 0.0;
        if (vz < -0.18) {
          vz = -vz * _bounce[idx];
          vx *= 0.74;
          vy *= 0.74;
        } else {
          vz = 0.0;
          vx *= 0.86;
          vy *= 0.86;
        }
      }

      _wx[idx] = wx;
      _wy[idx] = wy;
      _wz[idx] = wz;
      _vx[idx] = vx;
      _vy[idx] = vy;
      _vz[idx] = vz;
      _angle[idx] = _angle[idx] + _spin[idx] * step;
      idx++;
    }
  }

  void _copySlot(int src, int dst) {
    _wx[dst] = _wx[src];
    _wy[dst] = _wy[src];
    _wz[dst] = _wz[src];
    _vx[dst] = _vx[src];
    _vy[dst] = _vy[src];
    _vz[dst] = _vz[src];
    _gravity[dst] = _gravity[src];
    _bounce[dst] = _bounce[src];
    _drag[dst] = _drag[src];
    _size[dst] = _size[src];
    _age[dst] = _age[src];
    _life[dst] = _life[src];
    _angle[dst] = _angle[src];
    _spin[dst] = _spin[src];
    _argb[dst] = _argb[src];
    _kind[dst] = _kind[src];
  }

  /// Projects and draws all active 3D particles + contact micro-shadows using
  /// [camera] in at most 3 batched `Canvas.drawVertices` calls.
  void render(
    Canvas canvas,
    CameraRig3D camera, {
    double ambientBrightness = 1.0,
  }) {
    if (_activeCount == 0) {
      lastDrawCalls = 0;
      return;
    }

    final focal = camera.focalScalePx;
    final centerY = camera.groundOriginY;
    final perspStrength = camera.perspectiveStrength;
    final zPx = camera.zPixelsPerCell;
    final camX = camera.camWorldX;
    final camY = camera.camWorldY;

    var shadowVerts = 0;
    var alphaVerts = 0;
    var addVerts = 0;

    for (var k = 0; k < _activeCount; k++) {
      final progress = (_age[k] / _life[k]).clamp(0.0, 1.0);
      final fade = (1.0 - progress * progress).clamp(0.0, 1.0);
      if (fade <= 0.02) {
        continue;
      }

      final wx = _wx[k];
      final wy = _wy[k];
      final wz = _wz[k];
      final kind = _kind[k];
      final baseSize = _size[k];
      final ang = _angle[k];

      final gsx = (camera.rightX * wx + camera.rightY * wy) * focal;
      final gsy = centerY - (camera.upX * wx + camera.upY * wy) * focal;

      if ((kind == 1 || kind == 2) && wz < 1.8) {
        final shFade = (1.0 - wz * 0.55).clamp(0.15, 1.0) * fade;
        final shAlpha = (shFade * 88.0).round().clamp(0, 120);
        if (shAlpha > 4) {
          final rx = baseSize * (0.85 + wz * 0.25);
          final ry = rx * 0.50;
          final shCol = (shAlpha << 24) | 0x00100D1A;
          _writeDiamondQuad(
            _shadowPos,
            _shadowCol,
            shadowVerts,
            gsx,
            gsy,
            rx,
            ry,
            0.0,
            shCol,
          );
          shadowVerts += 6;
        }
      }

      final persp = wz * perspStrength;
      final sx = gsx + (gsx - camX) * persp;
      final sy = gsy - zPx * wz + (gsy - camY) * persp * 0.55;

      final rawCol = _argb[k];
      final baseA = (rawCol >>> 24) & 0xFF;
      var r = (rawCol >>> 16) & 0xFF;
      var g = (rawCol >>> 8) & 0xFF;
      var b = rawCol & 0xFF;

      if (kind == 0) {
        final rad = baseSize * (0.45 + 0.55 * fade);
        final aByte = (baseA * fade).round().clamp(0, 255);
        final col = (aByte << 24) | (r << 16) | (g << 8) | b;
        _writeDiamondQuad(
          _addPos,
          _addCol,
          addVerts,
          sx,
          sy,
          rad * 1.35,
          rad * 0.68,
          ang,
          col,
        );
        addVerts += 6;
      } else {
        double rx;
        double ry;
        var quadAngle = ang;
        if (kind == 1) {
          final flip = math.cos(ang).abs();
          rx = baseSize;
          ry = baseSize * (0.28 + 0.64 * flip);
          quadAngle = ang * 0.25;
          final glint = (0.72 + 0.52 * flip) * ambientBrightness;
          r = (r * glint).round().clamp(0, 255);
          g = (g * glint).round().clamp(0, 255);
          b = (b * glint).round().clamp(0, 255);
        } else if (kind == 2) {
          final flutter = 0.35 + 0.65 * math.sin(ang * 1.4).abs();
          rx = baseSize * 1.15;
          ry = baseSize * 0.55 * flutter;
        } else {
          final grow = 0.75 + 0.85 * progress;
          rx = baseSize * grow;
          ry = baseSize * grow * 0.72;
        }
        final aByte = (baseA * fade).round().clamp(0, 255);
        final col = (aByte << 24) | (r << 16) | (g << 8) | b;
        _writeDiamondQuad(
          _alphaPos,
          _alphaCol,
          alphaVerts,
          sx,
          sy,
          rx,
          ry,
          quadAngle,
          col,
        );
        alphaVerts += 6;
      }
    }

    var calls = 0;
    if (shadowVerts > 0) {
      final verts = ui.Vertices.raw(
        ui.VertexMode.triangles,
        Float32List.sublistView(_shadowPos, 0, shadowVerts * 2),
        colors: Int32List.sublistView(_shadowCol, 0, shadowVerts),
      );
      canvas.drawVertices(verts, BlendMode.dst, _alphaPaint);
      verts.dispose();
      calls++;
    }

    if (alphaVerts > 0) {
      final verts = ui.Vertices.raw(
        ui.VertexMode.triangles,
        Float32List.sublistView(_alphaPos, 0, alphaVerts * 2),
        colors: Int32List.sublistView(_alphaCol, 0, alphaVerts),
      );
      canvas.drawVertices(verts, BlendMode.dst, _alphaPaint);
      verts.dispose();
      calls++;
    }

    if (addVerts > 0) {
      final verts = ui.Vertices.raw(
        ui.VertexMode.triangles,
        Float32List.sublistView(_addPos, 0, addVerts * 2),
        colors: Int32List.sublistView(_addCol, 0, addVerts),
      );
      canvas.drawVertices(verts, BlendMode.dst, _addPaint);
      verts.dispose();
      calls++;
    }

    lastDrawCalls = calls;
  }

  static void _writeDiamondQuad(
    Float32List posBuf,
    Int32List colBuf,
    int vertOffset,
    double cx,
    double cy,
    double rx,
    double ry,
    double angle,
    int argb,
  ) {
    final ca = math.cos(angle);
    final sa = math.sin(angle);

    final ux = ca * rx;
    final uy = sa * rx;
    final vx = -sa * ry;
    final vy = ca * ry;

    final x0 = cx + ux;
    final y0 = cy + uy;
    final x1 = cx + vx;
    final y1 = cy + vy;
    final x2 = cx - ux;
    final y2 = cy - uy;
    final x3 = cx - vx;
    final y3 = cy - vy;

    final p = vertOffset * 2;
    posBuf[p] = x0;
    posBuf[p + 1] = y0;
    posBuf[p + 2] = x1;
    posBuf[p + 3] = y1;
    posBuf[p + 4] = x2;
    posBuf[p + 5] = y2;

    posBuf[p + 6] = x0;
    posBuf[p + 7] = y0;
    posBuf[p + 8] = x2;
    posBuf[p + 9] = y2;
    posBuf[p + 10] = x3;
    posBuf[p + 11] = y3;

    colBuf[vertOffset] = argb;
    colBuf[vertOffset + 1] = argb;
    colBuf[vertOffset + 2] = argb;
    colBuf[vertOffset + 3] = argb;
    colBuf[vertOffset + 4] = argb;
    colBuf[vertOffset + 5] = argb;
  }
}
