import 'dart:math';
import 'dart:ui';

import 'package:flame/src/camera/camera_component.dart';
import 'package:flame/src/camera/world.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/mixins/coordinate_transform.dart';
import 'package:flame/src/components/mixins/has_visibility.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:meta/meta.dart';

/// Skips drawing a [PositionComponent] while it is off-screen.
///
/// Supports both uniform [cullPadding] and directional [cullBoundsOutset]
/// (useful for tall 2.5D/3D towers extending in `-Y` or long directional
/// shadows without wasting padding on opposite sides), and caches axis-aligned
/// world bounds across stationary frames via `Transform2D.version`.
mixin CullWhenOffscreen on PositionComponent {
  /// Turns culling on or off for this component only.
  bool cullingEnabled = true;

  /// Turns on an extra check that helps to find culling mistakes in debug mode.
  static bool debugVerifyCulledSubtrees = false;

  /// Extra uniform space, in world units, added around [cullBounds] before
  /// checking if the component is on-screen.
  double cullPadding = 0;

  /// Asymmetric world-unit expansion `(left, top, right, bottom)` applied to
  /// [cullBounds] in addition to [cullPadding].
  ///
  /// Positive magnitudes expand outward on each respective side (for example,
  /// `const Rect.fromLTRB(12, 120, 48, 8)` expands 120 world units upward for a
  /// tall 3D spire and 48 units right for an evening cast shadow).
  Rect cullBoundsOutset = Rect.zero;

  Rect? _cachedWorldBounds;
  int _cachedTransformVersion = -1;
  double _cachedSizeX = double.nan;
  double _cachedSizeY = double.nan;
  double _cachedAnchorX = double.nan;
  double _cachedAnchorY = double.nan;
  bool _wasCulledLastFrame = false;
  int _cullBoundsComputeCount = 0;

  /// Whether this component was skipped by frustum culling on its most recent
  /// camera render check.
  bool get wasCulledLastFrame => _wasCulledLastFrame;

  /// Number of times the fast-path world bounds rectangle was recomputed (used
  /// in tests to verify `Transform2D.version` caching on stationary frames).
  @visibleForTesting
  int get cullBoundsComputeCount => _cullBoundsComputeCount;

  /// The area of the world that this component takes up.
  ///
  /// By default this is the box made by the position, size, anchor, scale and
  /// angle of the component and its parents, cached across frames whenever
  /// `transform.version`, `size`, and `anchor` are unchanged for unrotated
  /// components in direct [World] coordinates (either direct children of a
  /// [World] or nested under plain non-transforming [Component] layers).
  Rect get cullBounds {
    if (angle == 0 && (_hasDirectWorldCoords || parent is World)) {
      final txVersion = transform.version;
      final sx = size.x;
      final sy = size.y;
      final ax = anchor.x;
      final ay = anchor.y;
      final cached = _cachedWorldBounds;
      if (cached != null &&
          _cachedTransformVersion == txVersion &&
          _cachedSizeX == sx &&
          _cachedSizeY == sy &&
          _cachedAnchorX == ax &&
          _cachedAnchorY == ay) {
        return cached;
      }
      _cullBoundsComputeCount++;
      final width = sx * scale.x;
      final height = sy * scale.y;
      final left = position.x - ax * width;
      final top = position.y - ay * height;
      final computed = Rect.fromLTRB(
        min(left, left + width),
        min(top, top + height),
        max(left, left + width),
        max(top, top + height),
      );
      _cachedWorldBounds = computed;
      _cachedTransformVersion = txVersion;
      _cachedSizeX = sx;
      _cachedSizeY = sy;
      _cachedAnchorX = ax;
      _cachedAnchorY = ay;
      return computed;
    }
    _cachedWorldBounds = null;
    _cullBoundsComputeCount++;
    return toAbsoluteRect();
  }

  World? _world;
  bool _hasDirectWorldCoords = false;

  /// Whether this component has no transforming ancestors between itself and
  /// its owning [World].
  @internal
  bool get hasDirectWorldCoords => _hasDirectWorldCoords;

  bool _resolveDirectWorldCoords() {
    var cursor = parent;
    while (cursor != null) {
      if (cursor is World) {
        return true;
      }
      if (cursor is CoordinateTransform) {
        return false;
      }
      cursor = cursor.parent;
    }
    return false;
  }

  @mustCallSuper
  @override
  void onMount() {
    super.onMount();
    _world = findParent<World>();
    _hasDirectWorldCoords = _resolveDirectWorldCoords();
    _cachedWorldBounds = null;
  }

  @mustCallSuper
  @override
  void onRemove() {
    _world = null;
    _hasDirectWorldCoords = false;
    _cachedWorldBounds = null;
    super.onRemove();
  }

  @override
  void renderTree(Canvas canvas) {
    if (_isOffscreen()) {
      return;
    }
    super.renderTree(canvas);
  }

  Rect _expandedBounds(Rect bounds) {
    final p = cullPadding;
    final outset = cullBoundsOutset;
    if (p == 0.0 && outset == Rect.zero) {
      return bounds;
    }
    return Rect.fromLTRB(
      bounds.left - p - outset.left,
      bounds.top - p - outset.top,
      bounds.right + p + outset.right,
      bounds.bottom + p + outset.bottom,
    );
  }

  bool _isOffscreen() {
    final world = _world;
    if (!cullingEnabled ||
        world == null ||
        CameraComponent.currentCameras.isEmpty) {
      _wasCulledLastFrame = false;
      return false;
    }
    // The innermost camera is the one currently rendering this component.
    final camera = CameraComponent.currentCameras.last;
    if (camera.world != world) {
      _wasCulledLastFrame = false;
      return false;
    }
    final bounds = cullBounds;
    final expanded = _expandedBounds(bounds);
    final visibleRect = camera.visibleWorldRect;
    final offscreen = !visibleRect.overlaps(expanded);
    assert(_debugVerifyCulledSubtree(offscreen, visibleRect, expanded));
    _wasCulledLastFrame = offscreen;
    camera.recordCullDecision(culled: offscreen);
    return offscreen;
  }

  /// Only used in an assert, see [debugVerifyCulledSubtrees]. Always returns
  /// true, or throws when a culled component has a visible descendant.
  bool _debugVerifyCulledSubtree(
    bool offscreen,
    Rect visibleRect,
    Rect bounds,
  ) {
    if (offscreen && debugVerifyCulledSubtrees && hasChildren) {
      final problem = _debugCulledSubtreeProblem(visibleRect, bounds);
      if (problem != null) {
        throw AssertionError(problem);
      }
    }
    return true;
  }

  /// Returns a description of the problem when this component is culled while
  /// one of its descendants is visible, and null when culling is correct.
  String? _debugCulledSubtreeProblem(Rect visibleRect, Rect bounds) {
    PositionComponent? visibleDescendant;
    var requiredPadding = 0.0;
    final pending = <Component>[this];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!current.hasChildren) {
        continue;
      }
      for (final child in current.children) {
        if (child is HasVisibility && !child.isVisible) {
          continue;
        }
        pending.add(child);
        if (child is! PositionComponent) {
          continue;
        }
        final rect = child.toAbsoluteRect();
        requiredPadding = max(
          requiredPadding,
          max(
            max(bounds.left - rect.left, rect.right - bounds.right),
            max(bounds.top - rect.top, rect.bottom - bounds.bottom),
          ),
        );
        if (visibleDescendant == null && visibleRect.overlaps(rect)) {
          visibleDescendant = child;
        }
      }
    }
    if (visibleDescendant == null) {
      return null;
    }
    return '$runtimeType is off-screen and was skipped, but its child '
        '${visibleDescendant.runtimeType} is on-screen. A skipped component '
        'also skips its children. Set cullPadding to at least '
        '${requiredPadding.ceil()} (it is now $cullPadding), or override '
        'cullBounds.';
  }
}
