import 'dart:math' as math;
import 'dart:ui' show Color, Image, Rect, Size;

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/graphics/fullscreen_quad.dart';
import 'package:meta/meta.dart';

/// Runs soft-knee bright-pass extraction, multi-pass blur, and unified
/// single-pass composition for [BloomSettings], [PostProcessSettings],
/// [ColorLut3D], HDR decoding and display encoding, and [RenderDebugMode3D]
/// inside an open [GraphicsDevice] frame.
///
/// With `hdrEnabled` the scene target holds premultiplied colors sRGB-encoded
/// with an extended range (above 1), as every material writes them in an HDR
/// pass (see `RenderContext3D.hdrEnabled`); the prefilter and the composite
/// decode them to linear light.
@internal
class BloomPass(final GraphicsDevice _device) {
  static const String _prefilterBundle =
      'packages/flame_3d/assets/shaders/bloom_prefilter.shaderbundle';
  static const String _blurBundle =
      'packages/flame_3d/assets/shaders/bloom_blur.shaderbundle';
  static const String _downsampleBundle =
      'packages/flame_3d/assets/shaders/bloom_downsample.shaderbundle';
  static const String _upsampleBundle =
      'packages/flame_3d/assets/shaders/bloom_upsample.shaderbundle';
  static const String _compositeBundle =
      'packages/flame_3d/assets/shaders/bloom_composite.shaderbundle';
  static const String _compositeSimpleBundle =
      'packages/flame_3d/assets/shaders/bloom_composite_simple.shaderbundle';

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

  late final Shader _downsampleVert = VertexShader.fromAsset(_downsampleBundle);
  late final Shader _downsampleFrag = FragmentShader.fromAsset(
    _downsampleBundle,
    slots: const ['BloomBlur', 'sourceTexture'],
  );

  late final Shader _upsampleVert = VertexShader.fromAsset(_upsampleBundle);
  late final Shader _upsampleFrag = FragmentShader.fromAsset(
    _upsampleBundle,
    slots: const ['BloomBlur', 'sourceTexture'],
  );

  late final Shader _compositeVert = VertexShader.fromAsset(_compositeBundle);
  late final Shader _compositeFrag = FragmentShader.fromAsset(
    _compositeBundle,
    slots: const [
      'BloomComposite',
      'sceneTexture',
      'bloomTexture',
      'depthNormalTexture',
      'lutTexture',
    ],
  );

  late final Shader _compositeSimpleVert = VertexShader.fromAsset(
    _compositeSimpleBundle,
  );
  late final Shader _compositeSimpleFrag = FragmentShader.fromAsset(
    _compositeSimpleBundle,
    slots: const ['BloomComposite', 'sceneTexture', 'bloomTexture'],
  );

