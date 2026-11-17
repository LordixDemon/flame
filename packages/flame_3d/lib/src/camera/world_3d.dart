import 'dart:ui';

import 'package:flame/components.dart' as flame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/widgets.dart' show MediaQuery;
import 'package:meta/meta.dart';

/// {@template world_3d}
/// The root component for all 3D world elements.
///
/// The primary feature of this component is that it allows [Component3D]s to
/// render directly to a [GraphicsDevice] instead of the regular rendering.
///
/// Each camera that looks at the world renders it into an image of the
/// camera's viewport size in physical pixels, times [renderScale], which is
/// then drawn into the viewport.
/// {@endtemplate}
class World3D({
  super.children,
  super.priority,

  /// The fraction of the device pixels the world is rendered at, in `(0, 1]`
  /// to render fewer pixels than the viewport covers (the image is scaled up
  /// when drawn), or above `1` to render more pixels than it covers.
  double renderScale = 1.0,
}) extends flame.World with flame.HasGameRef<FlameGame3D> {
  final List<Light> _lights = [];

  RenderContext3D get context => gameRef.context;

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

  @internal
  @override
  void renderFromCamera(Canvas canvas) {
    final camera = CameraComponent3D.currentCamera!;
    final Viewport(virtualSize: size) = camera.viewport;

    final buildContext = gameRef.buildContext;
    final pixelRatio = buildContext == null
        ? 1.0
        : MediaQuery.devicePixelRatioOf(buildContext);
    final scale = pixelRatio * _renderScale;
    final renderSize = Size(size.x * scale, size.y * scale);

    // The camera's matrices are read once per pass, everything derived from
    // them is computed by the context.
    context
      ..lights = _lights
      ..setCamera(camera.viewMatrix, camera.projectionMatrix);

    final device = gameRef.device;
    device.beginPass(
      renderSize,
      msaaSampleCount: gameRef.msaa().sampleCount,
      frontFace: context.frontFace,
    );
    super.renderFromCamera(canvas);
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
