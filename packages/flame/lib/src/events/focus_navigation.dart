import 'dart:math' as math;

import 'package:flame/src/components/position_component.dart';
import 'package:vector_math/vector_math.dart';

/// Cardinal and sequential traversal directions for [FocusNavigationGroup].
enum FocusDirection() {
  up,
  down,
  left,
  right,
  next,
  previous,
}

/// Mixin making a [PositionComponent] navigable by keyboard arrows, `Tab`, or
/// gamepad D-Pad / stick inside a [FocusNavigationGroup].
mixin FocusableComponent on PositionComponent {
  bool _isFocused = false;

  /// Whether this component can currently receive focus.
  bool canFocus = true;

  /// Sequential ordering key used by [FocusDirection.next] /
  /// [FocusDirection.previous].
  int focusOrder = 0;

  /// Whether this component currently holds focus.
  bool get isFocused => _isFocused;

  /// Invoked when focus moves onto this component.
  void onFocusGain() {}

  /// Invoked when focus leaves this component.
  void onFocusLost() {}

  /// Invoked when the player triggers `confirm` / `Enter` / `Space` / `South`
  /// while focused.
  void onFocusActivate() {}
}

/// Spatial and sequential focus controller enabling seamless keyboard, D-Pad,
/// and TV-remote navigation across arbitrary 2D or isometric
/// [PositionComponent] layouts.
class FocusNavigationGroup({
  this.wrapSequential = true,
  this.maxConeHalfAngleRad = 1.22, // ~70 degrees
  this.lateralPenalty = 2.5,
}) {
  /// Whether `next` / `previous` wraps around at the ends.
  final bool wrapSequential;

  /// Half-angle (in radians) of the directional search cone for cardinal moves.
  final double maxConeHalfAngleRad;

  /// Weight multiplier penalizing off-axis lateral drift during cardinal moves.
  final double lateralPenalty;

  final List<FocusableComponent> _items = <FocusableComponent>[];
  FocusableComponent? _focused;
  final Vector2 _scratchA = Vector2.zero();
  final Vector2 _scratchB = Vector2.zero();

  /// Currently focused component, if any.
  FocusableComponent? get focused => _focused;

  /// Registered focusable candidates.
  List<FocusableComponent> get candidates =>
      List<FocusableComponent>.unmodifiable(_items);

  /// Registers [item] into this navigation group.
  void register(FocusableComponent item) {
    if (!_items.contains(item)) {
      _items.add(item);
    }
  }

  /// Removes [item] from this group (clearing focus if it was focused).
  void unregister(FocusableComponent item) {
    if (_focused == item) {
      requestFocus(null);
    }
    _items.remove(item);
  }

  /// Explicitly assigns focus to [target] (or clears focus when `null`).
  bool requestFocus(FocusableComponent? target) {
    if (target != null && !target.canFocus) {
      return false;
    }
    if (_focused == target) {
      return true;
    }
    final prev = _focused;
    if (prev != null) {
      prev._isFocused = false;
      prev.onFocusLost();
    }
    _focused = target;
    if (target != null) {
      target._isFocused = true;
      target.onFocusGain();
    }
    return true;
  }

  /// Invokes [FocusableComponent.onFocusActivate] on the currently focused
  /// item, returning `true` if one was active.
  bool activateFocused() {
    final current = _focused;
    if (current == null || !current.canFocus) {
      return false;
    }
    current.onFocusActivate();
    return true;
  }

  /// Moves focus in [direction], returning the newly focused component (or the
  /// existing one if no better candidate exists).
  FocusableComponent? moveFocus(FocusDirection direction) {
    final eligible = <FocusableComponent>[
      for (var i = 0; i < _items.length; i++)
        if (_items[i].canFocus) _items[i],
    ];
    if (eligible.isEmpty) {
      requestFocus(null);
      return null;
    }

    if (_focused == null || !eligible.contains(_focused)) {
      eligible.sort(_compareFocusOrder);
      final initial = direction == FocusDirection.previous
          ? eligible.last
          : eligible.first;
      requestFocus(initial);
      return initial;
    }

    if (direction == FocusDirection.next ||
        direction == FocusDirection.previous) {
      eligible.sort(_compareFocusOrder);
      final idx = eligible.indexOf(_focused!);
      final step = direction == FocusDirection.next ? 1 : -1;
      var nextIdx = idx + step;
      if (wrapSequential) {
        nextIdx =
            (nextIdx % eligible.length + eligible.length) % eligible.length;
      } else {
        nextIdx = nextIdx.clamp(0, eligible.length - 1);
      }
      final chosen = eligible[nextIdx];
      requestFocus(chosen);
      return chosen;
    }

    final (dirX, dirY) = switch (direction) {
      FocusDirection.right => (1.0, 0.0),
      FocusDirection.left => (-1.0, 0.0),
      FocusDirection.down => (0.0, 1.0),
      FocusDirection.up => (0.0, -1.0),
      _ => (1.0, 0.0),
    };

    _centerOf(_focused!, _scratchA);
    final minCos = math.cos(maxConeHalfAngleRad);
    FocusableComponent? best;
    var bestScore = double.infinity;

    for (var i = 0; i < eligible.length; i++) {
      final candidate = eligible[i];
      if (identical(candidate, _focused)) {
        continue;
      }
      _centerOf(candidate, _scratchB);
      final vx = _scratchB.x - _scratchA.x;
      final vy = _scratchB.y - _scratchA.y;
      final dist = math.sqrt(vx * vx + vy * vy);
      if (dist <= 1e-6) {
        continue;
      }
      final cosAngle = (vx * dirX + vy * dirY) / dist;
      if (cosAngle < minCos) {
        continue;
      }
      final axial = vx * dirX + vy * dirY;
      final lateral = (vx * -dirY + vy * dirX).abs();
      final score = axial + lateral * lateralPenalty;
      if (score < bestScore) {
        bestScore = score;
        best = candidate;
      }
    }

    if (best != null) {
      requestFocus(best);
    }
    return _focused;
  }

  static void _centerOf(PositionComponent c, Vector2 out) {
    if (c.isMounted) {
      out.setFrom(c.absoluteCenter);
    } else {
      out.setValues(
        c.position.x + c.size.x * 0.5,
        c.position.y + c.size.y * 0.5,
      );
    }
  }

  static int _compareFocusOrder(FocusableComponent a, FocusableComponent b) {
    final cmp = a.focusOrder.compareTo(b.focusOrder);
    if (cmp != 0) {
      return cmp;
    }
    final yCmp = a.position.y.compareTo(b.position.y);
    return yCmp != 0 ? yCmp : a.position.x.compareTo(b.position.x);
  }
}
