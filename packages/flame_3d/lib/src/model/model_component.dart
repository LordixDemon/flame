import 'dart:ui' show Color, VoidCallback;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/game.dart' show NotifyingVector4;
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/model/animation_state.dart';
import 'package:flame_3d/src/model/animation_state_machine_3d.dart';
import 'package:flame_3d/src/model/blend_space_3d.dart';
import 'package:flame_3d/src/model/model.dart';
import 'package:flame_3d/src/model/model_animation.dart';
import 'package:flame_3d/src/model/model_node.dart';
import 'package:flame_3d/src/model/procedural_rigging_3d.dart';
import 'package:flame_3d/src/model/root_motion_3d.dart';

/// Controls how [ModelComponent] advances clocks and evaluates skeletal poses
/// when culled outside the camera frustum.
enum OffscreenAnimationPolicy() {
  /// Evaluates the full skeletal pose on every [ModelComponent.update] tick
  /// whenever the animation changes (default, 100% backward-compatible).
  always,

  /// Advances clocks and dispatches [AnimationEvent3D]s every tick, but defers
  /// matrix hierarchy & skinning evaluation until [ModelComponent.draw],
  /// [ModelComponent.nodeTransform], `BoneSocket3D`, or
  /// [ModelComponent.raycast] requests the pose.
  tickOnlyEvaluateWhenVisible,

  /// Pauses clock advancement completely unless [ModelComponent.draw] ran on
  /// the preceding rendered frame.
  pauseWhenOffscreen,
}

