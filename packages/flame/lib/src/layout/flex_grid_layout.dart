import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flutter/painting.dart';

/// Immutable 2D edge padding for Flame in-world layout containers.
class const EdgePadding({
  final double left = 0.0,
  final double top = 0.0,
  final double right = 0.0,
  final double bottom = 0.0,
}) {
  /// Zero padding on all edges.
  static const EdgePadding zero = EdgePadding();

  /// Uniform padding [value] on all four edges.
  const EdgePadding.all(double value)
    : this(left: value, top: value, right: value, bottom: value);

  /// Symmetric [horizontal] and [vertical] padding.
  const EdgePadding.symmetric({
    double horizontal = 0.0,
    double vertical = 0.0,
  }) : this(
         left: horizontal,
         top: vertical,
         right: horizontal,
         bottom: vertical,
       );

  /// Total horizontal inset (`left + right`).
  double get horizontal => left + right;

  /// Total vertical inset (`top + bottom`).
  double get vertical => top + bottom;
}

/// Main-axis child distribution inside [RowLayoutComponent] and
/// [ColumnLayoutComponent].
enum FlexMainAxisAlignment() {
  /// Pack children at the leading edge.
  start,

  /// Center children along the main axis.
  center,

  /// Pack children at the trailing edge.
  end,

  /// Distribute remaining space evenly between adjacent children.
  spaceBetween,

  /// Distribute remaining space with half-sized outer margins.
  spaceAround,

  /// Distribute remaining space equally before, between, and after children.
  spaceEvenly,
}

/// Cross-axis child alignment inside [RowLayoutComponent] and
/// [ColumnLayoutComponent].
enum FlexCrossAxisAlignment() {
  /// Align children at the top (row) or left (column) inset.
  start,

  /// Center children along the cross axis.
  center,

  /// Align children at the bottom (row) or right (column) inset.
  end,

  /// Resize child cross-axis dimension to fill available inner cross extent.
  stretch,
}

abstract class _FlexLayoutBase({
  required final bool isHorizontal,
  var double spacing = 0.0,
  var EdgePadding padding = EdgePadding.zero,
  var FlexMainAxisAlignment mainAxisAlignment = FlexMainAxisAlignment.start,
  var FlexCrossAxisAlignment crossAxisAlignment = FlexCrossAxisAlignment.center,
  var bool shrinkWrap = true,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.key,
}) extends PositionComponent {
  final List<PositionComponent> _layoutScratch = <PositionComponent>[];

  @override
  void onMount() {
    super.onMount();
    performLayout();
  }

  @override
  void onChildrenChanged(Component child, ChildrenChangeType type) {
    super.onChildrenChanged(child, type);
    performLayout();
  }

  /// Executes single-pass `O(N)` flex positioning across all mounted
  /// [PositionComponent] children.
  void performLayout() {
    _layoutScratch.clear();
    for (final child in children) {
      if (child is PositionComponent) {
        if (child is HasVisibility && !(child as HasVisibility).isVisible) {
          continue;
        }
        _layoutScratch.add(child);
      }
    }

    final count = _layoutScratch.length;
    if (count == 0) {
      if (shrinkWrap) {
        size.setValues(padding.horizontal, padding.vertical);
      }
      return;
    }

    var totalMain = 0.0;
    var maxCross = 0.0;
    for (var i = 0; i < count; i++) {
      final c = _layoutScratch[i];
      final mainSpan = isHorizontal ? c.size.x : c.size.y;
      final crossSpan = isHorizontal ? c.size.y : c.size.x;
      totalMain += mainSpan;
      if (crossSpan > maxCross) {
        maxCross = crossSpan;
      }
    }
    final baseGaps = spacing * (count - 1);

    if (shrinkWrap) {
      if (isHorizontal) {
        size.setValues(
          totalMain + baseGaps + padding.horizontal,
          maxCross + padding.vertical,
        );
      } else {
        size.setValues(
          maxCross + padding.horizontal,
          totalMain + baseGaps + padding.vertical,
        );
      }
    }

    final innerMain = math.max(
      0.0,
      (isHorizontal ? size.x - padding.horizontal : size.y - padding.vertical),
    );
    final innerCross = math.max(
      0.0,
      (isHorizontal ? size.y - padding.vertical : size.x - padding.horizontal),
    );
    final freeMain = math.max(0.0, innerMain - (totalMain + baseGaps));

    var cursorMain = isHorizontal ? padding.left : padding.top;
    var effectiveGap = spacing;

    switch (mainAxisAlignment) {
      case FlexMainAxisAlignment.start:
        break;
      case FlexMainAxisAlignment.center:
        cursorMain += freeMain * 0.5;
      case FlexMainAxisAlignment.end:
        cursorMain += freeMain;
      case FlexMainAxisAlignment.spaceBetween:
        if (count > 1) {
          effectiveGap = spacing + freeMain / (count - 1);
        }
      case FlexMainAxisAlignment.spaceAround:
        final unit = freeMain / count;
        cursorMain += unit * 0.5;
        effectiveGap = spacing + unit;
      case FlexMainAxisAlignment.spaceEvenly:
        final unit = freeMain / (count + 1);
        cursorMain += unit;
        effectiveGap = spacing + unit;
    }

    final crossOrigin = isHorizontal ? padding.top : padding.left;
    for (var i = 0; i < count; i++) {
      final c = _layoutScratch[i];
      if (crossAxisAlignment == FlexCrossAxisAlignment.stretch) {
        if (isHorizontal) {
          c.size.y = innerCross;
        } else {
          c.size.x = innerCross;
        }
      }
      final cMain = isHorizontal ? c.size.x : c.size.y;
      final cCross = isHorizontal ? c.size.y : c.size.x;

      final double crossPos;
      switch (crossAxisAlignment) {
        case FlexCrossAxisAlignment.start:
        case FlexCrossAxisAlignment.stretch:
          crossPos = crossOrigin;
        case FlexCrossAxisAlignment.center:
          crossPos = crossOrigin + (innerCross - cCross) * 0.5;
        case FlexCrossAxisAlignment.end:
          crossPos = crossOrigin + (innerCross - cCross);
      }

      // Account for child's own anchor so its top-left box starts at
      // (cursorMain, crossPos).
      if (isHorizontal) {
        c.position.setValues(
          cursorMain + c.anchor.x * c.size.x,
          crossPos + c.anchor.y * c.size.y,
        );
      } else {
        c.position.setValues(
          crossPos + c.anchor.x * c.size.x,
          cursorMain + c.anchor.y * c.size.y,
        );
      }
      cursorMain += cMain + effectiveGap;
    }
  }
}

