import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:meta/meta.dart';

/// Base procedural bone modifier applied in model space after keyframe
/// evaluation and before skinning joint matrices are written.
abstract class BoneModifier3D() {
  /// Blend weight in `[0, 1]` (`0` disables the modifier).
  double weight = 1.0;

  /// Advances any stateful simulation (such as spring velocity) by [dt].
  void step(double dt) {}

  /// Modifies node transforms inside [workspace] given [model] and the owning
  /// component's [worldMatrix] (and its inverse [invWorldMatrix]).
  void apply(
    Model model,
    ModelPoseWorkspace workspace,
    Matrix4 worldMatrix,
    Matrix4 invWorldMatrix,
    double dt,
  );

  /// Builds `T(ox, oy, oz) * R(deltaRot) * T(-ox, -oy, -oz)` into [out]
  /// without computing a 4x4 matrix inverse.
  @internal
  static void buildPivotRotationDelta(
    double ox,
    double oy,
    double oz,
    Quaternion deltaRot,
    Matrix4 out,
  ) {
    out.setFromTranslationRotation(_zero, deltaRot);
    final m = out.storage;
    m[12] = ox - (m[0] * ox + m[4] * oy + m[8] * oz);
    m[13] = oy - (m[1] * ox + m[5] * oy + m[9] * oz);
    m[14] = oz - (m[2] * ox + m[6] * oy + m[10] * oz);
  }

  /// Applies model-space [delta] to every strict descendant of
  /// [modifiedNodeIndex] in topological order using a reusable stamp array.
  @internal
  static void propagateDeltaMatrixToDescendants(
    ModelPoseWorkspace workspace,
    int modifiedNodeIndex,
    Matrix4 delta,
  ) {
    final startIdx = workspace.orderIndexByNodeIndex[modifiedNodeIndex];
    if (startIdx == null) {
      return;
    }
    final ordered = workspace.orderedNodes;
    final parentOrder = workspace.parentOrderIndex;
    final len = ordered.length;
    final epoch = _nextStamp(len);
    _affectedStamp[startIdx] = epoch;
    for (var i = startIdx + 1; i < len; i++) {
      final p = parentOrder[i];
      if (p >= 0 && _affectedStamp[p] == epoch) {
        _affectedStamp[i] = epoch;
        final ct = ordered[i].combinedTransform;
        _temp
          ..setFrom(delta)
          ..multiply(ct);
        ct.setFrom(_temp);
      }
    }
  }

  /// Rotates [combined] around its translation pivot by [deltaRot] and
  /// propagates the resulting delta to all strict descendants without
  /// `copyInverse` or hash-set allocations.
  @internal
  static void rotateAndPropagateToDescendants(
    ModelPoseWorkspace workspace,
    int modifiedNodeIndex,
    Matrix4 combined,
    Quaternion deltaRot,
  ) {
    final m = combined.storage;
    final ox = m[12];
    final oy = m[13];
    final oz = m[14];
    buildPivotRotationDelta(ox, oy, oz, deltaRot, _delta);
    rotateCombinedAroundOrigin(combined, deltaRot);
    propagateDeltaMatrixToDescendants(workspace, modifiedNodeIndex, _delta);
  }

  /// Translates every strict descendant of [modifiedNodeIndex] by
  /// `(dx, dy, dz)` in model space without matrix multiplications.
  @internal
  static void propagateTranslationToDescendants(
    ModelPoseWorkspace workspace,
    int modifiedNodeIndex,
    double dx,
    double dy,
    double dz,
  ) {
    final startIdx = workspace.orderIndexByNodeIndex[modifiedNodeIndex];
    if (startIdx == null) {
      return;
    }
    final ordered = workspace.orderedNodes;
    final parentOrder = workspace.parentOrderIndex;
    final len = ordered.length;
    final epoch = _nextStamp(len);
    _affectedStamp[startIdx] = epoch;
    for (var i = startIdx + 1; i < len; i++) {
      final p = parentOrder[i];
      if (p >= 0 && _affectedStamp[p] == epoch) {
        _affectedStamp[i] = epoch;
        final s = ordered[i].combinedTransform.storage;
        s[12] += dx;
        s[13] += dy;
        s[14] += dz;
      }
    }
  }

