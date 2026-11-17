import 'dart:math';
import 'dart:ui';

import 'package:flame/src/camera/camera_component.dart';
import 'package:flame/src/camera/scene_layer_component.dart';
import 'package:flame/src/camera/world.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/mixins/cull_when_offscreen.dart';
import 'package:flame/src/components/mixins/passive_component.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:meta/meta.dart';

/// Hierarchical spatial sector/cluster container that culls its entire child
/// subtree in a single `CameraComponent.visibleWorldRect.overlaps` test.
///
/// Ideal for grouping map quadrants, island sides, tile chunks, or regional
/// prop clusters inside a [World] so off-screen regions skip iterating dozens
/// or hundreds of individual children when zoomed in.
///
/// The group is tested against `CameraComponent.cullWorldRect` (which covers
/// an active camera shake), shifted by the parallax of any
/// `SceneLayerComponent` it is drawn through, and is never culled while it is
/// recorded into a camera-independent cache.
class SpatialCullGroup({
  this.cullingEnabled = true,
  this.staticBounds = false,
  this.cullPadding = 0.0,
  this.cullBoundsOutset = Rect.zero,
  this.explicitWorldBounds,
  super.children,
  super.priority,
  super.sortKey,
  super.key,
}) extends Component with PassiveComponent {
  /// Whether frustum culling is active for this group.
  bool cullingEnabled;

  /// When `true`, child bounds are assumed stationary after mounting and are
  /// only recomputed when children are added/removed or [markBoundsDirty] is
  /// called, making per-frame culling `O(1)` regardless of child count.
  ///
  /// When `false` (default), child `Transform2D.version`, `size`, and `anchor`
  /// are checked so moving children automatically update the cached group box.
  bool staticBounds;

  /// Extra uniform padding (in world units) around the group's union box.
  double cullPadding;

  /// Directional `(left, top, right, bottom)` world-unit expansion around the
  /// group's union box (e.g. upward `-Y` headroom for tall 3D spires).
  Rect cullBoundsOutset;

  /// Optional explicit world-space AABB override. When non-null, used directly
  /// instead of scanning child `PositionComponent`s.
  Rect? explicitWorldBounds;

  World? _world;
  bool _hasDirectWorldCoords = false;
  List<SceneLayerComponent>? _sceneLayers;
  bool _boundsDirty = true;
  Rect? _cachedGroupBounds;
  int _cachedChildSignature = 0;
  int _cachedChildCount = -1;
  bool _wasGroupCulledLastFrame = false;
  int _boundsComputeCount = 0;

  /// Whether the entire group was skipped on its most recent camera render.
  bool get wasGroupCulledLastFrame => _wasGroupCulledLastFrame;

  /// Number of times the union world AABB of this group was computed.
  @visibleForTesting
  int get boundsComputeCount => _boundsComputeCount;

  /// Marks the cached union AABB dirty so it is recomputed on the next render.
  void markBoundsDirty() {
    _boundsDirty = true;
  }

  @mustCallSuper
  @override
  void onMount() {
    super.onMount();
    _world = enclosingWorld();
    _hasDirectWorldCoords = hasDirectWorldCoordinates();
    _sceneLayers = SceneLayerComponent.ancestorLayersOf(this);
    _boundsDirty = true;
  }

  @mustCallSuper
  @override
  void onRemove() {
    _world = null;
    _hasDirectWorldCoords = false;
    _sceneLayers = null;
    _cachedGroupBounds = null;
    _boundsDirty = true;
    super.onRemove();
  }

  @mustCallSuper
  @override
  void onChildrenChanged(Component child, ChildrenChangeType type) {
    super.onChildrenChanged(child, type);
    _boundsDirty = true;
  }

  /// Returns the cached or freshly computed union world-space AABB of all
  /// mounted [PositionComponent] children, or `null` if the group has none or
  /// contains unmeasured non-[PositionComponent] children without
  /// [explicitWorldBounds].
  Rect? get groupWorldBounds {
    final explicit = explicitWorldBounds;
    if (explicit != null) {
      return _expandBounds(explicit);
    }
    if (!hasChildren) {
      return null;
    }

    if (staticBounds && !_boundsDirty && _cachedGroupBounds != null) {
      return _expandBounds(_cachedGroupBounds!);
    }

    if (!staticBounds && _hasDirectWorldCoords && !_boundsDirty) {
      var sig = 17;
      var posCount = 0;
      var hasUnboundedChild = false;
      for (final child in children) {
        if (!child.isMounted) {
          continue;
        }
        if (child is PositionComponent) {
          posCount++;
          sig = 0x1fffffff & (sig * 31 + identityHashCode(child));
          sig = 0x1fffffff & (sig * 31 + child.transform.version);
          sig = 0x1fffffff & (sig * 31 + child.size.x.hashCode);
          sig = 0x1fffffff & (sig * 31 + child.size.y.hashCode);
          sig = 0x1fffffff & (sig * 31 + child.anchor.x.hashCode);
          sig = 0x1fffffff & (sig * 31 + child.anchor.y.hashCode);
          if (child is CullWhenOffscreen) {
            sig = 0x1fffffff & (sig * 31 + child.cullPadding.hashCode);
            sig = 0x1fffffff & (sig * 31 + child.cullBoundsOutset.hashCode);
          }
        } else {
          hasUnboundedChild = true;
          break;
        }
      }
      if (!hasUnboundedChild &&
          posCount > 0 &&
          _cachedGroupBounds != null &&
          _cachedChildCount == posCount &&
          _cachedChildSignature == sig) {
        return _expandBounds(_cachedGroupBounds!);
      }
    }

    var minL = double.infinity;
    var minT = double.infinity;
    var maxR = double.negativeInfinity;
    var maxB = double.negativeInfinity;
    var sig = 17;
    var posCount = 0;

    for (final child in children) {
      if (!child.isMounted) {
        continue;
      }
      if (child is! PositionComponent) {
        // Cannot safely cull an arbitrary non-PositionComponent without
        // explicitWorldBounds.
        _cachedGroupBounds = null;
        return null;
      }
      posCount++;
      Rect childRect;
      if (child is CullWhenOffscreen) {
        final raw = child.cullBounds;
        final cp = child.cullPadding;
        final co = child.cullBoundsOutset;
        childRect = (cp == 0.0 && co == Rect.zero)
            ? raw
            : Rect.fromLTRB(
                raw.left - cp - co.left,
                raw.top - cp - co.top,
                raw.right + cp + co.right,
                raw.bottom + cp + co.bottom,
              );
      } else {
        childRect = child.toAbsoluteRect();
      }
      minL = min(minL, childRect.left);
      minT = min(minT, childRect.top);
      maxR = max(maxR, childRect.right);
      maxB = max(maxB, childRect.bottom);

      sig = 0x1fffffff & (sig * 31 + identityHashCode(child));
      sig = 0x1fffffff & (sig * 31 + child.transform.version);
      sig = 0x1fffffff & (sig * 31 + child.size.x.hashCode);
      sig = 0x1fffffff & (sig * 31 + child.size.y.hashCode);
      sig = 0x1fffffff & (sig * 31 + child.anchor.x.hashCode);
      sig = 0x1fffffff & (sig * 31 + child.anchor.y.hashCode);
      if (child is CullWhenOffscreen) {
        sig = 0x1fffffff & (sig * 31 + child.cullPadding.hashCode);
        sig = 0x1fffffff & (sig * 31 + child.cullBoundsOutset.hashCode);
      }
    }

    if (posCount == 0) {
      _cachedGroupBounds = null;
      return null;
    }

    _boundsComputeCount++;
    final union = Rect.fromLTRB(minL, minT, maxR, maxB);
    _cachedGroupBounds = union;
    _cachedChildCount = posCount;
    _cachedChildSignature = sig;
    _boundsDirty = false;
    return _expandBounds(union);
  }

  Rect _expandBounds(Rect bounds) {
    final p = cullPadding;
    final o = cullBoundsOutset;
    if (p == 0.0 && o == Rect.zero) {
      return bounds;
    }
    return Rect.fromLTRB(
      bounds.left - p - o.left,
      bounds.top - p - o.top,
      bounds.right + p + o.right,
      bounds.bottom + p + o.bottom,
    );
  }

  bool _overlapsCullRect(CameraComponent camera, Rect bounds) {
    final visible = camera.cullWorldRect;
    final layers = _sceneLayers;
    if (layers == null) {
      return visible.overlaps(bounds);
    }
    var shiftX = 0.0;
    var shiftY = 0.0;
    for (var i = 0; i < layers.length; i++) {
      shiftX += layers[i].parallaxShiftX(camera);
      shiftY += layers[i].parallaxShiftY(camera);
    }
    return bounds.left + shiftX < visible.right &&
        visible.left < bounds.right + shiftX &&
        bounds.top + shiftY < visible.bottom &&
        visible.top < bounds.bottom + shiftY;
  }

  @override
  void renderTree(Canvas canvas) {
    final world = _world;
    // `currentCamera` is null while the subtree is recorded into a
    // camera-independent cache: nothing may be left out then.
    final camera = CameraComponent.currentCamera;
    if (cullingEnabled && world != null && camera != null) {
      if (camera.world == world) {
        final bounds = groupWorldBounds;
        if (bounds != null) {
          if (!_overlapsCullRect(camera, bounds)) {
            _wasGroupCulledLastFrame = true;
            camera.recordCullDecision(culled: true);
            return;
          }
          camera.recordCullDecision(culled: false);
        }
      }
    }
    _wasGroupCulledLastFrame = false;
    super.renderTree(canvas);
  }
}
