import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart' show Game;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/src/embedding/embedded_renderer.dart';
import 'package:flutter/widgets.dart' show MediaQuery;

/// {@template scene_3d_component}
/// A 2D component that shows a 3D scene as one layer of a 2D game.
///
/// The scene is the [world]: [Component3D]s and [LightComponent]s added to it
/// work as they do in a [FlameGame3D]. The [projection] maps the scene to the
/// local coordinates of this component, and the component draws it where the
/// projection says, through whatever transforms the canvas has: the 2D
/// camera's zoom, pan and rotation and this component's own position, scale,
/// angle and anchor. A scene point lands on the same pixel as a 2D component
/// drawn at the local point [scenePointToLocal] returns, at any zoom and pan.
///
/// The component is drawn like any other 2D component, at its [priority]:
/// components with a lower priority are drawn below the scene and those with
/// a higher priority above it. Its own children are drawn above the scene,
/// which suits labels placed with [scenePointToLocal].
///
/// ## Rendering
///
/// Every time the component renders, it renders the part of the scene that
/// is visible on screen in one render pass: the part of the canvas's clip (or
/// of the game's area when nothing clips) that the picture of the scene's
/// bounding box covers (see [Component3D.aabb]; lights do not count), inside
/// the component's [size] unless that is zero. It renders at the resolution
/// of the screen, [pixelRatio] times [renderScale] pixels per logical pixel,
/// aligned with the device's pixel grid, and culls the objects outside that
/// part. The image is drawn back over the same part of the screen,
/// unfiltered when [renderScale] is `1`. Nothing is rendered when that part
/// is empty.
///
/// The render target is rounded up to a multiple of 64 pixels in both
/// directions, and the target of the last render is kept while the visible
/// part fits in it and covers at least half of it, so that panning, zooming
/// and moving objects reuse the same target. It is at most [maxTextureSize]
/// pixels wide and high: a larger visible part is rendered at a lower
/// resolution.
///
/// In a [Game3D] game, the components use the game's [GraphicsDevice] and
/// [RenderContext3D], so its `renderStats` count their passes. In any other
/// game, all the components of the game share a device and a context of
/// their own. [renderStats] are the statistics of the last pass of this
/// component.
///
/// ## Size
///
/// With a zero [size] (the default) the layer is unbounded: the scene is drawn
/// wherever the projection puts it. With a non-zero [size], only the part of
/// the scene that falls inside the rectangle from `(0, 0)` to [size] is
/// drawn, and the component can receive pointer events there.
/// {@endtemplate}
class Scene3DComponent({
  required Scene3DProjection projection,
  World3D? world,
  Msaa msaa = Msaa.off,
  double? renderScale,
  int maxTextureSize = 4096,
  super.position,
  super.size,
  super.scale,
  super.angle,
  super.anchor,
  super.children,
  super.priority,
  super.key,
}) extends PositionComponent implements Scene3DHost {
  /// {@macro scene_3d_component}
  ///
  /// [world] defaults to a new [World3D]; [renderScale], when given, replaces
  /// the world's [World3D.renderScale].
  this {
    if (renderScale != null) {
      this.world.renderScale = renderScale;
    }
    this.maxTextureSize = maxTextureSize;
    add(this.world);
  }

  /// The 3D scene shown by this component, one of its children.
  final World3D world = world ?? World3D();

  /// How the scene maps to the local coordinates of this component.
  Scene3DProjection projection = projection;

  /// The multisample anti-aliasing of the render pass.
  Msaa msaa = msaa;

  /// The largest width and height in pixels of the render target, at least
  /// 64.
  int get maxTextureSize => _maxTextureSize;
  set maxTextureSize(int value) {
    if (value < _bucket) {
      throw ArgumentError.value(value, 'maxTextureSize', 'Must be at least 64');
    }
    _maxTextureSize = value;
  }

  int _maxTextureSize = 4096;

  /// The fraction of the device pixels the scene is rendered at: the
  /// [world]'s [World3D.renderScale].
  double get renderScale => world.renderScale;
  set renderScale(double value) => world.renderScale = value;

  /// The filter used to draw the image when it is not rendered at the
  /// device's resolution: the [world]'s [World3D.scaledFilterQuality].
  FilterQuality get scaledFilterQuality => world.scaledFilterQuality;
  set scaledFilterQuality(FilterQuality value) {
    world.scaledFilterQuality = value;
  }

  /// The statistics of the last render pass of this component.
  ///
  /// All zero when the last render found nothing to render.
  RenderStats get renderStats => _stats;
  final RenderStats _stats = RenderStats();

  /// The part of the canvas, in the canvas's device coordinates (logical
  /// pixels, without the canvas transform), that the last render covered; it
  /// is [Rect.zero] when nothing was rendered.
  Rect get renderedRect => _renderedRect;
  Rect _renderedRect = Rect.zero;

  /// The time the last render took on the CPU: recording, sorting and
  /// submitting the draws.
  Duration get lastRenderTime => Duration(microseconds: _renderMicroseconds);
  int _renderMicroseconds = 0;

  /// The local 2D point that [scenePoint] lands on, see
  /// [Scene3DProjection.scenePointToLocal].
  ///
  /// Convert it further with [positionOf] (to the parent's coordinates) or
  /// [absolutePositionOf] to place 2D components on scene points.
  Vector2 scenePointToLocal(Vector3 scenePoint, {Vector2? output}) {
    return projection.scenePointToLocal(scenePoint, output: output);
  }

  /// The ray of the scene points that land on the local 2D point
  /// [localPoint], see [Scene3DProjection.localPointToRay].
  ///
  /// [localPoint] is in the coordinates of this component, such as the
  /// `localPosition` of a pointer event it receives, or [absoluteToLocal] of
  /// a point of the world it is in.
  Ray localPointToRay(Vector2 localPoint, {Ray? output}) {
    return projection.localPointToRay(localPoint, output: output);
  }

  @override
  GraphicsDevice get device {
    _resolveRenderer();
    return _device!;
  }

  @override
  RenderContext3D get context {
    _resolveRenderer();
    return _context!;
  }

  @override
  int get msaaSampleCount => msaa.sampleCount;

  /// The device pixel ratio of the view the game is shown in, or `1` when it
  /// is not shown.
  @override
  double get pixelRatio => _pixelRatioOf(findGame());

  static double _pixelRatioOf(Game? game) {
    final buildContext = game?.buildContext;
    return buildContext == null
        ? 1.0
        : MediaQuery.devicePixelRatioOf(buildContext);
  }

  GraphicsDevice? _device;
  RenderContext3D? _context;
  Game3D? _game3D;
  EmbeddedRenderer? _renderer;

  void _resolveRenderer() {
    if (_context != null) {
      return;
    }
    final game = findGame();
    if (game case final Game3D game3D) {
      _game3D = game3D;
      _device = game3D.device;
      _context = game3D.context;
    } else {
      final renderer = _renderer = EmbeddedRenderer.of(game ?? this);
      _device = renderer.device;
      _context = renderer.context;
    }
  }

  @override
  void onRemove() {
    super.onRemove();
    _device = null;
    _context = null;
    _game3D = null;
    _renderer = null;
  }

  @override
  void render(Canvas canvas) {
    _stats.reset();
    _renderedRect = Rect.zero;
    _renderMicroseconds = 0;
    if (!world.isMounted || world.children.isEmpty) {
      return;
    }
    final stopwatch = _stopwatch
      ..reset()
      ..start();
    _renderScene(canvas);
    stopwatch.stop();
    _renderMicroseconds = stopwatch.elapsedMicroseconds;
  }

  void _renderScene(Canvas canvas) {
    // The canvas maps local coordinates to its device coordinates (logical
    // pixels); the device pixel ratio maps those to physical pixels.
    final transform = canvas.getTransform();
    final a = transform[0];
    final b = transform[1];
    final c = transform[4];
    final d = transform[5];
    final tx = transform[12];
    final ty = transform[13];
    final determinant = a * d - b * c;
    if (!(determinant.abs() > 1e-12)) {
      return;
    }

    // The part of the screen to render, in device coordinates: the clip, or
    // the game's area when nothing clips the canvas (the game is painted in
    // a layer of its own, starting at its top left corner).
    var visible = canvas.getDestinationClipBounds();
    final game = findGame();
    if (visible.width > _unclipped || visible.height > _unclipped) {
      if (game == null || !game.hasLayout) {
        return;
      }
      final gameSize = game.canvasSize;
      visible = visible.intersect(Rect.fromLTWH(0, 0, gameSize.x, gameSize.y));
    }
    final width = size.x;
    final height = size.y;
    final bounded = width != 0 || height != 0;
    if (bounded) {
      visible = visible.intersect(
        _deviceBounds(a, b, c, d, tx, ty, width, height),
      );
    }
    if (visible.isEmpty) {
      return;
    }
    final scene = _sceneBounds(a, b, c, d, tx, ty);
    if (scene != null) {
      visible = visible.intersect(scene);
    }
    if (visible.isEmpty || !visible.isFinite) {
      return;
    }

    // Whole pixels of the render target, aligned with the pixel grid.
    final fullScale = _pixelRatioOf(game) * world.renderScale;
    var pixelScale = fullScale;
    var left = (visible.left * pixelScale).floor();
    var top = (visible.top * pixelScale).floor();
    var pixelWidth = (visible.right * pixelScale).ceil() - left;
    var pixelHeight = (visible.bottom * pixelScale).ceil() - top;
    final maxSize = _maxTextureSize;
    if (pixelWidth > maxSize || pixelHeight > maxSize) {
      pixelScale *= (maxSize - 2) / math.max(pixelWidth, pixelHeight);
      left = (visible.left * pixelScale).floor();
      top = (visible.top * pixelScale).floor();
      pixelWidth = (visible.right * pixelScale).ceil() - left;
      pixelHeight = (visible.bottom * pixelScale).ceil() - top;
    }
    if (pixelWidth <= 0 || pixelHeight <= 0) {
      return;
    }
    // Keep the target of the last render while the part fits in it and
    // covers at least half of it: a part whose size changes a little from
    // frame to frame keeps rendering into the same target.
    final neededWidth = math.min(_roundUp(pixelWidth), maxSize);
    final neededHeight = math.min(_roundUp(pixelHeight), maxSize);
    if (_targetWidth < neededWidth ||
        _targetHeight < neededHeight ||
        _targetWidth > maxSize ||
        _targetHeight > maxSize ||
        _targetWidth * _targetHeight > 2 * neededWidth * neededHeight) {
      _targetWidth = neededWidth;
      _targetHeight = neededHeight;
    }
    final targetWidth = _targetWidth;
    final targetHeight = _targetHeight;

    _writeCamera(
      a,
      b,
      c,
      d,
      tx,
      ty,
      pixelScale,
      left,
      top,
      targetWidth,
      targetHeight,
    );

    _resolveRenderer();
    final device = _device!;
    final context = _context!;
    final game3D = _game3D;
    final bool closeFrame;
    if (game3D != null) {
      closeFrame = !game3D.isRenderingFrame;
      if (closeFrame) {
        device.begin();
      }
    } else {
      closeFrame = _renderer!.open();
    }

    _statsBefore.setFrom(device.stats);
    context.setCamera(_viewMatrix, _projectionMatrix);
    device.beginPass(
      Size(targetWidth.toDouble(), targetHeight.toDouble()),
      msaaSampleCount: msaa.sampleCount,
      frontFace: context.frontFace,
    );
    world.renderScene(canvas);
    context.flush();
    final image = device.endPass();
    _subtract(device.stats, _statsBefore, _stats);
    if (closeFrame) {
      if (game3D != null) {
        device.end();
      } else {
        _renderer!.close();
      }
    }

    // Draw the image over the pixels it was rendered for, in device
    // coordinates.
    final destination = Rect.fromLTRB(
      left / pixelScale,
      top / pixelScale,
      (left + pixelWidth) / pixelScale,
      (top + pixelHeight) / pixelScale,
    );
    final inverse = _inverseTransform
      ..[0] = d / determinant
      ..[1] = -b / determinant
      ..[4] = -c / determinant
      ..[5] = a / determinant
      ..[12] = (c * ty - d * tx) / determinant
      ..[13] = (b * tx - a * ty) / determinant;
    canvas.save();
    if (bounded && (b != 0 || c != 0)) {
      // Rotated: the bounds of the visible part are larger than the layer.
      canvas.clipRect(Rect.fromLTWH(0, 0, width, height));
    }
    canvas.transform(inverse);
    _paint.filterQuality = pixelScale == fullScale && world.renderScale == 1.0
        ? FilterQuality.none
        : world.scaledFilterQuality;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, pixelWidth.toDouble(), pixelHeight.toDouble()),
      destination,
      _paint,
    );
    canvas.restore();
    image.dispose();
    _renderedRect = destination;
  }

  /// The bounding box, in device coordinates, of the picture of the bounding
  /// box of the scene's components under the canvas transform
  /// `(a, b, c, d, tx, ty)`, or null when it is unknown: when there is no
  /// such component, or when the box reaches behind the eye of a perspective
  /// projection.
  Rect? _sceneBounds(
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
  ) {
    final box = _sceneBox;
    var empty = true;
    for (final child in world.children) {
      if (child is Component3D && child is! LightComponent) {
        if (empty) {
          box.setFrom(child.aabb);
          empty = false;
        } else {
          box.hull(child.aabb);
        }
      }
    }
    if (empty) {
      return null;
    }
    final m = projection.sceneToLocalValues;
    final min = box.min;
    final max = box.max;
    var left = double.infinity;
    var top = double.infinity;
    var right = double.negativeInfinity;
    var bottom = double.negativeInfinity;
    for (var corner = 0; corner < 8; corner++) {
      final x = corner & 1 == 0 ? min.x : max.x;
      final y = corner & 2 == 0 ? min.y : max.y;
      final z = corner & 4 == 0 ? min.z : max.z;
      final w = m[3] * x + m[7] * y + m[11] * z + m[15];
      if (!(w > 0)) {
        return null;
      }
      final localX = (m[0] * x + m[4] * y + m[8] * z + m[12]) / w;
      final localY = (m[1] * x + m[5] * y + m[9] * z + m[13]) / w;
      final deviceX = a * localX + c * localY + tx;
      final deviceY = b * localX + d * localY + ty;
      left = math.min(left, deviceX);
      top = math.min(top, deviceY);
      right = math.max(right, deviceX);
      bottom = math.max(bottom, deviceY);
    }
    return Rect.fromLTRB(left, top, right, bottom);
  }

  final Aabb3 _sceneBox = Aabb3();

  // The size of the render target of the last render, in pixels.
  int _targetWidth = 0;
  int _targetHeight = 0;

  /// Writes the camera of a pass whose render target of [targetWidth] by
  /// [targetHeight] pixels starts at the pixel ([left], [top]) of a screen
  /// with [pixelScale] pixels per device coordinate, under the canvas
  /// transform `(a, b, c, d, tx, ty)`.
  void _writeCamera(
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
    double pixelScale,
    int left,
    int top,
    int targetWidth,
    int targetHeight,
  ) {
    // Local coordinates -> device coordinates (the canvas transform) ->
    // pixels of the render target -> clip space, as rows over (X, Y, W) of
    // the local homogeneous coordinates; the depth Z is kept.
    final sx = 2 * pixelScale / targetWidth;
    final sy = 2 * pixelScale / targetHeight;
    final c00 = sx * a;
    final c01 = sx * c;
    final c03 = 2 * (pixelScale * tx - left) / targetWidth - 1;
    final c10 = -sy * b;
    final c11 = -sy * d;
    final c13 = 1 - 2 * (pixelScale * ty - top) / targetHeight;

    final viewToLocal = projection.viewToLocalValues;
    final p = _projectionMatrix.storage;
    for (var column = 0; column < 4; column++) {
      final i = column * 4;
      final x = viewToLocal[i];
      final y = viewToLocal[i + 1];
      final w = viewToLocal[i + 3];
      p[i] = c00 * x + c01 * y + c03 * w;
      p[i + 1] = c10 * x + c11 * y + c13 * w;
      p[i + 2] = viewToLocal[i + 2];
      p[i + 3] = w;
    }
    _viewMatrix.storage.setAll(0, projection.viewValues);
  }

  final Matrix4 _viewMatrix = Matrix4.identity();
  final Matrix4 _projectionMatrix = Matrix4.identity();
  final Float64List _inverseTransform = Float64List(16)
    ..[10] = 1
    ..[15] = 1;
  final Paint _paint = Paint();
  final RenderStats _statsBefore = RenderStats();
  final Stopwatch _stopwatch = Stopwatch();

  static const int _bucket = 64;

  /// The size, in logical pixels, beyond which a clip counts as no clip.
  static const double _unclipped = 1e6;

  static int _roundUp(int pixels) =>
      (pixels + _bucket - 1) ~/ _bucket * _bucket;

  /// The bounding box, in device coordinates, of the local rectangle from
  /// the origin to ([width], [height]) under the canvas transform
  /// `(a, b, c, d, tx, ty)`.
  static Rect _deviceBounds(
    double a,
    double b,
    double c,
    double d,
    double tx,
    double ty,
    double width,
    double height,
  ) {
    final x1 = a * width;
    final y1 = b * width;
    final x2 = c * height;
    final y2 = d * height;
    return Rect.fromLTRB(
      tx + math.min(0.0, x1) + math.min(0.0, x2),
      ty + math.min(0.0, y1) + math.min(0.0, y2),
      tx + math.max(0.0, x1) + math.max(0.0, x2),
      ty + math.max(0.0, y1) + math.max(0.0, y2),
    );
  }

  static void _subtract(
    RenderStats after,
    RenderStats before,
    RenderStats out,
  ) {
    out
      ..renderPasses = after.renderPasses - before.renderPasses
      ..drawCalls = after.drawCalls - before.drawCalls
      ..instances = after.instances - before.instances
      ..triangles = after.triangles - before.triangles
      ..pipelineChanges = after.pipelineChanges - before.pipelineChanges
      ..stateChanges = after.stateChanges - before.stateChanges
      ..materialChanges = after.materialChanges - before.materialChanges
      ..uniformUploads = after.uniformUploads - before.uniformUploads
      ..uploadedBytes = after.uploadedBytes - before.uploadedBytes;
  }
}