  /// Applies cumulative chain deltas [chainDeltas] anchored at
  /// [chainOrderIndices] across the entire subtree in a single topological
  /// pass.
  @internal
  static void applyChainDeltas(
    ModelPoseWorkspace workspace,
    Int32List chainOrderIndices,
    List<Matrix4> chainDeltas,
  ) {
    final chainCount = chainOrderIndices.length;
    if (chainCount == 0) {
      return;
    }
    final ordered = workspace.orderedNodes;
    final parentOrder = workspace.parentOrderIndex;
    final len = ordered.length;
    final epoch = _nextStamp(len);
    for (var k = 0; k < chainCount; k++) {
      final ord = chainOrderIndices[k];
      _affectedStamp[ord] = epoch;
      _affectedSlot[ord] = k;
    }
    final start = chainOrderIndices[0];
    for (var i = start; i < len; i++) {
      final int slot;
      if (_affectedStamp[i] == epoch) {
        slot = _affectedSlot[i];
      } else {
        final p = parentOrder[i];
        if (p < 0 || _affectedStamp[p] != epoch) {
          continue;
        }
        slot = _affectedSlot[p];
        _affectedStamp[i] = epoch;
        _affectedSlot[i] = slot;
      }
      final ct = ordered[i].combinedTransform;
      _temp
        ..setFrom(chainDeltas[slot])
        ..multiply(ct);
      ct.setFrom(_temp);
    }
  }

  /// Applies model-space delta matrix `delta = nextCombined * inv(oldCombined)`
  /// to every descendant of [modifiedNodeIndex] in topological order.
  static void propagateDeltaToDescendants(
    Model model,
    ModelPoseWorkspace workspace,
    int modifiedNodeIndex,
    Matrix4 oldCombined,
    Matrix4 nextCombined,
  ) {
    _invOld.copyInverse(oldCombined);
    _delta
      ..setFrom(nextCombined)
      ..multiply(_invOld);
    propagateDeltaMatrixToDescendants(workspace, modifiedNodeIndex, _delta);
  }

  /// Rotates [combined] around its translation pivot `(m[12], m[13], m[14])` by
  /// model-space quaternion [deltaRot].
  static void rotateCombinedAroundOrigin(
    Matrix4 combined,
    Quaternion deltaRot,
  ) {
    final m = combined.storage;
    final ox = m[12];
    final oy = m[13];
    final oz = m[14];
    m[12] = 0;
    m[13] = 0;
    m[14] = 0;
    _rotMat.setFromTranslationRotation(_zero, deltaRot);
    _temp
      ..setFrom(_rotMat)
      ..multiply(combined);
    _temp.storage[12] = ox;
    _temp.storage[13] = oy;
    _temp.storage[14] = oz;
    combined.setFrom(_temp);
  }

  /// Computes shortest-arc rotation from unit vector [fromDir] to unit vector
  /// [toDir] into [out], optionally clamped to [maxAngle] radians and scaled by
  /// [blendWeight].
  static void swingRotationInto(
    Vector3 fromDir,
    Vector3 toDir,
    Quaternion out, {
    double maxAngle = math.pi,
    double blendWeight = 1.0,
  }) {
    final dot = fromDir.dot(toDir).clamp(-1.0, 1.0);
    var angle = math.acos(dot);
    if (angle < 1e-6 || blendWeight <= 0.0) {
      out.setValues(0, 0, 0, 1);
      return;
    }
    if (angle > maxAngle) {
      angle = maxAngle;
    }
    angle *= blendWeight.clamp(0.0, 1.0);

    fromDir.crossInto(toDir, _axis);
    if (_axis.length2 < 1e-10) {
      // Anti-parallel fallback axis.
      fromDir.crossInto(fromDir.x.abs() < 0.9 ? _unitX : _unitY, _axis);
    }
    _axis.normalize();
    out.setAxisAngle(_axis, angle);
  }

