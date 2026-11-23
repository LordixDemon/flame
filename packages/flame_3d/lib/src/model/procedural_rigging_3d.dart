import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame_3d/core.dart';
import 'package:flame_3d/model.dart';
import 'package:meta/meta.dart';

part 'procedural_rigging_constraints_3d.dart';

class _BoneModifierScratch() {
  final Matrix4 invOld = Matrix4.identity();
  final Matrix4 delta = Matrix4.identity();
  Int32List affectedStamp = Int32List(0);
  Int32List affectedSlot = Int32List(0);
  int stampEpoch = 0;
  final Matrix4 ikDeltaRoot = Matrix4.identity();
  final Matrix4 ikDeltaMid = Matrix4.identity();
  final Matrix4 ikDeltaMidTotal = Matrix4.identity();
  final Vector3 zero = Vector3.zero();
  final Vector3 unitX = Vector3(1, 0, 0);
  final Vector3 unitY = Vector3(0, 1, 0);
  final Matrix4 rotMat = Matrix4.identity();
  final Matrix4 temp = Matrix4.identity();
  final Vector3 axis = Vector3.zero();
  final Vector3 ikPRoot = Vector3.zero();
  final Vector3 ikPMid = Vector3.zero();
  final Vector3 ikPTip = Vector3.zero();
  final Vector3 ikTargetM = Vector3.zero();
  final Vector3 ikPoleM = Vector3.zero();
  final Vector3 ikDirTarget = Vector3.zero();
  final Vector3 ikPoleProj = Vector3.zero();
  final Vector3 ikNewMid = Vector3.zero();
  final Vector3 ikOldUpper = Vector3.zero();
  final Vector3 ikNewUpper = Vector3.zero();
  final Vector3 ikCurLower = Vector3.zero();
  final Vector3 ikNewLower = Vector3.zero();
  final Vector3 ikGoalTip = Vector3.zero();
  final Quaternion ikQRoot = Quaternion.identity();
  final Quaternion ikQMid = Quaternion.identity();

