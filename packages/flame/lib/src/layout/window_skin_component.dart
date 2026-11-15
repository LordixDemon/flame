import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/layout/flex_grid_layout.dart';

/// Visual theme parameters for classic & modern JRPG [WindowSkinComponent]s.
class const WindowSkinStyle({
  this.backgroundColor = const ui.Color(0xE610182C),
  this.outerBorderColor = const ui.Color(0xFFE8DFC8),
  this.innerBorderColor = const ui.Color(0xFF4F628E),
  this.cursorFillColor = const ui.Color(0x446CA6FF),
  this.cursorBorderColor = const ui.Color(0xFFD6E8FF),
  this.textEnabledColor = const ui.Color(0xFFF6F8FF),
  this.textDisabledColor = const ui.Color(0xFF727C96),
  this.cornerRadius = 6.0,
  this.padding = const EdgePadding.all(10),
  this.cursorSmoothingRate = 22.0,
}) {
  /// Window interior fill color.
  final ui.Color backgroundColor;

  /// Crisp outer frame stroke color.
  final ui.Color outerBorderColor;

  /// Subtle inset bevel stroke color.
  final ui.Color innerBorderColor;

  /// Translucent fill of the gliding selection cursor.
  final ui.Color cursorFillColor;

  /// Highlight border of the gliding selection cursor.
  final ui.Color cursorBorderColor;

  /// Primary text color for selectable items.
  final ui.Color textEnabledColor;

  /// Dimmed text color for disabled or unaffordable items.
  final ui.Color textDisabledColor;

  /// Rounded frame corner radius in logical pixels.
  final double cornerRadius;

  /// Content inset inside the window border.
  final EdgePadding padding;

  /// Exponential glide speed of the selection cursor (`0` = instant snap).
  final double cursorSmoothingRate;
}

/// Entry descriptor for `CommandListWindow` and `PagedGridWindow`.
class const WindowCommandItem({
  required this.id,
  required this.label,
  this.rightBadge = '',
  this.helpDescription = '',
  this.enabled = true,
}) {
  /// Command/item identifier (e.g. `'attack'`, `'potion_hi'`).
  final String id;

  /// Primary display label.
  final String label;

  /// Optional right-aligned cost or quantity badge (`'12 MP'`, `'x5'`).
  final String rightBadge;

  /// Description pushed to a linked Help Window when highlighted.
  final String helpDescription;

  /// Whether confirming this item is currently allowed.
  final bool enabled;
}