  /// Analytic Law-of-Cosines two-bone IK solver for a `root -> mid -> tip`
  /// bone chain toward world-space [targetWorld] with bend direction
  /// [poleWorld], blended by [blendWeight] in `[0, 1]`.
  @internal
  static void solveTwoBoneIk({
    required Model model,
    required ModelPoseWorkspace workspace,
    required Matrix4 invWorldMatrix,
    required int rootIndex,
    required int midIndex,
    required int tipIndex,
    required Vector3 targetWorld,
    required Vector3 poleWorld,
    required double blendWeight,
  }) {
    final w = blendWeight.clamp(0.0, 1.0);
    if (w <= 0.0) {
      return;
    }
    final rootNode = workspace.nodesByIndex[rootIndex];
    final midNode = workspace.nodesByIndex[midIndex];
    final tipNode = workspace.nodesByIndex[tipIndex];
    if (rootNode == null || midNode == null || tipNode == null) {
      return;
    }

    final rm = rootNode.combinedTransform;
    final mm = midNode.combinedTransform;
    final tm = tipNode.combinedTransform;
    _ikPRoot.setValues(rm.storage[12], rm.storage[13], rm.storage[14]);
    _ikPMid.setValues(mm.storage[12], mm.storage[13], mm.storage[14]);
    _ikPTip.setValues(tm.storage[12], tm.storage[13], tm.storage[14]);

    final lenA = _ikPMid.distanceTo(_ikPRoot);
    final lenB = _ikPTip.distanceTo(_ikPMid);
    if (lenA < 1e-5 || lenB < 1e-5) {
      return;
    }

    _ikTargetM.setFrom(targetWorld);
    invWorldMatrix.transform3(_ikTargetM);
    _ikPoleM.setFrom(poleWorld);
    invWorldMatrix.transform3(_ikPoleM);

    _ikDirTarget
      ..setFrom(_ikTargetM)
      ..sub(_ikPRoot);
    final rawDist = _ikDirTarget.length;
    if (rawDist < 1e-6) {
      return;
    }
    _ikDirTarget.scale(1.0 / rawDist);

    final minReach = (lenA - lenB).abs() + 1e-4;
    final maxReach = lenA + lenB - 1e-4;
    final clampedDist = rawDist.clamp(minReach, maxReach);

    final cosAlpha =
        ((lenA * lenA + clampedDist * clampedDist - lenB * lenB) /
                (2.0 * lenA * clampedDist))
            .clamp(-1.0, 1.0);
    final sinAlpha = math.sqrt(math.max(0.0, 1.0 - cosAlpha * cosAlpha));

    _ikPoleProj
      ..setFrom(_ikPoleM)
      ..sub(_ikPRoot);
    final proj = _ikPoleProj.dot(_ikDirTarget);
    _ikPoleProj.addScaled(_ikDirTarget, -proj);
    if (_ikPoleProj.length2 < 1e-8) {
      if (_ikDirTarget.x.abs() < 0.9) {
        _ikDirTarget.crossInto(_unitX, _ikPoleProj);
      } else {
        _ikDirTarget.crossInto(_unitY, _ikPoleProj);
      }
    }
    _ikPoleProj.normalize();

    _ikNewMid
      ..setFrom(_ikPRoot)
      ..addScaled(_ikDirTarget, lenA * cosAlpha)
      ..addScaled(_ikPoleProj, lenA * sinAlpha);

    _ikOldUpper
      ..setFrom(_ikPMid)
      ..sub(_ikPRoot)
      ..normalize();
    _ikNewUpper
      ..setFrom(_ikNewMid)
      ..sub(_ikPRoot)
      ..normalize();
    swingRotationInto(
      _ikOldUpper,
      _ikNewUpper,
      _ikQRoot,
      blendWeight: w,
    );
    buildPivotRotationDelta(
      _ikPRoot.x,
      _ikPRoot.y,
      _ikPRoot.z,
      _ikQRoot,
      _ikDeltaRoot,
    );
    rotateCombinedAroundOrigin(rm, _ikQRoot);

    final rootOrder = workspace.orderIndexByNodeIndex[rootIndex];
    final midOrder = workspace.orderIndexByNodeIndex[midIndex];
    final tipOrder = workspace.orderIndexByNodeIndex[tipIndex];
    if (rootOrder == null || midOrder == null) {
      propagateDeltaMatrixToDescendants(workspace, rootIndex, _ikDeltaRoot);
      return;
    }
    final parentOrder = workspace.parentOrderIndex;
    var midDescendsFromRoot = false;
    var curP = parentOrder[midOrder];
    while (curP >= 0) {
      if (curP == rootOrder) {
        midDescendsFromRoot = true;
        break;
      }
      curP = parentOrder[curP];
    }
    if (midDescendsFromRoot) {
      _ikDeltaRoot.transform3(_ikPMid);
    }
    var tipDescendsFromRoot = false;
    if (tipOrder != null) {
      curP = parentOrder[tipOrder];
      while (curP >= 0) {
        if (curP == rootOrder) {
          tipDescendsFromRoot = true;
          break;
        }
        curP = parentOrder[curP];
      }
    }
    if (tipDescendsFromRoot) {
      _ikDeltaRoot.transform3(_ikPTip);
    }

    _ikGoalTip
      ..setFrom(_ikPRoot)
      ..addScaled(_ikDirTarget, clampedDist);

    _ikCurLower
      ..setFrom(_ikPTip)
      ..sub(_ikPMid);
    _ikNewLower
      ..setFrom(_ikGoalTip)
      ..sub(_ikPMid);
    if (_ikCurLower.length2 < 1e-10 || _ikNewLower.length2 < 1e-10) {
      propagateDeltaMatrixToDescendants(workspace, rootIndex, _ikDeltaRoot);
      return;
    }
    _ikCurLower.normalize();
    _ikNewLower.normalize();

    swingRotationInto(
      _ikCurLower,
      _ikNewLower,
      _ikQMid,
      blendWeight: w,
    );
    buildPivotRotationDelta(
      _ikPMid.x,
      _ikPMid.y,
      _ikPMid.z,
      _ikQMid,
      _ikDeltaMid,
    );
    _ikDeltaMidTotal
      ..setFrom(_ikDeltaMid)
      ..multiply(_ikDeltaRoot);

    final ordered = workspace.orderedNodes;
    final len = ordered.length;
    final epoch = _nextStamp(len);
    _affectedStamp[rootOrder] = epoch;
    _affectedSlot[rootOrder] = 0;

    final start = math.min(rootOrder, midOrder);
    for (var i = start; i < len; i++) {
      if (i == rootOrder) {
        continue;
      }
      if (i == midOrder) {
        final p = parentOrder[i];
        if (p >= 0 && _affectedStamp[p] == epoch) {
          final pSlot = _affectedSlot[p];
          final pDelta = pSlot == 0
              ? _ikDeltaRoot
              : (pSlot == 1 ? _ikDeltaMidTotal : _ikDeltaMid);
          _temp
            ..setFrom(pDelta)
            ..multiply(mm);
          mm.setFrom(_temp);
          rotateCombinedAroundOrigin(mm, _ikQMid);
          _affectedStamp[i] = epoch;
          _affectedSlot[i] = 1;
        } else {
          rotateCombinedAroundOrigin(mm, _ikQMid);
          _affectedStamp[i] = epoch;
          _affectedSlot[i] = 2;
        }
        continue;
      }
      final p = parentOrder[i];
      if (p >= 0 && _affectedStamp[p] == epoch) {
        final slot = _affectedSlot[p];
        _affectedStamp[i] = epoch;
        _affectedSlot[i] = slot;
        final delta = slot == 0
            ? _ikDeltaRoot
            : (slot == 1 ? _ikDeltaMidTotal : _ikDeltaMid);
        final ct = ordered[i].combinedTransform;
        _temp
          ..setFrom(delta)
          ..multiply(ct);
        ct.setFrom(_temp);
      }
    }
  }

