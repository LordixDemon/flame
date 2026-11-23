import 'dart:collection' show UnmodifiableSetView;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Canvas;

import 'package:flame/components.dart'
    show ChildrenChangeType, Component, HasWorldRef;
import 'package:flame_3d/camera.dart' show World3D;
import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/components/object_3d.dart' show Object3D;
import 'package:flame_3d/src/graphics/render_context_3d.dart'
    show RenderContext3D;
import 'package:flame_3d/src/resources/light/shadow_settings.dart'
    show ShadowCasterMotion;
import 'package:meta/meta.dart';

part 'component_bounds.dart';
part 'shadow_caster_tracker.dart';

/// {@template component_3d}
/// [Component3D] is a base class for any concept that lives in 3D space.
///
/// It is a [Component] implementation that represents a 3D object that can be
/// freely moved around in 3D space, rotated, and scaled.
///
/// The main property of this class is the [transform] (which combines
/// the [position], [rotation], and [scale]). Thus, the [Component3D] can be
/// seen as an object in 3D space.
///
/// It is typically not used directly, but rather use one of the following
/// implementations:
/// - [Object3D] for a 3D object that can be bound and rendered by the GPU
/// - `LightComponent` for a light source that affects how objects are rendered
///
/// If you want to have a pure group for several components, you have two
/// options:
/// - Use an [Object3D], the group itself will have some superfluous render
/// logic but should not affect your children.
/// - Extend the abstract class [Component3D] yourself.
///
/// The base [Component3D] class can also be used as a container
/// for several other components. In this case, changing the position,
/// rotating or scaling the [Component3D] will affect the whole
/// group as if it was a single entity.
/// {@endtemplate}
abstract class Component3D({
  Vector3? position,
  Vector3? scale,
  Quaternion? rotation,
  List<Component3D> children = const [],
  bool visible = true,
  Iterable<String>? tags3D,
  var String? prefabId,
  super.cameraMask,
}) extends Component with HasWorldRef<World3D> {
  final Transform3D transform = Transform3D()
    ..position = position ?? Vector3.zero()
    ..rotation = rotation ?? Quaternion.euler(0, 0, 0)
    ..scale = scale ?? Vector3.all(1);

  /// {@macro component_3d}
  this : super(children: children) {
    if (tags3D != null) {
      for (final tag in tags3D) {
        addTag3D(tag);
      }
    }
    transform.addListener(_onTransformChanged);
  }

  List<Component3D>? _childComponents3D;
  int _non3DChildCount = 0;
  bool _hasPrioritizedChild = false;

  @override
  void onChildrenChanged(Component child, ChildrenChangeType type) {
    super.onChildrenChanged(child, type);
    if (child is Component3D) {
      switch (type) {
        case ChildrenChangeType.added:
          (_childComponents3D ??= <Component3D>[]).add(child);
          if (child.priority != 0) {
            _hasPrioritizedChild = true;
          }
        case ChildrenChangeType.removed:
          _childComponents3D?.remove(child);
      }
    } else {
      switch (type) {
        case ChildrenChangeType.added:
          _non3DChildCount++;
        case ChildrenChangeType.removed:
          if (_non3DChildCount > 0) {
            _non3DChildCount--;
          }
      }
    }
  }

  @override
  void rebalanceChildren() {
    _hasPrioritizedChild = true;
    super.rebalanceChildren();
  }

  bool _visible = visible;

  /// Whether this component (and its 3D subtree) is locally visible.
  ///
  /// Toggling [visible] marks the enclosing [World3D] dirty without unmounting
  /// any components. See [isEffectivelyVisible] for hierarchical visibility.
  bool get visible => _visible;
  set visible(bool value) {
    if (_visible == value) {
      return;
    }
    _visible = value;
    markSubtreeDirty();
    final world = _cachedWorld;
    if (world == null) {
      return;
    }
    onVisibilityChanged(world, visible: value);
  }

  /// Whether changing [visible], [cameraMask], or mounting/removing this
  /// component invalidates the enclosing world's shadow pass.
  @protected
  bool get affectsShadowPass => true;

  /// Whether moving this component can affect shadow maps on its own (without
  /// counting child [Component3D]s).
  @protected
  bool get isShadowDirtyOnMove => false;

  /// Handles world invalidation when [visible] toggles while mounted in
  /// [world].
  @protected
  void onVisibilityChanged(World3D world, {required bool visible}) {
    // The casters of the subtree leave the kept layer of still casters, or
    // join the casters drawn in every frame (they were not in the layer).
    if (visible) {
      _noteShadowSubtreeShown(world);
    } else {
      _noteShadowSubtreeHidden(world);
    }
    world.markComponentDirty(shadows: true);
  }

  /// Hook invoked when this subtree becomes visible so casters can register.
  @protected
  void onShadowSubtreeShown(World3D world) {}

  /// Hook invoked when this subtree becomes hidden so casters can update.
  @protected
  void onShadowSubtreeHidden(World3D world) {}

  void _noteShadowSubtreeShown(World3D world) {
    onShadowSubtreeShown(world);
    final list = _childComponents3D;
    if (list != null && list.isNotEmpty) {
      for (var i = 0; i < list.length; i++) {
        list[i]._noteShadowSubtreeShown(world);
      }
    } else if (!isMounted && hasChildren) {
      for (final child in children) {
        if (child is Component3D) {
          child._noteShadowSubtreeShown(world);
        }
      }
    }
  }

  void _noteShadowSubtreeHidden(World3D world) {
    onShadowSubtreeHidden(world);
    final list = _childComponents3D;
    if (list != null && list.isNotEmpty) {
      for (var i = 0; i < list.length; i++) {
        list[i]._noteShadowSubtreeHidden(world);
      }
    } else if (!isMounted && hasChildren) {
      for (final child in children) {
        if (child is Component3D) {
          child._noteShadowSubtreeHidden(world);
        }
      }
    }
  }

  /// A 32-bit mask of the render passes that draw this component and its
  /// subtree, see `Component.cameraMask`.
  ///
  /// Changing it marks the enclosing [World3D] dirty, like [visible].
  @override
  set cameraMask(int value) {
    if (value == cameraMask) {
      return;
    }
    super.cameraMask = value;
    _cachedWorld?.markSceneDirty(shadows: affectsShadowPass);
  }

  /// Reports that what this component draws changed in a way the engine
  /// cannot see: data changed in place, such as joint matrices written into
  /// an existing list, a field of a material or of a light source's vector,
  /// or the buffers of a custom `Object3D.draw`.
  ///
  /// Changes made through the setters of the engine's components (transform,
  /// [visible], [cameraMask], `MeshComponent.color`, `instanceData`, ...) are
  /// reported by the setters themselves; only call this for the others.
  ///
  /// It bumps the enclosing [World3D]'s [World3D.sceneVersion], and its
  /// [World3D.castersVersion] unless [shadows] is `false`, so that
  /// `Scene3DCacheMode.retained` layers and a cached static shadow map
  /// (`ShadowSettings.cacheWhenStatic`) render again, and wakes a game whose
  /// `idleRenderMode` skips unchanged frames. Pass `shadows: false` when the
  /// change cannot reach a shadow map (a color, a value only the fragment
  /// shader reads). It costs two integer increments; it does nothing for a
  /// component outside a [World3D].
  ///
  /// With `ShadowSettings.cacheStillCasters`, an [Object3D] that reports a
  /// change that can reach the shadows is drawn in every frame until it
  /// stays unchanged for `ShadowSettings.stillCasterFrames` renders of the
  /// shadows; the kept layer of still casters is rendered again only when
  /// the object was part of it. For any other component, the layer is
  /// rendered again.
  void markDrawDirty({bool shadows = true}) {
    final world = _cachedWorld;
    if (world == null) {
      return;
    }
    onMarkDrawDirty(world, shadows: shadows);
  }

  /// Records a programmatic draw invalidation in [world].
  @protected
  void onMarkDrawDirty(World3D world, {required bool shadows}) {
    if (shadows) {
      world.markSceneDirty();
      return;
    }
    world.markComponentDirty(shadows: false);
  }

  bool _includeInSceneBounds = true;

  /// Whether this component's bounds ([aabb]) count in
  /// [World3D.sceneBounds], the region the sun's shadow map is fitted to.
  ///
  /// It is `true` by default. Set it to `false` on a component whose bounds
  /// are much larger than what the shadows should cover, such as an overlay
  /// that may draw anywhere (`DebugRenderer3D` does so), so that adding it
  /// does not spread the shadow map over its bounds and leave the scene
  /// without visible shadows. The component is still drawn, and culled with
  /// its [aabb]. While a world holds such a component, a `Scene3DComponent`
  /// renders all of its visible area rather than only the part the scene
  /// bounds cover (see [World3D.hasUnboundedComponents]).
  ///
  /// Only the direct children of the [World3D] are counted or left out: a
  /// nested component counts through the bounds of its parent, which contain
  /// it so that the parent is culled correctly.
  bool get includeInSceneBounds => _includeInSceneBounds;
  set includeInSceneBounds(bool value) {
    if (value == _includeInSceneBounds) {
      return;
    }
    _includeInSceneBounds = value;
    if (parent case final World3D world) {
      world.updateSceneBoundsMembership(this);
    }
  }

  /// Whether this component AND all of its [Component3D] ancestors have
  /// [visible] set to `true`.
  bool get isEffectivelyVisible {
    if (!_visible) {
      return false;
    }
    var cursor = parent;
    while (cursor != null) {
      if (cursor is Component3D && !cursor._visible) {
        return false;
      }
      cursor = cursor.parent;
    }
    return true;
  }

  int _worldTransformVersion = 0;

  /// Monotonically increasing counter bumped whenever this component's local
  /// [transform] or an ancestor [Component3D]'s transform invalidates
  /// [worldTransformMatrix].
  ///
  /// Downstream caches (`Collider3D`, `SceneSpatialIndex3D`, `SpatialAudio3D`)
  /// can compare [worldTransformVersion] against a previously recorded integer
  /// in `O(1)` to skip unchanged world transforms.
  int get worldTransformVersion => _worldTransformVersion;

  Set<String>? _tags3D;

  /// Unmodifiable view of lightweight string tags attached to this component.
  Set<String> get tags3D {
    final tags = _tags3D;
    return tags == null ? const <String>{} : UnmodifiableSetView(tags);
  }

  /// Adds [tag] to [tags3D], returning `true` if it was not already present.
  bool addTag3D(String tag) => (_tags3D ??= <String>{}).add(tag);

  /// Removes [tag] from [tags3D], returning `true` if it was present.
  bool removeTag3D(String tag) => _tags3D?.remove(tag) ?? false;

  /// Whether [tags3D] contains [tag].
  bool hasTag3D(String tag) => _tags3D?.contains(tag) ?? false;

  /// Removes all tags from [tags3D].
  void clearTags3D() => _tags3D?.clear();

  /// The total transformation matrix for the component. This matrix combines
  /// translation, rotation and scale transforms into a single entity. The
  /// matrix is cached and gets recalculated only as necessary.
  Matrix4 get transformMatrix => transform.transformMatrix;

  /// The world-space transformation matrix, accounting for all ancestor
  /// [Component3D]s.
  ///
  /// The result is cached and only recomputed when this component's or an
  /// ancestor's transform changes.
  Matrix4 get worldTransformMatrix {
    if (!_worldTransformDirty) {
      return _worldTransformMatrix;
    }
    _worldTransformDirty = false;

    final p = parent;
    if (p is Component3D) {
      return _worldTransformMatrix
        ..setFrom(p.worldTransformMatrix)
        ..multiply(transformMatrix);
    }
    return _worldTransformMatrix..setFrom(transformMatrix);
  }

  final Matrix4 _worldTransformMatrix = Matrix4.identity();
  bool _worldTransformDirty = true;
  bool _negativeScaleDirty = true;
  bool _hasNegativeScale = false;

  /// Whether this component's accumulated [worldTransformMatrix] reflects an
  /// odd number of negative scale axes (mirroring front-face winding).
  bool get hasNegativeScale {
    if (!_negativeScaleDirty) {
      return _hasNegativeScale;
    }
    _negativeScaleDirty = false;
    final s = scale;
    final prod = s.x * s.y * s.z;
    if (prod == 0) {
      return _hasNegativeScale = false;
    }
    final local = prod < 0;
    final p = parent;
    return _hasNegativeScale = p is Component3D
        ? (p.hasNegativeScale != local)
        : local;
  }

  /// The position of this component's anchor on the screen.
  NotifyingVector3 get position => transform.position;
  set position(Vector3 position) => transform.position = position;

  /// X position of this component's anchor on the screen.
  double get x => transform.x;
  set x(double x) => transform.x = x;

  /// Y position of this component's anchor on the screen.
  double get y => transform.y;
  set y(double y) => transform.y = y;

  /// Z position of this component's anchor on the screen.
  double get z => transform.z;
  set z(double z) => transform.z = z;

  /// The rotation of this component.
  NotifyingQuaternion get rotation => transform.rotation;
  set rotation(Quaternion rotation) => transform.rotation = rotation;

  /// The scale factor of this component. The scale can be different along
  /// the X, Y and Z dimensions. A scale greater than 1 makes the component
  /// bigger along that axis, and less than 1 smaller. The scale can also be
  /// negative, which results in a mirror reflection along the corresponding
  /// axis.
  NotifyingVector3 get scale => transform.scale;
  set scale(Vector3 scale) => transform.scale = scale;

  /// Measure the distance (in parent's coordinate space) between this
  /// component's anchor and the [other] component's anchor.
  double distance(Component3D other) => position.distanceTo(other.position);

  /// The world-space axis-aligned bounding box for this component and all its
  /// [Component3D] children.
  ///
  /// Subclasses with geometry (e.g. `MeshComponent`) override
  /// [computeLocalAabb] to include their own mesh bounds.
  Aabb3 get aabb {
    if (_aabbDirty) {
      _recomputeAabb();
      _aabbDirty = false;
    }
    return _cachedAabb;
  }

  final Aabb3 _cachedAabb = Aabb3();
  bool _aabbDirty = true;

  // The union of bounds this component is part of, see [ComponentBounds].
  ComponentBounds? _boundsOwner;
  // Whether this component waits in its owner's list of changed bounds.
  bool _boundsQueued = false;
  // The slot of this component in its owner.
  int _boundsSlot = 0;

  World3D? _cachedWorld;

  // The render of its world's shadows ([ShadowCasterTracker.clock]) in which
  // this component, an Object3D, last changed in a way that can move its
  // shadow, or [ShadowCasterTracker._unmounted].
  int _shadowChangeClock = ShadowCasterTracker._unmounted;

  /// Enclosing [World3D], or `null` when mounted outside of one (e.g. in
  /// standalone component tests).
  @internal
  World3D? get worldOrNull => _cachedWorld;

  /// Compute the local-space AABB for this component's own geometry.
  ///
  /// The base implementation returns `null` (no geometry). Subclasses with
  /// geometry should override this to return their mesh/model AABB.
  @protected
  Aabb3? computeLocalAabb() => null;

  @override
  void onMount() {
    super.onMount();
    _childComponents3D?.clear();
    _non3DChildCount = 0;
    _hasPrioritizedChild = false;
    _cachedWorld = null;
    var cursor = parent;
    while (cursor != null) {
      if (cursor is World3D) {
        _cachedWorld = cursor;
        break;
      }
      cursor = cursor.parent;
    }
    _markWorldTransformDirty();
    if (parent case final Component3D parent) {
      parent.markAabbDirty();
    }
    final world = _cachedWorld;
    if (world != null) {
      onWorldMounted(world);
    }
    world?.markComponentDirty(shadows: affectsShadowPass);
  }

  /// Hook invoked when this component mounts inside [world].
  @protected
  void onWorldMounted(World3D world) {}

  @override
  void onRemove() {
    final world = _cachedWorld;
    if (world != null) {
      onWorldRemoved(world);
    }
    world?.markComponentDirty(shadows: affectsShadowPass);
    _cachedWorld = null;
    if (parent case final Component3D parent) {
      parent.markAabbDirty();
    }
    super.onRemove();
  }

  /// Hook invoked when this component leaves [world].
  @protected
  void onWorldRemoved(World3D world) {}

  void _recomputeAabb() {
    final localAabb = computeLocalAabb();
    var initialized = false;

    if (localAabb != null) {
      _cachedAabb
        ..setFrom(localAabb)
        ..transform(worldTransformMatrix);
      initialized = true;
    }

    final list = _childComponents3D;
    if (list != null && list.isNotEmpty) {
      for (var i = 0; i < list.length; i++) {
        final childAabb = list[i].aabb;
        if (initialized) {
          _cachedAabb.hull(childAabb);
        } else {
          _cachedAabb.setFrom(childAabb);
          initialized = true;
        }
      }
    } else if (!isMounted && hasChildren) {
      for (final child in children) {
        if (child is Component3D) {
          final childAabb = child.aabb;
          if (initialized) {
            _cachedAabb.hull(childAabb);
          } else {
            _cachedAabb.setFrom(childAabb);
            initialized = true;
          }
        }
      }
    }

    if (!initialized) {
      // No geometry and no children, so degenerate to point at the world
      // position.
      final s = worldTransformMatrix.storage;
      _cachedAabb
        ..min.setValues(s[12], s[13], s[14])
        ..max.setValues(s[12], s[13], s[14]);
    }
  }

  /// Mark this component's AABB as needing recomputation.
  ///
  /// This propagates up to parent [Component3D]s so the entire hierarchy
  /// stays consistent.
  void markAabbDirty() {
    if (_aabbDirty) {
      return;
    }
    _aabbDirty = true;
    onAabbDirtied();

    if (parent case final Component3D parent) {
      parent.markAabbDirty();
    } else {
      _boundsOwner?._changed(this);
    }
  }

  /// Hook invoked when this component's bounds are marked dirty.
  @protected
  void onAabbDirtied() {}

  @override
  void renderTree(Canvas canvas) {
    if (!_visible) {
      return;
    }
    // The pass mask is tested for every component, not only for the
    // Object3Ds, so that a group's mask hides its subtree in every pass. The
    // default mask passes every pass that draws anything.
    if (cameraMask != 0xFFFFFFFF) {
      final world = _cachedWorld ?? findWorld();
      if (world != null &&
          world.isRendering &&
          (cameraMask & world.context.cameraMask) == 0) {
        return;
      }
    }
    super.renderTree(canvas);
  }

  /// Fast 3D traversal entry point bypassing Flame's per-child virtual
  /// `renderChild` / `PictureRecorder` overhead for pure 3D subtrees.
  @internal
  void renderTree3D(World3D world, RenderContext3D context, Canvas? canvas) {
    if (!_visible) {
      return;
    }
    if (cameraMask != 0xFFFFFFFF && (cameraMask & context.cameraMask) == 0) {
      return;
    }
    if (debugMode || _non3DChildCount > 0 || (!isMounted && hasChildren)) {
      super.renderTree(canvas ?? world.fallbackDummyCanvas());
      return;
    }
    if (_hasPrioritizedChild) {
      if (hasChildren) {
        for (final child in children) {
          if (child is Component3D) {
            child.renderTree3D(world, context, canvas);
          } else {
            child.renderTree(canvas ?? world.fallbackDummyCanvas());
          }
        }
      }
      return;
    }
    final list = _childComponents3D;
    if (list != null) {
      for (var i = 0; i < list.length; i++) {
        list[i].renderTree3D(world, context, canvas);
      }
    }
  }

  /// Creates a shallow copy of this component's own subtype and
  /// subtype-specific properties, without copying children.
  ///
  /// [clone] invokes [cloneSelf] and then copies [transform], [visible],
  /// [cameraMask], [priority], [prefabId], [tags3D], and (when requested)
  /// descendant [Component3D]s.
  ///
  /// The built-in leaf components override [cloneSelf] (`Group3D`,
  /// `MeshComponent`, `LightComponent`, `LodMeshComponent`, `InstancedGroup3D`,
  /// `SkyboxComponent3D`, `Text3DComponent`, and `ModelComponent`). Meshes,
  /// materials and models are shared with the copy, not copied. Any other
  /// type, a subclass included, throws an [UnsupportedError] unless it
  /// overrides [cloneSelf] to copy its own state: a copy of another type
  /// would silently lose it.
  @protected
  Component3D cloneSelf() {
    throw UnsupportedError(
      '$runtimeType cannot be cloned: it does not override '
      'Component3D.cloneSelf to copy its own state. Override cloneSelf, or '
      'register a builder prefab (PrefabRegistry3D.registerBuilder) instead of '
      'a prototype.',
    );
  }

  /// Hook allowing intermediate base classes (such as `Object3D`) to copy
  /// base-layer state onto [copy] during [clone].
  @protected
  void copySubtypeStateTo(Component3D copy) {}

  /// Deep-clones (or shallow-clones when [includeChildren] is `false`) this
  /// [Component3D], preserving local TRS [transform], [visible], [cameraMask],
  /// [priority], [prefabId], [tags3D], and base-subtype properties via
  /// [copySubtypeStateTo].
  Component3D clone({bool includeChildren = true}) {
    final copy = cloneSelf()
      ..position.setFrom(position)
      ..rotation.setFrom(rotation)
      ..scale.setFrom(scale)
      ..visible = _visible
      ..cameraMask = cameraMask
      ..priority = priority
      ..prefabId = prefabId;
    copySubtypeStateTo(copy);
    if (_tags3D case final tags? when tags.isNotEmpty) {
      for (final tag in tags) {
        copy.addTag3D(tag);
      }
    }
    if (includeChildren && hasChildren) {
      for (final child in children) {
        if (child is Component3D) {
          copy.add(child.clone());
        }
      }
    }
    return copy;
  }

  /// Mark this component's world transform, and therefore its AABB, as
  /// needing recomputation.
  ///
  /// This propagates down to child [Component3D]s so the entire subtree
  /// stays consistent.
  ///
  /// When [recordShadowMove] is `true`, shadow-casting descendants notify
  /// the world's `ShadowCasterTracker`.
  void _markWorldTransformDirty({bool recordShadowMove = false}) {
    _worldTransformVersion++;
    _worldTransformDirty = true;
    _negativeScaleDirty = true;
    _aabbDirty = true;
    onWorldTransformDirtied(_cachedWorld, recordShadowMove: recordShadowMove);
    final list = _childComponents3D;
    if (list != null && list.isNotEmpty) {
      for (var i = 0; i < list.length; i++) {
        list[i]._markWorldTransformDirty(recordShadowMove: recordShadowMove);
      }
    } else if (!isMounted && hasChildren) {
      for (final child in children) {
        if (child is Component3D) {
          child._markWorldTransformDirty(recordShadowMove: recordShadowMove);
        }
      }
    }
  }

  /// Hook invoked when this component's world transform becomes dirty.
  @protected
  void onWorldTransformDirtied(
    World3D? world, {
    required bool recordShadowMove,
  }) {}

  void _onTransformChanged() {
    final world = _cachedWorld;
    final movesShadows = world != null && _moveCanMoveShadows();
    _markWorldTransformDirty(recordShadowMove: movesShadows);
    if (parent case final Component3D parent) {
      parent.markAabbDirty();
    } else {
      _boundsOwner?._changed(this);
    }
    world?.markComponentDirty(shadows: movesShadows);
  }

  /// Whether moving this component can change a shadow map: when it has
  /// 3D children (they move along) or [isShadowDirtyOnMove] holds.
  bool _moveCanMoveShadows() {
    final list = _childComponents3D;
    if (list != null && list.isNotEmpty) {
      return true;
    }
    if (!isMounted && hasChildren) {
      for (final child in children) {
        if (child is Component3D) {
          return true;
        }
      }
    }
    return isShadowDirtyOnMove;
  }
}

/// Concrete grouping [Component3D] node without geometry of its own, used to
/// organize, transform, hide/show, tag, and clone 3D subtrees.
class Group3D({
  super.position,
  super.scale,
  super.rotation,
  super.children,
  super.visible,
  super.tags3D,
  super.prefabId,
  super.cameraMask,
}) extends Component3D {
  @override
  Component3D cloneSelf() {
    if (runtimeType != Group3D) {
      return super.cloneSelf();
    }
    return Group3D();
  }
}
