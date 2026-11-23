import 'dart:collection' show UnmodifiableSetView;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Canvas;

import 'package:flame/components.dart' show Component, HasWorldRef;
import 'package:flame/extensions.dart' show Matrix4Extension;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/resources.dart';
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
/// - [LightComponent] for a light source that affects how objects are rendered
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
    this.children.register<Component3D>();
    _childComponents = this.children.query<Component3D>();
    if (tags3D != null) {
      for (final tag in tags3D) {
        addTag3D(tag);
      }
    }
    transform.addListener(_onTransformChanged);
  }

  late final Iterable<Component3D> _childComponents;

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
    if (this is LightComponent) {
      world.markSceneDirty(shadows: false);
      return;
    }
    // The casters of the subtree leave the kept layer of still casters, or
    // join the casters drawn in every frame (they were not in the layer).
    final casters = world.shadowCasters;
    if (value) {
      _noteShadowSubtreeShown(casters);
    } else {
      _noteShadowSubtreeHidden(casters);
    }
    world.markComponentDirty(shadows: true);
  }

  void _noteShadowSubtreeShown(ShadowCasterTracker casters) {
    final self = this;
    if (self is Object3D) {
      casters.shown(self);
    }
    for (final child in _childComponents) {
      child._noteShadowSubtreeShown(casters);
    }
  }

  void _noteShadowSubtreeHidden(ShadowCasterTracker casters) {
    final self = this;
    if (self is Object3D) {
      casters.changed(self);
    }
    for (final child in _childComponents) {
      child._noteShadowSubtreeHidden(casters);
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
    _cachedWorld?.markSceneDirty(shadows: this is! LightComponent);
  }

  /// Reports that what this component draws changed in a way the engine
  /// cannot see: data changed in place, such as joint matrices written into
  /// an existing list, a field of a material or of a light source's vector,
  /// or the buffers of a custom [Object3D.draw].
  ///
  /// Changes made through the setters of the engine's components (transform,
  /// [visible], [cameraMask], `MeshComponent.color`, `instanceData`, ...) are
  /// reported by the setters themselves; only call this for the others.
  ///
  /// It bumps the enclosing [World3D]'s [World3D.sceneVersion], and its
  /// [World3D.castersVersion] unless [shadows] is `false`, so that
  /// `Scene3DCacheMode.retained` layers and a cached static shadow map
  /// ([ShadowSettings.cacheWhenStatic]) render again, and wakes a game whose
  /// `idleRenderMode` skips unchanged frames. Pass `shadows: false` when the
  /// change cannot reach a shadow map (a color, a value only the fragment
  /// shader reads). It costs two integer increments; it does nothing for a
  /// component outside a [World3D].
  ///
  /// With [ShadowSettings.cacheStillCasters], an [Object3D] that reports a
  /// change that can reach the shadows is drawn in every frame until it
  /// stays unchanged for [ShadowSettings.stillCasterFrames] renders of the
  /// shadows; the kept layer of still casters is rendered again only when
  /// the object was part of it. For any other component, the layer is
  /// rendered again.
  void markDrawDirty({bool shadows = true}) {
    final world = _cachedWorld;
    if (world == null) {
      return;
    }
    final self = this;
    if (shadows && self is! Object3D) {
      world.markSceneDirty();
      return;
    }
    if (shadows && self is Object3D) {
      world.shadowCasters.changed(self);
    }
    world.markComponentDirty(shadows: shadows);
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
  /// Downstream caches (`Collider3D`, [SceneSpatialIndex3D], `SpatialAudio3D`)
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
  set rotation(NotifyingQuaternion rotation) => transform.rotation = rotation;

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
  /// Subclasses with geometry (e.g. [MeshComponent]) override
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
    _cachedWorld = null;
    for (final ancestor in ancestors()) {
      if (ancestor is World3D) {
        _cachedWorld = ancestor;
        break;
      }
    }
    _markWorldTransformDirty();
    if (parent case final Component3D parent) {
      parent.markAabbDirty();
    }
    final world = _cachedWorld;
    final self = this;
    if (world != null && self is Object3D) {
      world.shadowCasters.added(self);
      world.spatialIndex3D.onObjectAdded(self);
    }
    world?.markComponentDirty(shadows: this is! LightComponent);
  }

  @override
  void onRemove() {
    final world = _cachedWorld;
    final self = this;
    if (world != null && self is Object3D) {
      world.shadowCasters.removed(self);
      world.spatialIndex3D.onObjectRemoved(self);
    }
    world?.markComponentDirty(shadows: this is! LightComponent);
    _cachedWorld = null;
    if (parent case final Component3D parent) {
      parent.markAabbDirty();
    }
    super.onRemove();
  }

  void _recomputeAabb() {
    final localAabb = computeLocalAabb();
    var initialized = false;

    if (localAabb != null) {
      _cachedAabb
        ..setFrom(localAabb)
        ..transform(worldTransformMatrix);
      initialized = true;
    }

    for (final child in _childComponents) {
      if (initialized) {
        _cachedAabb.hull(child.aabb);
      } else {
        _cachedAabb.setFrom(child.aabb);
        initialized = true;
      }
    }

    if (!initialized) {
      // No geometry and no children, so degenerate to point at the world
      // position.
      final world = worldTransformMatrix;
      _cachedAabb
        ..min.setValues(world.m41, world.m42, world.m43)
        ..max.setValues(world.m41, world.m42, world.m43);
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
    final self = this;
    if (self is Object3D) {
      _cachedWorld?.spatialIndex3D.onObjectMoved(self);
    }

    if (parent case final Component3D parent) {
      parent.markAabbDirty();
    } else {
      _boundsOwner?._changed(this);
    }
  }

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

  /// Creates a shallow copy of this component's own subtype and
  /// subtype-specific properties, without copying children.
  ///
  /// [clone] invokes [cloneSelf] and then copies [transform], [visible],
  /// [cameraMask], [priority], [prefabId], [tags3D], and (when requested)
  /// descendant [Component3D]s.
  ///
  /// The built-in implementation copies [Group3D], [MeshComponent],
  /// [LightComponent], [LodMeshComponent], [InstancedGroup3D] (with the
  /// colors and instance data of its instances), [SkyboxComponent3D] and
  /// [Text3DComponent]; `ModelComponent` overrides it. Meshes, materials and
  /// models are shared with the copy, not copied. Any other type, a subclass
  /// of these types included, throws an [UnsupportedError] unless it
  /// overrides [cloneSelf] to copy its own state: a copy of another type
  /// would silently lose it.
  @protected
  Component3D cloneSelf() {
    final type = runtimeType;
    switch (this) {
      case _ when type == Group3D:
        return Group3D();
      case final MeshComponent self when type == MeshComponent:
        return MeshComponent(
          mesh: self.mesh,
          castsShadows: self.castsShadows,
          color: self.color,
          instanceData: self.instanceData.clone(),
          jointTransforms: self.jointTransforms == null
              ? null
              : {
                  for (final entry in self.jointTransforms!.entries)
                    entry.key: [for (final m in entry.value) m.clone()],
                },
        );
      case final LightComponent self when type == LightComponent:
        return LightComponent(
          source: _cloneLightSource(self.source),
          lightMask: self.lightMask,
        );
      case final LodMeshComponent self when type == LodMeshComponent:
        return LodMeshComponent(
          levels: List.of(self.levels),
          shadowMesh: self.shadowMesh,
          lowestLodInShadowPass: self.lowestLodInShadowPass,
          hysteresis: self.hysteresis,
          color: self.color,
          instanceData: self.instanceData.clone(),
          castsShadows: self.castsShadows,
        );
      case final InstancedGroup3D self when type == InstancedGroup3D:
        final copy = InstancedGroup3D(
          mesh: self.mesh,
          initialCapacity: math.max(1, self.length),
          castsShadows: self.castsShadows,
        );
        final transform = Matrix4.zero();
        final data = Vector4.zero();
        for (var i = 0; i < self.length; i++) {
          copy.addInstance(
            transform: self.instanceTransform(i, out: transform),
            color: self.instanceColor(i),
            instanceData: self.instanceDataAt(i, out: data),
          );
        }
        return copy;
      case final SkyboxComponent3D self when type == SkyboxComponent3D:
        return SkyboxComponent3D(material: self.material);
      case final Text3DComponent self when type == Text3DComponent:
        return Text3DComponent(
          text: self.text,
          style: self.style,
          worldHeight: self.worldHeight,
          backgroundColor: self.backgroundColor,
          borderColor: self.borderColor,
          cornerRadius: self.cornerRadius,
          padding: self.padding,
          orientation: self.orientation,
        );
      case _:
        throw UnsupportedError(
          '$type cannot be cloned: it does not override Component3D.cloneSelf '
          'to copy its own state. Override cloneSelf, or register a builder '
          'prefab (PrefabRegistry3D.registerBuilder) instead of a prototype.',
        );
    }
  }

  /// Deep-clones (or shallow-clones when [includeChildren] is `false`) this
  /// [Component3D], preserving local TRS [transform], [visible], [cameraMask],
  /// [priority], [prefabId], [tags3D], and the [Object3D.shadowMotion] of an
  /// [Object3D].
  Component3D clone({bool includeChildren = true}) {
    final copy = cloneSelf()
      ..position.setFrom(position)
      ..rotation.setFrom(rotation)
      ..scale.setFrom(scale)
      ..visible = _visible
      ..cameraMask = cameraMask
      ..priority = priority
      ..prefabId = prefabId;
    final self = this;
    if (self is Object3D && copy is Object3D) {
      copy.shadowMotion = self.shadowMotion;
    }
    if (_tags3D case final tags? when tags.isNotEmpty) {
      for (final tag in tags) {
        copy.addTag3D(tag);
      }
    }
    if (includeChildren) {
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
  /// The [Object3D]s of the subtree are reported to [casters], when given, as
  /// casters that moved (see [ShadowSettings.cacheStillCasters]).
  void _markWorldTransformDirty([ShadowCasterTracker? casters]) {
    _worldTransformVersion++;
    _worldTransformDirty = true;
    _negativeScaleDirty = true;
    _aabbDirty = true;
    final self = this;
    if (self is LightComponent) {
      // The worlds that borrow the light follow it, see
      // [World3D.lightsVersion].
      _cachedWorld?.markLightsDirty(shadows: _moveCanMoveShadows());
    } else if (self is Object3D) {
      casters?.changed(self);
      _cachedWorld?.spatialIndex3D.onObjectMoved(self);
    }
    for (final child in _childComponents) {
      child._markWorldTransformDirty(casters);
    }
  }

  void _onTransformChanged() {
    final world = _cachedWorld;
    final movesShadows = world != null && _moveCanMoveShadows();
    _markWorldTransformDirty(
      world != null && movesShadows ? world.shadowCasters : null,
    );
    if (parent case final Component3D parent) {
      parent.markAabbDirty();
    } else {
      _boundsOwner?._changed(this);
    }
    world?.markComponentDirty(shadows: movesShadows);
  }

  /// Whether moving this component can change a shadow map: when it has
  /// 3D children (they move along), when it is an [Object3D] that casts
  /// shadows, or when it is a light whose source casts shadows (their maps
  /// are rendered from the light). A moving collider, sound, or light
  /// without shadows leaves a cached static shadow map alone.
  bool _moveCanMoveShadows() {
    if (_childComponents.isNotEmpty) {
      return true;
    }
    final self = this;
    if (self is Object3D) {
      return self.castsShadows;
    }
    if (self is LightComponent) {
      return switch (self.source) {
        final DirectionalLight light => light.shadows != null,
        final SpotLight light => light.shadows != null,
        final PointLight light => light.shadows != null,
        _ => false,
      };
    }
    return false;
  }

  static LightSource _cloneLightSource(LightSource source) {
    switch (source) {
      case final AmbientLight s:
        return AmbientLight(color: s.color, intensity: s.intensity);
      case final HemisphereLight s:
        return HemisphereLight(
          skyColor: s.skyColor,
          groundColor: s.groundColor,
          intensity: s.intensity,
          up: s.up.clone(),
        );
      case final DirectionalLight s:
        return DirectionalLight(
          color: s.color,
          intensity: s.intensity,
          direction: s.direction?.clone(),
          specular: s.specular,
          shadows: _cloneShadows(s.shadows),
        );
      case final PointLight s:
        return PointLight(
          color: s.color,
          intensity: s.intensity,
          range: s.range,
          shadows: _cloneShadows(s.shadows),
        );
      case final SpotLight s:
        return SpotLight(
          color: s.color,
          intensity: s.intensity,
          direction: s.direction?.clone(),
          innerConeAngle: s.innerConeAngle,
          outerConeAngle: s.outerConeAngle,
          range: s.range,
          specular: s.specular,
          shadows: _cloneShadows(s.shadows),
        );
      case _:
        throw UnsupportedError(
          'A LightComponent with a ${source.runtimeType} cannot be cloned.',
        );
    }
  }

  static ShadowSettings? _cloneShadows(ShadowSettings? shadows) {
    if (shadows == null) {
      return null;
    }
    return ShadowSettings(
      resolution: shadows.resolution,
      fit: shadows.fit,
      bounds: shadows.bounds == null ? null : Aabb3.copy(shadows.bounds!),
      casterBounds: shadows.casterBounds == null
          ? null
          : Aabb3.copy(shadows.casterBounds!),
      maxDistance: shadows.maxDistance,
      strength: shadows.strength,
      color: shadows.color,
      softness: shadows.softness,
      depthBias: shadows.depthBias,
      normalBias: shadows.normalBias,
      encoding: shadows.encoding,
      stabilize: shadows.stabilize,
      cacheWhenStatic: shadows.cacheWhenStatic,
      cacheStillCasters: shadows.cacheStillCasters,
      stillCasterFrames: shadows.stillCasterFrames,
      cascades: shadows.cascades,
      cascadeSplitRatio: shadows.cascadeSplitRatio,
      cascadeSplits: shadows.cascadeSplits == null
          ? null
          : List.of(shadows.cascadeSplits!),
      cascadeBlendRange: shadows.cascadeBlendRange,
    );
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
}) extends Component3D;