  /// Applies optional [bloom] and optional [postProcess] to [sceneTarget]
  /// (into which the 3D scene pass has just ended via `endTexturePass`),
  /// writing the composited [Image] into [outputTarget] (when given) or a
  /// pooled render target of the same size.
  ///
  /// [visibleFrame] is the part of the target that is seen, in its pixels
  /// (it may reach outside the target), which the vignette is centered on;
  /// the whole target when `null`.
  Image applyFromTarget(
    GpuTextureTarget sceneTarget,
    BloomSettings? bloom, {
    PostProcessSettings? postProcess,
    Texture? depthNormalTexture,
    GpuRenderTarget? outputTarget,
    bool hdrEnabled = false,
    RenderDebugMode3D debugMode = RenderDebugMode3D.none,
    Rect? visibleFrame,
  }) {
    final fullWidth = sceneTarget.width;
    final fullHeight = sceneTarget.height;
    final sceneTexture = _textureFor(sceneTarget);

    Texture bloomReadTex = Texture.empty;
    final runBloom =
        debugMode == RenderDebugMode3D.none &&
        bloom != null &&
        bloom.intensity > 0 &&
        bloom.radius > 0;

    if (runBloom) {
      final halfWidth = math.max(1, fullWidth >> 1);
      final halfHeight = math.max(1, fullHeight >> 1);
      final bloomFormat =
          sceneTarget.format == GpuPixelFormat.rgbaFloat16 &&
              _device.backend.supportsPixelFormat(GpuPixelFormat.rgbaFloat16)
          ? GpuPixelFormat.rgbaFloat16
          : GpuPixelFormat.rgba8888;

      final ping = _device.textureTarget(
        halfWidth,
        halfHeight,
        bloomFormat,
        clearValue: const Color(0x00000000),
        role: _BloomTarget.ping,
      );
      final pingTex = _textureFor(ping);

      final threshold = math.max(0.0, bloom.threshold);
      final knee = threshold * bloom.softKnee.clamp(0.0, 1.0) + 1e-4;

      _prefilterFrag.resource;
      final preOff =
          (_prefilterFrag.renderCache as _PrefilterCache?) ??
          (_prefilterFrag.renderCache = _PrefilterCache(_prefilterFrag));
      if (preOff.generation != _prefilterFrag.generation) {
        preOff.refresh(_prefilterFrag);
      }
      if (preOff.sourceIdx >= 0) {
        _prefilterFrag.setTextureAt(preOff.sourceIdx, sceneTexture);
      }
      preOff.block
        ..writeVec4ValuesAt(
          preOff.curveOff,
          threshold,
          threshold - knee,
          2.0 * knee,
          0.25 / knee,
        )
        ..writeVec4ValuesAt(
          preOff.texelOff,
          1.0 / fullWidth,
          1.0 / fullHeight,
          hdrEnabled ? 1.0 : 0.0,
          0,
        );

      _device.beginTexturePass(ping);
      _drawQuad(_prefilterVert, _prefilterFrag, preOff);
      _device.endTexturePass();

      if (bloom.dualKawase && bloom.passes > 1) {
        final passCount = bloom.passes;
        _downsampleFrag.resource;
        final downOff =
            (_downsampleFrag.renderCache as _BlurCache?) ??
            (_downsampleFrag.renderCache = _BlurCache(_downsampleFrag));
        if (downOff.generation != _downsampleFrag.generation) {
          downOff.refresh(_downsampleFrag);
        }
        _upsampleFrag.resource;
        final upOff =
            (_upsampleFrag.renderCache as _BlurCache?) ??
            (_upsampleFrag.renderCache = _BlurCache(_upsampleFrag));
        if (upOff.generation != _upsampleFrag.generation) {
          upOff.refresh(_upsampleFrag);
        }

        _mipTargets[0] = ping;
        _mipTexs[0] = pingTex;
        var curW = halfWidth;
        var curH = halfHeight;
        for (var i = 1; i <= passCount; i++) {
          curW = math.max(1, curW >> 1);
          curH = math.max(1, curH >> 1);
          final dst = _device.textureTarget(
            curW,
            curH,
            bloomFormat,
            clearValue: const Color(0x00000000),
            role: _dualDownRoles[i - 1],
          );
          if (downOff.sourceIdx >= 0) {
            _downsampleFrag.setTextureAt(downOff.sourceIdx, _mipTexs[i - 1]!);
          }
          downOff.block.writeVec4ValuesAt(
            downOff.offsetOff,
            bloom.radius / curW,
            bloom.radius / curH,
            0,
            0,
          );
          _device.beginTexturePass(dst);
          _drawQuad(_downsampleVert, _downsampleFrag, downOff);
          _device.endTexturePass();
          _mipTargets[i] = dst;
          _mipTexs[i] = _textureFor(dst);
        }
        var readTex = _mipTexs[passCount]!;
        for (var i = passCount - 1; i >= 0; i--) {
          final dst = i == 0
              ? ping
              : _device.textureTarget(
                  _mipTargets[i]!.width,
                  _mipTargets[i]!.height,
                  bloomFormat,
                  clearValue: const Color(0x00000000),
                  role: _dualUpRoles[i - 1],
                );
          if (upOff.sourceIdx >= 0) {
            _upsampleFrag.setTextureAt(upOff.sourceIdx, readTex);
          }
          upOff.block.writeVec4ValuesAt(
            upOff.offsetOff,
            bloom.radius / dst.width,
            bloom.radius / dst.height,
            0,
            0,
          );
          _device.beginTexturePass(dst);
          _drawQuad(_upsampleVert, _upsampleFrag, upOff);
          _device.endTexturePass();
          readTex = i == 0 ? pingTex : _textureFor(dst);
        }
        bloomReadTex = readTex;
      } else {
        final pong = _device.textureTarget(
          halfWidth,
          halfHeight,
          bloomFormat,
          clearValue: const Color(0x00000000),
          role: _BloomTarget.pong,
        );
        final pongTex = _textureFor(pong);

        _blurFrag.resource;
        final blurOff =
            (_blurFrag.renderCache as _BlurCache?) ??
            (_blurFrag.renderCache = _BlurCache(_blurFrag));
        if (blurOff.generation != _blurFrag.generation) {
          blurOff.refresh(_blurFrag);
        }

        var readTex = pingTex;
        var writeTarget = pong;
        for (var i = 0; i < bloom.passes; i++) {
          final spread = (i + 0.5) * bloom.radius;
          if (blurOff.sourceIdx >= 0) {
            _blurFrag.setTextureAt(blurOff.sourceIdx, readTex);
          }
          blurOff.block.writeVec4ValuesAt(
            blurOff.offsetOff,
            spread / halfWidth,
            spread / halfHeight,
            0,
            0,
          );
          _device.beginTexturePass(writeTarget);
          _drawQuad(_blurVert, _blurFrag, blurOff);
          _device.endTexturePass();

          if (identical(writeTarget, pong)) {
            readTex = pongTex;
            writeTarget = ping;
          } else {
            readTex = pingTex;
            writeTarget = pong;
          }
        }
        bloomReadTex = readTex;
      }
    }

    final bloomIntensity = runBloom ? bloom.intensity : 0.0;
    final exposure = postProcess?.exposure ?? 1.0;
    final contrast = postProcess?.contrast ?? 1.0;
    final saturation = postProcess?.saturation ?? 1.0;
    final effectiveToneMap =
        postProcess?.toneMap ??
        (hdrEnabled ? ToneMapMode.acesFilmic : ToneMapMode.none);
    final toneMap = effectiveToneMap.index.toDouble();
    final vigIntensity = postProcess?.vignetteIntensity ?? 0.0;
    final vigSmooth = postProcess?.vignetteSmoothness ?? 0.5;
    final fxaaEnabled = postProcess?.fxaa ?? false;
    final fxaa = fxaaEnabled ? 1.0 : 0.0;
    final c = postProcess?.tint ?? const Color(0xFFFFFFFF);

    final ssaoIntensity = postProcess?.ssaoIntensity ?? 0.0;
    final ssaoRadius = postProcess?.ssaoRadius ?? 1.5;
    final dofBlur = postProcess?.dofBlurStrength ?? 0.0;
    final dofFocus = postProcess?.dofFocusDepth ?? 0.5;
    final dofRange = postProcess?.dofFocusRange ?? 0.15;
    final hasDn = depthNormalTexture != null ? 1.0 : 0.0;

    final lut = postProcess?.colorLut;
    final lutStrength = lut != null
        ? (postProcess?.colorLutIntensity ?? 1.0).clamp(0.0, 1.0)
        : 0.0;
    final lutSize = lut?.size.toDouble() ?? 0.0;
    final lutTex = lut?.textureFor(_device.backend) ?? Texture.standard;

    final double frameCx;
    final double frameCy;
    final double frameSx;
    final double frameSy;
    if (visibleFrame == null ||
        !(visibleFrame.width > 0) ||
        !(visibleFrame.height > 0)) {
      frameCx = 0.5;
      frameCy = 0.5;
      frameSx = 2.0;
      frameSy = 2.0;
    } else {
      frameCx = visibleFrame.center.dx / fullWidth;
      frameCy = visibleFrame.center.dy / fullHeight;
      frameSx = 2 * fullWidth / visibleFrame.width;
      frameSy = 2 * fullHeight / visibleFrame.height;
    }

    final useSimpleComposite =
        debugMode == RenderDebugMode3D.none &&
        depthNormalTexture == null &&
        !fxaaEnabled &&
        lut == null;
    final compVert = useSimpleComposite ? _compositeSimpleVert : _compositeVert;
    final compFrag = useSimpleComposite ? _compositeSimpleFrag : _compositeFrag;
    compFrag.resource;
    final compCache =
        (compFrag.renderCache as _CompositeCache?) ??
        (compFrag.renderCache = _CompositeCache(compFrag));
    if (compCache.generation != compFrag.generation) {
      compCache.refresh(compFrag);
    }

    if (compCache.sceneIdx >= 0) {
      compFrag.setTextureAt(compCache.sceneIdx, sceneTexture);
    }
    if (compCache.bloomIdx >= 0) {
      compFrag.setTextureAt(compCache.bloomIdx, bloomReadTex);
    }
    if (compCache.depthNormalIdx >= 0) {
      compFrag.setTextureAt(
        compCache.depthNormalIdx,
        depthNormalTexture ?? Texture.standard,
      );
    }
    if (compCache.lutIdx >= 0) {
      compFrag.setTextureAt(compCache.lutIdx, lutTex);
    }

    compCache.block
      ..writeVec4ValuesAt(
        compCache.paramsOff,
        bloomIntensity,
        exposure,
        contrast,
        saturation,
      )
      ..writeVec4ValuesAt(
        compCache.gradingOff,
        toneMap,
        vigIntensity,
        vigSmooth,
        fxaa,
      )
      ..writeVec4ValuesAt(compCache.tintOff, c.r, c.g, c.b, 1.0)
      ..writeVec4ValuesAt(
        compCache.texelOff,
        1.0 / fullWidth,
        1.0 / fullHeight,
        0,
        0,
      )
      ..writeVec4ValuesAt(
        compCache.ssaoOff,
        ssaoIntensity,
        ssaoRadius,
        hasDn,
        0,
      )
      ..writeVec4ValuesAt(compCache.dofOff, dofBlur, dofFocus, dofRange, 0)
      ..writeVec4ValuesAt(
        compCache.lutParamsOff,
        lutStrength,
        lutSize,
        hdrEnabled ? 1.0 : 0.0,
        debugMode.index.toDouble(),
      )
      ..writeVec4ValuesAt(
        compCache.frameOff,
        frameCx,
        frameCy,
        frameSx,
        frameSy,
      );

    if (outputTarget != null) {
      _device.beginOwnedPass(outputTarget);
    } else {
      _device.beginPass(Size(fullWidth.toDouble(), fullHeight.toDouble()));
    }
    _drawQuad(compVert, compFrag, compCache);
    return _device.endPass();
  }

