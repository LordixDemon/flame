import 'dart:ui' show Color, VoidCallback;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/src/model/animation_state.dart';
import 'package:flame_3d/src/model/model.dart';
import 'package:flame_3d/src/model/procedural_rigging_3d.dart';

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
  double _pendingModifierDt = 0.0;

  /// Procedural post-animation bone modifiers (`SpringBone3D`,
  /// `LookAtConstraint3D`, `TwoBoneIkConstraint3D`) applied every frame.
  final List<BoneModifier3D> boneModifiers = [];

  final Matrix4 _invWorld = Matrix4.identity();
  final List<double> _morphScratch = [];

  /// Underlying animation state (supports speed, playback mode, crossfades, and
  /// masked `layers`).
  AnimationState get animationState => _animation;

  @override
  Aabb3? computeLocalAabb() => model.animatedAabb;

  final Matrix4 _nodeTransform = Matrix4.identity();

  /// Ensures the node transforms reflect the current [animationState] clock and
  /// any [boneModifiers].
  ModelPoseWorkspace evaluatePose() {
    if (_poseDirty) {
      _poseDirty = false;
      final dt = _pendingModifierDt;
      _pendingModifierDt = 0.0;
      if (boneModifiers.isNotEmpty) {
        final w = worldTransformMatrix;
        _invWorld.copyInverse(w);
        model.evaluateInto(
          _animation,
          _workspace,
          modifiers: boneModifiers,
          worldMatrix: w,
          invWorldMatrix: _invWorld,
          dt: dt,
        );
      } else {
        model.evaluateInto(_animation, _workspace);
      }
      _evaluateAnimatedMorphTargets();
    }
    return _workspace;
  }

  final List<double> _layerMorphScratch = [];

  void _evaluateAnimatedMorphTargets() {
    final baseAnim = _animation.animationRef;
    final layers = _animation.layers;
    if (baseAnim == null && layers.isEmpty) {
      return;
    }

    for (final node in model.nodes.values) {
      final mesh = node.mesh;
      if (mesh == null) {
        continue;
      }
      final idx = node.nodeIndex;
      final baseMorph = baseAnim?.nodes[idx]?.morphWeights;
      var hasLayerMorph = false;
      var targetCount = baseMorph?.targetCount ?? 0;
      for (var li = 0; li < layers.length; li++) {
        final layer = layers[li];
        if (layer.weight <= 0 || !layer.nodeIndices.contains(idx)) {
          continue;
        }
        final lm = layer.state.animationRef?.nodes[idx]?.morphWeights;
        if (lm != null) {
          hasLayerMorph = true;
          if (lm.targetCount > targetCount) {
            targetCount = lm.targetCount;
          }
        }
      }
      if (baseMorph == null && !hasLayerMorph) {
        continue;
      }

      while (_morphScratch.length < targetCount) {
        _morphScratch.add(0.0);
      }
      for (var k = 0; k < targetCount; k++) {
        _morphScratch[k] = 0.0;
      }
      if (baseMorph != null) {
        baseMorph.sampleInto(_animation.clock, _morphScratch);
      }

      if (hasLayerMorph) {
        while (_layerMorphScratch.length < targetCount) {
          _layerMorphScratch.add(0.0);
        }
        for (var li = 0; li < layers.length; li++) {
          final layer = layers[li];
          final w = layer.weight.clamp(0.0, 1.0);
          if (w <= 0 || !layer.nodeIndices.contains(idx)) {
            continue;
          }
          final lm = layer.state.animationRef?.nodes[idx]?.morphWeights;
          if (lm == null) {
            continue;
          }
          for (var k = 0; k < targetCount; k++) {
            _layerMorphScratch[k] = 0.0;
          }
          lm.sampleInto(layer.state.clock, _layerMorphScratch);
          for (var k = 0; k < lm.targetCount; k++) {
            _morphScratch[k] += (_layerMorphScratch[k] - _morphScratch[k]) * w;
          }
        }
      }

      for (final surface in mesh.surfaces) {
        if (surface.morphTargets.isNotEmpty) {
          surface.applyMorphWeights(_morphScratch);
        }
      }
    }
  }

  /// Applies [weights] directly to all morph-enabled surfaces of [nodeName]
  /// (or to every morph-enabled surface in the model when [nodeName] is
  /// `null`).
  void setMorphWeights(List<double> weights, {String? nodeName}) {
    for (final node in model.nodes.values) {
      if (nodeName != null && node.name != nodeName) {
        continue;
      }
      final mesh = node.mesh;
      if (mesh == null) {
        continue;
      }
      for (final surface in mesh.surfaces) {
        if (surface.morphTargets.isNotEmpty) {
          surface.applyMorphWeights(weights);
        }
      }
    }
    worldOrNull?.markSceneDirty(shadows: castsShadows);
  }

  /// Creates and attaches a masked [AnimationLayer3D] affecting [boneNames]
  /// (and all descendant bones when [includeDescendants] is `true`).
  AnimationLayer3D addOverlayLayer({
    required Set<String> boneNames,
    bool includeDescendants = true,
    double weight = 1.0,
  }) {
    final indices = <int>{};
    for (final name in boneNames) {
      final idx = model.nodeIndexByName(name);
      if (idx != null) {
        indices.add(idx);
      }
    }
    if (includeDescendants && indices.isNotEmpty) {
      for (final node in model.processingOrder) {
        final p = node.parentNodeIndex;
        if (p != null && indices.contains(p)) {
          indices.add(node.nodeIndex);
        }
      }
    }
    final layer = AnimationLayer3D(nodeIndices: indices, weight: weight);
    _animation.layers.add(layer);
    _markPoseChanged();
    return layer;
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
    context.beginDepthPrepassGroup();
    try {
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
    } finally {
      context.endDepthPrepassGroup();
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
    final animChanged = _animation.update(dt);
    final hasModifiers = boneModifiers.any((m) => m.weight > 0.0);
    if (animChanged || (hasModifiers && dt > 0.0)) {
      _pendingModifierDt = dt;
      _poseDirty = true;
      evaluatePose();
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
