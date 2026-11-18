import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color, Image, Size;

import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:meta/meta.dart';

/// Runs soft-knee bright-pass extraction, multi-pass Kawase blur, and
/// alpha-preserving additive composition for [BloomSettings] inside an open
/// [GraphicsDevice] frame.
@internal
class BloomPass(final GraphicsDevice _device) {
  static const String _prefilterBundle =
      'packages/flame_3d/assets/shaders/bloom_prefilter.shaderbundle';
  static const String _blurBundle =
      'packages/flame_3d/assets/shaders/bloom_blur.shaderbundle';
  static const String _compositeBundle =
      'packages/flame_3d/assets/shaders/bloom_composite.shaderbundle';

  static final Surface _fullscreenQuad = Surface.fromBuffers(
    vertices: Float32List.fromList(const [
      -1.0, -1.0, 0.0, //
      1.0, -1.0, 0.0, //
      1.0, 1.0, 0.0, //
      -1.0, 1.0, 0.0, //
    ]),
    indices: Uint16List.fromList(const [0, 1, 2, 0, 2, 3]),
    layout: VertexLayout(const [
      VertexAttribute(VertexLayout.positionAttribute, 3),
    ]),
  );

  static const RenderState _fullscreenState = RenderState(
    depthTest: false,
    depthWrite: false,
  );

  late final Shader _prefilterVert = VertexShader.fromAsset(_prefilterBundle);
  late final Shader _prefilterFrag = FragmentShader.fromAsset(
    _prefilterBundle,
    slots: const ['BloomPrefilter', 'sourceTexture'],
  );

  late final Shader _blurVert = VertexShader.fromAsset(_blurBundle);
  late final Shader _blurFrag = FragmentShader.fromAsset(
    _blurBundle,
    slots: const ['BloomBlur', 'sourceTexture'],
  );

  late final Shader _compositeVert = VertexShader.fromAsset(_compositeBundle);
  late final Shader _compositeFrag = FragmentShader.fromAsset(
    _compositeBundle,
    slots: const ['BloomComposite', 'sceneTexture', 'bloomTexture'],
  );

  final Vector4 _curve = Vector4.zero();
  final Vector4 _texel = Vector4.zero();
  final Vector4 _offset = Vector4.zero();
  final Vector4 _params = Vector4.zero();

  /// Applies [settings] to [sceneTarget] (into which the 3D scene pass has just
  /// ended via `endTexturePass`), writing the composited [Image] into
  /// [outputTarget] (when given) or a pooled render target of the same size.
  Image applyFromTarget(
    GpuTextureTarget sceneTarget,
    BloomSettings settings, {
    GpuRenderTarget? outputTarget,
  }) {
    final fullWidth = sceneTarget.width;
    final fullHeight = sceneTarget.height;
    final sceneTexture = Texture(
      null,
      width: fullWidth,
      height: fullHeight,
      sampler: TextureSampler.linear,
      gpuTexture: sceneTarget.texture,
    );
    final halfWidth = math.max(1, fullWidth >> 1);
    final halfHeight = math.max(1, fullHeight >> 1);

    // Distinct clear colors ensure two separate ping-pong targets even when
    // `halfWidth == fullWidth` on 1x1 edge cases.
    final ping = _device.textureTarget(
      halfWidth,
      halfHeight,
      GpuPixelFormat.rgba8888,
      clearValue: const Color(0x00000002),
    );
    final pong = _device.textureTarget(
      halfWidth,
      halfHeight,
      GpuPixelFormat.rgba8888,
      clearValue: const Color(0x00000003),
    );

    final pingTex = Texture(
      null,
      width: halfWidth,
      height: halfHeight,
      sampler: TextureSampler.linear,
      gpuTexture: ping.texture,
    );
    final pongTex = Texture(
      null,
      width: halfWidth,
      height: halfHeight,
      sampler: TextureSampler.linear,
      gpuTexture: pong.texture,
    );

    // 1. Bright-pass prefilter + 2x downsample into `ping`.
    final threshold = math.max(0.0, settings.threshold);
    final knee = threshold * settings.softKnee.clamp(0.0, 1.0) + 1e-4;
    _curve.setValues(threshold, threshold - knee, 2.0 * knee, 0.25 / knee);
    _texel.setValues(1.0 / fullWidth, 1.0 / fullHeight, 0, 0);
    _prefilterFrag
      ..setTexture('sourceTexture', sceneTexture)
      ..setVector4('BloomPrefilter.curve', _curve)
      ..setVector4('BloomPrefilter.texel', _texel);

    _device.beginTexturePass(ping);
    _drawQuad(_prefilterVert, _prefilterFrag);
    _device.endTexturePass();

    // 2. Ping-pong Kawase blur passes at half resolution.
    var readTex = pingTex;
    var writeTarget = pong;
    for (var i = 0; i < settings.passes; i++) {
      final spread = (i + 0.5) * settings.radius;
      _offset.setValues(spread / halfWidth, spread / halfHeight, 0, 0);
      _blurFrag
        ..setTexture('sourceTexture', readTex)
        ..setVector4('BloomBlur.offset', _offset);
      _device.beginTexturePass(writeTarget);
      _drawQuad(_blurVert, _blurFrag);
      _device.endTexturePass();

      if (identical(writeTarget, pong)) {
        readTex = pongTex;
        writeTarget = ping;
      } else {
        readTex = pingTex;
        writeTarget = pong;
      }
    }

    // 3. Composite `sceneTexture + bloom * intensity` preserving `scene.a`.
    _params.setValues(settings.intensity, 0, 0, 0);
    _compositeFrag
      ..setTexture('sceneTexture', sceneTexture)
      ..setTexture('bloomTexture', readTex)
      ..setVector4('BloomComposite.params', _params);

    if (outputTarget != null) {
      _device.beginOwnedPass(outputTarget);
    } else {
      _device.beginPass(Size(fullWidth.toDouble(), fullHeight.toDouble()));
    }
    _drawQuad(_compositeVert, _compositeFrag);
    return _device.endPass();
  }

  void _drawQuad(Shader vert, Shader frag) {
    vert.resource;
    frag.resource;
    final pipeline = _device.pipelineFor(vert, frag, _fullscreenQuad.layout);
    _device
      ..bindPipeline(pipeline)
      ..setRenderState(_fullscreenState);
    for (final slotName in frag.slots) {
      final slot = frag.slot(slotName);
      if (slot.sizeInBytes == null) {
        _device.bindTexture(slot, frag.texture(slotName) ?? Texture.standard);
      } else {
        _device.bindUniformBlock(frag.block(slotName));
      }
    }
    _device
      ..bindSurface(_fullscreenQuad)
      ..drawSurface(_fullscreenQuad);
  }
}
