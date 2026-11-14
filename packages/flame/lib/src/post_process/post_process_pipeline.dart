import 'dart:async';
import 'dart:ui' as ui show Image;
import 'dart:ui' hide Image;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/post_process.dart';

/// A single named, quality-gated stage inside a [PostProcessPipeline].
class PostProcessStage({
  required final String name,
  required final PostProcess postProcess,
  var bool enabled = true,
  var GraphicsQualityTier minQualityTier = GraphicsQualityTier.low,
  var double resolutionScale = 1.0,
  var bool Function()? activePredicate,
}) {
  /// Evaluates whether this stage should execute under [controller].
  bool isStageActive(GraphicsSettingsController? controller) {
    if (!enabled) {
      return false;
    }
    if (controller != null) {
      if (!controller.effectivePostProcessEnabled) {
        return false;
      }
      if (!controller.meetsTier(minQualityTier)) {
        return false;
      }
    }
    final predicate = activePredicate;
    return predicate == null || predicate();
  }
}

sealed class _CompiledPipelineOp();

final class _StagePipelineOp(final PostProcessStage stage)
    extends _CompiledPipelineOp;

final class _FoldedColorGradingOp(
  final List<double> matrix,
  final ColorGradingPostProcess representative,
) extends _CompiledPipelineOp;

