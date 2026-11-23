import 'dart:ui';

import 'package:flame/game.dart' show FlameGame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

/// {@template object_3d}
/// [Object3D]s are the basic building blocks for a 3D [FlameGame].
///
/// It is an object that is positioned in 3D space and can be drawn by a
/// [RenderContext].
///
/// However, it has no visual representation of its own (except in
/// debug mode). It is common, therefore, to derive from this class
/// and implement a specific rendering logic.
///
/// See the [MeshComponent] for an [Object3D] that has a visual representation
/// using a [Mesh].
/// {@endtemplate}
abstract class Object3D({
  super.position,
  super.scale,
  super.rotation,
  super.children,
  super.visible,
  super.tags3D,
  super.prefabId,
  bool castsShadows = true,
  super.cameraMask,
}) extends Component3D {
  /// Whether this object casts shadows, when the scene has a light that
  /// casts them (see [ShadowSettings]). It applies to this object's own
  /// draws, not to its children; the surfaces of materials that cast no
  /// shadows (see [Material.castsShadows]) cast none either way.
  ///
  /// Changing it marks the shadow casters of the enclosing [World3D] dirty
  /// (see [World3D.castersVersion]).
  bool get castsShadows => _castsShadows;
  set castsShadows(bool value) {
    if (value == _castsShadows) {
      return;
    }
    _castsShadows = value;
    markDrawDirty();
  }

  bool _castsShadows = castsShadows;

  /// How the shadow of this object is kept by
  /// [ShadowSettings.cacheStillCasters]: decided by the engine from the
  /// changes it sees ([ShadowCasterMotion.auto], the default), always kept
  /// with the still casters ([ShadowCasterMotion.still]), or always drawn
  /// again ([ShadowCasterMotion.moving]).
  ///
  /// The engine sees the changes made through the setters of the engine's
  /// components (a move of the object or of an ancestor, [visible],
  /// [castsShadows], `jointTransforms`, the instances of an
  /// `InstancedGroup3D`, the poses of a `ModelComponent`, live mesh
  /// particles, ...) and those reported with [markDrawDirty]. Set
  /// [ShadowCasterMotion.moving] on an object whose shadow changes in ways
  /// it cannot see and that you do not report, such as vertices your own
  /// code writes in place in every frame.
  ///
  /// Changing it renders the kept layer of still casters again.
  ShadowCasterMotion get shadowMotion => _shadowMotion;
  set shadowMotion(ShadowCasterMotion value) {
    if (value == _shadowMotion) {
      return;
    }
    final previous = _shadowMotion;
    _shadowMotion = value;
    final world = worldOrNull;
    if (world != null) {
      world.shadowCasters.motionChanged(this, previous, value);
      world.markComponentDirty(shadows: true);
    }
  }

  ShadowCasterMotion _shadowMotion = ShadowCasterMotion.auto;

  /// Index inside `ShadowCasterTracker`'s active movers list, or `-1`.
  @internal
  int shadowMoverIndex = -1;

  /// Whether [SceneSpatialIndex3D] has queued a pending transform/bounds update
  /// for this object.
  @internal
  bool spatialIndexDirty = false;

  /// Whether this component uses the default frustum AABB test in
  /// [isVisible] without custom subclass overrides.
  @internal
  bool get usesDefaultFrustumVisibility => false;

  /// Whether an ancestor's AABB was fully inside the frustum, meaning
  /// children can skip their own frustum tests.
  static bool _ancestorFullyInside = false;

  @override
  void renderTree(Canvas canvas) {
    if (!visible) {
      return;
    }
    final world = worldOrNull;
    if (world != null) {
      if (!world.isTraversingTree && !isEffectivelyVisible) {
        return;
      }
      _renderObjectTree(world, world.context, canvas, fast3D: false);
      return;
    }
    if (!isEffectivelyVisible) {
      return;
    }
    final resolvedWorld = worldRef;
    _renderObjectTree(
      resolvedWorld,
      resolvedWorld.context,
      canvas,
      fast3D: false,
    );
  }

  @override
  void renderTree3D(World3D world, RenderContext3D context, Canvas? canvas) {
    if (!visible) {
      return;
    }
    _renderObjectTree(world, context, canvas, fast3D: true);
  }

  void _renderObjectTree(
    World3D world,
    RenderContext3D context,
    Canvas? canvas, {
    required bool fast3D,
  }) {
    assert(
      world.isRendering,
      'Object3D is rendered outside of the rendering of its World3D',
    );
    if (cameraMask != 0xFFFFFFFF && (cameraMask & context.cameraMask) == 0) {
      return;
    }
    final hasKids = hasChildren;
    final isShadowPass = context.isShadowPass;
    var drawSelf = true;
    if (isShadowPass) {
      final layer = context.shadowCasterLayer;
      if (!castsShadows ||
          (layer != ShadowCasterLayer.all && !_inShadowLayer(layer))) {
        if (!hasKids) {
          return;
        }
        drawSelf = false;
      }
    }
    // The frustum of the pass, computed once by the context.
    final frustum = context.frustum;
    RenderProfile.lap(RenderPhase.traversal);

    // If ancestor is inside, so are we, otherwise test.
    final cullResult = _ancestorFullyInside
        ? CullResult.inside
        : aabb.frustumCullTest(frustum);
    RenderProfile.lap(RenderPhase.culling);

    // Result is fully outside, skip children and self.
    if (cullResult == CullResult.outside) {
      return;
    }

    if (!isShadowPass) {
      final culler = world.occlusionCuller;
      if (culler != null &&
          culler.rasterizedOccluderCount > 0 &&
          !culler.isAabbVisible(aabb, context.viewProjection)) {
        return;
      }
    }

    if (hasKids) {
      final wasAncestorFullyInside = _ancestorFullyInside;
      if (cullResult == CullResult.inside) {
        _ancestorFullyInside = true;
      }
      if (fast3D) {
        super.renderTree3D(world, context, canvas);
      } else {
        super.renderTree(canvas!);
      }
      _ancestorFullyInside = wasAncestorFullyInside;
      RenderProfile.lap(RenderPhase.traversal);
    }

    final inFrustum =
        drawSelf &&
        (cullResult == CullResult.inside ||
            usesDefaultFrustumVisibility ||
            isVisible(frustum));
    RenderProfile.lap(RenderPhase.culling);
    if (inFrustum) {
      world.recordVisibleObject(this);
      if (fast3D ? visible : (!hasKids || isEffectivelyVisible)) {
        draw(context);
      }
    }
  }

  /// Binds and records this object's draws into [context] unless hidden by
  /// [isEffectivelyVisible], excluded from a shadow pass by [castsShadows],
  /// or not of the layer of casters the shadow pass records
  /// ([RenderContext3D.shadowCasterLayer], see [shadowMotion]).
  void bind(RenderContext context) {
    if (!isEffectivelyVisible) {
      return;
    }
    if (context is RenderContext3D && context.isShadowPass) {
      if (!castsShadows) {
        return;
      }
      final layer = context.shadowCasterLayer;
      if (layer != ShadowCasterLayer.all && !_inShadowLayer(layer)) {
        return;
      }
    }
    draw(context);
  }

  /// Whether this object is of the casters of [layer], [ShadowCasterLayer]
  /// `still` or `moving`.
  bool _inShadowLayer(ShadowCasterLayer layer) {
    final casters = worldOrNull?.shadowCasters;
    if (casters == null) {
      return layer == ShadowCasterLayer.still;
    }
    final still = casters.isStill(this);
    if (layer == ShadowCasterLayer.still) {
      return still;
    }
    if (!still) {
      casters.drawnMoving(this);
    }
    return !still;
  }

  /// Records the draws of this object into [context], see
  /// [RenderContext3D.drawMesh] and [RenderContext3D.drawSurface].
  ///
  /// It is called while the world is traversed; the recorded draws reach the
  /// GPU when the context is flushed at the end of the pass. When the scene
  /// has a light that casts shadows, the world is traversed a first time to
  /// render the shadow map, with the light's view as the camera (see
  /// [RenderContext3D.isShadowPass]); objects that do not [castsShadows] are
  /// not drawn then.
  void draw(RenderContext context);

  /// Whether this component should be culled for [frustum] (either because
  /// [isEffectivelyVisible] is `false` or because its [aabb] is outside
  /// [frustum]).
  bool shouldCull(Frustum frustum) => !isVisible(frustum);

  /// Whether this component itself should be drawn when its [aabb] is not
  /// fully inside the camera's [frustum] (the light's view in a shadow
  /// pass).
  ///
  /// Returns `false` immediately when [isEffectivelyVisible] is `false`.
  /// Otherwise checks whether the world-space [aabb] intersects [frustum].
  bool isVisible(Frustum frustum) {
    if (!isEffectivelyVisible) {
      return false;
    }
    return frustum.intersectsWithAabb3(aabb);
  }

  /// Intersects [worldRay] against this object's own geometry within
  /// [maxDistance], returning the closest [RayHit3D] or `null` when missed.
  ///
  /// Subclasses that draw meshes ([MeshComponent], `ModelComponent`,
  /// [LodMeshComponent], [InstancedGroup3D]) override this using `Surface.bvh`.
  RayHit3D? raycast(
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) => null;

  @override
  bool get isShadowDirtyOnMove => castsShadows;

  @override
  void onShadowSubtreeShown(World3D world) {
    world.shadowCasters.shown(this);
  }

  @override
  void onShadowSubtreeHidden(World3D world) {
    world.shadowCasters.changed(this);
  }

  @override
  void onMarkDrawDirty(World3D world, {required bool shadows}) {
    if (shadows) {
      world.shadowCasters.changed(this);
    }
    world.markComponentDirty(shadows: shadows);
  }

  @override
  void onWorldTransformDirtied(
    World3D? world, {
    required bool recordShadowMove,
  }) {
    if (world == null) {
      return;
    }
    if (recordShadowMove) {
      world.shadowCasters.changed(this);
    }
    world.spatialIndex3D.onObjectMoved(this);
  }

  @override
  void onWorldMounted(World3D world) {
    world.shadowCasters.added(this);
    world.spatialIndex3D.onObjectAdded(this);
  }

  @override
  void onWorldRemoved(World3D world) {
    world.shadowCasters.removed(this);
    world.spatialIndex3D.onObjectRemoved(this);
  }

  @override
  void onAabbDirtied() {
    worldOrNull?.spatialIndex3D.onObjectMoved(this);
  }

  @override
  void copySubtypeStateTo(Component3D copy) {
    if (copy is Object3D) {
      copy.shadowMotion = shadowMotion;
    }
  }

  /// Visits every `(mesh, worldMatrix)` pair contributing to this object's
  /// collision geometry. Return `false` from [visitor] to stop early.
  void visitCollisionMeshes(
    bool Function(Mesh mesh, Matrix4 worldMatrix) visitor,
  ) {}
}
