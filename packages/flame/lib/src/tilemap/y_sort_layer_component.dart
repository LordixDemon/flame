import 'dart:ui' as ui;

import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/mixins/has_visibility.dart';
import 'package:flame/src/components/position_component.dart';

/// Container that renders its [PositionComponent] children sorted dynamically
/// by foot baseline (`position.y + ySortBaselineOffset`), breaking ties stably
/// by `position.x`, so actors walk seamlessly in front of and behind trees,
/// pillars, fences, and NPCs without mutating `Component.priority` every frame.
class YSortLayerComponent({
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.priority,
  super.sortKey,
  super.cameraMask,
  super.key,
}) extends PositionComponent with HasVisibility {
  final List<Component> _drawOrder = <Component>[];

  /// Optional baseline offset map for children whose visual foot is offset from
  /// `position.y`.
  final Map<Component, double> baselineOffsets = <Component, double>{};

  double _sortY(Component c) {
    if (c is PositionComponent) {
      return c.position.y + (baselineOffsets[c] ?? 0.0);
    }
    return baselineOffsets[c] ?? 0.0;
  }

  double _sortX(Component c) => c is PositionComponent ? c.position.x : 0.0;

  @override
  void renderTree(ui.Canvas canvas) {
    if (!isVisible) {
      return;
    }
    decorator.applyChain(
      (c) {
        render(c);
        _drawOrder
          ..clear()
          ..addAll(children);
        _drawOrder.sort((a, b) {
          final dy = _sortY(a).compareTo(_sortY(b));
          if (dy != 0) {
            return dy;
          }
          return _sortX(a).compareTo(_sortX(b));
        });
        for (var i = 0; i < _drawOrder.length; i++) {
          _drawOrder[i].renderTree(c);
        }
      },
      canvas,
    );
  }
}