  final Expando<_TargetTex> _targetTextures = Expando();
  final List<GpuTextureTarget?> _mipTargets = List.filled(5, null);
  final List<Texture?> _mipTexs = List.filled(5, null);
  static const List<Object> _dualDownRoles = [
    #_bloomDualDown1,
    #_bloomDualDown2,
    #_bloomDualDown3,
    #_bloomDualDown4,
  ];
  static const List<Object> _dualUpRoles = [
    #_bloomDualUp1,
    #_bloomDualUp2,
    #_bloomDualUp3,
    #_bloomDualUp4,
  ];

  Texture _textureFor(GpuTextureTarget target) {
    final existing = _targetTextures[target];
    final gpuTex = target.texture;
    if (existing != null && identical(existing.gpuTex, gpuTex)) {
      return existing.tex;
    }
    final tex = Texture(
      null,
      width: target.width,
      height: target.height,
      sampler: TextureSampler.linear,
      gpuTexture: gpuTex,
    );
    _targetTextures[target] = _TargetTex(gpuTex, tex);
    return tex;
  }

  void _drawQuad(Shader vert, Shader frag, _BloomShaderCache cache) {
    vert.resource;
    frag.resource;
    final pipeline = _device.pipelineFor(
      vert,
      frag,
      fullscreenQuadSurface.layout,
    );
    _device
      ..bindPipeline(pipeline)
      ..setRenderState(fullscreenQuadState)
      ..bindUniformBlock(cache.block);
    final slots = cache.samplerSlots;
    final indices = cache.samplerIndices;
    for (var i = 0; i < slots.length; i++) {
      _device.bindTexture(
        slots[i],
        frag.textureAt(indices[i]) ?? Texture.standard,
      );
    }
    _device
      ..bindSurface(fullscreenQuadSurface)
      ..drawSurface(fullscreenQuadSurface);
  }
}

