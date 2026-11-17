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
}) extends Component3D {
  /// Whether an ancestor's AABB was fully inside the frustum, meaning
  /// children can skip their own frustum tests.
  static bool _ancestorFullyInside = false;

  @override
  void renderTree(Canvas canvas) {
    assert(
      CameraComponent3D.currentCamera != null,
      '''Component is either not part of a World3D or the render is being called outside of the camera rendering''',
    );
    final context = worldRef.context;
    // The frustum of the pass, computed once by the context.
    final frustum = context.frustum;

    // If ancestor is inside, so are we, otherwise test.
    final cullResult = _ancestorFullyInside
        ? CullResult.inside
        : aabb.frustumCullTest(frustum);

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

    if (cullResult == CullResult.inside || isVisible(frustum)) {
      draw(context);
    }
  }

  /// Records the draws of this object into [context], see
  /// [RenderContext3D.drawMesh] and [RenderContext3D.drawSurface].
  ///
  /// It is called while the world is traversed; the recorded draws reach the
  /// GPU when the context is flushed at the end of the pass.
  void draw(RenderContext context);

  /// Whether this component itself should be drawn when its [aabb] is not
  /// fully inside the camera's [frustum].
  ///
  /// The default implementation checks whether the world-space [aabb]
  /// intersects the frustum, so a partially visible component is drawn.
  bool isVisible(Frustum frustum) {
    return frustum.intersectsWithAabb3(aabb);
  }
}