/// Base RPG window container supporting classic vertical `openness` (`0..1`)
/// center-unfold animation, spring-gliding selection cursor, and top/bottom
/// scroll-more indicator arrows.
class WindowSkinComponent({
  this.skinStyle = const WindowSkinStyle(),
  double initialOpenness = 1.0,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.key,
}) extends PositionComponent {
  /// Frame, cursor, and typography colors.
  WindowSkinStyle skinStyle;

  double _openness = initialOpenness.clamp(0.0, 1.0);
  double _targetOpenness = initialOpenness.clamp(0.0, 1.0);
  double _openSpeed = 0.0;

  ui.Rect? _targetCursorRect;
  ui.Rect? _currentCursorRect;
  double _pulseClock = 0.0;

  /// Whether more content exists above the current scroll viewport.
  bool showScrollUpIndicator = false;

  /// Whether more content exists below the current scroll viewport.
  bool showScrollDownIndicator = false;

  final ui.Paint _bgPaint = ui.Paint();
  final ui.Paint _borderPaint = ui.Paint()..style = ui.PaintingStyle.stroke;
  final ui.Paint _cursorFillPaint = ui.Paint();
  final ui.Paint _cursorStrokePaint = ui.Paint()
    ..style = ui.PaintingStyle.stroke
    ..strokeWidth = 1.5;

  /// Current vertical unfold state in `[0.0 .. 1.0]` (`0.0` = closed flat,
  /// `1.0` = fully open).
  double get openness => _openness;

  set openness(double value) {
    _openness = value.clamp(0.0, 1.0);
    _targetOpenness = _openness;
    _openSpeed = 0.0;
  }

  /// Whether the window is completely open (`openness >= 0.999`).
  bool get isFullyOpen => _openness >= 0.999;

  /// Whether the window is completely closed (`openness <= 0.001`).
  bool get isFullyClosed => _openness <= 0.001;

  /// Current interpolated selection cursor rectangle in local coordinates.
  ui.Rect? get currentCursorRect => _currentCursorRect;

  /// Animates [openness] to `1.0` over [durationSeconds].
  void open({double durationSeconds = 0.16}) {
    _targetOpenness = 1.0;
    if (durationSeconds <= 1e-6) {
      _openness = 1.0;
      _openSpeed = 0.0;
    } else {
      _openSpeed = 1.0 / durationSeconds;
    }
  }

  /// Animates [openness] to `0.0` over [durationSeconds].
  void close({double durationSeconds = 0.14}) {
    _targetOpenness = 0.0;
    if (durationSeconds <= 1e-6) {
      _openness = 0.0;
      _openSpeed = 0.0;
    } else {
      _openSpeed = 1.0 / durationSeconds;
    }
  }

  /// Sets or updates the target selection cursor rectangle in local window
  /// coordinates.
  void setTargetCursorRect(ui.Rect? rect, {bool snap = false}) {
    _targetCursorRect = rect;
    if (rect == null) {
      _currentCursorRect = null;
      return;
    }
    if (snap ||
        _currentCursorRect == null ||
        skinStyle.cursorSmoothingRate <= 0.0) {
      _currentCursorRect = rect;
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (dt <= 0.0) {
      return;
    }
    _pulseClock += dt;

    if (_openSpeed > 0.0 && (_openness - _targetOpenness).abs() > 1e-5) {
      final step = _openSpeed * dt;
      if (_openness < _targetOpenness) {
        _openness = math.min(_targetOpenness, _openness + step);
      } else {
        _openness = math.max(_targetOpenness, _openness - step);
      }
      if ((_openness - _targetOpenness).abs() <= 1e-5) {
        _openness = _targetOpenness;
        _openSpeed = 0.0;
      }
    }

    final target = _targetCursorRect;
    final cur = _currentCursorRect;
    if (target != null && cur != null && skinStyle.cursorSmoothingRate > 0.0) {
      final alpha = 1.0 - math.exp(-skinStyle.cursorSmoothingRate * dt);
      _currentCursorRect = ui.Rect.lerp(cur, target, alpha);
    }
  }

  @override
  void renderTree(ui.Canvas canvas) {
    if (_openness <= 0.001 || size.x <= 0.0 || size.y <= 0.0) {
      return;
    }
    if (_openness < 0.999) {
      final midY = size.y * 0.5;
      canvas
        ..save()
        ..translate(position.x, position.y + midY)
        ..scale(1.0, _openness)
        ..translate(-position.x, -(position.y + midY));
      super.renderTree(canvas);
      canvas.restore();
      return;
    }
    super.renderTree(canvas);
  }

  @override
  void render(ui.Canvas canvas) {
    final w = size.x;
    final h = size.y;
    if (w <= 0.0 || h <= 0.0) {
      return;
    }
    final outerRect = ui.Rect.fromLTWH(0, 0, w, h);
    final outerRRect = ui.RRect.fromRectAndRadius(
      outerRect,
      ui.Radius.circular(skinStyle.cornerRadius),
    );

    _bgPaint.color = skinStyle.backgroundColor;
    canvas.drawRRect(outerRRect, _bgPaint);

    final innerRRect = outerRRect.deflate(2.5);
    _borderPaint
      ..color = skinStyle.innerBorderColor
      ..strokeWidth = 1.0;
    canvas.drawRRect(innerRRect, _borderPaint);

    _borderPaint
      ..color = skinStyle.outerBorderColor
      ..strokeWidth = 1.75;
    canvas.drawRRect(outerRRect.deflate(0.875), _borderPaint);

    if (_openness >= 0.85) {
      final curRect = _currentCursorRect;
      if (curRect != null) {
        final pulse = 0.82 + 0.18 * math.sin(_pulseClock * 6.0);
        final cursorRRect = ui.RRect.fromRectAndRadius(
          curRect,
          const ui.Radius.circular(4),
        );
        _cursorFillPaint.color = skinStyle.cursorFillColor.withValues(
          alpha: (skinStyle.cursorFillColor.a * pulse).clamp(0.0, 1.0),
        );
        _cursorStrokePaint.color = skinStyle.cursorBorderColor;
        canvas
          ..drawRRect(cursorRRect, _cursorFillPaint)
          ..drawRRect(cursorRRect, _cursorStrokePaint);
      }

      renderWindowContents(canvas);
      _renderScrollArrows(canvas, w, h);
    }
  }

  /// Subclasses override this hook to draw clipped interior rows/cells above
  /// the selection cursor and below the scroll arrows.
  void renderWindowContents(ui.Canvas canvas) {}

  void _renderScrollArrows(ui.Canvas canvas, double w, double h) {
    if (!showScrollUpIndicator && !showScrollDownIndicator) {
      return;
    }
    final bob = math.sin(_pulseClock * 7.0) * 1.5;
    final arrowPaint = ui.Paint()..color = skinStyle.outerBorderColor;
    final cx = w * 0.5;
    if (showScrollUpIndicator) {
      final topY = 4.5 + bob * 0.5;
      final path = ui.Path()
        ..moveTo(cx, topY)
        ..lineTo(cx - 5.0, topY + 5.0)
        ..lineTo(cx + 5.0, topY + 5.0)
        ..close();
      canvas.drawPath(path, arrowPaint);
    }
    if (showScrollDownIndicator) {
      final botY = h - 4.5 + bob * 0.5;
      final path = ui.Path()
        ..moveTo(cx, botY)
        ..lineTo(cx - 5.0, botY - 5.0)
        ..lineTo(cx + 5.0, botY - 5.0)
        ..close();
      canvas.drawPath(path, arrowPaint);
    }
  }
}
