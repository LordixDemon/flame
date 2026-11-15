import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/src/layout/flex_grid_layout.dart';
import 'package:flame/src/text/renderers/raster_font_atlas.dart';
import 'package:flutter/painting.dart';

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

    // Only render interior contents & cursor once mostly unfolded.
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

/// Entry descriptor for [CommandListWindow] and [PagedGridWindow].
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

/// Virtualized single-column JRPG command/list menu (`O(visible_rows)`) capable
/// of scrolling smoothly through `10,000+` items without creating per-row
/// components.
class CommandListWindow({
  List<WindowCommandItem> items = const <WindowCommandItem>[],
  this.rowHeight = 28.0,
  this.fontAtlas,
  this.onHighlightChanged,
  this.onConfirmed,
  this.onDisabledBuzzer,
  super.skinStyle,
  super.initialOpenness,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.priority,
  super.key,
}) extends WindowSkinComponent {
  this : assert(rowHeight > 0.0, 'rowHeight must be > 0.');

  final List<WindowCommandItem> _items = List<WindowCommandItem>.of(items);

  /// Height of each virtualized row in logical pixels.
  final double rowHeight;

  /// Optional [RasterFontAtlas] enabling single-draw-call `GlyphBatchRenderer`
  /// text rendering. Falls back to a single reusable [TextPainter] if `null`.
  RasterFontAtlas? fontAtlas;

  /// Fired whenever the highlighted index changes (ideal for updating a Help
  /// description bar).
  void Function(int index, WindowCommandItem item)? onHighlightChanged;

  /// Fired when [confirmSelection] is called on an enabled item.
  void Function(int index, WindowCommandItem item)? onConfirmed;

  /// Fired when [confirmSelection] is attempted on a disabled item.
  void Function(int index, WindowCommandItem item)? onDisabledBuzzer;

  final GlyphBatchRenderer _glyphBatch = GlyphBatchRenderer();
  TextPainter? _fallbackPainter;

  int _selectedIndex = 0;
  int _scrollTopIndex = 0;
  int _renderedRowCountLastFrame = 0;

  /// Read-only view of all items in this window.
  List<WindowCommandItem> get items =>
      List<WindowCommandItem>.unmodifiable(_items);

  /// Total item count.
  int get itemCount => _items.length;

  /// Currently highlighted item index (`-1` when empty).
  int get selectedIndex => _items.isEmpty ? -1 : _selectedIndex;

  /// Currently highlighted item, or `null` when empty.
  WindowCommandItem? get selectedItem =>
      (_items.isEmpty || _selectedIndex < 0 || _selectedIndex >= _items.length)
      ? null
      : _items[_selectedIndex];

  /// Index of the top-most visible row in the scroll viewport.
  int get scrollTopIndex => _scrollTopIndex;

  /// Number of rows that fit inside the padded window height.
  int get visibleRowCapacity {
    final innerH = math.max(0.0, size.y - skinStyle.padding.vertical);
    return math.max(1, (innerH / rowHeight).floor());
  }

  /// Diagnostic count of rows actually rendered during the last frame
  /// (verifies `O(visible)` virtualization over `10,000+` items).
  int get renderedRowCountLastFrame => _renderedRowCountLastFrame;

  @override
  void onMount() {
    super.onMount();
    _syncSelectionAndCursor(snap: true, notify: false);
  }

  @override
  void onRemove() {
    _fallbackPainter?.dispose();
    _fallbackPainter = null;
    super.onRemove();
  }

  /// Replaces the list of [nextItems], clamping selection and scroll bounds.
  void setItems(List<WindowCommandItem> nextItems, {int? selectIndex}) {
    _items
      ..clear()
      ..addAll(nextItems);
    if (_items.isEmpty) {
      _selectedIndex = -1;
      _scrollTopIndex = 0;
      setTargetCursorRect(null, snap: true);
      showScrollUpIndicator = false;
      showScrollDownIndicator = false;
      return;
    }
    _selectedIndex = (selectIndex ?? _selectedIndex).clamp(
      0,
      _items.length - 1,
    );
    _syncSelectionAndCursor(snap: true, notify: true);
  }

  /// Moves the selection cursor by [delta] rows (`+1` down, `-1` up),
  /// optionally wrapping at list ends and skipping disabled items.
  void moveSelection(
    int delta, {
    bool wrap = true,
    bool skipDisabled = false,
  }) {
    if (_items.isEmpty || delta == 0) {
      return;
    }
    final n = _items.length;
    var candidate = _selectedIndex;
    final step = delta > 0 ? 1 : -1;
    final steps = delta.abs();

    for (var s = 0; s < steps; s++) {
      var probes = 0;
      do {
        final next = candidate + step;
        if (wrap) {
          candidate = ((next % n) + n) % n;
        } else {
          candidate = next.clamp(0, n - 1);
        }
        probes++;
      } while (skipDisabled && !_items[candidate].enabled && probes < n);
    }

    if (candidate != _selectedIndex) {
      _selectedIndex = candidate;
      _syncSelectionAndCursor(snap: false, notify: true);
    }
  }

  /// Jumps directly to [index].
  void selectIndex(int index, {bool snapCursor = false}) {
    if (_items.isEmpty) {
      return;
    }
    final clamped = index.clamp(0, _items.length - 1);
    final changed = clamped != _selectedIndex;
    _selectedIndex = clamped;
    _syncSelectionAndCursor(snap: snapCursor, notify: changed);
  }

  /// Triggers [onConfirmed] if the highlighted item is enabled, or
  /// [onDisabledBuzzer] if disabled, returning `true` on confirmation.
  bool confirmSelection() {
    final item = selectedItem;
    if (item == null) {
      return false;
    }
    if (!item.enabled) {
      onDisabledBuzzer?.call(_selectedIndex, item);
      return false;
    }
    onConfirmed?.call(_selectedIndex, item);
    return true;
  }

  void _syncSelectionAndCursor({required bool snap, required bool notify}) {
    if (_items.isEmpty) {
      setTargetCursorRect(null, snap: true);
      showScrollUpIndicator = false;
      showScrollDownIndicator = false;
      return;
    }
    _selectedIndex = _selectedIndex.clamp(0, _items.length - 1);
    final cap = visibleRowCapacity;
    if (_selectedIndex < _scrollTopIndex) {
      _scrollTopIndex = _selectedIndex;
    } else if (_selectedIndex >= _scrollTopIndex + cap) {
      _scrollTopIndex = _selectedIndex - cap + 1;
    }
    final maxScroll = math.max(0, _items.length - cap);
    _scrollTopIndex = _scrollTopIndex.clamp(0, maxScroll);

    showScrollUpIndicator = _scrollTopIndex > 0;
    showScrollDownIndicator = _scrollTopIndex + cap < _items.length;

    final visSlot = _selectedIndex - _scrollTopIndex;
    final pad = skinStyle.padding;
    final innerW = math.max(0.0, size.x - pad.horizontal);
    final cursorRect = ui.Rect.fromLTWH(
      pad.left,
      pad.top + visSlot * rowHeight,
      innerW,
      rowHeight,
    );
    setTargetCursorRect(cursorRect, snap: snap);

    if (notify) {
      onHighlightChanged?.call(_selectedIndex, _items[_selectedIndex]);
    }
  }

  @override
  void renderWindowContents(ui.Canvas canvas) {
    if (_items.isEmpty) {
      _renderedRowCountLastFrame = 0;
      return;
    }
    final pad = skinStyle.padding;
    final innerW = math.max(0.0, size.x - pad.horizontal);
    final innerH = math.max(0.0, size.y - pad.vertical);
    if (innerW <= 0.0 || innerH <= 0.0) {
      _renderedRowCountLastFrame = 0;
      return;
    }

    final cap = visibleRowCapacity;
    final endExclusive = math.min(_items.length, _scrollTopIndex + cap);
    _renderedRowCountLastFrame = math.max(0, endExclusive - _scrollTopIndex);

    canvas
      ..save()
      ..clipRect(ui.Rect.fromLTWH(pad.left, pad.top, innerW, innerH));

    final atlas = fontAtlas;
    if (atlas != null && !atlas.isDisposed) {
      _glyphBatch.begin();
      for (var idx = _scrollTopIndex; idx < endExclusive; idx++) {
        final item = _items[idx];
        final slot = idx - _scrollTopIndex;
        final rowTop = pad.top + slot * rowHeight;
        final textY = rowTop + (rowHeight - atlas.lineHeight) * 0.5;
        final color = item.enabled
            ? skinStyle.textEnabledColor
            : skinStyle.textDisabledColor;
        _glyphBatch.addText(
          atlas,
          item.label,
          x: pad.left + 8.0,
          y: textY,
          color: color,
        );
        if (item.rightBadge.isNotEmpty) {
          _glyphBatch.addText(
            atlas,
            item.rightBadge,
            x: pad.left + innerW - 8.0,
            y: textY,
            anchor: Anchor.topRight,
            color: color,
          );
        }
      }
      _glyphBatch.flush(canvas, atlas);
    } else {
      final painter = _fallbackPainter ??= TextPainter(
        textDirection: TextDirection.ltr,
      );
      for (var idx = _scrollTopIndex; idx < endExclusive; idx++) {
        final item = _items[idx];
        final slot = idx - _scrollTopIndex;
        final rowTop = pad.top + slot * rowHeight;
        final color = item.enabled
            ? skinStyle.textEnabledColor
            : skinStyle.textDisabledColor;
        final style = TextStyle(color: color, fontSize: 14);
        painter
          ..text = TextSpan(text: item.label, style: style)
          ..layout(maxWidth: innerW)
          ..paint(
            canvas,
            ui.Offset(
              pad.left + 8.0,
              rowTop + (rowHeight - painter.height) * 0.5,
            ),
          );
        if (item.rightBadge.isNotEmpty) {
          painter
            ..text = TextSpan(text: item.rightBadge, style: style)
            ..layout(maxWidth: innerW)
            ..paint(
              canvas,
              ui.Offset(
                pad.left + innerW - 8.0 - painter.width,
                rowTop + (rowHeight - painter.height) * 0.5,
              ),
            );
        }
      }
    }

    canvas.restore();
  }
}