  int nextStamp(int nodeCount) {
    if (affectedStamp.length < nodeCount) {
      var cap = math.max(64, affectedStamp.length);
      while (cap < nodeCount) {
        cap *= 2;
      }
      affectedStamp = Int32List(cap);
      affectedSlot = Int32List(cap);
    }
    var epoch = ++stampEpoch;
    if (epoch >= 0x3FFFFFFF) {
      affectedStamp.fillRange(0, affectedStamp.length, 0);
      stampEpoch = 1;
      epoch = 1;
    }
    return epoch;
  }
}

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
    out.setFromTranslationRotation(_scratch.zero, deltaRot);
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
    final s = _scratch;
    final epoch = s.nextStamp(len);
    s.affectedStamp[startIdx] = epoch;
    for (var i = startIdx + 1; i < len; i++) {
      final p = parentOrder[i];
      if (p >= 0 && s.affectedStamp[p] == epoch) {
        s.affectedStamp[i] = epoch;
        final ct = ordered[i].combinedTransform;
        s.temp
          ..setFrom(delta)
          ..multiply(ct);
        ct.setFrom(s.temp);
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
    final s = _scratch;
    buildPivotRotationDelta(ox, oy, oz, deltaRot, s.delta);
    rotateCombinedAroundOrigin(combined, deltaRot);
    propagateDeltaMatrixToDescendants(workspace, modifiedNodeIndex, s.delta);
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
    final epoch = _scratch.nextStamp(len);
    _scratch.affectedStamp[startIdx] = epoch;
    for (var i = startIdx + 1; i < len; i++) {
      final p = parentOrder[i];
      if (p >= 0 && _scratch.affectedStamp[p] == epoch) {
        _scratch.affectedStamp[i] = epoch;
        final st = ordered[i].combinedTransform.storage;
        st[12] += dx;
        st[13] += dy;
        st[14] += dz;
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
    final s = _scratch;
    final epoch = s.nextStamp(len);
    for (var k = 0; k < chainCount; k++) {
      final ord = chainOrderIndices[k];
      s.affectedStamp[ord] = epoch;
      s.affectedSlot[ord] = k;
    }
    final start = chainOrderIndices[0];
    for (var i = start; i < len; i++) {
      final int slot;
      if (s.affectedStamp[i] == epoch) {
        slot = s.affectedSlot[i];
      } else {
        final p = parentOrder[i];
        if (p < 0 || s.affectedStamp[p] != epoch) {
          continue;
        }
        slot = s.affectedSlot[p];
        s.affectedStamp[i] = epoch;
        s.affectedSlot[i] = slot;
      }
      final ct = ordered[i].combinedTransform;
      s.temp
        ..setFrom(chainDeltas[slot])
        ..multiply(ct);
      ct.setFrom(s.temp);
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
    final s = _scratch;
    s.invOld.copyInverse(oldCombined);
    s.delta
      ..setFrom(nextCombined)
      ..multiply(s.invOld);
    propagateDeltaMatrixToDescendants(workspace, modifiedNodeIndex, s.delta);
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
    final s = _scratch;
    s.rotMat.setFromTranslationRotation(s.zero, deltaRot);
    s.temp
      ..setFrom(s.rotMat)
      ..multiply(combined);
    s.temp.storage[12] = ox;
    s.temp.storage[13] = oy;
    s.temp.storage[14] = oz;
    combined.setFrom(s.temp);
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

    final s = _scratch;
    fromDir.crossInto(toDir, s.axis);
    if (s.axis.length2 < 1e-10) {
      // Anti-parallel fallback axis.
      fromDir.crossInto(fromDir.x.abs() < 0.9 ? s.unitX : s.unitY, s.axis);
    }
    s.axis.normalize();
    out.setAxisAngle(s.axis, angle);
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

    final s = _scratch;
    final rm = rootNode.combinedTransform;
    final mm = midNode.combinedTransform;
    final tm = tipNode.combinedTransform;
    s.ikPRoot.setValues(rm.storage[12], rm.storage[13], rm.storage[14]);
    s.ikPMid.setValues(mm.storage[12], mm.storage[13], mm.storage[14]);
    s.ikPTip.setValues(tm.storage[12], tm.storage[13], tm.storage[14]);

    final lenA = s.ikPMid.distanceTo(s.ikPRoot);
    final lenB = s.ikPTip.distanceTo(s.ikPMid);
    if (lenA < 1e-5 || lenB < 1e-5) {
      return;
    }

    s.ikTargetM.setFrom(targetWorld);
    invWorldMatrix.transform3(s.ikTargetM);
    s.ikPoleM.setFrom(poleWorld);
    invWorldMatrix.transform3(s.ikPoleM);

    s.ikDirTarget
      ..setFrom(s.ikTargetM)
      ..sub(s.ikPRoot);
    final rawDist = s.ikDirTarget.length;
    if (rawDist < 1e-6) {
      return;
    }
    s.ikDirTarget.scale(1.0 / rawDist);

    final minReach = (lenA - lenB).abs() + 1e-4;
    final maxReach = lenA + lenB - 1e-4;
    final clampedDist = rawDist.clamp(minReach, maxReach);

    final cosAlpha =
        ((lenA * lenA + clampedDist * clampedDist - lenB * lenB) /
                (2.0 * lenA * clampedDist))
            .clamp(-1.0, 1.0);
    final sinAlpha = math.sqrt(math.max(0.0, 1.0 - cosAlpha * cosAlpha));

    s.ikPoleProj
      ..setFrom(s.ikPoleM)
      ..sub(s.ikPRoot);
    final proj = s.ikPoleProj.dot(s.ikDirTarget);
    s.ikPoleProj.addScaled(s.ikDirTarget, -proj);
    if (s.ikPoleProj.length2 < 1e-8) {
      if (s.ikDirTarget.x.abs() < 0.9) {
        s.ikDirTarget.crossInto(s.unitX, s.ikPoleProj);
      } else {
        s.ikDirTarget.crossInto(s.unitY, s.ikPoleProj);
      }
    }
    s.ikPoleProj.normalize();

    s.ikNewMid
      ..setFrom(s.ikPRoot)
      ..addScaled(s.ikDirTarget, lenA * cosAlpha)
      ..addScaled(s.ikPoleProj, lenA * sinAlpha);

    s.ikOldUpper
      ..setFrom(s.ikPMid)
      ..sub(s.ikPRoot)
      ..normalize();
    s.ikNewUpper
      ..setFrom(s.ikNewMid)
      ..sub(s.ikPRoot)
      ..normalize();
    swingRotationInto(
      s.ikOldUpper,
      s.ikNewUpper,
      s.ikQRoot,
      blendWeight: w,
    );
    buildPivotRotationDelta(
      s.ikPRoot.x,
      s.ikPRoot.y,
      s.ikPRoot.z,
      s.ikQRoot,
      s.ikDeltaRoot,
    );
    rotateCombinedAroundOrigin(rm, s.ikQRoot);

    final rootOrder = workspace.orderIndexByNodeIndex[rootIndex];
    final midOrder = workspace.orderIndexByNodeIndex[midIndex];
    final tipOrder = workspace.orderIndexByNodeIndex[tipIndex];
    if (rootOrder == null || midOrder == null) {
      propagateDeltaMatrixToDescendants(workspace, rootIndex, s.ikDeltaRoot);
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
      s.ikDeltaRoot.transform3(s.ikPMid);
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
      s.ikDeltaRoot.transform3(s.ikPTip);
    }

    s.ikGoalTip
      ..setFrom(s.ikPRoot)
      ..addScaled(s.ikDirTarget, clampedDist);

    s.ikCurLower
      ..setFrom(s.ikPTip)
      ..sub(s.ikPMid);
    s.ikNewLower
      ..setFrom(s.ikGoalTip)
      ..sub(s.ikPMid);
    if (s.ikCurLower.length2 < 1e-10 || s.ikNewLower.length2 < 1e-10) {
      propagateDeltaMatrixToDescendants(workspace, rootIndex, s.ikDeltaRoot);
      return;
    }
    s.ikCurLower.normalize();
    s.ikNewLower.normalize();

    swingRotationInto(
      s.ikCurLower,
      s.ikNewLower,
      s.ikQMid,
      blendWeight: w,
    );
    buildPivotRotationDelta(
      s.ikPMid.x,
      s.ikPMid.y,
      s.ikPMid.z,
      s.ikQMid,
      s.ikDeltaMid,
    );
    s.ikDeltaMidTotal
      ..setFrom(s.ikDeltaMid)
      ..multiply(s.ikDeltaRoot);

    final ordered = workspace.orderedNodes;
    final len = ordered.length;
    final epoch = s.nextStamp(len);
    s.affectedStamp[rootOrder] = epoch;
    s.affectedSlot[rootOrder] = 0;

    final start = math.min(rootOrder, midOrder);
    for (var i = start; i < len; i++) {
      if (i == rootOrder) {
        continue;
      }
      if (i == midOrder) {
        final p = parentOrder[i];
        if (p >= 0 && s.affectedStamp[p] == epoch) {
          final pSlot = s.affectedSlot[p];
          final pDelta = pSlot == 0
              ? s.ikDeltaRoot
              : (pSlot == 1 ? s.ikDeltaMidTotal : s.ikDeltaMid);
          s.temp
            ..setFrom(pDelta)
            ..multiply(mm);
          mm.setFrom(s.temp);
          rotateCombinedAroundOrigin(mm, s.ikQMid);
          s.affectedStamp[i] = epoch;
          s.affectedSlot[i] = 1;
        } else {
          rotateCombinedAroundOrigin(mm, s.ikQMid);
          s.affectedStamp[i] = epoch;
          s.affectedSlot[i] = 2;
        }
        continue;
      }
      final p = parentOrder[i];
      if (p >= 0 && s.affectedStamp[p] == epoch) {
        final slot = s.affectedSlot[p];
        s.affectedStamp[i] = epoch;
        s.affectedSlot[i] = slot;
        final delta = slot == 0
            ? s.ikDeltaRoot
            : (slot == 1 ? s.ikDeltaMidTotal : s.ikDeltaMid);
        final ct = ordered[i].combinedTransform;
        s.temp
          ..setFrom(delta)
          ..multiply(ct);
        ct.setFrom(s.temp);
      }
    }
  }

  static final _BoneModifierScratch _scratch = _BoneModifierScratch();
}
