import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/src/game/game.dart';

/// Scroll axis direction for [ScrollContainerComponent].
enum ScrollDirection() {
  vertical,
  horizontal,
  both,
}

/// Pure-Flame clipped, inertial, wheel- & drag-enabled scrollable viewport
/// container with automatic frustum child virtualization.
///
/// Key engine guarantees:
/// - Clips **both** `Canvas` rendering AND pointer hit-testing
///   (`clipsChildEvents == true`) to `Offset.zero & size`, so scrolled-out
///   child buttons never intercept clicks outside the container.
/// - Handles desktop mouse-wheel / trackpad `ScrollCallbacks` AND touch/mouse
///   `DragCallbacks` with exponential velocity damping (`decelerationRate`).
/// - Skips `renderChild` for child [PositionComponent]s whose local bounds lie
///   completely outside the active scroll viewport (`lastCulledChildCount`).
class ScrollContainerComponent({
  final ScrollDirection scrollDirection = ScrollDirection.vertical,
  Vector2? contentSize,
  var double wheelScrollMultiplier = 1.0,
  var bool dragEnabled = true,
  var bool wheelEnabled = true,
  var double decelerationRate = 7.5,
  var bool showScrollbar = false,
  var Color scrollbarColor = const Color(0x88FFFFFF),
  var double scrollbarThickness = 4.0,
  var bool virtualizeOffscreenChildren = true,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  Iterable<Component>? contentChildren,
  super.priority,
  super.sortKey,
  super.key,
}) extends PositionComponent
    with DragCallbacks, ScrollCallbacks, HasVisibility {
  this {
    add(_viewportContent);
    if (contentChildren != null) {
      _viewportContent.addAll(contentChildren);
    }
  }
  final Vector2? _explicitContentSize = contentSize?.clone();
  final Vector2 _scrollOffset = Vector2.zero();
  final Vector2 _velocity = Vector2.zero();
  bool _isDragging = false;
  int _lastVisibleChildCount = 0;
  int _lastCulledChildCount = 0;

  late final _ScrollContentLayer _viewportContent = _ScrollContentLayer(this);
  final Paint _scrollbarPaint = Paint();

  /// Inner content container whose `position` is `-scrollOffset`. Add
  /// scrollable items via [addContent] / [addAllContent] or directly to
  /// [content].
  PositionComponent get content => _viewportContent;

  /// Current positive scroll offset `(scrollX, scrollY)` in `[0 .. maxScroll]`.
  Vector2 get scrollOffset => _scrollOffset;

  /// Current inertial velocity in logical pixels/second.
  Vector2 get scrollVelocity => _velocity;

  /// Number of content children rendered in the most recent pass.
  int get lastVisibleChildCount => _lastVisibleChildCount;

  /// Number of offscreen content children skipped by virtualization in the most
  /// recent render pass.
  int get lastCulledChildCount => _lastCulledChildCount;

  /// Adds [component] inside the scrollable [content] layer.
  void addContent(Component component) => _viewportContent.add(component);

  /// Adds [components] inside the scrollable [content] layer.
  void addAllContent(Iterable<Component> components) =>
      _viewportContent.addAll(components);

  /// Explicit content extent override, or auto-measured extent of [content]
  /// children when `null`.
  Vector2 get effectiveContentSize {
    final explicit = _explicitContentSize;
    if (explicit != null) {
      return explicit;
    }
    var maxX = size.x;
    var maxY = size.y;
    if (_viewportContent.hasChildren) {
      for (final child in _viewportContent.children) {
        if (child is PositionComponent) {
          final rect = child.toRect();
          if (rect.right > maxX) {
            maxX = rect.right;
          }
          if (rect.bottom > maxY) {
            maxY = rect.bottom;
          }
        }
      }
    }
    return Vector2(maxX, maxY);
  }

  /// Sets an explicit scrollable content extent (`null` reverts to automatic
  /// child bounds measurement).
  void setContentSize(Vector2? nextSize) {
    if (nextSize == null) {
      _explicitContentSize?.setZero();
    } else if (_explicitContentSize != null) {
      _explicitContentSize.setFrom(nextSize);
    }
    _applyClampedOffset(_scrollOffset.x, _scrollOffset.y);
  }

  /// Maximum scrollable X offset (`>= 0`).
  double get maxScrollX => scrollDirection == ScrollDirection.vertical
      ? 0.0
      : math.max(0.0, effectiveContentSize.x - size.x);

  /// Maximum scrollable Y offset (`>= 0`).
  double get maxScrollY => scrollDirection == ScrollDirection.horizontal
      ? 0.0
      : math.max(0.0, effectiveContentSize.y - size.y);

  @override
  bool get clipsChildEvents => true;

  @override
  bool containsClipPoint(Vector2 localPoint) => containsLocalPoint(localPoint);

  /// Scrolls immediately to `(x, y)` clamped to `[0 .. maxScroll]` and cancels
  /// active inertia.
  void scrollTo({double? x, double? y}) {
    _velocity.setZero();
    _applyClampedOffset(x ?? _scrollOffset.x, y ?? _scrollOffset.y);
  }

  /// Scrolls by `(dx, dy)` in content coordinates.
  void scrollBy(double dx, double dy) {
    _applyClampedOffset(_scrollOffset.x + dx, _scrollOffset.y + dy);
  }

  /// Ensures [targetRect] (in [content] coordinates) is visible within the
  /// scroll viewport.
  void ensureRectVisible(Rect targetRect, {double padding = 0.0}) {
    var nextX = _scrollOffset.x;
    var nextY = _scrollOffset.y;
    if (scrollDirection != ScrollDirection.vertical) {
      if (targetRect.left - padding < nextX) {
        nextX = targetRect.left - padding;
      } else if (targetRect.right + padding > nextX + size.x) {
        nextX = targetRect.right + padding - size.x;
      }
    }
    if (scrollDirection != ScrollDirection.horizontal) {
      if (targetRect.top - padding < nextY) {
        nextY = targetRect.top - padding;
      } else if (targetRect.bottom + padding > nextY + size.y) {
        nextY = targetRect.bottom + padding - size.y;
      }
    }
    scrollTo(x: nextX, y: nextY);
  }

  void _applyClampedOffset(double rawX, double rawY) {
    final nx = scrollDirection == ScrollDirection.vertical
        ? 0.0
        : rawX.clamp(0.0, maxScrollX);
    final ny = scrollDirection == ScrollDirection.horizontal
        ? 0.0
        : rawY.clamp(0.0, maxScrollY);
    if ((_scrollOffset.x - nx).abs() > 1e-5 ||
        (_scrollOffset.y - ny).abs() > 1e-5) {
      _scrollOffset.setValues(nx, ny);
      _viewportContent.position.setValues(-nx, -ny);
      Game.notifyVisualMutation();
      markSubtreeDirty();
    }
  }

  @override
  void onScroll(ScrollEvent event) {
    if (!wheelEnabled) {
      event.continuePropagation = true;
      return;
    }
    final dx = scrollDirection == ScrollDirection.vertical
        ? 0.0
        : event.scrollDelta.x * wheelScrollMultiplier;
    final dy = scrollDirection == ScrollDirection.horizontal
        ? 0.0
        : event.scrollDelta.y * wheelScrollMultiplier;
    _velocity.setZero();
    scrollBy(dx, dy);
    event.continuePropagation = false;
  }

  @override
  void onDragStart(DragStartEvent event) {
    super.onDragStart(event);
    if (!dragEnabled) {
      event.continuePropagation = true;
      return;
    }
    _isDragging = true;
    _velocity.setZero();
  }

  @override
  void onDragUpdate(DragUpdateEvent event) {
    if (!dragEnabled || !_isDragging) {
      return;
    }
    final delta = event.renderingTrace.isEmpty
        ? event.canvasDelta
        : event.localDelta;
    scrollBy(-delta.x, -delta.y);
  }

  @override
  void onDragEnd(DragEndEvent event) {
    super.onDragEnd(event);
    if (!_isDragging) {
      return;
    }
    _isDragging = false;
    if (dragEnabled) {
      _velocity.setValues(
        scrollDirection == ScrollDirection.vertical ? 0.0 : -event.velocity.x,
        scrollDirection == ScrollDirection.horizontal ? 0.0 : -event.velocity.y,
      );
    }
  }

  @override
  void onDragCancel(DragCancelEvent event) {
    super.onDragCancel(event);
    _isDragging = false;
    _velocity.setZero();
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (_isDragging || dt <= 0.0) {
      return;
    }
    final vx = _velocity.x;
    final vy = _velocity.y;
    if (vx.abs() <= 1.0 && vy.abs() <= 1.0) {
      _velocity.setZero();
      return;
    }
    scrollBy(vx * dt, vy * dt);
    final decay = math.exp(-decelerationRate * dt);
    _velocity.scale(decay);
    if ((_scrollOffset.x <= 0.0 || _scrollOffset.x >= maxScrollX) &&
        vx.abs() > 0) {
      _velocity.x = 0.0;
    }
    if ((_scrollOffset.y <= 0.0 || _scrollOffset.y >= maxScrollY) &&
        vy.abs() > 0) {
      _velocity.y = 0.0;
    }
  }

  @override
  void renderTree(Canvas canvas) {
    if (!isVisible || !isActiveForCurrentGraphicsTier) {
      return;
    }
    if (size.x <= 0 || size.y <= 0) {
      return;
    }
    decorator.applyChain(
      (innerCanvas) {
        innerCanvas.save();
        innerCanvas.clipRect(Rect.fromLTWH(0, 0, size.x, size.y));
        render(innerCanvas);
        _viewportContent.renderVirtualized(innerCanvas);
        if (showScrollbar) {
          _renderScrollbar(innerCanvas);
        }
        innerCanvas.restore();
        if (debugMode) {
          renderDebugMode(innerCanvas);
        }
      },
      canvas,
      bounds: Rect.fromLTWH(0, 0, size.x, size.y),
    );
  }

  void _renderScrollbar(Canvas canvas) {
    _scrollbarPaint.color = scrollbarColor;
    final radius = Radius.circular(scrollbarThickness * 0.5);
    if (scrollDirection != ScrollDirection.horizontal && maxScrollY > 0.0) {
      final totalH = size.y + maxScrollY;
      final thumbH = math.max(16.0, (size.y / totalH) * size.y);
      final ratio = (_scrollOffset.y / maxScrollY).clamp(0.0, 1.0);
      final thumbY = ratio * (size.y - thumbH);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            size.x - scrollbarThickness - 2.0,
            thumbY,
            scrollbarThickness,
            thumbH,
          ),
          radius,
        ),
        _scrollbarPaint,
      );
    }
    if (scrollDirection != ScrollDirection.vertical && maxScrollX > 0.0) {
      final totalW = size.x + maxScrollX;
      final thumbW = math.max(16.0, (size.x / totalW) * size.x);
      final ratio = (_scrollOffset.x / maxScrollX).clamp(0.0, 1.0);
      final thumbX = ratio * (size.x - thumbW);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            thumbX,
            size.y - scrollbarThickness - 2.0,
            thumbW,
            scrollbarThickness,
          ),
          radius,
        ),
        _scrollbarPaint,
      );
    }
  }
}

class _ScrollContentLayer(final ScrollContainerComponent _owner)
    extends PositionComponent {
  void renderVirtualized(Canvas canvas) {
    if (!hasChildren) {
      _owner._lastVisibleChildCount = 0;
      _owner._lastCulledChildCount = 0;
      return;
    }
    final viewLeft = _owner._scrollOffset.x;
    final viewTop = _owner._scrollOffset.y;
    final viewRight = viewLeft + _owner.size.x;
    final viewBottom = viewTop + _owner.size.y;
    final virtualize = _owner.virtualizeOffscreenChildren;

    var visible = 0;
    var culled = 0;

    canvas.save();
    canvas.translate(position.x, position.y);
    for (final child in children) {
      if (virtualize &&
          child is PositionComponent &&
          child.size.x > 0 &&
          child.size.y > 0) {
        final r = child.toRect();
        if (r.right < viewLeft ||
            r.left > viewRight ||
            r.bottom < viewTop ||
            r.top > viewBottom) {
          culled++;
          continue;
        }
      }
      visible++;
      renderChild(canvas, child);
    }
    afterChildrenRendered(canvas);
    canvas.restore();

    _owner._lastVisibleChildCount = visible;
    _owner._lastCulledChildCount = culled;
  }
}
