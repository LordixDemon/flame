import 'dart:ui' show Color, VoidCallback;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/src/model/animation_state.dart';
import 'package:flame_3d/src/model/model.dart';

/// A component wrapper over a 3D [Model], using an allocation-free
/// [ModelPoseWorkspace] and [AnimationState] to evaluate animations, crossfades
/// and attached `BoneSocket3D` children.
class ModelComponent({
  required final Model model,
  var Color color = const Color(0xFFFFFFFF),
  Vector4? instanceData,
  super.position,
  super.rotation,
  super.scale,
  super.children,
  super.castsShadows,
}) extends Object3D {
  /// Four floats of per-instance data forwarded to materials.
  final Vector4 instanceData = instanceData?.clone() ?? Vector4.zero();

  final Set<int> _hiddenNodes = {};
  final AnimationState _animation = AnimationState();
  late final ModelPoseWorkspace _workspace = ModelPoseWorkspace.forModel(model);
  bool _poseDirty = true;

  /// Underlying animation state (supports speed, playback mode and crossfades).
  AnimationState get animationState => _animation;

  @override
  Aabb3? computeLocalAabb() => model.animatedAabb;

  final Matrix4 _nodeTransform = Matrix4.identity();

  /// Ensures the node transforms reflect the current [animationState] clock.
  ModelPoseWorkspace evaluatePose() {
    if (_poseDirty) {
      _poseDirty = false;
      model.evaluateInto(_animation, _workspace);
    }
    return _workspace;
  }

  /// Combined model-space transform of [nodeIndex] in the current pose, or
  /// `null` if no such node exists.
  Matrix4? nodeTransform(int nodeIndex) {
    return evaluatePose().nodesByIndex[nodeIndex]?.combinedTransform;
  }

  /// Combined model-space transform of the node named [name] in the current
  /// pose, or `null` if no such node exists.
  Matrix4? nodeTransformByName(String name) {
    final index = model.nodeIndexByName(name);
    return index == null ? null : nodeTransform(index);
  }

  @override
  void draw(covariant RenderContext3D context) {
    final workspace = evaluatePose();
    for (final node in workspace.orderedNodes) {
      if (_hiddenNodes.contains(node.node.nodeIndex)) {
        continue;
      }

      final mesh = node.node.mesh;
      if (mesh != null) {
        _nodeTransform
          ..setFrom(worldTransformMatrix)
          ..multiply(node.combinedTransform);
        context.drawMesh(
          mesh,
          transform: _nodeTransform,
          color: color,
          instanceData: instanceData,
          jointTransforms: node.jointTransforms,
        );
      }
    }
  }

  @override
  RayHit3D? raycast(
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) {
    final workspace = evaluatePose();
    RayHit3D? best;
    var limit = maxDistance;
    for (final node in workspace.orderedNodes) {
      if (_hiddenNodes.contains(node.node.nodeIndex)) {
        continue;
      }
      final mesh = node.node.mesh;
      if (mesh == null) {
        continue;
      }
      _nodeTransform
        ..setFrom(worldTransformMatrix)
        ..multiply(node.combinedTransform);
      final hit = RayHit3D.intersectMesh(
        owner: this,
        mesh: mesh,
        modelMatrix: _nodeTransform,
        worldRay: worldRay,
        maxDistance: limit,
        cullMode: cullMode,
      );
      if (hit != null && hit.distance < limit) {
        limit = hit.distance;
        best = hit;
      }
    }
    return best;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (_animation.update(dt)) {
      _poseDirty = true;
      model.evaluateInto(_animation, _workspace);
      _poseDirty = false;
      worldOrNull?.markSceneDirty(shadows: castsShadows);
    }
  }

  Set<String> get animationNames => model.animationNames;

  void playAnimationByName(
    String name, {
    bool resetClock = true,
    AnimationPlayMode mode = AnimationPlayMode.loop,
    VoidCallback? onComplete,
  }) {
    final animation = model.animations.where((e) => e.name == name).firstOrNull;
    if (animation == null) {
      throw ArgumentError('No animation with name $name');
    }
    _animation.startAnimation(
      animation,
      resetClock: resetClock,
      mode: mode,
      onComplete: onComplete,
    );
    _markPoseChanged();
  }

  void playAnimationByIndex(
    int index, {
    bool resetClock = true,
    AnimationPlayMode mode = AnimationPlayMode.loop,
    VoidCallback? onComplete,
  }) {
    final animation = model.animations[index];
    _animation.startAnimation(
      animation,
      resetClock: resetClock,
      mode: mode,
      onComplete: onComplete,
    );
    _markPoseChanged();
  }

  /// Smoothly crossfades to the animation named [name] over [duration] seconds.
  void crossFadeToByName(
    String name, {
    double duration = 0.25,
    bool resetClock = true,
    AnimationPlayMode mode = AnimationPlayMode.loop,
    VoidCallback? onComplete,
  }) {
    final animation = model.animations.where((e) => e.name == name).firstOrNull;
    if (animation == null) {
      throw ArgumentError('No animation with name $name');
    }
    _animation.crossFadeTo(
      animation,
      duration: duration,
      resetClock: resetClock,
      mode: mode,
      onComplete: onComplete,
    );
    _markPoseChanged();
  }

  /// Smoothly crossfades to the animation at [index] over [duration] seconds.
  void crossFadeToByIndex(
    int index, {
    double duration = 0.25,
    bool resetClock = true,
    AnimationPlayMode mode = AnimationPlayMode.loop,
    VoidCallback? onComplete,
  }) {
    final animation = model.animations[index];
    _animation.crossFadeTo(
      animation,
      duration: duration,
      resetClock: resetClock,
      mode: mode,
      onComplete: onComplete,
    );
    _markPoseChanged();
  }

  void stopAnimation() {
    _animation.startAnimation(null);
    _markPoseChanged();
  }

  void hideNodeByName(String name, {bool hidden = true}) {
    final node = model.nodes.entries.firstWhere((e) => e.value.name == name);
    if (hidden) {
      _hiddenNodes.add(node.key);
    } else {
      _hiddenNodes.remove(node.key);
    }
    worldOrNull?.markSceneDirty(shadows: castsShadows);
  }

  void _markPoseChanged() {
    _poseDirty = true;
    worldOrNull?.markSceneDirty(shadows: castsShadows);
  }
}
