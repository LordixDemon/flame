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
