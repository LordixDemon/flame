import 'dart:ui';

import 'package:flame/game.dart' show FlameGame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/extensions.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

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

  /// Whether an ancestor's AABB was fully inside the frustum, meaning
  /// children can skip their own frustum tests.
  static bool _ancestorFullyInside = false;

  @override
  void renderTree(Canvas canvas) {
    if (!isEffectivelyVisible) {
      return;
    }
    final world = worldRef;
    assert(
      world.isRendering,
      'Object3D is rendered outside of the rendering of its World3D',
    );
    final context = world.context;
    if ((cameraMask & context.cameraMask) == 0) {
      return;
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

    // Render children. If fully inside, children can skip frustum tests.
    final wasAncestorFullyInside = _ancestorFullyInside;
    if (cullResult == CullResult.inside) {
      _ancestorFullyInside = true;
    }
    super.renderTree(canvas);
    _ancestorFullyInside = wasAncestorFullyInside;
    RenderProfile.lap(RenderPhase.traversal);

    final inFrustum = cullResult == CullResult.inside || isVisible(frustum);
    RenderProfile.lap(RenderPhase.culling);
    if (inFrustum) {
      bind(context);
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
}
