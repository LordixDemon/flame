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
    }
    world?.markComponentDirty(shadows: this is! LightComponent);
  }

  @override
  void onRemove() {
    final world = _cachedWorld;
    final self = this;
    if (world != null && self is Object3D) {
      world.shadowCasters.removed(self);
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
    _aabbDirty = true;
    final self = this;
    if (self is LightComponent) {
      // The worlds that borrow the light follow it, see
      // [World3D.lightsVersion].
      _cachedWorld?.markLightsDirty(shadows: _moveCanMoveShadows());
    } else if (casters != null && self is Object3D) {
      casters.changed(self);
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

/// {@template shadow_caster_tracker}
/// The change tracking of the shadow casters of a [World3D] that
/// [ShadowSettings.cacheStillCasters] relies on: which casters stand still,
/// and when the kept layer of still casters must be rendered again.
///
/// The renders of the world's shadows are counted ([clock]). Each [Object3D]
/// notes the render in which it last changed in a way that can move its
/// shadow; the casters whose last change is at or before [cutoff] are the
/// still ones, kept in the layer, the others are drawn in every frame (see
/// [Object3D.shadowMotion] for the casters that decide themselves).
/// [version] increases when the layer no longer holds what the still
/// casters draw: one of them changed, was hidden or removed, or casters that
/// stopped moving are to join it. The cutoff only moves when [version]
/// does, so that every tile of a map rendered with one version holds the
/// same casters.
/// {@endtemplate}
@internal
class ShadowCasterTracker() {
  static const int _unmounted = 0x7fffffffffff;

  /// The number of renders of the world's shadows so far.
  int get clock => _clock;
  int _clock = 0;

  /// The casters whose last change is at or before this render are still.
  int get cutoff => _cutoff;
  int _cutoff = -1;

  /// Increases when the kept layer of still casters is to be rendered again.
  int get version => _version;
  int _version = 0;
  int _cutoffVersion = -1;

  int _stillFrames = 30;
  bool _joinPending = false;
  // The render in which a caster last changed.
  int _lastChange = -1;

  /// The number of mounted casters whose [Object3D.shadowMotion] is
  /// [ShadowCasterMotion.moving].
  int get alwaysMoving => _alwaysMoving;
  int _alwaysMoving = 0;

  /// Whether [caster] is kept with the still casters.
  bool isStill(Object3D caster) {
    return switch (caster.shadowMotion) {
      ShadowCasterMotion.auto => caster._shadowChangeClock <= _cutoff,
      ShadowCasterMotion.still => true,
      ShadowCasterMotion.moving => false,
    };
  }

  /// Notes that [caster] changed in a way that can move its shadow.
  void changed(Object3D caster) {
    if (isStill(caster)) {
      _version++;
    }
    caster._shadowChangeClock = _clock;
    _noteMover(caster);
  }

  /// Notes that [caster] was mounted.
  void added(Object3D caster) {
    caster._shadowChangeClock = _clock;
    _noteMover(caster);
    switch (caster.shadowMotion) {
      case ShadowCasterMotion.still:
        _version++;
      case ShadowCasterMotion.moving:
        _alwaysMoving++;
      case ShadowCasterMotion.auto:
        break;
    }
  }

  /// Notes that [caster] was shown: it was not drawn into the kept layer.
  void shown(Object3D caster) {
    caster._shadowChangeClock = _clock;
    _noteMover(caster);
    if (caster.shadowMotion == ShadowCasterMotion.still) {
      _version++;
    }
  }

  /// Notes that [caster] is being removed.
  void removed(Object3D caster) {
    if (isStill(caster)) {
      _version++;
    }
    if (caster.shadowMotion == ShadowCasterMotion.moving) {
      _alwaysMoving--;
    }
    caster._shadowChangeClock = _unmounted;
  }

  /// Notes that the [Object3D.shadowMotion] of a mounted [caster] changes
  /// from [from] to [to].
  void motionChanged(
    Object3D caster,
    ShadowCasterMotion from,
    ShadowCasterMotion to,
  ) {
    if (from == ShadowCasterMotion.moving) {
      _alwaysMoving--;
    }
    if (to == ShadowCasterMotion.moving) {
      _alwaysMoving++;
    }
    caster._shadowChangeClock = _clock;
    _noteMover(caster);
    _version++;
  }

  // Notes that [caster], which just changed, is now drawn as a moving
  // caster when the engine decides for it.
  void _noteMover(Object3D caster) {
    if (caster.shadowMotion == ShadowCasterMotion.auto) {
      _lastChange = _clock;
    }
  }

  /// Notes that [caster] is drawn as a moving caster: once it stayed
  /// unchanged long enough, the still casters are kept again with it.
  void drawnMoving(Object3D caster) {
    if (caster.shadowMotion == ShadowCasterMotion.auto &&
        _clock - caster._shadowChangeClock >= _stillFrames) {
      _joinPending = true;
    }
  }

  /// Notes that every caster must be drawn again into the kept layer.
  void invalidate() {
    _version++;
  }

  /// Prepares a render of the shadows whose casters stay unchanged for
  /// [stillFrames] renders before they are kept: the casters that stopped
  /// moving join the still ones (all of them once none changed for that
  /// long, or those drawn as moving casters that did not), and the cutoff
  /// follows [version].
  void prepare(int stillFrames) {
    _stillFrames = stillFrames;
    if (_cutoff < _lastChange && _clock - _lastChange >= stillFrames) {
      _joinPending = true;
    }
    if (_joinPending) {
      _joinPending = false;
      _version++;
    }
    if (_version != _cutoffVersion) {
      _cutoffVersion = _version;
      _cutoff = _clock - stillFrames;
    }
  }

  /// Counts a render of the shadows.
  void advance() {
    _clock++;
  }
}

/// {@template component_bounds}
/// The union of the world-space bounds ([Component3D.aabb]) of a set of
/// components that have no [Component3D] parent, such as the components of a
/// [World3D] (see [World3D.sceneBounds]), kept up to date incrementally.
///
/// Components tell their set when their bounds change: when they or one of
/// their descendants move, or when a descendant is added or removed. The set
/// keeps the bounds of its components in a binary tree whose nodes hold the
/// union of their children, so that reading [value] after `k` of `n`
/// components changed costs at most `k * log2(n)` unions (and nothing when
/// none did), instead of `n`. The union is always exactly that of the
/// current bounds of the components.
/// {@endtemplate}
@internal
class ComponentBounds() {
  // The components, by slot.
  final List<Component3D> _components = [];
  final List<Component3D> _changedComponents = [];

  // A complete binary tree of boxes in an array: node `i` has the children
  // `2i` and `2i + 1`, node 1 is the root and the leaves start at
  // `_capacity`, the leaf of slot `s` being node `_capacity + s`. Each node
  // holds six values, its min and max; empty leaves hold an inverted box.
  Float64List _nodes = Float64List(0);
  int _capacity = 0;
  // Whether the inner nodes are out of date: they are recomputed together
  // once few components change again.
  bool _treeStale = false;

  final Aabb3 _union = Aabb3();
  // Whether [_union] is the union of the leaves.
  bool _unionCurrent = false;

  /// The number of components in the set.
  int get length => _components.length;

  /// Whether [component] is in the set.
  bool contains(Component3D component) =>
      identical(component._boundsOwner, this);

  /// Adds [component] to the set.
  void add(Component3D component) {
    assert(component._boundsOwner == null, 'Already in a set of bounds');
    final slot = _components.length;
    if (slot == _capacity) {
      _grow();
    }
    _components.add(component);
    component
      .._boundsOwner = this
      .._boundsSlot = slot;
    _changed(component);
  }

  /// Removes [component] from the set.
  void remove(Component3D component) {
    if (!identical(component._boundsOwner, this)) {
      return;
    }
    if (component._boundsQueued) {
      component._boundsQueued = false;
      _changedComponents.remove(component);
    }
    // The last component takes the slot of the removed one.
    final slot = component._boundsSlot;
    final last = _components.removeLast();
    final lastSlot = _components.length;
    if (!identical(last, component)) {
      _components[slot] = last;
      last._boundsSlot = slot;
      _copyNode(_capacity + lastSlot, _capacity + slot);
      _updatePath(slot);
    }
    _setEmpty(_capacity + lastSlot);
    _updatePath(lastSlot);
    component._boundsOwner = null;
    _unionCurrent = false;
  }

  void _changed(Component3D component) {
    if (!component._boundsQueued) {
      component._boundsQueued = true;
      _changedComponents.add(component);
    }
  }

  /// The union of the bounds of the components, or `null` when there are
  /// none.
  ///
  /// The box is owned by this set and changes when it is read again; copy it
  /// to keep it.
  Aabb3? get value {
    final changed = _changedComponents;
    if (changed.isNotEmpty) {
      for (final component in changed) {
        component._boundsQueued = false;
        _writeLeaf(_capacity + component._boundsSlot, component.aabb);
      }
      if (changed.length * _capacity.bitLength > _capacity) {
        // So many changed that updating their paths would cost more than
        // uniting the leaves: the inner nodes wait for calmer times.
        _treeStale = true;
      } else if (_treeStale) {
        _uniteAll();
        _treeStale = false;
      } else {
        for (final component in changed) {
          _updatePath(component._boundsSlot);
        }
      }
      changed.clear();
      _unionCurrent = false;
    }
    if (_components.isEmpty) {
      return null;
    }
    if (!_unionCurrent) {
      _unionCurrent = true;
      if (_treeStale) {
        _uniteLeaves();
      } else {
        final nodes = _nodes;
        _union.min.setValues(nodes[6], nodes[7], nodes[8]);
        _union.max.setValues(nodes[9], nodes[10], nodes[11]);
      }
    }
    return _union;
  }

  /// Sets [_union] to the union of the leaves that hold a component.
  void _uniteLeaves() {
    final nodes = _nodes;
    var o = _capacity * 6;
    var minX = nodes[o];
    var minY = nodes[o + 1];
    var minZ = nodes[o + 2];
    var maxX = nodes[o + 3];
    var maxY = nodes[o + 4];
    var maxZ = nodes[o + 5];
    for (var slot = 1; slot < _components.length; slot++) {
      o += 6;
      minX = math.min(minX, nodes[o]);
      minY = math.min(minY, nodes[o + 1]);
      minZ = math.min(minZ, nodes[o + 2]);
      maxX = math.max(maxX, nodes[o + 3]);
      maxY = math.max(maxY, nodes[o + 4]);
      maxZ = math.max(maxZ, nodes[o + 5]);
    }
    _union.min.setValues(minX, minY, minZ);
    _union.max.setValues(maxX, maxY, maxZ);
  }

  void _grow() {
    final capacity = _capacity == 0 ? 8 : _capacity * 2;
    final previous = _nodes;
    _nodes = Float64List(capacity * 2 * 6);
    // Every node starts empty: those above empty leaves stay so.
    for (var node = 1; node < capacity * 2; node++) {
      _setEmpty(node);
    }
    for (var slot = 0; slot < _capacity; slot++) {
      _nodes.setRange(
        (capacity + slot) * 6,
        (capacity + slot) * 6 + 6,
        previous,
        (_capacity + slot) * 6,
      );
    }
    _capacity = capacity;
    _treeStale = true;
    _unionCurrent = false;
  }

  /// Recomputes every inner node above a leaf that holds a component.
  void _uniteAll() {
    final nodes = _nodes;
    final count = _components.length;
    if (count == 0) {
      return;
    }
    var level = 1;
    for (var first = _capacity >> 1; first >= 1; first >>= 1) {
      final last = first + ((count - 1) >> level);
      for (var node = first; node <= last; node++) {
        final o = node * 6;
        final a = node * 12;
        final b = a + 6;
        nodes
          ..[o] = math.min(nodes[a], nodes[b])
          ..[o + 1] = math.min(nodes[a + 1], nodes[b + 1])
          ..[o + 2] = math.min(nodes[a + 2], nodes[b + 2])
          ..[o + 3] = math.max(nodes[a + 3], nodes[b + 3])
          ..[o + 4] = math.max(nodes[a + 4], nodes[b + 4])
          ..[o + 5] = math.max(nodes[a + 5], nodes[b + 5]);
      }
      level++;
    }
  }

  void _writeLeaf(int node, Aabb3 box) {
    final o = node * 6;
    final min = box.min;
    final max = box.max;
    _nodes
      ..[o] = min.x
      ..[o + 1] = min.y
      ..[o + 2] = min.z
      ..[o + 3] = max.x
      ..[o + 4] = max.y
      ..[o + 5] = max.z;
  }

  void _setEmpty(int node) {
    final o = node * 6;
    _nodes
      ..[o] = double.infinity
      ..[o + 1] = double.infinity
      ..[o + 2] = double.infinity
      ..[o + 3] = double.negativeInfinity
      ..[o + 4] = double.negativeInfinity
      ..[o + 5] = double.negativeInfinity;
  }

  void _copyNode(int from, int to) {
    _nodes.setRange(to * 6, to * 6 + 6, _nodes, from * 6);
  }

  /// Recomputes the ancestors of the leaf of [slot], up to the first one
  /// that does not change.
  void _updatePath(int slot) {
    if (_treeStale) {
      return;
    }
    for (var node = (_capacity + slot) >> 1; node >= 1; node >>= 1) {
      if (!_unite(node)) {
        return;
      }
    }
  }

  /// Sets [node] to the union of its children; returns whether it changed.
  bool _unite(int node) {
    final nodes = _nodes;
    final o = node * 6;
    final a = node * 12;
    final b = a + 6;
    final minX = math.min(nodes[a], nodes[b]);
    final minY = math.min(nodes[a + 1], nodes[b + 1]);
    final minZ = math.min(nodes[a + 2], nodes[b + 2]);
    final maxX = math.max(nodes[a + 3], nodes[b + 3]);
    final maxY = math.max(nodes[a + 4], nodes[b + 4]);
    final maxZ = math.max(nodes[a + 5], nodes[b + 5]);
    if (nodes[o] == minX &&
        nodes[o + 1] == minY &&
        nodes[o + 2] == minZ &&
        nodes[o + 3] == maxX &&
        nodes[o + 4] == maxY &&
        nodes[o + 5] == maxZ) {
      return false;
    }
    nodes
      ..[o] = minX
      ..[o + 1] = minY
      ..[o + 2] = minZ
      ..[o + 3] = maxX
      ..[o + 4] = maxY
      ..[o + 5] = maxZ;
    return true;
  }
}
