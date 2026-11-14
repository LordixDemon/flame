import 'dart:ui';

import 'package:flame/src/camera/camera_component.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:meta/meta.dart';

/// Named rendering pass executed by a [CameraComponent] when multi-pass world
/// rendering is enabled via [CameraComponent.renderPasses].
@immutable
class const RenderPass({
  required final String name,
  final Object? tag,
  final bool exclusiveToMultiPass = false,
}) {
  /// Ground/contact shadow pass rendered underneath opaque geometry.
  static const shadows = RenderPass(name: 'shadows');

  /// Background terrain/surface pass.
  static const background = RenderPass(name: 'background');

  /// Primary opaque sprite & 3D mesh pass.
  static const opaque = RenderPass(name: 'opaque');

  /// Alpha-blended translucent geometry & particles pass.
  static const translucent = RenderPass(name: 'translucent');

  /// Additive/HDR emissive glow, neon, and bloom-source pass.
  static const emissive = RenderPass(name: 'emissive');

  /// Selective auxiliary emissive/mask pass in which ordinary non-[MultiPassComponent]
  /// components automatically skip [Component.render] while still traversing
  /// descendants.
  static const emissiveMask = RenderPass(
    name: 'emissiveMask',
    exclusiveToMultiPass: true,
  );

  /// World-space indicators, badges, and selection gizmos rendered on top.
  static const overlay = RenderPass(name: 'overlay');

  /// Standard tabletop/isometric multi-pass pipeline.
  static const List<RenderPass> standardPipeline = [
    shadows,
    opaque,
    translucent,
    emissive,
    overlay,
  ];

  @override
  String toString() =>
      tag == null ? 'RenderPass($name)' : 'RenderPass($name, tag: $tag)';
}

/// Mixin for [Component]s that split their rendering across multiple
/// camera-driven [RenderPass]es so cross-component batches (shadows, opaque 3D
/// meshes, additive glows) do not thrash GPU blend/shader state.
///
/// When rendered outside a multi-pass camera (for example in a single-pass
/// camera or a `Snapshot`), [fallbackPasses] are executed sequentially in local
/// order so the component still renders completely.
mixin MultiPassComponent on Component {
  /// Optional subset of passes this component participates in. When `null`,
  /// [renderPass] is invoked for every active pass.
  Set<RenderPass>? get activeRenderPasses => null;

  /// Passes executed in order when `CameraComponent.currentRenderPass` is
  /// `null` (single-pass camera or offscreen snapshot).
  List<RenderPass> get fallbackPasses => RenderPass.standardPipeline;

  /// Renders the portion of this component belonging to [pass].
  void renderPass(Canvas canvas, RenderPass pass);

  @override
  void render(Canvas canvas) {
    final pass = CameraComponent.currentRenderPass;
    final filter = activeRenderPasses;
    if (pass != null) {
      if (filter == null || filter.contains(pass)) {
        renderPass(canvas, pass);
      }
      return;
    }
    for (final fallback in fallbackPasses) {
      if (filter == null || filter.contains(fallback)) {
        renderPass(canvas, fallback);
      }
    }
  }
}
