import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/src/model/animation_state.dart';
import 'package:flame_3d/src/model/model.dart';
import 'package:flame_3d/src/model/model_animation.dart';
import 'package:flame_3d/src/model/model_node.dart';

/// Pre-evaluated pose of a single mesh-bearing [ModelNode] at one quantized
/// frame inside a [BakedClipPoseBank3D].
class BakedNodePose3D({
  required final ModelNode node,
  required final Matrix4 combinedTransform,
  required final Map<int, List<Matrix4>> jointTransforms,
}) {
  /// Whether this node renders skinned surfaces.
  bool get isSkinned => jointTransforms.isNotEmpty;
}

/// Pre-sampled frame bank of a single [ModelAnimation] clip used by
/// [SkinnedCrowdBatch3D] so `N` crowd agents index `(clipIndex, frameIndex)` in
/// `O(1)` without per-frame [AnimationState] or [Matrix4] hierarchy work.
class BakedClipPoseBank3D({
  required final String? name,
  required final double duration,
  required final double bakedFps,
  required final List<List<BakedNodePose3D>> frames,
  required final List<Map<int, List<Matrix4>>> primaryJointBank,
}) {
  /// Number of pre-baked pose frames in this clip bank (`>= 1`).
  int get frameCount => frames.length;
}

/// High-throughput crowd renderer ([Object3D]) managing `N` animated instances
/// of a shared [Model].
///
/// All clips of [model] are quantized once at [bakedFps] (`30` FPS by default)
/// into immutable [BakedClipPoseBank3D]s. At runtime:
/// - **Update (`O(N)` scalar math)**: each agent advances a scalar clock and
///   computes its integer `frameIndex` with **`0` `AnimationState` updates and
///   `0` `Matrix4` hierarchy/joint multiplies**.
/// - **Draw**: skinned mesh nodes submit pre-baked `Map<int, List<Matrix4>>`
///   palettes directly by reference, while unskinned static sub-nodes are
///   automatically coalesced across all `N` agents into `1`
///   [RenderContext3D.drawInstances] batch per surface.
class SkinnedCrowdBatch3D({
  required final Model model,
  final double bakedFps = 30.0,
  int initialCapacity = 64,
  super.position,
  super.rotation,
  super.scale,
  super.children,
  super.castsShadows,
}) extends Object3D {
  this {
    if (bakedFps <= 0.0 || bakedFps.isNaN || bakedFps.isInfinite) {
      throw ArgumentError.value(bakedFps, 'bakedFps', 'Must be finite and > 0');
    }
    if (initialCapacity < 1) {
      throw ArgumentError.value(
        initialCapacity,
        'initialCapacity',
        'Must be >= 1',
      );
    }
    _capacity = initialCapacity;
    _transforms = Float32List(_capacity * 16);
    _colorsAndData = Float32List(_capacity * 8);
    _clocks = Float64List(_capacity);
    _speeds = Float64List(_capacity);
    _clipIndices = Int32List(_capacity);
    _frameIndices = Int32List(_capacity);
    _modes = Int32List(_capacity);
    _pingPongDirs = Int32List(_capacity);
    poseBanks = _bakeModel(model, bakedFps);
    _classifyMeshNodes();
  }

  static const int _instanceStride = VertexLayout.instanceStrideInFloats;

  /// Pre-sampled animation banks indexed by clip index (`0` holds the rest pose
  /// when [Model.animations] is empty).
  late final List<BakedClipPoseBank3D> poseBanks;

  final List<int> _skinnedMeshSlots = [];
  final List<int> _staticMeshSlots = [];
  List<Float32List> _staticInstanceBuffers = const [];
  List<Float32List> _skinnedInstanceBuffers = const [];
  late final Int32List _clipBaseOffsets;
  late final int _totalPoseCount;
  late final Int32List _bucketHead;
  late final Int32List _usedBuckets;
  late Int32List _bucketNext;

  int _capacity = 64;
  int _length = 0;

  late Float32List _transforms;
  late Float32List _colorsAndData;

  /// The color of each agent as a [Color], kept beside [_colorsAndData] so
  /// skinned draws pass it without creating one per agent and frame.
  final List<Color> _colors = [];
  late Float64List _clocks;
  late Float64List _speeds;
  late Int32List _clipIndices;
  late Int32List _frameIndices;
  late Int32List _modes;
  late Int32List _pingPongDirs;

  final Aabb3 _localAabb = Aabb3();
  bool _boundsDirty = true;

  int _lastInstancedSubNodeDraws = 0;
  int _lastSkinnedNodeDraws = 0;
  int _lastSkinnedPoseBuckets = 0;

  /// Number of active crowd agents.
  int get length => _length;

  /// Whether this batch contains zero agents.
  bool get isEmpty => _length == 0;

  /// Whether this batch contains at least one agent.
  bool get isNotEmpty => _length > 0;

  /// Number of `drawInstances` batches submitted for unskinned static sub-nodes
  /// during the most recent [draw] pass.
  int get lastInstancedSubNodeDraws => _lastInstancedSubNodeDraws;

  /// Number of skinned node agent draws submitted during the most recent [draw]
  /// pass.
  int get lastSkinnedNodeDraws => _lastSkinnedNodeDraws;

  /// Number of pose-bucketed GPU `drawInstances` submissions emitted for
  /// skinned nodes during the most recent [draw] pass.
  int get lastSkinnedPoseBuckets => _lastSkinnedPoseBuckets;

  static List<BakedClipPoseBank3D> _bakeModel(Model model, double fps) {
    final workspace = ModelPoseWorkspace.forModel(model);
    final state = AnimationState();
    final meshNodeIndices = <int>[
      for (var i = 0; i < workspace.orderedNodes.length; i++)
        if (workspace.orderedNodes[i].node.mesh != null) i,
    ];

    BakedClipPoseBank3D bakeSingle({
      required String? name,
      required double duration,
      required void Function(double time) evaluateAt,
    }) {
      final count = duration > 1e-9 ? math.max(1, (duration * fps).round()) : 1;
      final frames = <List<BakedNodePose3D>>[];
      final primaryBank = <Map<int, List<Matrix4>>>[];

      for (var f = 0; f < count; f++) {
        final t = count <= 1 ? 0.0 : (f / fps).clamp(0.0, duration);
        evaluateAt(t);

        final nodePoses = <BakedNodePose3D>[];
        Map<int, List<Matrix4>>? firstSkinnedJoints;
        for (final orderIdx in meshNodeIndices) {
          final processed = workspace.orderedNodes[orderIdx];
          final clonedJoints = <int, List<Matrix4>>{
            for (final entry in processed.jointTransforms.entries)
              entry.key: List<Matrix4>.unmodifiable([
                for (final jm in entry.value) jm.clone(),
              ]),
          };
          firstSkinnedJoints ??= clonedJoints.isNotEmpty ? clonedJoints : null;
          nodePoses.add(
            BakedNodePose3D(
              node: processed.node,
              combinedTransform: processed.combinedTransform.clone(),
              jointTransforms: Map<int, List<Matrix4>>.unmodifiable(
                clonedJoints,
              ),
            ),
          );
        }
        frames.add(List<BakedNodePose3D>.unmodifiable(nodePoses));
        primaryBank.add(firstSkinnedJoints ?? const {});
      }

      return BakedClipPoseBank3D(
        name: name,
        duration: duration,
        bakedFps: fps,
        frames: List<List<BakedNodePose3D>>.unmodifiable(frames),
        primaryJointBank: List<Map<int, List<Matrix4>>>.unmodifiable(
          primaryBank,
        ),
      );
    }

    if (model.animations.isEmpty) {
      return List<BakedClipPoseBank3D>.unmodifiable([
        bakeSingle(
          name: null,
          duration: 0.0,
          evaluateAt: (_) => model.evaluateInto(state, workspace),
        ),
      ]);
    }

    final banks = <BakedClipPoseBank3D>[];
    for (final clip in model.animations) {
      state.startAnimation(clip, mode: AnimationPlayMode.once);
      banks.add(
        bakeSingle(
          name: clip.name,
          duration: clip.lastTime,
          evaluateAt: (time) {
            state.clock = time;
            model.evaluateInto(state, workspace);
          },
        ),
      );
    }
    return List<BakedClipPoseBank3D>.unmodifiable(banks);
  }

  void _classifyMeshNodes() {
    _skinnedMeshSlots.clear();
    _staticMeshSlots.clear();
    if (poseBanks.isEmpty || poseBanks.first.frames.isEmpty) {
      return;
    }
    final firstFrame = poseBanks.first.frames.first;
    for (var slot = 0; slot < firstFrame.length; slot++) {
      if (firstFrame[slot].isSkinned) {
        _skinnedMeshSlots.add(slot);
      } else {
        _staticMeshSlots.add(slot);
      }
    }
    _staticInstanceBuffers = List<Float32List>.generate(
      _staticMeshSlots.length,
      (_) => Float32List(_capacity * _instanceStride),
      growable: false,
    );
    _skinnedInstanceBuffers = List<Float32List>.generate(
      _skinnedMeshSlots.length,
      (_) => Float32List(_capacity * _instanceStride),
      growable: false,
    );
    _clipBaseOffsets = Int32List(poseBanks.length);
    var totalPoses = 0;
    for (var i = 0; i < poseBanks.length; i++) {
      _clipBaseOffsets[i] = totalPoses;
      totalPoses += poseBanks[i].frameCount;
    }
    _totalPoseCount = math.max(1, totalPoses);
    _bucketHead = Int32List(_totalPoseCount * 2)
      ..fillRange(0, _totalPoseCount * 2, -1);
    _usedBuckets = Int32List(_totalPoseCount * 2);
    _bucketNext = Int32List(_capacity);
  }

  int _resolveClipIndex(int? clipIndex, String? clipName) {
    if (clipName != null) {
      for (var i = 0; i < poseBanks.length; i++) {
        if (poseBanks[i].name == clipName) {
          return i;
        }
      }
      throw ArgumentError.value(clipName, 'clipName', 'Unknown clip name');
    }
    final idx = clipIndex ?? 0;
    RangeError.checkValidIndex(idx, poseBanks, 'clipIndex');
    return idx;
  }

  /// Appends a crowd agent and returns its `0`-based index.
  int addAgent({
    Matrix4? transform,
    Vector3? position,
    Quaternion? rotation,
    Vector3? scale,
    int clipIndex = 0,
    String? clipName,
    double initialClock = 0.0,
    double speed = 1.0,
    AnimationPlayMode mode = AnimationPlayMode.loop,
    Color color = const Color(0xFFFFFFFF),
    Vector4? instanceData,
  }) {
    final resolvedClip = _resolveClipIndex(clipIndex, clipName);
    final idx = _length;
    if (idx == _capacity) {
      _grow(_capacity * 2);
    }
    _length++;

    if (transform != null) {
      _writeAgentMatrix(idx, transform);
    } else {
      _composeScratch.setFromTranslationRotationScale(
        position ?? _zeroVec,
        rotation ?? _identityQuat,
        scale ?? _unitScaleVec,
      );
      _writeAgentMatrix(idx, _composeScratch);
    }

    if (idx < _colors.length) {
      _colors[idx] = color;
    } else {
      _colors.add(color);
    }
    final cb = idx * 8;
    _colorsAndData
      ..[cb] = color.r
      ..[cb + 1] = color.g
      ..[cb + 2] = color.b
      ..[cb + 3] = color.a
      ..[cb + 4] = instanceData?.x ?? 0.0
      ..[cb + 5] = instanceData?.y ?? 0.0
      ..[cb + 6] = instanceData?.z ?? 0.0
      ..[cb + 7] = instanceData?.w ?? 0.0;

    _clipIndices[idx] = resolvedClip;
    _speeds[idx] = speed;
    _modes[idx] = mode.index;
    _pingPongDirs[idx] = 1;

    final bank = poseBanks[resolvedClip];
    final normalizedClock =
        bank.duration > 1e-9 && mode == AnimationPlayMode.loop
        ? (initialClock % bank.duration + bank.duration) % bank.duration
        : initialClock.clamp(0.0, bank.duration);
    _clocks[idx] = normalizedClock;
    _frameIndices[idx] = _clockToFrame(bank, normalizedClock);

    _invalidateBounds();
    return idx;
  }

  /// Updates mutable properties of the agent at [index] in place.
  void setAgent(
    int index, {
    Matrix4? transform,
    int? clipIndex,
    String? clipName,
    double? clock,
    double? speed,
    AnimationPlayMode? mode,
    Color? color,
    Vector4? instanceData,
  }) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    if (transform != null) {
      _writeAgentMatrix(index, transform);
      _boundsDirty = true;
      markAabbDirty();
    }
    if (clipIndex != null || clipName != null) {
      _clipIndices[index] = _resolveClipIndex(clipIndex, clipName);
    }
    if (speed != null) {
      _speeds[index] = speed;
    }
    if (mode != null) {
      _modes[index] = mode.index;
    }
    if (clock != null) {
      _clocks[index] = clock;
    }
    final bank = poseBanks[_clipIndices[index]];
    _frameIndices[index] = _clockToFrame(bank, _clocks[index]);

    final cb = index * 8;
    if (color != null) {
      _colors[index] = color;
      _colorsAndData
        ..[cb] = color.r
        ..[cb + 1] = color.g
        ..[cb + 2] = color.b
        ..[cb + 3] = color.a;
    }
    if (instanceData != null) {
      _colorsAndData
        ..[cb + 4] = instanceData.x
        ..[cb + 5] = instanceData.y
        ..[cb + 6] = instanceData.z
        ..[cb + 7] = instanceData.w;
    }
    markDrawDirty(shadows: castsShadows);
  }

  /// Removes the agent at [index] in `O(1)` by swapping the last agent into
  /// its slot.
  void removeAgentAtSwapLast(int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    final last = --_length;
    if (index != last) {
      _transforms.setRange(
        index * 16,
        (index + 1) * 16,
        _transforms,
        last * 16,
      );
      _colorsAndData.setRange(
        index * 8,
        (index + 1) * 8,
        _colorsAndData,
        last * 8,
      );
      _colors[index] = _colors[last];
      _clocks[index] = _clocks[last];
      _speeds[index] = _speeds[last];
      _clipIndices[index] = _clipIndices[last];
      _frameIndices[index] = _frameIndices[last];
      _modes[index] = _modes[last];
      _pingPongDirs[index] = _pingPongDirs[last];
    }
    _invalidateBounds();
  }

  /// Removes all agents while retaining preallocated capacity.
  void clear() {
    if (_length == 0) {
      return;
    }
    _length = 0;
    _invalidateBounds();
  }

  /// Active clip bank index of [index].
  int agentClipIndex(int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    return _clipIndices[index];
  }

  /// Current quantized frame index of [index] within its [BakedClipPoseBank3D].
  int agentFrameIndex(int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    return _frameIndices[index];
  }

  /// Current playback clock (in seconds) of [index].
  double agentClock(int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    return _clocks[index];
  }

  /// Pre-baked mesh-node pose list for [index] in `O(1)`.
  List<BakedNodePose3D> agentPose(int index) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    return poseBanks[_clipIndices[index]].frames[_frameIndices[index]];
  }

  /// Reads the local transform of [index] into [out] (or a new [Matrix4]).
  Matrix4 agentTransform(int index, {Matrix4? out}) {
    RangeError.checkValidIndex(index, this, 'index', _length);
    final dst = out ?? Matrix4.zero();
    final b = index * 16;
    for (var i = 0; i < 16; i++) {
      dst.storage[i] = _transforms[b + i];
    }
    return dst;
  }

  static int _clockToFrame(BakedClipPoseBank3D bank, double clock) {
    final count = bank.frameCount;
    if (count <= 1 || bank.duration <= 1e-9) {
      return 0;
    }
    final raw = (clock * bank.bakedFps).floor();
    return raw.clamp(0, count - 1);
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (dt == 0.0 || _length == 0) {
      return;
    }

    var anyFrameChanged = false;
    for (var i = 0; i < _length; i++) {
      final spd = _speeds[i];
      if (spd == 0.0) {
        continue;
      }
      final bank = poseBanks[_clipIndices[i]];
      final duration = bank.duration;
      if (duration <= 1e-9 || bank.frameCount <= 1) {
        continue;
      }
      final scaledDt = dt * spd;
      final modeIdx = _modes[i];
      var next = _clocks[i];

      if (modeIdx == 0) {
        // AnimationPlayMode.loop
        next = (next + scaledDt) % duration;
        if (next < 0.0) {
          next += duration;
        }
      } else if (modeIdx == 1) {
        // AnimationPlayMode.once
        next = (next + scaledDt).clamp(0.0, duration);
      } else {
        // AnimationPlayMode.pingPong
        var dir = _pingPongDirs[i];
        next += scaledDt * dir;
        while (next > duration || next < 0.0) {
          if (next > duration) {
            next = 2.0 * duration - next;
            dir = -1;
          } else if (next < 0.0) {
            next = -next;
            dir = 1;
          }
        }
        _pingPongDirs[i] = dir;
      }

      _clocks[i] = next;
      final newFrame = _clockToFrame(bank, next);
      if (newFrame != _frameIndices[i]) {
        _frameIndices[i] = newFrame;
        anyFrameChanged = true;
      }
    }

    if (anyFrameChanged) {
      markDrawDirty(shadows: castsShadows);
    }
  }

  @override
  Aabb3? computeLocalAabb() {
    if (_length == 0) {
      return null;
    }
    if (_boundsDirty) {
      _boundsDirty = false;
      final modelBox = model.animatedAabb;
      final cx = 0.5 * (modelBox.min.x + modelBox.max.x);
      final cy = 0.5 * (modelBox.min.y + modelBox.max.y);
      final cz = 0.5 * (modelBox.min.z + modelBox.max.z);
      final hx = 0.5 * (modelBox.max.x - modelBox.min.x);
      final hy = 0.5 * (modelBox.max.y - modelBox.min.y);
      final hz = 0.5 * (modelBox.max.z - modelBox.min.z);
      final transforms = _transforms;

      var minX = double.infinity;
      var minY = double.infinity;
      var minZ = double.infinity;
      var maxX = double.negativeInfinity;
      var maxY = double.negativeInfinity;
      var maxZ = double.negativeInfinity;

      for (var idx = 0; idx < _length; idx++) {
        final b = idx * 16;
        final m0 = transforms[b];
        final m1 = transforms[b + 1];
        final m2 = transforms[b + 2];
        final m4 = transforms[b + 4];
        final m5 = transforms[b + 5];
        final m6 = transforms[b + 6];
        final m8 = transforms[b + 8];
        final m9 = transforms[b + 9];
        final m10 = transforms[b + 10];

        final wx = m0 * cx + m4 * cy + m8 * cz + transforms[b + 12];
        final wy = m1 * cx + m5 * cy + m9 * cz + transforms[b + 13];
        final wz = m2 * cx + m6 * cy + m10 * cz + transforms[b + 14];

        final ex = m0.abs() * hx + m4.abs() * hy + m8.abs() * hz;
        final ey = m1.abs() * hx + m5.abs() * hy + m9.abs() * hz;
        final ez = m2.abs() * hx + m6.abs() * hy + m10.abs() * hz;

        if (wx - ex < minX) {
          minX = wx - ex;
        }
        if (wy - ey < minY) {
          minY = wy - ey;
        }
        if (wz - ez < minZ) {
          minZ = wz - ez;
        }
        if (wx + ex > maxX) {
          maxX = wx + ex;
        }
        if (wy + ey > maxY) {
          maxY = wy + ey;
        }
        if (wz + ez > maxZ) {
          maxZ = wz + ez;
        }
      }
      _localAabb
        ..min.setValues(minX, minY, minZ)
        ..max.setValues(maxX, maxY, maxZ);
    }
    return _localAabb;
  }

  static bool _isMirroredF32(Float32List m, int base) {
    final m0 = m[base];
    final m1 = m[base + 1];
    final m2 = m[base + 2];
    final m4 = m[base + 4];
    final m5 = m[base + 5];
    final m6 = m[base + 6];
    final m8 = m[base + 8];
    final m9 = m[base + 9];
    final m10 = m[base + 10];
    return (m0 * (m5 * m10 - m6 * m9) -
            m4 * (m1 * m10 - m2 * m9) +
            m8 * (m1 * m6 - m2 * m5)) <
        0.0;
  }

  @override
  void draw(covariant RenderContext3D context) {
    _lastInstancedSubNodeDraws = 0;
    _lastSkinnedNodeDraws = 0;
    _lastSkinnedPoseBuckets = 0;
    if (_length == 0) {
      return;
    }

    final batchWorld = worldTransformMatrix;
    final batchIsIdentity = batchWorld.isIdentity();
    final batchMirrorBit =
        !batchIsIdentity && _isMirroredF32(batchWorld.storage, 0) ? 1 : 0;

    // 1. Skinned mesh nodes: group agents sharing `(clipIndex, frameIndex)` and
    //    handedness into contiguous pose buckets and submit 1 instanced draw
    //    per bucket per surface.
    for (var s = 0; s < _skinnedMeshSlots.length; s++) {
      final slot = _skinnedMeshSlots[s];
      final samplePose = poseBanks.first.frames.first[slot];
      final mesh = samplePose.node.mesh;
      if (mesh == null) {
        continue;
      }
      final instBuf = _skinnedInstanceBuffers[s];

      var usedBucketCount = 0;
      for (var i = _length - 1; i >= 0; i--) {
        final clipIdx = _clipIndices[i];
        final frameIdx = _frameIndices[i];
        final pose = poseBanks[clipIdx].frames[frameIdx][slot];
        final poseMirrorBit = _isMirroredF32(pose.combinedTransform.storage, 0)
            ? 1
            : 0;
        final agentMirrorBit = _isMirroredF32(_transforms, i * 16) ? 1 : 0;
        final mirrorBit = batchMirrorBit ^ agentMirrorBit ^ poseMirrorBit;
        final bucketId =
            ((_clipBaseOffsets[clipIdx] + frameIdx) << 1) | mirrorBit;

        final prevHead = _bucketHead[bucketId];
        if (prevHead == -1) {
          _usedBuckets[usedBucketCount++] = bucketId;
        }
        _bucketNext[i] = prevHead;
        _bucketHead[bucketId] = i;
      }

      var cursor = 0;
      for (var u = 0; u < usedBucketCount; u++) {
        final bucketId = _usedBuckets[u];
        var i = _bucketHead[bucketId];
        _bucketHead[bucketId] = -1;

        final firstAgent = i;
        final firstPose = poseBanks[_clipIndices[firstAgent]]
            .frames[_frameIndices[firstAgent]][slot];
        final startAgent = cursor;
        var sumX = 0.0;
        var sumY = 0.0;
        var sumZ = 0.0;

        while (i != -1) {
          final pose =
              poseBanks[_clipIndices[i]].frames[_frameIndices[i]][slot];
          _loadAgentWorldMatrix(
            batchWorld,
            i,
            _agentWorldScratch,
            batchIsIdentity: batchIsIdentity,
          );
          _drawMatrixScratch
            ..setFrom(_agentWorldScratch)
            ..multiply(pose.combinedTransform);

          final outBase = cursor * _instanceStride;
          final ms = _drawMatrixScratch.storage;
          for (var k = 0; k < 16; k++) {
            instBuf[outBase + k] = ms[k];
          }
          sumX += ms[12];
          sumY += ms[13];
          sumZ += ms[14];

          final cb = i * 8;
          for (var k = 0; k < 8; k++) {
            instBuf[outBase + 16 + k] = _colorsAndData[cb + k];
          }
          cursor++;
          _lastSkinnedNodeDraws++;
          i = _bucketNext[i];
        }

        final bucketCount = cursor - startAgent;
        final invCount = 1.0 / bucketCount;
        _bucketCenterScratch.setValues(
          sumX * invCount,
          sumY * invCount,
          sumZ * invCount,
        );
        final isMirroredBucket = (bucketId & 1) == 1;
        final jointMap = firstPose.jointTransforms;
        var surfaceIdx = 0;
        for (final surface in mesh.surfaces) {
          context.drawInstances(
            surface,
            instances: instBuf,
            count: bucketCount,
            instanceOffset: startAgent,
            jointTransforms: jointMap[surfaceIdx],
            center: _bucketCenterScratch,
            mirrored: isMirroredBucket,
          );
          _lastSkinnedPoseBuckets++;
          surfaceIdx++;
        }
      }
    }

    // 2. Unskinned static sub-nodes: pack all N agents into contiguous
    //    `Float32List` instance buffers and submit 1 `drawInstances` call per
    //    surface!
    for (var u = 0; u < _staticMeshSlots.length; u++) {
      final slot = _staticMeshSlots[u];
      final samplePose = poseBanks.first.frames.first[slot];
      final mesh = samplePose.node.mesh;
      if (mesh == null) {
        continue;
      }
      final instBuf = _staticInstanceBuffers[u];
      for (var i = 0; i < _length; i++) {
        final pose = poseBanks[_clipIndices[i]].frames[_frameIndices[i]][slot];
        _loadAgentWorldMatrix(
          batchWorld,
          i,
          _agentWorldScratch,
          batchIsIdentity: batchIsIdentity,
        );
        _drawMatrixScratch
          ..setFrom(_agentWorldScratch)
          ..multiply(pose.combinedTransform);

        final outBase = i * _instanceStride;
        final ms = _drawMatrixScratch.storage;
        for (var k = 0; k < 16; k++) {
          instBuf[outBase + k] = ms[k];
        }
        final cb = i * 8;
        for (var k = 0; k < 8; k++) {
          instBuf[outBase + 16 + k] = _colorsAndData[cb + k];
        }
      }

      for (final surface in mesh.surfaces) {
        context.drawInstances(
          surface,
          instances: instBuf,
          count: _length,
        );
        _lastInstancedSubNodeDraws++;
      }
    }
  }

  @override
  RayHit3D? raycast(
    Ray worldRay, {
    double maxDistance = double.infinity,
    CullMode? cullMode,
  }) {
    if (_length == 0) {
      return null;
    }
    final batchWorld = worldTransformMatrix;
    RayHit3D? best;
    var bestAgent = 0;
    var limit = maxDistance;

    for (var i = 0; i < _length; i++) {
      _loadAgentWorldMatrix(batchWorld, i, _agentWorldScratch);
      final nodePoses = poseBanks[_clipIndices[i]].frames[_frameIndices[i]];
      for (var s = 0; s < nodePoses.length; s++) {
        final pose = nodePoses[s];
        final mesh = pose.node.mesh;
        if (mesh == null) {
          continue;
        }
        _drawMatrixScratch
          ..setFrom(_agentWorldScratch)
          ..multiply(pose.combinedTransform);
        final hit = RayHit3D.intersectMesh(
          owner: this,
          mesh: mesh,
          modelMatrix: _drawMatrixScratch,
          worldRay: worldRay,
          maxDistance: limit,
          cullMode: cullMode,
        );
        if (hit != null && hit.distance < limit) {
          limit = hit.distance;
          best = hit;
          bestAgent = i;
        }
      }
    }
    return best?.onInstance(bestAgent);
  }

  void _loadAgentWorldMatrix(
    Matrix4 batchWorld,
    int index,
    Matrix4 out, {
    bool? batchIsIdentity,
  }) {
    final b = index * 16;
    for (var k = 0; k < 16; k++) {
      _agentLocalScratch.storage[k] = _transforms[b + k];
    }
    if (batchIsIdentity ?? batchWorld.isIdentity()) {
      out.setFrom(_agentLocalScratch);
    } else {
      out
        ..setFrom(batchWorld)
        ..multiply(_agentLocalScratch);
    }
  }

  void _writeAgentMatrix(int index, Matrix4 m) {
    final base = index * 16;
    final s = m.storage;
    for (var k = 0; k < 16; k++) {
      _transforms[base + k] = s[k];
    }
  }

  void _grow(int newCapacity) {
    _transforms = Float32List(newCapacity * 16)
      ..setRange(0, _length * 16, _transforms);
    _colorsAndData = Float32List(newCapacity * 8)
      ..setRange(0, _length * 8, _colorsAndData);
    _clocks = Float64List(newCapacity)..setRange(0, _length, _clocks);
    _speeds = Float64List(newCapacity)..setRange(0, _length, _speeds);
    _clipIndices = Int32List(newCapacity)..setRange(0, _length, _clipIndices);
    _frameIndices = Int32List(newCapacity)..setRange(0, _length, _frameIndices);
    _modes = Int32List(newCapacity)..setRange(0, _length, _modes);
    _pingPongDirs = Int32List(newCapacity)..setRange(0, _length, _pingPongDirs);
    _staticInstanceBuffers = List<Float32List>.generate(
      _staticMeshSlots.length,
      (_) => Float32List(newCapacity * _instanceStride),
      growable: false,
    );
    _skinnedInstanceBuffers = List<Float32List>.generate(
      _skinnedMeshSlots.length,
      (_) => Float32List(newCapacity * _instanceStride),
      growable: false,
    );
    _bucketNext = Int32List(newCapacity);
    _capacity = newCapacity;
  }

  void _invalidateBounds() {
    _boundsDirty = true;
    markAabbDirty();
    markDrawDirty(shadows: castsShadows);
  }

  static final Vector3 _zeroVec = Vector3.zero();
  static final Quaternion _identityQuat = Quaternion.identity();
  static final Vector3 _unitScaleVec = Vector3.all(1.0);
  static final Matrix4 _composeScratch = Matrix4.identity();
  static final Matrix4 _agentLocalScratch = Matrix4.identity();
  static final Matrix4 _agentWorldScratch = Matrix4.identity();
  static final Matrix4 _drawMatrixScratch = Matrix4.identity();
  static final Vector3 _bucketCenterScratch = Vector3.zero();
}