/// Single-pass horizontal flex container for in-world HUD bars, card trays,
/// price tags, and status icon strips.
class RowLayoutComponent({
  super.spacing,
  super.padding,
  super.mainAxisAlignment,
  super.crossAxisAlignment,
  super.shrinkWrap,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.key,
}) extends _FlexLayoutBase {
  this : super(isHorizontal: true);
}

/// Single-pass vertical flex container for in-world tooltips, stat stacks, and
/// menu lists.
class ColumnLayoutComponent({
  super.spacing,
  super.padding,
  super.mainAxisAlignment,
  super.crossAxisAlignment,
  super.shrinkWrap,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.key,
}) extends _FlexLayoutBase {
  this : super(isHorizontal: false);
}

/// Single-pass fixed-column 2D grid container for inventories, shop boards,
/// badge racks, and skill selectors.
class GridLayoutComponent({
  required var int columns,
  required var double cellWidth,
  required var double cellHeight,
  var double horizontalSpacing = 0.0,
  var double verticalSpacing = 0.0,
  var EdgePadding padding = EdgePadding.zero,
  var bool shrinkWrap = true,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.key,
}) extends PositionComponent {
  this : assert(columns >= 1, 'columns must be >= 1');

  @override
  void onMount() {
    super.onMount();
    performLayout();
  }

  @override
  void onChildrenChanged(Component child, ChildrenChangeType type) {
    super.onChildrenChanged(child, type);
    performLayout();
  }

  /// Positions all visible [PositionComponent] children into grid cells.
  void performLayout() {
    final cols = math.max(1, columns);
    var idx = 0;
    for (final child in children) {
      if (child is! PositionComponent) {
        continue;
      }
      if (child is HasVisibility && !(child as HasVisibility).isVisible) {
        continue;
      }
      final col = idx % cols;
      final row = idx ~/ cols;
      final slotX = padding.left + col * (cellWidth + horizontalSpacing);
      final slotY = padding.top + row * (cellHeight + verticalSpacing);
      final offsetX = (cellWidth - child.size.x) * 0.5;
      final offsetY = (cellHeight - child.size.y) * 0.5;
      child.position.setValues(
        slotX + offsetX + child.anchor.x * child.size.x,
        slotY + offsetY + child.anchor.y * child.size.y,
      );
      idx++;
    }

    if (shrinkWrap) {
      if (idx == 0) {
        size.setValues(padding.horizontal, padding.vertical);
      } else {
        final usedCols = math.min(cols, idx);
        final rows = (idx + cols - 1) ~/ cols;
        size.setValues(
          padding.horizontal +
              usedCols * cellWidth +
              (usedCols - 1) * horizontalSpacing,
          padding.vertical + rows * cellHeight + (rows - 1) * verticalSpacing,
        );
      }
    }
  }
}

/// Scalable 9-slice panel component backed by native `Canvas.drawImageNine`
/// (or a crisp procedural rounded frame when [image] is `null`).
class NineSlicePanelComponent({
  var ui.Image? image,
  var Rect? centerSlice,
  var Color tint = const Color(0xFFFFFFFF),
  var Color fallbackFillColor = const Color(0xDD1A1E2E),
  var Color fallbackBorderColor = const Color(0xFF5A688E),
  var double cornerRadius = 10.0,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.key,
}) extends PositionComponent {
  final Paint _fillPaint = Paint()..isAntiAlias = true;
  final Paint _borderPaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..isAntiAlias = true;

  @override
  void render(Canvas canvas) {
    if (size.x <= 0 || size.y <= 0) {
      return;
    }
    final dst = Rect.fromLTWH(0, 0, size.x, size.y);
    final img = image;
    if (img != null) {
      final slice =
          centerSlice ??
          Rect.fromLTWH(
            img.width * 0.25,
            img.height * 0.25,
            img.width * 0.5,
            img.height * 0.5,
          );
      // The tint multiplies the image once, color and alpha alike: the paint
      // stays opaque white, as its alpha would be applied on top of the
      // filter and square the opacity of a translucent tint.
      _fillPaint
        ..color = const Color(0xFFFFFFFF)
        ..colorFilter = tint == const Color(0xFFFFFFFF)
            ? null
            : ColorFilter.mode(tint, BlendMode.modulate);
      canvas.drawImageNine(img, slice, dst, _fillPaint);
      _fillPaint.colorFilter = null;
      return;
    }

    final rrect = RRect.fromRectAndRadius(dst, Radius.circular(cornerRadius));
    _fillPaint.color = fallbackFillColor;
    _borderPaint.color = fallbackBorderColor;
    canvas.drawRRect(rrect, _fillPaint);
    canvas.drawRRect(rrect, _borderPaint);
  }
}
