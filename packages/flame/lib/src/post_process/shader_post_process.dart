import 'dart:async';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/post_process.dart';
import 'package:flutter/painting.dart';
import 'package:meta/meta.dart';

/// Base class for GPU fragment-shader post processes that automatically caches
/// a single [ui.FragmentShader] instance across frames and disposes transient
/// rasterized subtree [ui.Image]s without per-frame shader allocations or GPU
/// texture leaks.
abstract class ShaderPostProcess extends PostProcess {
  /// Creates a [ShaderPostProcess] that loads `assetPath` during [onLoad].
  ShaderPostProcess({
    this._assetPath,
    this._program,
    this.enabled = true,
    super.pixelRatio,
  });

  /// Creates a [ShaderPostProcess] backed by an already-loaded [program].
  ShaderPostProcess.fromProgram(
    ui.FragmentProgram program, {
    this.enabled = true,
    super.pixelRatio,
  }) : _assetPath = null,
       _program = program;

  final String? _assetPath;
  ui.FragmentProgram? _program;
  ui.FragmentProgram? _shaderProgram;
  ui.FragmentShader? _cachedShader;
  ui.Image? _heldImage;

  int _quadW = -1;
  int _quadH = -1;
  Rect _quadRect = Rect.zero;
  final Vector2 _imageSizeScratch = Vector2.zero();
  final Paint _shaderPaint = Paint();

  double _time = 0.0;

  /// Whether shader post-processing is active; when false, the subtree is
  /// rendered directly without offscreen rasterization.
  bool enabled;

  /// Elapsed time in seconds accumulated across [update] ticks.
  double get time => _time;

  /// Whether a live [ui.FragmentShader] instance is currently cached.
  bool get hasCachedShader => _cachedShader != null;

  /// Returns the active [ui.FragmentProgram], allowing subclasses to supply a
  /// lazily loaded or shared program.
  @protected
  ui.FragmentProgram? resolveProgram() => _program;

  @override
  @mustCallSuper
  Future<void> onLoad() async {
    await super.onLoad();
    final path = _assetPath;
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

  ui.FragmentShader _obtainShader(ui.FragmentProgram program) {
    if (!identical(_shaderProgram, program) || _cachedShader == null) {
      _cachedShader?.dispose();
      _shaderProgram = program;
      _cachedShader = program.fragmentShader();
    }
    return _cachedShader!;
  }

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    final program = resolveProgram();
    if (!enabled || program == null || size.x < 4 || size.y < 4) {
      renderSubtree(canvas);
      return;
    }

    final dpr = pixelRatio.clamp(0.5, 3.0);
    final imgW = (size.x * dpr).ceil();
    final imgH = (size.y * dpr).ceil();
    if (imgW <= 0 || imgH <= 0) {
      renderSubtree(canvas);
      return;
    }

    final ui.Image frameImage;
    try {
      final recorder = ui.PictureRecorder();
      final inner = Canvas(recorder);
      if (dpr != 1.0) {
        inner.scale(dpr, dpr);
      }
      renderSubtree(inner);
      final picture = recorder.endRecording();
      try {
        frameImage = picture.toImageSync(imgW, imgH);
      } finally {
        picture.dispose();
      }
    } on Object {
      renderSubtree(canvas);
      return;
    }

    _heldImage?.dispose();
    _heldImage = frameImage;

    if (imgW != _quadW || imgH != _quadH) {
      _quadW = imgW;
      _quadH = imgH;
      _quadRect = Rect.fromLTWH(0, 0, imgW.toDouble(), imgH.toDouble());
    }
    _imageSizeScratch.setValues(imgW.toDouble(), imgH.toDouble());

    final shader = _obtainShader(program);
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

  @override
  @mustCallSuper
  void onRemove() {
    _heldImage?.dispose();
    _heldImage = null;
    super.onRemove();
  }

  @override
  @mustCallSuper
  void dispose() {
    super.dispose();
    _cachedShader?.dispose();
    _cachedShader = null;
    _shaderProgram = null;
  }
}