class _TargetTex(this.gpuTex, this.tex) {
  final GpuTexture gpuTex;
  final Texture tex;
}

abstract class _BloomShaderCache() {
  int generation = -1;
  late UniformBlock block;
  late List<GpuUniformSlot> samplerSlots;
  late List<int> samplerIndices;

  void _initBase(Shader frag, String blockName) {
    generation = frag.generation;
    block = frag.block(blockName);
    final slots = <GpuUniformSlot>[];
    final indices = <int>[];
    final slotNames = frag.slots;
    final resolved = frag.resolvedSlots;
    for (var i = 0; i < slotNames.length; i++) {
      if (resolved[i].sizeInBytes == null) {
        slots.add(resolved[i]);
        indices.add(frag.samplerIndexOf(slotNames[i]));
      }
    }
    samplerSlots = slots;
    samplerIndices = indices;
  }
}

class _PrefilterCache(Shader frag) extends _BloomShaderCache {
  this {
    refresh(frag);
  }

  late int sourceIdx;
  late int curveOff;
  late int texelOff;

  void refresh(Shader frag) {
    _initBase(frag, 'BloomPrefilter');
    sourceIdx = frag.samplerIndexOf('sourceTexture');
    curveOff = block.resolveOffset('curve');
    texelOff = block.resolveOffset('texel');
  }
}

