part of 'widget_surface_3d.dart';

/// Base interactive 2D control hosted on a [WidgetSurface3D] panel.
abstract class SurfaceControl2D({
  required var ui.Rect bounds,
  var bool enabled = true,
}) {
  WidgetSurface3D? _owner;

  /// Whether a 3D pointer ray is currently hovering inside [bounds].
  bool hovered = false;

  /// Whether this control is currently held down by an active tap/drag.
  bool pressed = false;

  /// Marks the owning [WidgetSurface3D] dirty so its texture re-renders.
  void invalidate() {
    _owner?.markDirty();
  }

  /// Releases any cached native resources owned by this control.
  @internal
  void dispose() {}

  /// Paints this control onto [canvas] in panel pixel coordinates.
  void paint(ui.Canvas canvas);

  /// Handles pointer press at [panelOffset].
  void handlePointerDown(ui.Offset panelOffset) {}

  /// Handles pointer drag at [panelOffset].
  void handlePointerDrag(ui.Offset panelOffset) {}

  /// Handles pointer release (`inside` indicates whether release landed inside
  /// [bounds]).
  void handlePointerUp(ui.Offset panelOffset, {required bool inside}) {}
}

/// Interactive 2D button control for a diegetic [WidgetSurface3D].
class SurfaceButton2D({
  required super.bounds,
  var String label = '',
  this.onPressed,
  var ui.Color normalColor = const ui.Color(0xFF1E293B),
  var ui.Color hoverColor = const ui.Color(0xFF334155),
  var ui.Color pressedColor = const ui.Color(0xFF0EA5E9),
  var ui.Color borderColor = const ui.Color(0xFF38BDF8),
  var ui.Color textColor = const ui.Color(0xFFF8FAFC),
  var double borderRadius = 8.0,
  var double fontSize = 18.0,
  super.enabled,
}) extends SurfaceControl2D {
  /// Callback invoked when a tap completes inside [bounds].
  ui.VoidCallback? onPressed;

  final ui.Paint _fillPaint = ui.Paint();
  final ui.Paint _borderPaint = ui.Paint()..style = ui.PaintingStyle.stroke;
  TextPainter? _textPainter;
  bool _hasLayout = false;
  String? _cachedLabel;
  ui.Color? _cachedTextColor;
  double _cachedFontSize = -1;
  double _cachedMaxWidth = -1;

  @override
  void dispose() {
    _textPainter?.dispose();
    _textPainter = null;
    _hasLayout = false;
  }

  TextPainter _ensureLabelPainter(double maxW) {
    var painter = _textPainter;
    if (painter == null ||
        !_hasLayout ||
        _cachedLabel != label ||
        _cachedTextColor != textColor ||
        _cachedFontSize != fontSize ||
        _cachedMaxWidth != maxW) {
      painter ??= _textPainter = TextPainter(textDirection: TextDirection.ltr);
      painter
        ..text = TextSpan(
          text: label,
          style: TextStyle(
            color: textColor,
            fontSize: fontSize,
            fontWeight: ui.FontWeight.w600,
          ),
        )
        ..layout(maxWidth: maxW);
      _hasLayout = true;
      _cachedLabel = label;
      _cachedTextColor = textColor;
      _cachedFontSize = fontSize;
      _cachedMaxWidth = maxW;
    }
    return painter;
  }

  @override
  void handlePointerUp(ui.Offset panelOffset, {required bool inside}) {
    if (enabled && inside) {
      onPressed?.call();
    }
  }

  @override
  void paint(ui.Canvas canvas) {
    final fill = !enabled
        ? const ui.Color(0xFF0F172A)
        : pressed
        ? pressedColor
        : hovered
        ? hoverColor
        : normalColor;
    final rrect = ui.RRect.fromRectAndRadius(
      bounds,
      ui.Radius.circular(borderRadius),
    );
    _fillPaint.color = fill;
    _borderPaint
      ..color = borderColor
      ..strokeWidth = hovered || pressed ? 2.5 : 1.5;
    canvas
      ..drawRRect(rrect, _fillPaint)
      ..drawRRect(rrect, _borderPaint);

    if (label.isNotEmpty) {
      final painter = _ensureLabelPainter(math.max(0.0, bounds.width - 8.0));
      final tx = bounds.left + (bounds.width - painter.width) * 0.5;
      final ty = bounds.top + (bounds.height - painter.height) * 0.5;
      painter.paint(canvas, ui.Offset(tx, ty));
    }
  }
}

/// Interactive horizontal 2D slider control for a diegetic [WidgetSurface3D].
class SurfaceSlider2D({
  required super.bounds,
  double value = 0.5,
  final double min = 0.0,
  final double max = 1.0,
  this.onChanged,
  var ui.Color trackColor = const ui.Color(0xFF1E293B),
  var ui.Color activeColor = const ui.Color(0xFF38BDF8),
  var ui.Color thumbColor = const ui.Color(0xFFF8FAFC),
  super.enabled,
}) extends SurfaceControl2D {
  this : assert(max > min, 'max must be > min') {
    _value = value.clamp(min, max);
  }

  double _value = 0.5;

  /// Callback invoked whenever [value] changes via click or drag.
  ValueChanged<double>? onChanged;

  /// Current slider value in `[min..max]`.
  double get value => _value;
  set value(double next) {
    final clamped = next.clamp(min, max);
    if ((clamped - _value).abs() > 1e-6) {
      _value = clamped;
      invalidate();
    }
  }

  /// Normalized `[0..1]` slider fraction.
  double get normalizedValue => ((_value - min) / (max - min)).clamp(0.0, 1.0);

  void _scrubAt(double panelX) {
    if (!enabled || bounds.width <= 1e-6) {
      return;
    }
    final t = ((panelX - bounds.left) / bounds.width).clamp(0.0, 1.0);
    final next = min + (max - min) * t;
    if ((next - _value).abs() > 1e-6) {
      _value = next;
      invalidate();
      onChanged?.call(_value);
    }
  }

  @override
  void handlePointerDown(ui.Offset panelOffset) {
    _scrubAt(panelOffset.dx);
  }

  @override
  void handlePointerDrag(ui.Offset panelOffset) {
    _scrubAt(panelOffset.dx);
  }

  final ui.Paint _paint = ui.Paint();

  @override
  void paint(ui.Canvas canvas) {
    final cy = bounds.center.dy;
    final trackHeight = math.min(8.0, bounds.height * 0.35);
    final trackRect = ui.Rect.fromLTWH(
      bounds.left,
      cy - trackHeight * 0.5,
      bounds.width,
      trackHeight,
    );
    final trackRRect = ui.RRect.fromRectAndRadius(
      trackRect,
      ui.Radius.circular(trackHeight * 0.5),
    );
    canvas.drawRRect(trackRRect, _paint..color = trackColor);

    final frac = normalizedValue;
    final fillW = bounds.width * frac;
    if (fillW > 0.5) {
      final fillRect = ui.Rect.fromLTWH(
        bounds.left,
        cy - trackHeight * 0.5,
        fillW,
        trackHeight,
      );
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          fillRect,
          ui.Radius.circular(trackHeight * 0.5),
        ),
        _paint..color = activeColor,
      );
    }

    final thumbRadius = math.min(
      bounds.height * 0.45,
      pressed || hovered ? 10.0 : 8.5,
    );
    final thumbX = bounds.left + fillW;
    canvas.drawCircle(
      ui.Offset(thumbX, cy),
      thumbRadius,
      _paint..color = thumbColor,
    );
  }
}
