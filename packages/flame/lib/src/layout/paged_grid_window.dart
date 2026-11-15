import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/src/anchor.dart';
import 'package:flame/src/layout/window_skin_component.dart';
import 'package:flame/src/text/renderers/raster_font_atlas.dart';
import 'package:flutter/painting.dart';

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