class _BlurCache(Shader frag) extends _BloomShaderCache {
  this {
    refresh(frag);
  }

  late int sourceIdx;
  late int offsetOff;

  void refresh(Shader frag) {
    _initBase(frag, 'BloomBlur');
    sourceIdx = frag.samplerIndexOf('sourceTexture');
    offsetOff = block.resolveOffset('offset');
  }
}

class _CompositeCache(Shader frag) extends _BloomShaderCache {
  this {
    refresh(frag);
  }

  late int sceneIdx;
  late int bloomIdx;
  late int depthNormalIdx;
  late int lutIdx;
  late int paramsOff;
  late int gradingOff;
  late int tintOff;
  late int texelOff;
  late int ssaoOff;
  late int dofOff;
  late int lutParamsOff;
  late int frameOff;

  void refresh(Shader frag) {
    _initBase(frag, 'BloomComposite');
    sceneIdx = frag.samplerIndexOf('sceneTexture');
    bloomIdx = frag.samplerIndexOf('bloomTexture');
    depthNormalIdx = frag.samplerIndexOf('depthNormalTexture');
    lutIdx = frag.samplerIndexOf('lutTexture');
    paramsOff = block.resolveOffset('params');
    gradingOff = block.resolveOffset('grading');
    tintOff = block.resolveOffset('tint');
    texelOff = block.resolveOffset('texel');
    ssaoOff = block.resolveOffset('ssao');
    dofOff = block.resolveOffset('dof');
    lutParamsOff = block.resolveOffset('lutParams');
    frameOff = block.resolveOffset('frame');
  }
}

/// The two half-size targets the bloom blur alternates between.
enum _BloomTarget() {
  ping,
  pong,
}
