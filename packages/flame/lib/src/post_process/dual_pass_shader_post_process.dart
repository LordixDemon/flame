import 'dart:async';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/src/post_process/post_process.dart';
import 'package:flame/src/post_process/uniform_slot_buffer.dart';
import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

/// Multi-texture GPU fragment-shader post-process that rasterizes both the
/// primary full-resolution scene (`uScene` / sampler `0`) and a downscaled
/// auxiliary pass (`uAux` / sampler `1`, such as `0.25x`
/// `RenderPass.emissiveMask` or downsampled bloom) without GPU texture leaks or
/// full-resolution 9-tap bandwidth stalls.
abstract class DualPassShaderPostProcess extends PostProcess {
  /// Creates a [DualPassShaderPostProcess] that loads [assetPath] in [onLoad].
  DualPassShaderPostProcess({
    this.assetPath,
    ui.FragmentProgram? program,
    this.enabled = true,
    super.pixelRatio,
    this.auxiliaryResolutionScale = 0.25,
    this.auxiliaryPassTag = 'auxiliary',
    this.auxiliaryRenderPass = RenderPass.emissiveMask,
  }) {
    _program = program;
  }

  /// Creates a [DualPassShaderPostProcess] backed by an already-loaded
  /// [program].
  DualPassShaderPostProcess.fromProgram(
    ui.FragmentProgram program, {
    this.enabled = true,
    super.pixelRatio,
    this.auxiliaryResolutionScale = 0.25,
    this.auxiliaryPassTag = 'auxiliary',
    this.auxiliaryRenderPass = RenderPass.emissiveMask,
  }) : assetPath = null,
       _program = program;

  /// Optional asset path passed to [ui.FragmentProgram.fromAsset] in [onLoad].
  final String? assetPath;
  ui.FragmentProgram? _program;
  ui.FragmentProgram? _shaderProgram;
  ui.FragmentShader? _cachedShader;
  double _time = 0.0;

  /// Float uniform writer associated with this post-process.
  final UniformSlotBuffer uniforms = UniformSlotBuffer();

  /// Whether shader post-processing is active; when false, the subtree is
  /// rendered directly without offscreen rasterization.
  bool enabled;

  /// Elapsed time in seconds accumulated across [update] ticks.
  double get time => _time;

  /// Whether a live [ui.FragmentShader] instance is currently cached.
  bool get hasCachedShader => _cachedShader != null;

  /// Writes [value] into uniform slot [index] on [shader] through [uniforms].
  @protected
  bool setShaderFloat(ui.FragmentShader shader, int index, double value) =>
      uniforms.setFloat(shader, index, value);

  /// Returns the active [ui.FragmentProgram], allowing subclasses to supply a
  /// lazily loaded or shared program.
  @protected
  ui.FragmentProgram? resolveProgram() => _program;

  @override
  @mustCallSuper
  Future<void> onLoad() async {
    await super.onLoad();
    final path = assetPath;
    if (_program == null && path != null) {
      _program = await ui.FragmentProgram.fromAsset(path);
    }
  }

  @override
  @mustCallSuper
  void update(double dt) {
    super.update(dt);
    _time += dt;
  }

  /// Returns the cached [ui.FragmentShader] for [program], recreating it only
  /// when [program] changes or no shader is cached yet.
  @protected
  ui.FragmentShader obtainCachedShader(ui.FragmentProgram program) {
    if (!identical(_shaderProgram, program) || _cachedShader == null) {
      _cachedShader?.dispose();
      uniforms.invalidate();
      _shaderProgram = program;
      _cachedShader = program.fragmentShader();
    }
    return _cachedShader!;
  }

  /// Replaces and disposes the previously held primary scene [ui.Image].
  @protected
  void replaceHeldSceneImage(ui.Image nextImage) => holdFrameImage(nextImage);

  @override
  bool get isEffectivelyNoOp => !enabled || resolveProgram() == null;

  /// Resolution multiplier `(0.125 .. 1.0]` applied to [pixelRatio] when
  /// rasterizing the auxiliary pass (`0.25` = `1/16` pixel count).
  double auxiliaryResolutionScale;