  static int _nextStamp(int nodeCount) {
    if (_affectedStamp.length < nodeCount) {
      var cap = math.max(64, _affectedStamp.length);
      while (cap < nodeCount) {
        cap *= 2;
      }
      _affectedStamp = Int32List(cap);
      _affectedSlot = Int32List(cap);
    }
    var epoch = ++_stampEpoch;
    if (epoch >= 0x3FFFFFFF) {
      _affectedStamp.fillRange(0, _affectedStamp.length, 0);
      _stampEpoch = 1;
      epoch = 1;
    }
    return epoch;
  }

  static final Matrix4 _invOld = Matrix4.identity();
  static final Matrix4 _delta = Matrix4.identity();
  static Int32List _affectedStamp = Int32List(0);
  static Int32List _affectedSlot = Int32List(0);
  static int _stampEpoch = 0;
  static final Matrix4 _ikDeltaRoot = Matrix4.identity();
  static final Matrix4 _ikDeltaMid = Matrix4.identity();
  static final Matrix4 _ikDeltaMidTotal = Matrix4.identity();
  static final Vector3 _zero = Vector3.zero();
  static final Vector3 _unitX = Vector3(1, 0, 0);
  static final Vector3 _unitY = Vector3(0, 1, 0);
  static final Matrix4 _rotMat = Matrix4.identity();
  static final Matrix4 _temp = Matrix4.identity();
  static final Vector3 _axis = Vector3.zero();
  static final Vector3 _ikPRoot = Vector3.zero();
  static final Vector3 _ikPMid = Vector3.zero();
  static final Vector3 _ikPTip = Vector3.zero();
  static final Vector3 _ikTargetM = Vector3.zero();
  static final Vector3 _ikPoleM = Vector3.zero();
  static final Vector3 _ikDirTarget = Vector3.zero();
  static final Vector3 _ikPoleProj = Vector3.zero();
  static final Vector3 _ikNewMid = Vector3.zero();
  static final Vector3 _ikOldUpper = Vector3.zero();
  static final Vector3 _ikNewUpper = Vector3.zero();
  static final Vector3 _ikCurLower = Vector3.zero();
  static final Vector3 _ikNewLower = Vector3.zero();
  static final Vector3 _ikGoalTip = Vector3.zero();
  static final Quaternion _ikQRoot = Quaternion.identity();
  static final Quaternion _ikQMid = Quaternion.identity();
}

