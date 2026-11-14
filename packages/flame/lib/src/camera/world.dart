import 'dart:ui';

import 'package:flame/src/camera/camera_component.dart';
import 'package:flame/src/camera/render_pass.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/mixins/coordinate_transform.dart';
import 'package:flame/src/rendering/decorator.dart';
import 'package:vector_math/vector_math.dart';

/// The root component for all game world elements.
///
/// The primary feature of this component is that it disables regular rendering,
/// and allows itself to be rendered through a [CameraComponent] only. The
/// updates proceed through the world tree normally.
///
/// The [priority] of the world by default is the maximum 32bit negative int
/// value to ensure it will always be earlier in the component tree than a
/// [CameraComponent].
class World({
  super.children,
  super.priority = -0x7fffffff,
  super.key,
}) extends Component implements CoordinateTransform {
  /// Optional decorator chain applied when this world is rendered through a
  /// [CameraComponent] (also used by `WorldRoute.addRenderEffect`).
  final Decorator decorator = Decorator();

  /// Optional callback invoked before each [RenderPass] when observed by a
  /// multi-pass [CameraComponent].
  void Function(Canvas canvas, RenderPass pass)? beforePassCallback;

  /// Optional callback invoked after each [RenderPass] when observed by a
  /// multi-pass [CameraComponent] (for example to flush shared 3D or sprite
  /// pass buffers).
  void Function(Canvas canvas, RenderPass pass)? afterPassCallback;

  @override
  void renderTree(Canvas canvas) {}

  /// Hook invoked immediately before [renderFromCamera] for [pass] when
  /// [CameraComponent.renderPasses] is non-empty.
  void onBeforeRenderPass(Canvas canvas, RenderPass pass) {}

  /// Hook invoked immediately after [renderFromCamera] for [pass] when
  /// [CameraComponent.renderPasses] is non-empty.
  void onAfterRenderPass(Canvas canvas, RenderPass pass) {}

  /// The rendering method invoked by the [CameraComponent].
  ///
  /// If you want to do changes to the rendering of the world, this is the
  /// method that you want to override, not [renderTree].
  void renderFromCamera(Canvas canvas) {
    assert(CameraComponent.currentCamera != null);
    if (decorator.isLastDecorator) {
      super.renderTree(canvas);
    } else {
      decorator.applyChain(super.renderTree, canvas);
    }
  }

  @override
  bool containsLocalPoint(Vector2 point) => true;

  @override
  Vector2? localToParent(Vector2 point) => null;

  @override
  Vector2? parentToLocal(Vector2 point) => null;
}