  /// Value exposed via [PostProcess.currentPassTag] while rasterizing the
  /// auxiliary pass.
  Object? auxiliaryPassTag;

  /// Optional [RenderPass] pushed onto `CameraComponent.currentRenderPass`
  /// while rasterizing the auxiliary pass (defaults to
  /// [RenderPass.emissiveMask] for selective emissive bloom; set to `null` to
  /// downsample the entire scene).
  RenderPass? auxiliaryRenderPass;

  ui.Image? _heldAuxImage;
  int _quadW = -1;
  int _quadH = -1;
  Rect _quadRect = Rect.zero;
  final Vector2 _sceneSizeScratch = Vector2.zero();
  final Vector2 _auxSizeScratch = Vector2.zero();
  final Paint _dualShaderPaint = Paint();

  /// Whether the auxiliary pass should be rasterized this frame. Returning
  /// `false` allows subclasses to skip the second pass dynamically when
  /// auxiliary intensity (for example bloom strength) is zero.
  @protected
  bool get shouldRasterizeAuxiliaryPass => true;

  /// Writes uniforms and binds both [sceneImage] (sampler `0`) and [auxImage]
  /// (sampler `1`, or [sceneImage] when [shouldRasterizeAuxiliaryPass] is
  /// `false`) onto [shader].
  @protected
  void configureDualPassShader(
    ui.FragmentShader shader,
    Vector2 sceneImageSize,
    Vector2 auxImageSize,
    ui.Image sceneImage,
    ui.Image auxImage,
    double time,
  );

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    final program = resolveProgram();
    if (!enabled || program == null || size.x < 4 || size.y < 4) {
      releaseFrameResources();
      renderSubtree(canvas);
      return;
    }

    final dpr = pixelRatio.clamp(0.5, 3.0);
    final ui.Image sceneImage;
    final ui.Image auxImage;
    try {
      sceneImage = rasterizePass(passTag: 'primary');
      if (shouldRasterizeAuxiliaryPass) {
        auxImage = rasterizePass(
          resolutionScale: auxiliaryResolutionScale,
          passTag: auxiliaryPassTag,
          cameraRenderPass: auxiliaryRenderPass,
        );
      } else {
        auxImage = sceneImage;
      }
    } on Object {
      renderSubtree(canvas);
      return;
    }

    replaceHeldSceneImage(sceneImage);
    if (!identical(auxImage, sceneImage)) {
      _heldAuxImage?.dispose();
      _heldAuxImage = auxImage;
    } else {
      _heldAuxImage?.dispose();
      _heldAuxImage = null;
    }

    final imgW = sceneImage.width;
    final imgH = sceneImage.height;
    if (imgW != _quadW || imgH != _quadH) {
      _quadW = imgW;
      _quadH = imgH;
      _quadRect = Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble());
    }
    _sceneSizeScratch.setValues(imgW.toDouble(), imgH.toDouble());
    _auxSizeScratch.setValues(
      auxImage.width.toDouble(),
      auxImage.height.toDouble(),
    );

    final shader = obtainCachedShader(program);
    configureDualPassShader(
      shader,
      _sceneSizeScratch,
      _auxSizeScratch,
      sceneImage,
      auxImage,
      _time,
    );

    _dualShaderPaint.shader = shader;
    if (dpr != 1.0) {
      canvas.save();
      canvas.scale(1.0 / dpr, 1.0 / dpr);
      canvas.drawRect(_quadRect, _dualShaderPaint);
      canvas.restore();
    } else {
      canvas.drawRect(_quadRect, _dualShaderPaint);
    }
    _dualShaderPaint.shader = null;
  }

  @override
  bool get holdsFrameImage => super.holdsFrameImage || _heldAuxImage != null;

  @override
  @mustCallSuper
  void releaseFrameResources() {
    _heldAuxImage?.dispose();
    _heldAuxImage = null;
    super.releaseFrameResources();
    uniforms.invalidate();
    _cachedShader?.dispose();
    _cachedShader = null;
    _shaderProgram = null;
  }
}
