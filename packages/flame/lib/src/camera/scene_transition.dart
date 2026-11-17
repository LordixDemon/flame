import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/animation.dart' show Curve, Curves;
import 'package:flutter/painting.dart' show Alignment;

/// Base visual transition compositing an outgoing camera snapshot (`ui.Image`)
/// over the live incoming scene across [duration] seconds without requiring
/// per-frame `Canvas.saveLayer` allocations.
///
/// The snapshot is captured at [capturePixelRatio] texels per logical viewport
/// pixel. Leave it `null` (the default) to capture at the game's effective
/// device pixel ratio, so the outgoing frame is exactly as sharp as the live
/// scene it replaces; pass an explicit value (for example `1.0`) to trade
/// sharpness for a smaller texture.
///
/// When [aboveViewportHud] is `true` the snapshot includes the viewport (HUD)
/// components and is drawn above them; otherwise it only covers the world.
abstract class const SceneTransition({
  final double duration = 0.4,
  final Curve curve = Curves.easeInOutCubic,
  final double? capturePixelRatio,
  final bool aboveViewportHud = false,
}) {
  this
    : assert(duration >= 0, 'duration must be non-negative: $duration'),
      assert(
        capturePixelRatio == null || capturePixelRatio > 0,
        'capturePixelRatio must be positive: $capturePixelRatio',
      );

  /// Composites [outgoingSnapshot] onto [canvas] covering [viewportBounds] at
  /// normalized curved [progress] in `[0.0 .. 1.0]`.
  void renderTransition(
    ui.Canvas canvas,
    ui.Image outgoingSnapshot,
    ui.Rect viewportBounds,
    double progress,
  );
}

/// Smoothly dissolves from the captured outgoing frame into the live incoming
/// world using a single modulated `Canvas.drawImageRect` call (zero
/// `saveLayer`).
class const CrossFadeSceneTransition({
  super.duration = 0.4,
  super.curve = Curves.easeInOutCubic,
  super.capturePixelRatio,
  super.aboveViewportHud = false,
  final ui.Color? flashTint,
}) extends SceneTransition {
  static final ui.Paint _imagePaint = ui.Paint()
    ..filterQuality = ui.FilterQuality.low;
  static final ui.Paint _flashPaint = ui.Paint();

  @override
  void renderTransition(
    ui.Canvas canvas,
    ui.Image outgoingSnapshot,
    ui.Rect viewportBounds,
    double progress,
  ) {
    final outgoingAlpha = (1.0 - progress).clamp(0.0, 1.0);
    if (outgoingAlpha > 0.001) {
      final src = ui.Rect.fromLTWH(
        0,
        0,
        outgoingSnapshot.width.toDouble(),
        outgoingSnapshot.height.toDouble(),
      );
      _imagePaint.color = ui.Color.fromRGBO(255, 255, 255, outgoingAlpha);
      canvas.drawImageRect(outgoingSnapshot, src, viewportBounds, _imagePaint);
    }
    final tint = flashTint;
    if (tint != null) {
      // Bell-curve flash peaking at mid-transition (progress == 0.5).
      final bell = 4.0 * progress * (1.0 - progress);
      final alpha = (tint.a * bell).clamp(0.0, 1.0);
      if (alpha > 0.002) {
        _flashPaint.color = tint.withValues(alpha: alpha);
        canvas.drawRect(viewportBounds, _flashPaint);
      }
    }
  }
}

/// Reveals the incoming world through an expanding circular iris centered at
/// [center] using an even-odd clip path (zero `Canvas.saveLayer`).
class CircularRevealSceneTransition({
  super.duration = 0.5,
  super.curve = Curves.easeOutCubic,
  super.capturePixelRatio,
  super.aboveViewportHud = false,
  final Alignment center = Alignment.center,
  final ui.Color? ringColor,
  final double ringStrokeWidth = 2.5,
}) extends SceneTransition {
  final ui.Path _clipPath = ui.Path()..fillType = ui.PathFillType.evenOdd;
  final ui.Paint _imagePaint = ui.Paint()..filterQuality = ui.FilterQuality.low;
  final ui.Paint _ringPaint = ui.Paint()..style = ui.PaintingStyle.stroke;

  @override
  void renderTransition(
    ui.Canvas canvas,
    ui.Image outgoingSnapshot,
    ui.Rect viewportBounds,
    double progress,
  ) {
    final p = progress.clamp(0.0, 1.0);
    if (p >= 0.9999) {
      return;
    }
    final cx =
        viewportBounds.left + viewportBounds.width * (center.x * 0.5 + 0.5);
    final cy =
        viewportBounds.top + viewportBounds.height * (center.y * 0.5 + 0.5);
    final dx = math.max(cx - viewportBounds.left, viewportBounds.right - cx);
    final dy = math.max(cy - viewportBounds.top, viewportBounds.bottom - cy);
    final maxRadius = math.sqrt(dx * dx + dy * dy);
    final radius = maxRadius * p;

    _clipPath
      ..reset()
      ..fillType = ui.PathFillType.evenOdd
      ..addRect(viewportBounds);
    if (radius > 0.1) {
      _clipPath.addOval(
        ui.Rect.fromCircle(center: ui.Offset(cx, cy), radius: radius),
      );
    }

    final src = ui.Rect.fromLTWH(
      0,
      0,
      outgoingSnapshot.width.toDouble(),
      outgoingSnapshot.height.toDouble(),
    );
    canvas.save();
    canvas.clipPath(_clipPath);
    canvas.drawImageRect(outgoingSnapshot, src, viewportBounds, _imagePaint);
    canvas.restore();

    final ring = ringColor;
    if (ring != null && radius > 0.5 && p < 0.99) {
      _ringPaint
        ..color = ring.withValues(alpha: (ring.a * (1.0 - p)).clamp(0.0, 1.0))
        ..strokeWidth = ringStrokeWidth;
      canvas.drawCircle(ui.Offset(cx, cy), radius, _ringPaint);
    }
  }
}

/// Custom GPU [ui.FragmentShader]-driven transition binding `outgoingSnapshot`
/// to sampler `0` and `(width, height, progress)` to floats `0..2` (or via a
/// custom [configureShader] callback).
class ShaderSceneTransition({
  required final ui.FragmentShader shader,
  final void Function(
    ui.FragmentShader shader,
    ui.Image outgoingSnapshot,
    ui.Rect viewportBounds,
    double progress,
  )?
  configureShader,
  super.duration = 0.45,
  super.curve = Curves.easeInOutCubic,
  super.capturePixelRatio,
  super.aboveViewportHud = false,
}) extends SceneTransition {
  final ui.Paint _shaderPaint = ui.Paint();

  @override
  void renderTransition(
    ui.Canvas canvas,
    ui.Image outgoingSnapshot,
    ui.Rect viewportBounds,
    double progress,
  ) {
    final custom = configureShader;
    if (custom != null) {
      custom(shader, outgoingSnapshot, viewportBounds, progress);
    } else {
      shader
        ..setFloat(0, viewportBounds.width)
        ..setFloat(1, viewportBounds.height)
        ..setFloat(2, progress)
        ..setImageSampler(0, outgoingSnapshot);
    }
    _shaderPaint.shader = shader;
    canvas.save();
    canvas.translate(viewportBounds.left, viewportBounds.top);
    canvas.drawRect(
      ui.Rect.fromLTWH(0, 0, viewportBounds.width, viewportBounds.height),
      _shaderPaint,
    );
    canvas.restore();
    _shaderPaint.shader = null;
  }
}