/// Smoothly rotates a bone (such as a head, turret, or eye) so its local
/// [forwardAxis] aims toward [targetWorld], clamped to [maxAngle] radians.
class LookAtConstraint3D({
  required final String nodeName,
  Vector3? targetWorld,
  Vector3? forwardAxis,
  var double maxAngle = 1.25,
  double weight = 1.0,
}) extends BoneModifier3D {
  this {
    this.weight = weight;
  }

  /// World-space point to aim at.
  final Vector3 targetWorld = targetWorld?.clone() ?? Vector3.zero();

  /// Bone-local axis pointing forward (`(0, 0, 1)` by default).
  final Vector3 forwardAxis = (forwardAxis?.clone() ?? Vector3(0, 0, 1))
    ..normalize();

  int? _cachedIndex;
  final Vector3 _targetModel = Vector3.zero();
  final Vector3 _origin = Vector3.zero();
  final Vector3 _curForward = Vector3.zero();
  final Vector3 _desired = Vector3.zero();
  final Quaternion _deltaQ = Quaternion.identity();

  @override
  void apply(
    Model model,
    ModelPoseWorkspace workspace,
    Matrix4 worldMatrix,
    Matrix4 invWorldMatrix,
    double dt,
  ) {
    if (weight <= 0.0) {
      return;
    }
    final idx = _cachedIndex ??= model.nodeIndexByName(nodeName);
    if (idx == null) {
      return;
    }
    final processed = workspace.nodesByIndex[idx];
    if (processed == null) {
      return;
    }

    final m = processed.combinedTransform;
    _origin.setValues(m.storage[12], m.storage[13], m.storage[14]);

    _targetModel.setFrom(targetWorld);
    invWorldMatrix.transform3(_targetModel);
    _desired
      ..setFrom(_targetModel)
      ..sub(_origin);
    final dist2 = _desired.length2;
    if (dist2 < 1e-10) {
      return;
    }
    _desired.scale(1.0 / math.sqrt(dist2));

    _curForward.setFrom(forwardAxis);
    m.rotate3(_curForward);
    final fLen2 = _curForward.length2;
    if (fLen2 < 1e-10) {
      return;
    }
    _curForward.scale(1.0 / math.sqrt(fLen2));

    BoneModifier3D.swingRotationInto(
      _curForward,
      _desired,
      _deltaQ,
      maxAngle: maxAngle,
      blendWeight: weight,
    );
    BoneModifier3D.rotateAndPropagateToDescendants(workspace, idx, m, _deltaQ);
  }
}

