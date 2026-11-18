import 'dart:ui';

import 'package:flame/components.dart' as flame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

/// {@template world_3d}
/// The root component for all 3D world elements.
///
/// The primary feature of this component is that it allows [Component3D]s to
/// render directly to a [GraphicsDevice] instead of the regular rendering.
///
/// A world renders with the device and render context of its [host], the
/// nearest ancestor that is a [Scene3DHost]:
///
/// - In a [Game3D] game such as [FlameGame3D], each camera that looks at the
///   world renders it into an image of the camera's viewport size in physical
///   pixels, times [renderScale], which is then drawn into the viewport.
/// - In a [Scene3DComponent], the component renders the world as one layer of
///   a 2D game, see there.
///
/// When one of its directional lights casts shadows (see [ShadowSettings]),
/// the world is rendered a first time from the light into its shadow map,
/// before each main pass, see [renderShadows].
/// {@endtemplate}
class World3D({
  super.children,
  super.priority,

  /// The fraction of the device pixels the world is rendered at, in `(0, 1]`
  /// to render fewer pixels than the viewport covers (the image is scaled up
  /// when drawn), or above `1` to render more pixels than it covers.
  double renderScale = 1.0,
}) extends flame.World {
  final List<Light> _lights = [];

  /// The [Scene3DHost] this world renders with: the nearest ancestor that is
  /// one, such as a [Scene3DComponent] or a [Game3D] game.
  ///
  /// Throws a [StateError] when there is none.
  Scene3DHost get host => _host ??= _findHost();
  Scene3DHost? _host;

  /// The render context that records the draws of this world, the one of
  /// its [host].
  RenderContext3D get context => host.context;

  /// Whether this world is being rendered: [Object3D]s record their draws
  /// into [context] only while this is true.
  bool get isRendering => _rendering;
  bool _rendering = false;

  /// The fraction of the device pixels the world is rendered at, see
  /// [World3D.new].
  double get renderScale => _renderScale;
  double _renderScale = _checkRenderScale(renderScale);
  set renderScale(double value) => _renderScale = _checkRenderScale(value);

  /// The filter used to scale the rendered image to the viewport when
  /// [renderScale] is not `1`.
  FilterQuality scaledFilterQuality = FilterQuality.low;

  /// The union of the world-space bounds ([Component3D.aabb]) of the
  /// [Component3D]s of this world, lights excepted, or `null` when there are
  /// none.
  ///
  /// It is kept up to date incrementally: reading it visits only the
  /// components whose bounds changed since the last read (because they or
  /// one of their descendants moved, were added or were removed), at a cost
  /// of up to `log2(n)` unions each for `n` components, and nothing when
  /// none changed. It is always the exact union of the current bounds. Call
  /// [Component3D.markAabbDirty] when the geometry of a component changes
  /// without it moving. The box belongs to the world and changes when the
  /// bounds change; copy it to keep it.
  Aabb3? get sceneBounds => _sceneBounds.value;
  final ComponentBounds _sceneBounds = ComponentBounds();

  @override
  void onChildrenChanged(flame.Component child, flame.ChildrenChangeType type) {
    super.onChildrenChanged(child, type);
    if (child is! Component3D || child is LightComponent) {
      return;
    }
    switch (type) {
      case flame.ChildrenChangeType.added:
        _sceneBounds.add(child);
      case flame.ChildrenChangeType.removed:
        _sceneBounds.remove(child);
    }
  }

  /// Register a [light] with this world.
  @internal
  void addLight(Light light) => _lights.add(light);

  /// Unregister a [light] from this world.
  @internal
  void removeLight(Light light) => _lights.remove(light);

  @override
  void onRemove() {
    super.onRemove();
    _host = null;
  }

  Scene3DHost _findHost() {
    for (final ancestor in ancestors()) {
      if (ancestor case final Scene3DHost host) {
        return host;
      }
    }
    throw StateError(
      'A World3D needs a Scene3DHost ancestor: a Scene3DComponent, or a '
      'Game3D game such as FlameGame3D.',
    );
  }

  /// The projection of the shadow map of this world, fitted by
  /// [renderShadows] before each main pass when a light casts shadows.
  DirectionalShadowProjection get shadowProjection => _shadowProjection;
  final DirectionalShadowProjection _shadowProjection =
      DirectionalShadowProjection();

  /// Renders the shadow map of this world, when one of its directional lights
  /// casts shadows (see [ShadowSettings]), and returns whether it did.
  ///
  /// This is how a host that runs the render passes itself renders the
  /// shadows: call it once the camera of the main pass is set with
  /// [RenderContext3D.setCamera], before the main pass begins (see
  /// [renderScene]). The draws of the main pass then receive the shadows.
  /// The components are traversed as for the main pass, with the light's view
  /// as the camera; [canvas] is passed on to them.
  bool renderShadows(Canvas canvas) {
    final context = this.context..lights = _lights;
    if (!context.beginShadowPass(
      projection: _shadowProjection,
      sceneBounds: sceneBounds,
    )) {
      return false;
    }
    _rendering = true;
    try {
      for (final child in children) {
        child.renderTree(canvas);
      }
    } finally {
      _rendering = false;
      context.endShadowPass();
    }
    return true;
  }

  /// Records the draws of every component of this world into [context], with
  /// the lights of this world.
  ///
  /// This is how a host that runs the render pass itself, such as a
  /// [Scene3DComponent], renders the world: the [host]'s device must be in a
  /// render pass and the camera of [context] set with
  /// [RenderContext3D.setCamera]; the host then flushes the context and ends
  /// the pass. [canvas] is passed on to the components, which do not draw on
  /// it.
  void renderScene(Canvas canvas) {
    context.lights = _lights;
    _rendering = true;
    try {
      for (final child in children) {
        child.renderTree(canvas);
      }
    } finally {
      _rendering = false;
    }
  }

  @internal
  @override
  void renderFromCamera(Canvas canvas) {
    final camera = CameraComponent3D.currentCamera!;
    final Viewport(virtualSize: size) = camera.viewport;

    final host = this.host;
    final scale = host.pixelRatio * _renderScale;
    final renderSize = Size(size.x * scale, size.y * scale);

    // The camera's matrices are read once per pass, everything derived from
    // them is computed by the context.
    final context = host.context
      ..lights = _lights
      ..setCamera(camera.viewMatrix, camera.projectionMatrix);
    renderShadows(canvas);

    final device = host.device;
    device.beginPass(
      renderSize,
      msaaSampleCount: host.msaaSampleCount,
      frontFace: context.frontFace,
    );
    _rendering = true;
    try {
      super.renderFromCamera(canvas);
    } finally {
      _rendering = false;
    }
    context.flush();

    final image = device.endPass();
    _paint.filterQuality = _renderScale == 1.0
        ? FilterQuality.none
        : scaledFilterQuality;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(-size.x / 2, -size.y / 2, size.x, size.y),
      _paint,
    );
    image.dispose();
  }

  final Paint _paint = Paint();

  static double _checkRenderScale(double value) {
    if (!(value > 0) || value.isInfinite) {
      throw ArgumentError.value(value, 'renderScale', 'Must be above 0');
    }
    return value;
  }
}
