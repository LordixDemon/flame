import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/src/anchor.dart';
import 'package:flame/src/layout/window_skin_component.dart';
import 'package:flame/src/text/renderers/raster_font_atlas.dart';
import 'package:flutter/painting.dart';

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