/// Damped Hooke-spring secondary-motion bone modifier for hair, capes, tails,
/// antennas, and foliage attachments.
class SpringBone3D({
  required final String nodeName,
  Vector3? localTipOffset,
  var double stiffness = 180.0,
  var double damping = 14.0,
  Vector3? gravity,
  var double maxAngle = 0.85,
  double weight = 1.0,
}) extends BoneModifier3D {
  this {
    this.weight = weight;
  }

  /// Bone-local vector from the bone pivot to its simulated tip.
  final Vector3 localTipOffset = localTipOffset?.clone() ?? Vector3(0, 0.5, 0);

  /// Constant world-space acceleration (such as gravity or wind) pulling the
  /// simulated tip.
  final Vector3 gravity = gravity?.clone() ?? Vector3.zero();

  int? _cachedIndex;
  bool _initialized = false;
  final Vector3 _simTipWorld = Vector3.zero();
  final Vector3 _velWorld = Vector3.zero();

  final Vector3 _pivotModel = Vector3.zero();
  final Vector3 _pivotWorld = Vector3.zero();
  final Vector3 _restTipModel = Vector3.zero();
  final Vector3 _restTipWorld = Vector3.zero();
  final Vector3 _simTipModel = Vector3.zero();
  final Vector3 _fromDir = Vector3.zero();
  final Vector3 _toDir = Vector3.zero();
  final Quaternion _deltaQ = Quaternion.identity();

  /// Resets the spring tip to rest on the next evaluation.
  void reset() {
    _initialized = false;
    _velWorld.setZero();
  }

  /// Current world-space position of the simulated spring tip.
  Vector3 get currentTipWorld => _simTipWorld;

  @override
  void apply(
    Model model,
    ModelPoseWorkspace workspace,
    Matrix4 worldMatrix,
    Matrix4 invWorldMatrix,
    double dt,
  ) {
    if (weight <= 0.0) {
      return;
    }
    final idx = _cachedIndex ??= model.nodeIndexByName(nodeName);
    if (idx == null) {
      return;
    }
    final processed = workspace.nodesByIndex[idx];
    if (processed == null) {
      return;
    }

    final m = processed.combinedTransform;
    _pivotModel.setValues(m.storage[12], m.storage[13], m.storage[14]);
    _restTipModel.setFrom(localTipOffset);
    m.transform3(_restTipModel);

    _pivotWorld.setFrom(_pivotModel);
    worldMatrix.transform3(_pivotWorld);
    _restTipWorld.setFrom(_restTipModel);
    worldMatrix.transform3(_restTipWorld);

    final rodLen = _restTipWorld.distanceTo(_pivotWorld);
    if (rodLen < 1e-6) {
      return;
    }

    if (!_initialized) {
      _simTipWorld.setFrom(_restTipWorld);
      _velWorld.setZero();
      _initialized = true;
      return;
    }

    final stepDt = dt.clamp(0.0, 0.05);
    if (stepDt > 0.0) {
      final ax =
          (_restTipWorld.x - _simTipWorld.x) * stiffness +
          gravity.x -
          _velWorld.x * damping;
      final ay =
          (_restTipWorld.y - _simTipWorld.y) * stiffness +
          gravity.y -
          _velWorld.y * damping;
      final az =
          (_restTipWorld.z - _simTipWorld.z) * stiffness +
          gravity.z -
          _velWorld.z * damping;

      _velWorld.setValues(
        _velWorld.x + ax * stepDt,
        _velWorld.y + ay * stepDt,
        _velWorld.z + az * stepDt,
      );
      _simTipWorld.setValues(
        _simTipWorld.x + _velWorld.x * stepDt,
        _simTipWorld.y + _velWorld.y * stepDt,
        _simTipWorld.z + _velWorld.z * stepDt,
      );

      // Distance constraint keeps the bone length invariant.
      final dx = _simTipWorld.x - _pivotWorld.x;
      final dy = _simTipWorld.y - _pivotWorld.y;
      final dz = _simTipWorld.z - _pivotWorld.z;
      final dLen = math.sqrt(dx * dx + dy * dy + dz * dz);
      if (dLen > 1e-6) {
        final s = rodLen / dLen;
        _simTipWorld.setValues(
          _pivotWorld.x + dx * s,
          _pivotWorld.y + dy * s,
          _pivotWorld.z + dz * s,
        );
      } else {
        _simTipWorld.setFrom(_restTipWorld);
      }
    }

    _simTipModel.setFrom(_simTipWorld);
    invWorldMatrix.transform3(_simTipModel);

    _fromDir
      ..setFrom(_restTipModel)
      ..sub(_pivotModel);
    _toDir
      ..setFrom(_simTipModel)
      ..sub(_pivotModel);
    if (_fromDir.length2 < 1e-10 || _toDir.length2 < 1e-10) {
      return;
    }
    _fromDir.normalize();
    _toDir.normalize();

    BoneModifier3D.swingRotationInto(
      _fromDir,
      _toDir,
      _deltaQ,
      maxAngle: maxAngle,
      blendWeight: weight,
    );
    BoneModifier3D.rotateAndPropagateToDescendants(workspace, idx, m, _deltaQ);
  }
}