/// Virtualized multi-column 2D RPG item/skill grid window (`O(visible_cells)`).
class PagedGridWindow({
  List<WindowCommandItem> items = const <WindowCommandItem>[],
  this.columns = 2,
  this.rowHeight = 30.0,
  this.columnSpacing = 8.0,
  this.fontAtlas,
  this.onHighlightChanged,
  this.onConfirmed,
  this.onDisabledBuzzer,
  super.skinStyle,
  super.initialOpenness,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.priority,
  super.key,
}) extends WindowSkinComponent {
  this
    : assert(columns >= 1, 'columns must be >= 1.'),
      assert(rowHeight > 0.0, 'rowHeight must be > 0.');

  final List<WindowCommandItem> _items = List<WindowCommandItem>.of(items);

  /// Number of columns per row.
  final int columns;

  /// Height of each grid row in logical pixels.
  final double rowHeight;

  /// Horizontal gap between columns in logical pixels.
  final double columnSpacing;

  /// Optional [RasterFontAtlas] for single-draw-call batched glyph rendering.
  RasterFontAtlas? fontAtlas;

  /// Fired when the highlighted cell changes.
  void Function(int index, WindowCommandItem item)? onHighlightChanged;

  /// Fired when an enabled cell is confirmed.
  void Function(int index, WindowCommandItem item)? onConfirmed;

  /// Fired when a disabled cell is confirmed.
  void Function(int index, WindowCommandItem item)? onDisabledBuzzer;

  final GlyphBatchRenderer _glyphBatch = GlyphBatchRenderer();
  TextPainter? _fallbackPainter;

  int _selectedIndex = 0;
  int _scrollTopRow = 0;
  int _renderedCellCountLastFrame = 0;

  /// Total items in the grid.
  int get itemCount => _items.length;

  /// Currently selected item index (`-1` if empty).
  int get selectedIndex => _items.isEmpty ? -1 : _selectedIndex;

  /// Diagnostic count of cells rendered during the most recent frame.
  int get renderedCellCountLastFrame => _renderedCellCountLastFrame;

  /// Visible row capacity in the current viewport.
  int get visibleRowCapacity {
    final innerH = math.max(0.0, size.y - skinStyle.padding.vertical);
    return math.max(1, (innerH / rowHeight).floor());
  }

  @override
  void onMount() {
    super.onMount();
    _syncCursor(snap: true, notify: false);
  }

  @override
  void onRemove() {
    _fallbackPainter?.dispose();
    _fallbackPainter = null;
    super.onRemove();
  }

  /// Replaces grid contents.
  void setItems(List<WindowCommandItem> nextItems, {int? selectIndex}) {
    _items
      ..clear()
      ..addAll(nextItems);
    if (_items.isEmpty) {
      _selectedIndex = -1;
      _scrollTopRow = 0;
      setTargetCursorRect(null, snap: true);
      return;
    }
    _selectedIndex = (selectIndex ?? _selectedIndex).clamp(
      0,
      _items.length - 1,
    );
    _syncCursor(snap: true, notify: true);
  }

  /// Moves 2D selection by `(dCol, dRow)` across the grid.
  void moveCursor(int dCol, int dRow) {
    if (_items.isEmpty) {
      return;
    }
    final curCol = _selectedIndex % columns;
    final curRow = _selectedIndex ~/ columns;
    final totalRows = (_items.length + columns - 1) ~/ columns;
    final nextCol = (curCol + dCol).clamp(0, columns - 1);
    final nextRow = (curRow + dRow).clamp(0, totalRows - 1);
    final nextIdx = math.min(_items.length - 1, nextRow * columns + nextCol);
    if (nextIdx != _selectedIndex) {
      _selectedIndex = nextIdx;
      _syncCursor(snap: false, notify: true);
    }
  }

  /// Confirms the highlighted cell.
  bool confirmSelection() {
    if (_items.isEmpty || _selectedIndex < 0) {
      return false;
    }
    final item = _items[_selectedIndex];
    if (!item.enabled) {
      onDisabledBuzzer?.call(_selectedIndex, item);
      return false;
    }
    onConfirmed?.call(_selectedIndex, item);
    return true;
  }

  void _syncCursor({required bool snap, required bool notify}) {
    if (_items.isEmpty) {
      setTargetCursorRect(null, snap: true);
      showScrollUpIndicator = false;
      showScrollDownIndicator = false;
      return;
    }
    _selectedIndex = _selectedIndex.clamp(0, _items.length - 1);
    final selRow = _selectedIndex ~/ columns;
    final selCol = _selectedIndex % columns;
    final capRows = visibleRowCapacity;
    if (selRow < _scrollTopRow) {
      _scrollTopRow = selRow;
    } else if (selRow >= _scrollTopRow + capRows) {
      _scrollTopRow = selRow - capRows + 1;
    }
    final totalRows = (_items.length + columns - 1) ~/ columns;
    _scrollTopRow = _scrollTopRow.clamp(0, math.max(0, totalRows - capRows));

    showScrollUpIndicator = _scrollTopRow > 0;
    showScrollDownIndicator = _scrollTopRow + capRows < totalRows;

    final pad = skinStyle.padding;
    final innerW = math.max(0.0, size.x - pad.horizontal);
    final cellW =
        (innerW - columnSpacing * (columns - 1)) / math.max(1, columns);
    final visRow = selRow - _scrollTopRow;
    setTargetCursorRect(
      ui.Rect.fromLTWH(
        pad.left + selCol * (cellW + columnSpacing),
        pad.top + visRow * rowHeight,
        math.max(0.0, cellW),
        rowHeight,
      ),
      snap: snap,
    );

    if (notify) {
      onHighlightChanged?.call(_selectedIndex, _items[_selectedIndex]);
    }
  }

  @override
  void renderWindowContents(ui.Canvas canvas) {
    if (_items.isEmpty) {
      _renderedCellCountLastFrame = 0;
      return;
    }
    final pad = skinStyle.padding;
    final innerW = math.max(0.0, size.x - pad.horizontal);
    final innerH = math.max(0.0, size.y - pad.vertical);
    final cellW =
        (innerW - columnSpacing * (columns - 1)) / math.max(1, columns);
    if (cellW <= 0.0 || innerH <= 0.0) {
      _renderedCellCountLastFrame = 0;
      return;
    }

    final capRows = visibleRowCapacity;
    final startIdx = _scrollTopRow * columns;
    final endExclusive = math.min(
      _items.length,
      (_scrollTopRow + capRows) * columns,
    );
    _renderedCellCountLastFrame = math.max(0, endExclusive - startIdx);

    canvas
      ..save()
      ..clipRect(ui.Rect.fromLTWH(pad.left, pad.top, innerW, innerH));

    final atlas = fontAtlas;
    if (atlas != null && !atlas.isDisposed) {
      _glyphBatch.begin();
      for (var idx = startIdx; idx < endExclusive; idx++) {
        final item = _items[idx];
        final row = (idx ~/ columns) - _scrollTopRow;
        final col = idx % columns;
        final cellLeft = pad.left + col * (cellW + columnSpacing);
        final cellTop = pad.top + row * rowHeight;
        final textY = cellTop + (rowHeight - atlas.lineHeight) * 0.5;
        final color = item.enabled
            ? skinStyle.textEnabledColor
            : skinStyle.textDisabledColor;
        _glyphBatch.addText(
          atlas,
          item.label,
          x: cellLeft + 6.0,
          y: textY,
          color: color,
        );
        if (item.rightBadge.isNotEmpty) {
          _glyphBatch.addText(
            atlas,
            item.rightBadge,
            x: cellLeft + cellW - 6.0,
            y: textY,
            anchor: Anchor.topRight,
            color: color,
          );
        }
      }
      _glyphBatch.flush(canvas, atlas);
    } else {
      final painter = _fallbackPainter ??= TextPainter(
        textDirection: TextDirection.ltr,
      );
      for (var idx = startIdx; idx < endExclusive; idx++) {
        final item = _items[idx];
        final row = (idx ~/ columns) - _scrollTopRow;
        final col = idx % columns;
        final cellLeft = pad.left + col * (cellW + columnSpacing);
        final cellTop = pad.top + row * rowHeight;
        final color = item.enabled
            ? skinStyle.textEnabledColor
            : skinStyle.textDisabledColor;
        final style = TextStyle(color: color, fontSize: 13);
        painter
          ..text = TextSpan(text: item.label, style: style)
          ..layout(maxWidth: cellW)
          ..paint(
            canvas,
            ui.Offset(
              cellLeft + 6.0,
              cellTop + (rowHeight - painter.height) * 0.5,
            ),
          );
      }
    }

    canvas.restore();
  }
}

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
    // Count existing recent popups near `(worldX, worldY)` for anti-overlap!
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
    // Steal oldest slot when pool is saturated.
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
        // Punch-in pop during first 15% of lifetime, smooth fade during last
        // 30%.
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