/// A component wrapper over a 3D [Model], using an allocation-free
/// [ModelPoseWorkspace] and [AnimationState] to evaluate animations,
/// crossfades, 1D/2D blend spaces, root motion, and attached `BoneSocket3D`
/// children.
class ModelComponent({
  required final Model model,
  Color color = const Color(0xFFFFFFFF),
  Vector4? instanceData,
  var OffscreenAnimationPolicy offscreenPolicy =
      OffscreenAnimationPolicy.always,
  var RootMotionExtractor3D? rootMotion,
  AnimationStateMachine3D? stateMachine,
  var AnimationEventCallback3D? onAnimationEvent,
  super.position,
  super.rotation,
  super.scale,
  super.children,
  super.castsShadows,
}) extends Object3D {
  this {
    _animation.addEventListener(_forwardAnimationEvent);
    if (stateMachine != null) {
      this.stateMachine = stateMachine;
    }
    this.instanceData.addListener(_onInstanceDataChanged);
  }

  /// The per-instance color forwarded to materials. Changing it marks the
  /// enclosing `World3D` dirty.
  Color get color => _color;
  set color(Color value) {
    if (value == _color) {
      return;
    }
    _color = value;
    markDrawDirty(shadows: false);
  }

  Color _color = color;

  /// Four floats of per-instance data forwarded to materials; every change,
  /// in place too, marks the enclosing `World3D` dirty.
  final NotifyingVector4 instanceData = NotifyingVector4.zero()
    ..setFrom(instanceData ?? Vector4.zero());

  void _onInstanceDataChanged() => markDrawDirty(shadows: false);

  final Set<int> _hiddenNodes = {};
  final AnimationState _animation = AnimationState();
  AnimationStateMachine3D? _stateMachine;
  late final ModelPoseWorkspace _workspace = ModelPoseWorkspace.forModel(model);
  bool _poseDirty = true;
  double _pendingModifierDt = 0.0;
  bool _drawnSinceLastUpdate = false;
  int _poseEvaluationsCount = 0;

  /// Procedural post-animation bone modifiers (`SpringBone3D`,
  /// `LookAtConstraint3D`, `TwoBoneIkConstraint3D`, `FabrikIkConstraint3D`,
  /// `FootPlacementIk3D`, `RagdollController3D`) applied every frame.
  final List<BoneModifier3D> boneModifiers = [];

  final Matrix4 _invWorld = Matrix4.identity();
  final List<double> _morphScratch = [];

  /// The nodes whose mesh has at least one surface with morph targets.
  late final List<ModelNode> _morphNodes = [
    for (final node in model.processingOrder)
      if (node.mesh?.surfaces.any((s) => s.morphTargets.isNotEmpty) ?? false)
        node,
  ];

  /// This component's own meshes for morphed nodes, by node index: the
  /// surfaces with morph targets are copies (see
  /// [Surface.copyWithOwnVertices]), the others are the model's. Created the
  /// first time morph weights reach a node, so components that never morph
  /// draw the model's surfaces.
  final Map<int, Mesh> _ownMeshes = {};

  /// The morph weights last applied to each node in [_ownMeshes].
  final Map<int, List<double>> _appliedMorphWeights = {};

  void _forwardAnimationEvent(AnimationEvent3D event) {
    onAnimationEvent?.call(event);
  }

  /// Optional declarative HFSM [AnimationStateMachine3D] driving
  /// [animationState] on every [update] tick.
  AnimationStateMachine3D? get stateMachine => _stateMachine;
  set stateMachine(AnimationStateMachine3D? value) {
    if (identical(value, _stateMachine)) {
      return;
    }
    _stateMachine = value;
    value?.bind(_animation);
    _markPoseChanged();
  }

  /// Marks this component's skeletal pose dirty so the next [evaluatePose]
  /// recomputes bone transforms and skinning matrices.
  void markPoseDirty() => _markPoseChanged();

  /// Underlying animation state (supports speed, playback mode, crossfades,
  /// 1D/2D blend spaces, events, and masked `layers`).
  AnimationState get animationState => _animation;

  /// Total number of times [evaluatePose] has recomputed this component's
  /// node hierarchy and skinning matrices.
  int get poseEvaluationsCount => _poseEvaluationsCount;

  /// Resets [poseEvaluationsCount] back to `0` (useful for profiling/tests).
  void resetPoseEvaluationsCount() {
    _poseEvaluationsCount = 0;
  }

  /// Current 1D parameter driving [AnimationState.activeBlendSpace1D].
  double get blendParameter1D => _animation.blendParameter1D;
  set blendParameter1D(double value) {
    if (_animation.blendParameter1D != value) {
      _animation.blendParameter1D = value;
      _markPoseChanged();
    }
  }

  /// Current 2D parameter driving [AnimationState.activeBlendSpace2D].
  Vector2 get blendParameter2D => _animation.blendParameter2D;
  set blendParameter2D(Vector2 value) {
    if (_animation.blendParameter2D != value) {
      _animation.blendParameter2D = value;
      _markPoseChanged();
    }
  }

  @override
  Aabb3? computeLocalAabb() => model.animatedAabb;

  final Matrix4 _nodeTransform = Matrix4.identity();

  /// Ensures the node transforms reflect the current [animationState] clock,
  /// optional [rootMotion] pose lock, and any [boneModifiers].
  ModelPoseWorkspace evaluatePose() {
    if (_poseDirty) {
      _poseDirty = false;
      _poseEvaluationsCount++;
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
          rootMotion: rootMotion,
        );
      } else {
        model.evaluateInto(
          _animation,
          _workspace,
          rootMotion: rootMotion,
        );
      }
      _evaluateAnimatedMorphTargets();
    }
    return _workspace;
  }

  void _evaluateAnimatedMorphTargets() {
    if (!_animation.hasActiveEvaluation && _animation.layers.isEmpty) {
      return;
    }
    for (var i = 0; i < _morphNodes.length; i++) {
      final node = _morphNodes[i];
      final targetCount = _animation.sampleNodeMorphWeights(
        node.nodeIndex,
        _morphScratch,
      );
      if (targetCount > 0) {
        _applyMorphWeights(node, _morphScratch, targetCount);
      }
    }
  }

  /// Applies [weights] directly to all morph-enabled surfaces of [nodeName]
  /// (or to every morph-enabled surface in the model when [nodeName] is
  /// `null`).
  ///
  /// The weights are this component's own: other components of the same
  /// [model] keep theirs. The first call for a node gives this component its
  /// own copy of the node's morphed surfaces (vertices and GPU buffer).
  void setMorphWeights(List<double> weights, {String? nodeName}) {
    for (var i = 0; i < _morphNodes.length; i++) {
      final node = _morphNodes[i];
      if (nodeName != null && node.name != nodeName) {
        continue;
      }
      _applyMorphWeights(node, weights, weights.length);
    }
    worldOrNull?.markSceneDirty(shadows: castsShadows);
  }

  void _applyMorphWeights(ModelNode node, List<double> weights, int count) {
    final applied = _appliedMorphWeights[node.nodeIndex];
    if (applied != null && applied.length == count) {
      var same = true;
      for (var k = 0; k < count; k++) {
        if (applied[k] != weights[k]) {
          same = false;
          break;
        }
      }
      if (same) {
        return;
      }
    }
    final mesh = _ownMeshes[node.nodeIndex] ??= _copyMorphedSurfaces(
      node.mesh!,
    );
    for (final surface in mesh.surfaces) {
      if (surface.morphTargets.isNotEmpty) {
        surface.applyMorphWeights(weights, targetCount: count);
      }
    }
    mesh.updateBounds();
    final store = applied != null && applied.length == count
        ? applied
        : (_appliedMorphWeights[node.nodeIndex] = List<double>.filled(
            count,
            0.0,
          ));
    for (var k = 0; k < count; k++) {
      store[k] = weights[k];
    }
  }

  static Mesh _copyMorphedSurfaces(Mesh shared) {
    final mesh = Mesh();
    for (final surface in shared.surfaces) {
      mesh.addSurface(
        surface.morphTargets.isEmpty ? surface : surface.copyWithOwnVertices(),
      );
    }
    return mesh;
  }

  /// The mesh this component draws for [node]: its own copy when the node is
  /// morphed, the model's otherwise.
  Mesh? _meshOf(ModelNode node) => _ownMeshes[node.nodeIndex] ?? node.mesh;

  /// The mesh this component draws for the node at [nodeIndex]: its own copy
  /// of the node's mesh once morph weights reached the node (see
  /// [setMorphWeights]), the model's mesh otherwise, or `null` when the node
  /// has no mesh.
  Mesh? nodeMesh(int nodeIndex) {
    final node = model.nodes[nodeIndex];
    return node == null ? null : _meshOf(node);
  }

  @override
  void onRemove() {
    // Release the GPU buffers of this component's own morphed surfaces; they
    // are recreated if the component is added again.
    for (final mesh in _ownMeshes.values) {
      for (final surface in mesh.surfaces) {
        if (surface.morphTargets.isNotEmpty) {
          surface.dispose();
        }
      }
    }
    super.onRemove();
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
    _drawnSinceLastUpdate = true;
    final workspace = evaluatePose();
    context.beginDepthPrepassGroup();
    try {
      for (final node in workspace.orderedNodes) {
        if (_hiddenNodes.contains(node.node.nodeIndex)) {
          continue;
        }

        final mesh = _meshOf(node.node);
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
      final mesh = _meshOf(node.node);
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
    final wasDrawn = _drawnSinceLastUpdate;
    _drawnSinceLastUpdate = false;

    if (offscreenPolicy == OffscreenAnimationPolicy.pauseWhenOffscreen &&
        !wasDrawn) {
      rootMotion?.clearStepDeltas();
      return;
    }

    final extractor = rootMotion;
    extractor?.ensureSeededBeforeTick(model, _animation);

    final sm = _stateMachine;
    final animChanged = sm != null
        ? sm.update(dt, targetState: _animation)
        : _animation.update(dt);
    var hasModifiers = false;
    for (var i = 0; i < boneModifiers.length; i++) {
      if (boneModifiers[i].weight > 0.0) {
        hasModifiers = true;
        break;
      }
    }

    if (extractor != null) {
      if (animChanged) {
        extractor.extractStep(model, _animation, worldTransformMatrix);
        if (extractor.applyToComponentTransform) {
          // The deltas are in the model's space: `position` and `rotation`
          // are in the parent's, so the step goes through this component's
          // own rotation and scale (right under any parent transform), and
          // the turn applies about the model's up axis.
          _rootMotionStep
            ..setFrom(extractor.deltaPositionLocal)
            ..multiply(scale);
          rotation.rotate(_rootMotionStep);
          position.add(_rootMotionStep);
          if (extractor.deltaYawRad.abs() > 1e-9) {
            final up = extractor.horizontalPlane == RootMotionPlane3D.xz
                ? _upY
                : _upZ;
            _yawDeltaQ.setAxisAngle(up, extractor.deltaYawRad);
            final x = rotation.x;
            final y = rotation.y;
            final z = rotation.z;
            final w = rotation.w;
            final ox = _yawDeltaQ.x;
            final oy = _yawDeltaQ.y;
            final oz = _yawDeltaQ.z;
            final ow = _yawDeltaQ.w;
            rotation
              ..setValues(
                w * ox + x * ow + y * oz - z * oy,
                w * oy + y * ow + z * ox - x * oz,
                w * oz + z * ow + x * oy - y * ox,
                w * ow - x * ox - y * oy - z * oz,
              )
              ..normalize();
          }
        }
      } else {
        extractor.clearStepDeltas();
      }
    }

    if (animChanged || (hasModifiers && dt > 0.0)) {
      _pendingModifierDt += dt;
      _poseDirty = true;
      if (offscreenPolicy == OffscreenAnimationPolicy.always) {
        evaluatePose();
      }
      worldOrNull?.markSceneDirty(shadows: castsShadows);
    }
  }

  Set<String> get animationNames => model.animationNames;

  /// Activates a 1D [BlendSpace1D] on this component's [animationState].
  void playBlendSpace1D(
    BlendSpace1D space, {
    double initialValue = 0.0,
    bool resetClock = true,
  }) {
    if (resetClock) {
      rootMotion?.reset();
    }
    _animation.playBlendSpace1D(
      space,
      initialValue: initialValue,
      resetClock: resetClock,
    );
    _markPoseChanged();
  }

  /// Activates a 2D [BlendSpace2D] on this component's [animationState].
  void playBlendSpace2D(
    BlendSpace2D space, {
    Vector2? initialValue,
    bool resetClock = true,
  }) {
    if (resetClock) {
      rootMotion?.reset();
    }
    _animation.playBlendSpace2D(
      space,
      initialValue: initialValue,
      resetClock: resetClock,
    );
    _markPoseChanged();
  }

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
    if (resetClock) {
      rootMotion?.reset();
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
    if (resetClock) {
      rootMotion?.reset();
    }
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
    if (resetClock) {
      rootMotion?.reset();
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
    if (resetClock) {
      rootMotion?.reset();
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

  void stopAnimation() {
    rootMotion?.reset();
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

  /// Copies this component for [clone]: the copy shares the [model] and
  /// has the same [color], [instanceData], [offscreenPolicy],
  /// [onAnimationEvent], [castsShadows] and hidden nodes. It starts in the
  /// rest pose, with no animation playing.
  ///
  /// Throws an [UnsupportedError] when a [stateMachine], [rootMotion] or
  /// [boneModifiers] are set, since they are bound to this component's
  /// animation and pose; build such components with a builder prefab.
  @override
  Component3D cloneSelf() {
    if (runtimeType != ModelComponent) {
      return super.cloneSelf();
    }
    if (_stateMachine != null ||
        rootMotion != null ||
        boneModifiers.isNotEmpty) {
      throw UnsupportedError(
        'A ModelComponent with a stateMachine, rootMotion or boneModifiers '
        'cannot be cloned: they are bound to its pose. Register a builder '
        'prefab (PrefabRegistry3D.registerBuilder) instead of a prototype.',
      );
    }
    final copy = ModelComponent(
      model: model,
      color: color,
      instanceData: instanceData.clone(),
      offscreenPolicy: offscreenPolicy,
      onAnimationEvent: onAnimationEvent,
      castsShadows: castsShadows,
    );
    copy._hiddenNodes.addAll(_hiddenNodes);
    return copy;
  }

  void _markPoseChanged() {
    _poseDirty = true;
    worldOrNull?.markSceneDirty(shadows: castsShadows);
  }

  static final Vector3 _upY = Vector3(0, 1, 0);
  static final Vector3 _upZ = Vector3(0, 0, 1);
  static final Quaternion _yawDeltaQ = Quaternion.identity();
  static final Vector3 _rootMotionStep = Vector3.zero();
}