/// Analytic Law-of-Cosines two-bone Inverse Kinematics solver for limbs
/// (`root` -> `mid` -> `tip`, such as shoulder-elbow-hand or hip-knee-foot)
/// with a world-space [poleWorld] bend-direction hint.
class TwoBoneIkConstraint3D({
  required final String rootNodeName,
  required final String midNodeName,
  required final String tipNodeName,
  Vector3? targetWorld,
  Vector3? poleWorld,
  double weight = 1.0,
}) extends BoneModifier3D {
  this {
    this.weight = weight;
  }

  /// Desired world-space position of the `tip` joint.
  final Vector3 targetWorld = targetWorld?.clone() ?? Vector3.zero();

  /// World-space pole target steering the knee/elbow bend plane.
  final Vector3 poleWorld = poleWorld?.clone() ?? Vector3(0, 0, 1);

  int? _rootIdx;
  int? _midIdx;
  int? _tipIdx;

  @override
  void apply(
    Model model,
    ModelPoseWorkspace workspace,
    Matrix4 worldMatrix,
    Matrix4 invWorldMatrix,
    double dt,
  ) {
    final w = weight.clamp(0.0, 1.0);
    if (w <= 0.0) {
      return;
    }
    final rIdx = _rootIdx ??= model.nodeIndexByName(rootNodeName);
    final mIdx = _midIdx ??= model.nodeIndexByName(midNodeName);
    final tIdx = _tipIdx ??= model.nodeIndexByName(tipNodeName);
    if (rIdx == null || mIdx == null || tIdx == null) {
      return;
    }
    BoneModifier3D.solveTwoBoneIk(
      model: model,
      workspace: workspace,
      invWorldMatrix: invWorldMatrix,
      rootIndex: rIdx,
      midIndex: mIdx,
      tipIndex: tIdx,
      targetWorld: targetWorld,
      poleWorld: poleWorld,
      blendWeight: w,
    );
  }
}