/// Ordered post-processing pipeline with per-stage [GraphicsQualityTier]
/// gating, per-stage [PostProcessStage.resolutionScale], live HiDPI sync,
/// automatic no-op stage culling, consecutive `ColorGradingPostProcess` `4x5`
/// matrix folding, direct [ui.Image] input chaining, and proper nested
/// [PostProcessingContextFinder] context propagation.
///
/// When zero stages are active (for example on [GraphicsQualityTier.low], when
/// `graphics.effectivePostProcessEnabled == false`, or when all enabled stages
/// have zero intensity), [postProcess] invokes [renderSubtree] directly onto
/// the destination canvas with `0` offscreen `PictureRecorder` or
/// `Picture.toImageSync` calls.
class PostProcessPipeline({
  List<PostProcessStage>? stages,
  this.graphics,
  super.pixelRatio,
}) extends PostProcess {
  /// Ordered list of pipeline stages from earliest (closest to world) to final.
  final List<PostProcessStage> stages = stages != null
      ? List<PostProcessStage>.of(stages)
      : <PostProcessStage>[];

  /// Optional explicit [GraphicsSettingsController]; when `null`, automatically
  /// resolves `FlameGame.graphics` from `CameraComponent.currentCamera`.
  GraphicsSettingsController? graphics;

  final List<PostProcessStage> _activeStagesScratch = <PostProcessStage>[];
  final List<_CompiledPipelineOp> _compiledOpsScratch = <_CompiledPipelineOp>[];
  final List<PostProcess> _contextStack = <PostProcess>[];
  final Paint _foldedGradePaint = Paint()..filterQuality = FilterQuality.medium;

  int _lastActiveStageCount = 0;
  int _lastSkippedNoOpStageCount = 0;
  int _lastFoldedColorGradingCount = 0;
  int _lastRasterizedImageCount = 0;
  bool _bypassedLastFrame = false;

  /// Number of effective stages that executed during the most recent pass.
  int get lastActiveStageCount => _lastActiveStageCount;

  /// Number of enabled stages automatically skipped because their effect
  /// parameters evaluated to an identity no-op (`intensity == 0`, etc.).
  int get lastSkippedNoOpStageCount => _lastSkippedNoOpStageCount;

  /// Number of redundant `ColorGradingPostProcess` stages folded into an
  /// adjacent `4x5` color matrix during the most recent pass.
  int get lastFoldedColorGradingCount => _lastFoldedColorGradingCount;

  /// Number of offscreen `Picture.toImageSync` GPU texture allocations
  /// performed during the most recent [postProcess] or [renderFromImage] call.
  int get lastRasterizedImageCount => _lastRasterizedImageCount;

  /// Whether the most recent frame bypassed offscreen rasterization completely
  /// because zero stages were active.
  bool get bypassedLastFrame => _bypassedLastFrame;

  @override
  bool get supportsImageInput => true;

  @override
  void syncDevicePixelRatio(double targetRatio) {
    super.syncDevicePixelRatio(targetRatio);
    for (var i = 0; i < stages.length; i++) {
      stages[i].postProcess.syncDevicePixelRatio(targetRatio);
    }
  }

  /// Looks up the first stage matching [name], or `null` if not found.
  PostProcessStage? findStage(String name) {
    for (var i = 0; i < stages.length; i++) {
      if (stages[i].name == name) {
        return stages[i];
      }
    }
    return null;
  }

  /// Enables or disables the stage with [name], returning `true` if found.
  bool setStageEnabled(String name, {required bool enabled}) {
    final stage = findStage(name);
    if (stage == null) {
      return false;
    }
    stage.enabled = enabled;
    return true;
  }

  GraphicsSettingsController? _resolveGraphics() {
    final explicit = graphics;
    if (explicit != null) {
      return explicit;
    }
    final game = CameraComponent.currentCamera?.findGame();
    if (game is FlameGame) {
      return game.graphics;
    }
    return null;
  }

  @override
  Future<void> onLoad() async {
    await Future.wait([
      for (final stage in stages) Future.sync(stage.postProcess.onLoad),
    ]);
  }

  @override
  void update(double dt) {
    final controller = _resolveGraphics();
    for (var i = 0; i < stages.length; i++) {
      final stage = stages[i];
      if (stage.isStageActive(controller)) {
        stage.postProcess.update(dt);
      }
    }
  }

  @override
  void onRemove() {
    for (var i = 0; i < stages.length; i++) {
      stages[i].postProcess.onRemove();
    }
    super.onRemove();
  }

  @override
  void dispose() {
    for (var i = 0; i < stages.length; i++) {
      stages[i].postProcess.dispose();
    }
    super.dispose();
  }

  void _compileActiveOps() {
    final controller = _resolveGraphics();
    _activeStagesScratch.clear();
    _compiledOpsScratch.clear();
    var skippedNoOp = 0;
    var foldedGrades = 0;

    for (var i = 0; i < stages.length; i++) {
      final stage = stages[i];
      if (!stage.isStageActive(controller)) {
        continue;
      }
      if (stage.postProcess.isEffectivelyNoOp) {
        skippedNoOp++;
        continue;
      }
      _activeStagesScratch.add(stage);
    }

    _lastSkippedNoOpStageCount = skippedNoOp;
    _lastActiveStageCount = _activeStagesScratch.length;
    if (_activeStagesScratch.isEmpty) {
      _lastFoldedColorGradingCount = 0;
      return;
    }

    final baseRatio = pixelRatio;
    for (var i = 0; i < _activeStagesScratch.length; i++) {
      final stage = _activeStagesScratch[i];
      stage.postProcess.pixelRatio =
          (baseRatio * stage.resolutionScale.clamp(0.125, 2.5)).clamp(
            0.25,
            4.0,
          );
    }

    var i = 0;
    while (i < _activeStagesScratch.length) {
      final first = _activeStagesScratch[i];
      final pp = first.postProcess;
      if (pp is ColorGradingPostProcess) {
        var combined = pp.computeColorMatrix();
        var j = i + 1;
        while (j < _activeStagesScratch.length &&
            _activeStagesScratch[j].postProcess is ColorGradingPostProcess) {
          final nextGrade =
              _activeStagesScratch[j].postProcess as ColorGradingPostProcess;
          combined = ColorGradingPostProcess.concatColorMatrices(
            nextGrade.computeColorMatrix(),
            combined,
          );
          foldedGrades++;
          j++;
        }
        if (j > i + 1) {
          _compiledOpsScratch.add(_FoldedColorGradingOp(combined, pp));
        } else {
          _compiledOpsScratch.add(_StagePipelineOp(first));
        }
        i = j;
      } else {
        _compiledOpsScratch.add(_StagePipelineOp(first));
        i++;
      }
    }
    _lastFoldedColorGradingCount = foldedGrades;
  }

  @override
  bool renderFromImage(ui.Image inputImage, Vector2 size, Canvas canvas) {
    final beforeRaster = PostProcess.debugRasterizeCount;
    _compileActiveOps();
    final dst = Rect.fromLTWH(0, 0, size.x, size.y);
    final src = Rect.fromLTWH(
      0,
      0,
      inputImage.width.toDouble(),
      inputImage.height.toDouble(),
    );

    if (_compiledOpsScratch.isEmpty) {
      _bypassedLastFrame = true;
      _foldedGradePaint.colorFilter = null;
      canvas.drawImageRect(inputImage, src, dst, _foldedGradePaint);
      _lastRasterizedImageCount =
          PostProcess.debugRasterizeCount - beforeRaster;
      return true;
    }

    _bypassedLastFrame = false;
    _contextStack.clear();

    void handleContext(PostProcess? next) {
      if (next != null) {
        _contextStack.add(next);
        updateSubtreeContext(next);
      } else {
        if (_contextStack.isNotEmpty) {
          _contextStack.removeLast();
        }
        updateSubtreeContext(_contextStack.isEmpty ? null : _contextStack.last);
      }
    }

    void renderOpAt(int index, Canvas targetCanvas) {
      final op = _compiledOpsScratch[index];
      if (index == 0) {
        switch (op) {
          case _FoldedColorGradingOp(:final matrix):
            _foldedGradePaint.colorFilter = ColorFilter.matrix(matrix);
            targetCanvas.drawImageRect(inputImage, src, dst, _foldedGradePaint);
            return;
          case _StagePipelineOp(:final stage):
            if (stage.postProcess.supportsImageInput &&
                stage.postProcess.renderFromImage(
                  inputImage,
                  size,
                  targetCanvas,
                )) {
              return;
            }
            stage.postProcess.render(
              targetCanvas,
              size,
              (innerCanvas) {
                _foldedGradePaint.colorFilter = null;
                innerCanvas.drawImageRect(
                  inputImage,
                  src,
                  dst,
                  _foldedGradePaint,
                );
              },
              handleContext,
            );
            return;
        }
      }

      switch (op) {
        case _FoldedColorGradingOp(:final matrix, :final representative):
          _foldedGradePaint.colorFilter = ColorFilter.matrix(matrix);
          targetCanvas.saveLayer(dst, _foldedGradePaint);
          handleContext(representative);
          try {
            renderOpAt(index - 1, targetCanvas);
          } finally {
            handleContext(null);
            targetCanvas.restore();
          }
        case _StagePipelineOp(:final stage):
          stage.postProcess.render(
            targetCanvas,
            size,
            (innerCanvas) => renderOpAt(index - 1, innerCanvas),
            handleContext,
          );
      }
    }

    try {
      renderOpAt(_compiledOpsScratch.length - 1, canvas);
    } finally {
      _contextStack.clear();
      updateSubtreeContext(null);
      _lastRasterizedImageCount =
          PostProcess.debugRasterizeCount - beforeRaster;
    }
    return true;
  }

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    final beforeRaster = PostProcess.debugRasterizeCount;
    _compileActiveOps();

    if (_compiledOpsScratch.isEmpty) {
      _bypassedLastFrame = true;
      renderSubtree(canvas);
      _lastRasterizedImageCount =
          PostProcess.debugRasterizeCount - beforeRaster;
      return;
    }

    _bypassedLastFrame = false;
    _contextStack.clear();
    final dst = Rect.fromLTWH(0, 0, size.x, size.y);

    void handleContext(PostProcess? next) {
      if (next != null) {
        _contextStack.add(next);
        updateSubtreeContext(next);
      } else {
        if (_contextStack.isNotEmpty) {
          _contextStack.removeLast();
        }
        updateSubtreeContext(_contextStack.isEmpty ? null : _contextStack.last);
      }
    }

    void renderOpAt(int index, Canvas targetCanvas) {
      final op = _compiledOpsScratch[index];
      switch (op) {
        case _FoldedColorGradingOp(:final matrix, :final representative):
          _foldedGradePaint.colorFilter = ColorFilter.matrix(matrix);
          targetCanvas.saveLayer(dst, _foldedGradePaint);
          handleContext(representative);
          try {
            if (index == 0) {
              renderRawSubtree(targetCanvas);
            } else {
              renderOpAt(index - 1, targetCanvas);
            }
          } finally {
            handleContext(null);
            targetCanvas.restore();
          }
        case _StagePipelineOp(:final stage):
          stage.postProcess.render(
            targetCanvas,
            size,
            (innerCanvas) {
              if (index == 0) {
                renderRawSubtree(innerCanvas);
              } else {
                renderOpAt(index - 1, innerCanvas);
              }
            },
            handleContext,
          );
      }
    }

    try {
      renderOpAt(_compiledOpsScratch.length - 1, canvas);
    } finally {
      _contextStack.clear();
      updateSubtreeContext(null);
      _lastRasterizedImageCount =
          PostProcess.debugRasterizeCount - beforeRaster;
    }
  }
}
