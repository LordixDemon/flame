import 'dart:async';
import 'dart:ui';

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

/// Ordered post-processing pipeline with per-stage [GraphicsQualityTier]
/// gating, per-stage [PostProcessStage.resolutionScale], live HiDPI sync, and
/// zero-rasterization fast bypass when all stages are inactive.
///
/// When zero stages are active (for example on [GraphicsQualityTier.low] or
/// when `graphics.effectivePostProcessEnabled == false`), [postProcess] invokes
/// [renderSubtree] directly onto the destination canvas with `0` offscreen
/// `PictureRecorder` or `Picture.toImageSync` calls.
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
  int _lastActiveStageCount = 0;
  bool _bypassedLastFrame = false;

  /// Number of stages that executed during the most recent [postProcess] pass.
  int get lastActiveStageCount => _lastActiveStageCount;

  /// Whether the most recent frame bypassed offscreen rasterization completely
  /// because zero stages were active.
  bool get bypassedLastFrame => _bypassedLastFrame;

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

  @override
  void postProcess(Vector2 size, Canvas canvas) {
    final controller = _resolveGraphics();
    _activeStagesScratch.clear();
    for (var i = 0; i < stages.length; i++) {
      final stage = stages[i];
      if (stage.isStageActive(controller)) {
        _activeStagesScratch.add(stage);
      }
    }

    _lastActiveStageCount = _activeStagesScratch.length;
    if (_activeStagesScratch.isEmpty) {
      _bypassedLastFrame = true;
      renderSubtree(canvas);
      return;
    }

    _bypassedLastFrame = false;
    final baseRatio = pixelRatio;
    for (var i = 0; i < _activeStagesScratch.length; i++) {
      final stage = _activeStagesScratch[i];
      stage.postProcess.pixelRatio =
          (baseRatio * stage.resolutionScale.clamp(0.125, 2.5)).clamp(
            0.25,
            4.0,
          );
    }

    void renderChainAt(int index, Canvas targetCanvas) {
      final stage = _activeStagesScratch[index];
      stage.postProcess.render(
        targetCanvas,
        size,
        (innerCanvas) {
          if (index == 0) {
            renderSubtree(innerCanvas);
          } else {
            renderChainAt(index - 1, innerCanvas);
          }
        },
        (_) {},
      );
    }

    renderChainAt(_activeStagesScratch.length - 1, canvas);
  }
}
