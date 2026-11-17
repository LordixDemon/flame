import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/anchor.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/game/game.dart';
import 'package:flame/src/text/renderers/raster_font_atlas.dart';
import 'package:flutter/painting.dart';

/// Visual preset category for [FloatingCombatTextPool] popups.
enum CombatPopupKind() {
  /// Standard white/ivory HP damage number.
  damage,

  /// Enlarged gold/amber critical hit burst.
  criticalDamage,

  /// Emerald green HP recovery number.
  heal,

  /// Azure blue MP/SP recovery number.
  manaRestore,

  /// Cool grey `'MISS'` / `'DODGE'` callout.
  miss,

  /// Status/buff callout (`'+ATK'`, `'POISON'`).
  statusText,
}

/// Zero-allocation Struct-of-Arrays pool of floating RPG combat damage, heal,
/// critical, and status popups with automatic multi-hit cascade staggering.
///
/// When multiple hits land near the same world coordinate within
/// [clusterWindowSeconds], subsequent popups automatically stagger vertically
/// and fan slightly horizontally so multi-hit combos remain 100% legible.
///
/// Spawning, moving, expiring and clearing popups all report a visual mutation
/// (`Game.notifyVisualMutation`), so the pool keeps repainting under
/// `IdleRenderMode.onDemand` for as long as a popup is alive and for the frame
/// that removes the last one.
class FloatingCombatTextPool({
  this.fontAtlas,
  this.maxPopups = 128,
  this.clusterRadius = 28.0,
  this.clusterWindowSeconds = 0.45,
  this.staggerStepY = 18.0,
  this.staggerStepX = 10.0,
  super.priority,
  super.key,
}) extends Component {
  this : assert(maxPopups >= 1, 'maxPopups must be >= 1.');

  /// Optional [RasterFontAtlas] enabling single-`drawRawAtlas` rendering across
  /// all active popups.
  RasterFontAtlas? fontAtlas;

  /// Fixed pool slot capacity.
  final int maxPopups;

  /// Spatial distance threshold within which simultaneous hits stagger into a
  /// readable vertical cascade.
  final double clusterRadius;

  /// Maximum age of an existing popup to still count toward a multi-hit
  /// stagger cluster.
  final double clusterWindowSeconds;

  /// Vertical pixel offset added per stacked popup in a multi-hit cluster.
  final double staggerStepY;

  /// Alternating horizontal pixel fan added per stacked popup in a cluster.
  final double staggerStepX;

  final Uint8List _active = Uint8List(maxPopups);
  final Float64List _x = Float64List(maxPopups);
  final Float64List _y = Float64List(maxPopups);
  final Float64List _originX = Float64List(maxPopups);
  final Float64List _originY = Float64List(maxPopups);
  final Float64List _vx = Float64List(maxPopups);
  final Float64List _vy = Float64List(maxPopups);
  final Float64List _gravity = Float64List(maxPopups);
  final Float64List _age = Float64List(maxPopups);
  final Float64List _duration = Float64List(maxPopups);
  final Float64List _baseScale = Float64List(maxPopups);
  final Int32List _colors = Int32List(maxPopups);
  final List<String> _labels = List<String>.filled(maxPopups, '');

  final GlyphBatchRenderer _glyphBatch = GlyphBatchRenderer();
  TextPainter? _fallbackPainter;
  int _activeCount = 0;

  /// Number of currently live floating popups.
  int get activeCount => _activeCount;

  /// Number of `drawRawAtlas` calls issued in the last render pass (`1` when
  /// [fontAtlas] is supplied and `activeCount > 0`).
  int get lastFlushDrawCalls => _glyphBatch.lastFlushDrawCalls;

  /// Spawns a popup at `(worldX, worldY)` and returns its slot index.
  int spawn({
    required String text,
    required double worldX,
    required double worldY,
    CombatPopupKind kind = CombatPopupKind.damage,
    ui.Color? customColor,
    double? durationSeconds,
    double? scale,
  }) {
    var clusterRank = 0;
    final rSq = clusterRadius * clusterRadius;
    for (var i = 0; i < maxPopups; i++) {
      if (_active[i] == 0 || _age[i] > clusterWindowSeconds) {
        continue;
      }
      final dx = _originX[i] - worldX;
      final dy = _originY[i] - worldY;
      if (dx * dx + dy * dy <= rSq) {
        clusterRank++;
      }
    }

    final slot = _acquireSlot();
    final fanDir = clusterRank == 0
        ? 0.0
        : (clusterRank.isOdd ? 1.0 : -1.0) * ((clusterRank + 1) ~/ 2);
    final spawnX = worldX + fanDir * staggerStepX;
    final spawnY = worldY - clusterRank * staggerStepY;

    final defaultColor = switch (kind) {
      CombatPopupKind.damage => const ui.Color(0xFFFFF8EE),
      CombatPopupKind.criticalDamage => const ui.Color(0xFFFFCA3A),
      CombatPopupKind.heal => const ui.Color(0xFF56F08A),
      CombatPopupKind.manaRestore => const ui.Color(0xFF6BCBFF),
      CombatPopupKind.miss => const ui.Color(0xFFB4BECE),
      CombatPopupKind.statusText => const ui.Color(0xFFE4B8FF),
    };
    final defaultScale = kind == CombatPopupKind.criticalDamage ? 1.35 : 1.0;

    _active[slot] = 1;
    _originX[slot] = worldX;
    _originY[slot] = worldY;
    _x[slot] = spawnX;
    _y[slot] = spawnY;
    _vx[slot] = fanDir * 8.0;
    _vy[slot] = kind == CombatPopupKind.criticalDamage ? -78.0 : -58.0;
    _gravity[slot] = 115.0;
    _age[slot] = 0.0;
    _duration[slot] = durationSeconds ?? 0.85;
    _baseScale[slot] = scale ?? defaultScale;
    _colors[slot] = (customColor ?? defaultColor).toARGB32();
    _labels[slot] = text;
    Game.notifyVisualMutation();
    return slot;
  }

  /// Queries the live world `(x, y)` coordinates of popup [slot] for tests or
  /// attachment overlays.
  ({double x, double y, bool active}) inspectSlot(int slot) => (
    x: _x[slot],
    y: _y[slot],
    active: _active[slot] != 0,
  );

  /// Immediately clears all active popups.
  void clear() {
    if (_activeCount > 0) {
      Game.notifyVisualMutation();
    }
    _active.fillRange(0, maxPopups, 0);
    _activeCount = 0;
  }

  int _acquireSlot() {
    for (var i = 0; i < maxPopups; i++) {
      if (_active[i] == 0) {
        _activeCount++;
        return i;
      }
    }
    var oldestIdx = 0;
    var oldestAge = -1.0;
    for (var i = 0; i < maxPopups; i++) {
      if (_age[i] > oldestAge) {
        oldestAge = _age[i];
        oldestIdx = i;
      }
    }
    return oldestIdx;
  }

  @override
  void update(double dt) {
    if (dt <= 0.0 || _activeCount == 0) {
      return;
    }
    for (var i = 0; i < maxPopups; i++) {
      if (_active[i] == 0) {
        continue;
      }
      final nextAge = _age[i] + dt;
      if (nextAge >= _duration[i]) {
        _active[i] = 0;
        _activeCount--;
        continue;
      }
      _age[i] = nextAge;
      _vy[i] += _gravity[i] * dt;
      _x[i] += _vx[i] * dt;
      _y[i] += _vy[i] * dt;
    }
    // Every live popup moved or faded, and an expired one has to be painted
    // away.
    Game.notifyVisualMutation();
  }

  @override
  void render(ui.Canvas canvas) {
    if (_activeCount == 0) {
      return;
    }
    final atlas = fontAtlas;
    if (atlas != null && !atlas.isDisposed) {
      _glyphBatch.begin();
      for (var i = 0; i < maxPopups; i++) {
        if (_active[i] == 0) {
          continue;
        }
        final t = (_age[i] / _duration[i]).clamp(0.0, 1.0);
        final pop = t < 0.15 ? (0.7 + 0.5 * (t / 0.15)) : 1.0;
        final alpha = t > 0.70 ? ((1.0 - t) / 0.30).clamp(0.0, 1.0) : 1.0;
        final baseColor = ui.Color(_colors[i]);
        final color = baseColor.withValues(alpha: baseColor.a * alpha);
        _glyphBatch.addText(
          atlas,
          _labels[i],
          x: _x[i],
          y: _y[i],
          anchor: Anchor.center,
          scale: _baseScale[i] * pop,
          color: color,
        );
      }
      _glyphBatch.flush(canvas, atlas);
    } else {
      final painter = _fallbackPainter ??= TextPainter(
        textDirection: TextDirection.ltr,
      );
      for (var i = 0; i < maxPopups; i++) {
        if (_active[i] == 0) {
          continue;
        }
        final t = (_age[i] / _duration[i]).clamp(0.0, 1.0);
        final alpha = t > 0.70 ? ((1.0 - t) / 0.30).clamp(0.0, 1.0) : 1.0;
        final baseColor = ui.Color(_colors[i]);
        painter
          ..text = TextSpan(
            text: _labels[i],
            style: TextStyle(
              color: baseColor.withValues(alpha: baseColor.a * alpha),
              fontSize: 15 * _baseScale[i],
              fontWeight: FontWeight.bold,
            ),
          )
          ..layout()
          ..paint(
            canvas,
            ui.Offset(
              _x[i] - painter.width * 0.5,
              _y[i] - painter.height * 0.5,
            ),
          );
      }
    }
  }

  @override
  void onRemove() {
    _fallbackPainter?.dispose();
    _fallbackPainter = null;
    super.onRemove();
  }
}
