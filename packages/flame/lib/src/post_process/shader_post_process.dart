import 'dart:async';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/src/post_process/post_process.dart';
import 'package:flame/src/post_process/uniform_slot_buffer.dart';
import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

/// Base class for GPU fragment-shader post processes that automatically caches
/// a single [ui.FragmentShader] instance across frames, writes its float
/// uniforms through [uniforms], and disposes transient rasterized subtree
/// [ui.Image]s without per-frame shader allocations or GPU texture leaks.
///
/// The subtree is rasterized into a new image every frame; that image is
/// kept until the next frame replaces it. While the post process is switched
/// off ([enabled] is false or there is no program) it passes the subtree
/// through untouched and holds neither the last image nor the shader that
/// samples it.
abstract class ShaderPostProcess extends PostProcess {
  /// Creates a [ShaderPostProcess] that loads [assetPath] during [onLoad] or
  /// uses an already-loaded [program].
  ShaderPostProcess({
    this.assetPath,
    ui.FragmentProgram? program,
    this.enabled = true,
    super.pixelRatio,
  }) {
    _program = program;
  }

  /// Creates a [ShaderPostProcess] backed by an already-loaded [program].
  ShaderPostProcess.fromProgram(
    ui.FragmentProgram program, {
    this.enabled = true,
    super.pixelRatio,
  }) : assetPath = null,
       _program = program;

  /// Optional asset path passed to [ui.FragmentProgram.fromAsset] in [onLoad].
  final String? assetPath;
  ui.FragmentProgram? _program;
  ui.FragmentProgram? _shaderProgram;
  ui.FragmentShader? _cachedShader;

  int _quadW = -1;
  int _quadH = -1;
  Rect _quadRect = Rect.zero;
  final Vector2 _imageSizeScratch = Vector2.zero();
  final Paint _shaderPaint = Paint();

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

  /// Writes uniforms and image samplers onto [shader] for the current frame.
  @protected
  void configureShader(
    ui.FragmentShader shader,
    Vector2 imageSize,
    ui.Image subtreeImage,
    double time,
  );

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

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    final program = resolveProgram();
    if (!enabled || program == null || size.x < 4 || size.y < 4) {
      releaseFrameResources();
      renderSubtree(canvas);
      return;
    }

    final dpr = pixelRatio.clamp(0.5, 3.0);
    final ui.Image frameImage;
    try {
      frameImage = rasterizePass();
    } on Object {
      renderSubtree(canvas);
      return;
    }

    replaceHeldSceneImage(frameImage);

    final imgW = frameImage.width;
    final imgH = frameImage.height;
    if (imgW != _quadW || imgH != _quadH) {
      _quadW = imgW;
      _quadH = imgH;
      _quadRect = Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble());
    }
    _imageSizeScratch.setValues(imgW.toDouble(), imgH.toDouble());

    final shader = obtainCachedShader(program);
    configureShader(shader, _imageSizeScratch, frameImage, _time);

    _shaderPaint.shader = shader;
    if (dpr != 1.0) {
      canvas.save();
      canvas.scale(1.0 / dpr, 1.0 / dpr);
      canvas.drawRect(_quadRect, _shaderPaint);
      canvas.restore();
    } else {
      canvas.drawRect(_quadRect, _shaderPaint);
    }
    _shaderPaint.shader = null;
  }

  /// Besides the held scene image this drops the cached shader, because a
  /// shader keeps the textures bound to its samplers alive; a new one is
  /// created on the next frame.
  @override
  @mustCallSuper
  void releaseFrameResources() {
    super.releaseFrameResources();
    uniforms.invalidate();
    _cachedShader?.dispose();
    _cachedShader = null;
    _shaderProgram = null;
  }
}
