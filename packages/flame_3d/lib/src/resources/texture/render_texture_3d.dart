import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Canvas, Color, PictureRecorder, PixelFormat;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/embedding/embedded_renderer.dart';

/// {@template render_texture_3d}
/// Live offscreen GPU render-to-texture resource backed by a
/// [GpuTextureTarget].
///
/// Unlike [World3D.renderToImage], [RenderTexture3D] keeps the rendered output
/// on the GPU as a sampleable [texture] with **zero CPU readback** and **zero
/// `dart:ui.Image` round-trips**, making it ideal for live 3D security
/// monitors, portals, rear-view mirrors, and planar floor reflections.
///
/// [texture] is one [Texture] object for the whole life of the render
/// texture: give it to a material once, at setup. Until the first
/// [renderWorld] (and after [resize] until the next one) it shows a single
/// white pixel, and so does it inside the passes of [renderWorld] itself,
/// so that a mesh showing it never samples the texture being rendered.
/// {@endtemplate}
class RenderTexture3D({
  int width = 512,
  int height = 512,
  var Color clearValue = const Color(0xFF000000),
  TextureSampler sampler = TextureSampler.linear,
}) {
  /// {@macro render_texture_3d}
  this {
    _width = math.max(1, width);
    _height = math.max(1, height);
    _texture = _RenderTextureHandle(this, sampler);
  }

  int _width = 1;
  int _height = 1;
  GpuTextureTarget? _target;
  late final _RenderTextureHandle _texture;
  int _renderCount = 0;
  bool _isRendering = false;
  final Matrix4 _savedView = Matrix4.zero();
  final Matrix4 _savedProjection = Matrix4.zero();

  /// Width of the backing GPU texture, in pixels.
  int get width => _width;

  /// Height of the backing GPU texture, in pixels.
  int get height => _height;

  /// Number of offscreen passes rendered into this texture.
  int get renderCount => _renderCount;

  /// Sampleable [Texture] bindable on any [Material] (`albedoTexture`,
  /// `emissiveTexture`, etc.): the same object from construction on, see
  /// [RenderTexture3D].
  Texture get texture => _texture;

  /// Resizes the offscreen target on the next [renderWorld] call.
  void resize(int width, int height) {
    final clampedWidth = math.max(1, width);
    final clampedHeight = math.max(1, height);
    if (clampedWidth == _width && clampedHeight == _height) {
      return;
    }
    _width = clampedWidth;
    _height = clampedHeight;
    _target = null;
    _texture.recreateResource = true;
  }

  void _ensureTarget(GraphicsDevice device) {
    if (_target != null) {
      return;
    }
    _target = device.backend.createTextureTarget(
      width: _width,
      height: _height,
      format: GpuPixelFormat.rgba8888,
      clearValue: clearValue,
    );
    _texture.recreateResource = true;
  }

  /// Renders [world] from [view] and [projection] (filtering by [cameraMask])
  /// directly into this GPU [texture].
  ///
  /// The draws are recorded into [context] on [device] when both are given,
  /// otherwise into those of the game [world] is in (or of a renderer of its
  /// own when it is in none, for example an unmounted world, whose lights
  /// are gathered from its tree). Returns `false` without rendering when
  /// called from within its own [renderWorld] or when the device cannot
  /// render into textures.
  bool renderWorld(
    World3D world, {
    required Matrix4 view,
    required Matrix4 projection,
    int cameraMask = 0xFFFFFFFF,
    bool renderShadows = false,
    GraphicsDevice? device,
    RenderContext3D? context,
  }) {
    if (_isRendering) {
      return false;
    }
    GraphicsDevice resolvedDevice;
    RenderContext3D resolvedContext;
    var closeFrame = false;
    EmbeddedRenderer? embedded;
    var closeEmbedded = false;

    if (device != null && context != null) {
      resolvedDevice = device;
      resolvedContext = context;
    } else {
      final game = world.findGame();
      if (game case final Game3D g3d) {
        resolvedDevice = g3d.device;
        resolvedContext = g3d.context;
        if (!g3d.isRenderingFrame) {
          resolvedDevice.begin();
          closeFrame = true;
        }
      } else {
        embedded = EmbeddedRenderer.of(game ?? world);
        resolvedDevice = embedded.device;
        resolvedContext = embedded.context;
        closeEmbedded = embedded.open();
      }
    }

    if (!resolvedDevice.backend.supportsTextureTargets) {
      if (closeFrame) {
        resolvedDevice.end();
      } else if (closeEmbedded) {
        embedded!.close();
      }
      return false;
    }

    _ensureTarget(resolvedDevice);
    final target = _target!;
    final recorder = PictureRecorder();
    final dummyCanvas = Canvas(recorder);

    _savedView.setFrom(resolvedContext.view);
    _savedProjection.setFrom(resolvedContext.projection);
    final savedMask = resolvedContext.cameraMask;

    _isRendering = true;
    try {
      world.renderWithHost(resolvedDevice, resolvedContext, () {
        resolvedContext
          ..cameraMask = cameraMask
          ..setCamera(view, projection);
        if (renderShadows) {
          world.renderShadows(dummyCanvas, overrideContext: resolvedContext);
        }
        resolvedDevice.beginTexturePass(
          target,
          frontFace: resolvedContext.frontFace,
        );
        world.renderScene(dummyCanvas, overrideContext: resolvedContext);
        resolvedContext.flush();
        resolvedDevice.endTexturePass();
      });
      _renderCount++;
      return true;
    } finally {
      _isRendering = false;
      resolvedContext
        ..cameraMask = savedMask
        ..setCamera(_savedView, _savedProjection);
      recorder.endRecording().dispose();
      if (closeFrame) {
        resolvedDevice.end();
      } else if (closeEmbedded) {
        embedded!.close();
      }
    }
  }

  /// Releases the GPU texture: [texture] shows a white pixel again until the
  /// next [renderWorld], which creates a new one.
  void dispose() {
    _target = null;
    _texture.dispose();
  }
}

/// The [RenderTexture3D.texture]: the texture of the current target, or a
/// white pixel when there is none or while the owner renders into it.
class _RenderTextureHandle(
  final RenderTexture3D _owner,
  TextureSampler sampler,
) extends Texture {
  this
    : super(
        ByteData(4),
        width: 1,
        height: 1,
        format: PixelFormat.bgra8888,
        sampler: sampler,
      );

  @override
  int get width => _owner._width;

  @override
  int get height => _owner._height;

  @override
  GpuTexture get resource {
    if (_owner._isRendering) {
      return Texture.standard.resource;
    }
    return super.resource;
  }

  @override
  GpuTexture createResource() {
    return _owner._target?.texture ?? Texture.standard.resource;
  }
}
