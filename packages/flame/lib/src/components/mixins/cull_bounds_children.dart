import 'dart:ui';

import 'package:flame/src/components/mixins/cull_when_offscreen.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:meta/meta.dart';

/// Makes [CullWhenOffscreen] look at some of the children of a component too.
///
/// By default, [CullWhenOffscreen] only looks at the box of the component
/// itself. A child that sticks out of that box disappears when the box leaves
/// the screen, even if the child is still visible. List such children in
/// [cullBoundsChildren], and their boxes are added to the box of the component.
///
/// ```dart
/// class Tank extends PositionComponent
///     with CullWhenOffscreen, CullBoundsChildren {
///   late final HealthBar healthBar;
///
///   @override
///   Iterable<PositionComponent> get cullBoundsChildren => [healthBar];
/// }
/// ```
///
/// List only the children that stick out. When this component is in direct
/// world coordinates and all listed components are direct children, the union
/// box is cached across stationary frames via `Transform2D.version`.
///
/// The list is read on every frame, so it can change at any time, for example
/// in `update`. To use all of the direct children, return the cached list of
/// the children. It follows children that are added or removed:
///
/// ```dart
/// @override
/// Iterable<PositionComponent> get cullBoundsChildren =>
///     hasChildren ? children.query<PositionComponent>() : const [];
/// ```
mixin CullBoundsChildren on CullWhenOffscreen {
  /// The children (or other descendants) that stick out of the box of this
  /// component, and that must be on-screen when deciding to draw it.
  ///
  /// The area that is checked is the [cullBounds] of the component without
  /// this mixin, plus the box of each component in this list, plus
  /// [cullPadding]. The boxes are measured on every frame, so a listed child
  /// that moves is followed. A listed component that is not mounted is ignored.
  ///
  /// This is a getter, so it is read on every frame. Return components that
  /// you keep in fields, and do not create new components in it.
  Iterable<PositionComponent> get cullBoundsChildren;

  Rect? _cachedUnionBounds;
  Rect? _cachedBaseBounds;
  int _cachedChildrenSignature = 0;
  int _cachedChildrenCount = -1;
  int _unionRecomputeCount = 0;

  /// Number of times the union bounds across [cullBoundsChildren] was
  /// recomputed.
  @visibleForTesting
  int get cullUnionRecomputeCount => _unionRecomputeCount;

  @override
  Rect get cullBounds {
    final baseBounds = super.cullBounds;
    if (hasDirectWorldCoords) {
      var canUseFastSignature = true;
      var count = 0;
      var sig = transform.version;
      for (final child in cullBoundsChildren) {
        if (!child.isMounted) {
          continue;
        }
        if (!identical(child.parent, this)) {
          canUseFastSignature = false;
          break;
        }
        count++;
        sig = 0x1fffffff & (sig * 31 + identityHashCode(child));
        sig = 0x1fffffff & (sig * 31 + child.transform.version);
        sig = 0x1fffffff & (sig * 31 + child.size.x.hashCode);
        sig = 0x1fffffff & (sig * 31 + child.size.y.hashCode);
        sig = 0x1fffffff & (sig * 31 + child.anchor.x.hashCode);
        sig = 0x1fffffff & (sig * 31 + child.anchor.y.hashCode);
      }
      if (canUseFastSignature) {
        if (count == 0) {
          _cachedUnionBounds = baseBounds;
          _cachedBaseBounds = baseBounds;
          _cachedChildrenCount = 0;
          _cachedChildrenSignature = sig;
          return baseBounds;
        }
        final cached = _cachedUnionBounds;
        if (cached != null &&
            _cachedBaseBounds == baseBounds &&
            _cachedChildrenCount == count &&
            _cachedChildrenSignature == sig) {
          return cached;
        }
        _unionRecomputeCount++;
        var bounds = baseBounds;
        for (final child in cullBoundsChildren) {
          if (child.isMounted) {
            bounds = bounds.expandToInclude(child.toAbsoluteRect());
          }
        }
        _cachedUnionBounds = bounds;
        _cachedBaseBounds = baseBounds;
        _cachedChildrenCount = count;
        _cachedChildrenSignature = sig;
        return bounds;
      }
    }

    _cachedUnionBounds = null;
    _unionRecomputeCount++;
    var bounds = baseBounds;
    for (final child in cullBoundsChildren) {
      if (child.isMounted) {
        bounds = bounds.expandToInclude(child.toAbsoluteRect());
      }
    }
    return bounds;
  }
}
