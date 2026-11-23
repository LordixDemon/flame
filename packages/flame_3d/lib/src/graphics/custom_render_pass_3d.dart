import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';

/// Injection stage for a user-supplied [CustomRenderPass3D] on `World3D`.
enum CustomRenderPassStage3D() {
  /// Runs after shadow & depth-normal prepasses, right before the main scene
  /// pass begins.
  beforeScene,

  /// Runs after the main 3D scene pass has finished, before the
  /// post-processing composite: [CustomRenderPassContext3D.sceneTarget] holds
  /// the scene, which a pass reads, or draws over with
  /// `device.beginTexturePass(sceneTarget, keepContents: true)`.
  afterScene,
}

/// Context passed to a [CustomRenderPass3D] registered in
/// `World3D.customPasses`.
class CustomRenderPassContext3D({
  required final GraphicsDevice device,
  required final RenderContext3D renderContext,
  required final int width,
  required final int height,

  /// The scene's texture target, for [CustomRenderPassStage3D.afterScene]
  /// passes. Begin a pass on it with `keepContents: true` to draw over the
  /// scene: without it the pass clears the scene.
  final GpuTextureTarget? sceneTarget,
  final Texture? depthNormalTexture,
});

/// User-defined GPU render pass hook executed by `World3D` during frame
/// rendering.
class CustomRenderPass3D({
  required final String name,
  required final void Function(CustomRenderPassContext3D context) execute,
  final CustomRenderPassStage3D stage = CustomRenderPassStage3D.afterScene,
  var bool enabled = true,
});
