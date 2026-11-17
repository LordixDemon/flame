import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/src/post_process/post_process.dart';
import 'package:flame/src/post_process/shader_post_process.dart';
import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

/// Multi-texture GPU fragment-shader post-process that rasterizes both the
/// primary full-resolution scene (`uScene` / sampler `0`) and a downscaled
/// auxiliary pass (`uAux` / sampler `1`, such as `0.25x` `RenderPass.emissiveMask`
/// or downsampled bloom) without GPU texture leaks or full-resolution 9-tap
/// bandwidth stalls.
abstract class DualPassShaderPostProcess extends ShaderPostProcess {
  /// Creates a [DualPassShaderPostProcess] that loads `assetPath` in [onLoad].
  DualPassShaderPostProcess({
    super.assetPath,
    super.program,
    super.enabled,
    super.pixelRatio,
    this.auxiliaryResolutionScale = 0.25,
    this.auxiliaryPassTag = 'auxiliary',
    this.auxiliaryRenderPass = RenderPass.emissiveMask,
  });

  /// Creates a [DualPassShaderPostProcess] backed by an already-loaded
  /// [program].
  DualPassShaderPostProcess.fromProgram(
    super.program, {
    super.enabled,
    super.pixelRatio,
    this.auxiliaryResolutionScale = 0.25,
    this.auxiliaryPassTag = 'auxiliary',
    this.auxiliaryRenderPass = RenderPass.emissiveMask,
  }) : super.fromProgram();

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

  @override
  void configureShader(
    ui.FragmentShader shader,
    Vector2 imageSize,
    ui.Image subtreeImage,
    double time,
  ) {
    configureDualPassShader(
      shader,
      imageSize,
      imageSize,
      subtreeImage,
      subtreeImage,
      time,
    );
  }

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
      time,
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
  }
}
