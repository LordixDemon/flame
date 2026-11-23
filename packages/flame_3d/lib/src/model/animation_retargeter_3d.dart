import 'dart:math' as math;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:flame_3d/src/model/animation_state.dart';
import 'package:flame_3d/src/model/model.dart';
import 'package:flame_3d/src/model/model_animation.dart';

part 'animation_retargeter_clip_3d.dart';

/// Canonical humanoid skeleton bone slots used by [HumanoidProfile3D] and
/// [AnimationRetargeter3D].
enum HumanoidBone3D() {
  hips,
  spine,
  chest,
  upperChest,
  neck,
  head,
  leftShoulder,
  leftUpperArm,
  leftLowerArm,
  leftHand,
  rightShoulder,
  rightUpperArm,
  rightLowerArm,
  rightHand,
  leftUpperLeg,
  leftLowerLeg,
  leftFoot,
  leftToes,
  rightUpperLeg,
  rightLowerLeg,
  rightFoot,
  rightToes,
}

class _BoneRestTransform({
  required final int nodeIndex,
  required final Vector3 localTranslation,
  required final Quaternion localRotation,
  required final Vector3 localScale,
  required final Vector3 worldPosition,
  required final Quaternion worldRotation,
  required final Quaternion parentWorldRotation,
});

/// Maps canonical [HumanoidBone3D] slots to node indices on a [Model] and
/// caches bind/rest-pose local & model-space rotations plus [hipsRestHeight].
class HumanoidProfile3D({
  required final Model model,
  required Map<HumanoidBone3D, int> boneNodeIndices,
  double? hipsRestHeight,
}) {
  /// Builds a [HumanoidProfile3D] from explicit bone node names on [model].
  factory HumanoidProfile3D.fromBoneNames({
    required Model model,
    required Map<HumanoidBone3D, String> boneNames,
    double? hipsRestHeight,
  }) {
    final indices = <HumanoidBone3D, int>{};
    for (final entry in boneNames.entries) {
      final idx = model.nodeIndexByName(entry.value);
      if (idx == null) {
        throw ArgumentError(
          'Model does not contain bone "${entry.value}" for ${entry.key.name}',
        );
      }
      indices[entry.key] = idx;
    }
    return HumanoidProfile3D(
      model: model,
      boneNodeIndices: indices,
      hipsRestHeight: hipsRestHeight,
    );
  }

  /// Automatically detects canonical [HumanoidBone3D] mappings across Mixamo,
  /// glTF/Unity/Unreal, VRM (`J_Bip_*`), and Blender Rigify (`DEF-*`) naming
  /// conventions.
  factory HumanoidProfile3D.autoDetect(Model model) {
    final detected = <HumanoidBone3D, int>{};
    final claimedNodes = <int>{};

    // Sort nodes deterministically by nodeIndex so hierarchy order is stable.
    final sortedEntries = model.nodes.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    final parsedNodes = <_CandidateBoneName>[];
    for (final entry in sortedEntries) {
      final rawName = entry.value.name;
      if (rawName == null || rawName.isEmpty) {
        continue;
      }
      // Skip pure mesh wrapper nodes that have no children and no joints when a
      // skeleton exists, unless the node name clearly matches a bone.
      parsedNodes.add(_CandidateBoneName.parse(entry.key, rawName));
    }

    void assignFirst(
      HumanoidBone3D slot,
      bool Function(_CandidateBoneName c) predicate,
    ) {
      if (detected.containsKey(slot)) {
        return;
      }
      for (final cand in parsedNodes) {
        if (!claimedNodes.contains(cand.nodeIndex) && predicate(cand)) {
          detected[slot] = cand.nodeIndex;
          claimedNodes.add(cand.nodeIndex);
          return;
        }
      }
    }

    // 1. Torso & Head chain (specific -> general so `upperchest` / `spine2`
    // never get swallowed by `chest` / `spine`).
    assignFirst(
      HumanoidBone3D.hips,
      (c) =>
          c.side == _BoneSide.none &&
          (c.stem == 'hips' ||
              c.stem == 'pelvis' ||
              c.stem == 'hip' ||
              c.rawLower == 'def-spine'),
    );
    assignFirst(
      HumanoidBone3D.upperChest,
      (c) =>
          c.side == _BoneSide.none &&
          (c.stem == 'upperchest' ||
              c.stem == 'spine2' ||
              c.stem == 'spine02' ||
              c.stem == 'spine003' ||
              c.stem == 'chest2'),
    );
    assignFirst(
      HumanoidBone3D.chest,
      (c) =>
          c.side == _BoneSide.none &&
          (c.stem == 'chest' ||
              c.stem == 'thorax' ||
              c.stem == 'spine1' ||
              c.stem == 'spine01' ||
              c.stem == 'spine002'),
    );
    assignFirst(
      HumanoidBone3D.spine,
      (c) =>
          c.side == _BoneSide.none &&
          (c.stem == 'spine' ||
              c.stem == 'spine0' ||
              c.stem == 'spine00' ||
              c.stem == 'spine001' ||
              c.stem == 'abdomen' ||
              c.stem == 'waist'),
    );
    assignFirst(
      HumanoidBone3D.neck,
      (c) =>
          c.side == _BoneSide.none &&
          (c.stem == 'neck' ||
              c.stem == 'neck01' ||
              c.stem == 'spine004' ||
              c.stem == 'spine005'),
    );
    assignFirst(
      HumanoidBone3D.head,
      (c) =>
          c.side == _BoneSide.none &&
          (c.stem == 'head' || c.stem == 'spine006'),
    );

    // 2. Left & Right Arms (specific -> general).
    for (final side in const [_BoneSide.left, _BoneSide.right]) {
      final isLeft = side == _BoneSide.left;
      assignFirst(
        isLeft ? HumanoidBone3D.leftShoulder : HumanoidBone3D.rightShoulder,
        (c) =>
            c.side == side &&
            (c.stem == 'shoulder' ||
                c.stem == 'clavicle' ||
                c.stem == 'collar'),
      );
      assignFirst(
        isLeft ? HumanoidBone3D.leftLowerArm : HumanoidBone3D.rightLowerArm,
        (c) =>
            c.side == side &&
            (c.stem == 'lowerarm' ||
                c.stem == 'forearm' ||
                c.stem == 'elbow' ||
                c.stem == 'armlower'),
      );
      assignFirst(
        isLeft ? HumanoidBone3D.leftUpperArm : HumanoidBone3D.rightUpperArm,
        (c) =>
            c.side == side &&
            (c.stem == 'upperarm' || c.stem == 'arm' || c.stem == 'armupper'),
      );
      assignFirst(
        isLeft ? HumanoidBone3D.leftHand : HumanoidBone3D.rightHand,
        (c) => c.side == side && (c.stem == 'hand' || c.stem == 'wrist'),
      );
    }

    // 3. Left & Right Legs (specific -> general so `upleg` / `lowerleg`
    // match before Mixamo's `LeftLeg` = calf).
    for (final side in const [_BoneSide.left, _BoneSide.right]) {
      final isLeft = side == _BoneSide.left;
      assignFirst(
        isLeft ? HumanoidBone3D.leftUpperLeg : HumanoidBone3D.rightUpperLeg,
        (c) =>
            c.side == side &&
            (c.stem == 'upperleg' ||
                c.stem == 'upleg' ||
                c.stem == 'thigh' ||
                c.stem == 'hip'),
      );
      assignFirst(
        isLeft ? HumanoidBone3D.leftLowerLeg : HumanoidBone3D.rightLowerLeg,
        (c) =>
            c.side == side &&
            (c.stem == 'lowerleg' ||
                c.stem == 'leg' ||
                c.stem == 'calf' ||
                c.stem == 'shin' ||
                c.stem == 'knee'),
      );
      assignFirst(
        isLeft ? HumanoidBone3D.leftToes : HumanoidBone3D.rightToes,
        (c) =>
            c.side == side &&
            (c.stem == 'toes' ||
                c.stem == 'toe' ||
                c.stem == 'toebase' ||
                c.stem == 'ball'),
      );
      assignFirst(
        isLeft ? HumanoidBone3D.leftFoot : HumanoidBone3D.rightFoot,
        (c) => c.side == side && (c.stem == 'foot' || c.stem == 'ankle'),
      );
    }

    return HumanoidProfile3D(
      model: model,
      boneNodeIndices: detected,
    );
  }

  /// Immutable mapping from [HumanoidBone3D] to `ModelNode.nodeIndex`.
  final Map<HumanoidBone3D, int> boneNodeIndices =
      Map<HumanoidBone3D, int>.unmodifiable(boneNodeIndices);

  final double? _explicitHipsHeight = hipsRestHeight;

  late final Map<int, HumanoidBone3D> _nodeToBone = {
    for (final entry in boneNodeIndices.entries) entry.value: entry.key,
  };

  late final Map<int, _BoneRestTransform> _restByNode = _computeRestPose(model);

  /// Rest-pose vertical height of the pelvis (`hips`) above ground in model
  /// units (always `> 0`), used to scale root/pelvis translations across
  /// skeletons of differing stature.
  late final double hipsRestHeight =
      _explicitHipsHeight ?? _measureHipsRestHeight(boneNodeIndices);

  /// Node index mapped to [bone], or `null` if unmapped.
  int? nodeIndexFor(HumanoidBone3D bone) => boneNodeIndices[bone];

  /// Node name mapped to [bone], or `null` if unmapped.
  String? nodeNameFor(HumanoidBone3D bone) {
    final idx = boneNodeIndices[bone];
    return idx == null ? null : model.nodes[idx]?.name;
  }

  /// Canonical [HumanoidBone3D] mapped to [nodeIndex], or `null`.
  HumanoidBone3D? boneForNodeIndex(int nodeIndex) => _nodeToBone[nodeIndex];

  /// Local bind/rest-pose rotation of [bone], or `null` if unmapped.
  Quaternion? localRestRotation(HumanoidBone3D bone) {
    final idx = boneNodeIndices[bone];
    return idx == null ? null : _restByNode[idx]?.localRotation.clone();
  }

  /// Model-space (rig-space) bind/rest-pose rotation of [bone], or `null` if
  /// unmapped.
  Quaternion? worldRestRotation(HumanoidBone3D bone) {
    final idx = boneNodeIndices[bone];
    return idx == null ? null : _restByNode[idx]?.worldRotation.clone();
  }

  double _measureHipsRestHeight(Map<HumanoidBone3D, int> mapping) {
    final hipsIdx = mapping[HumanoidBone3D.hips];
    final hipsRest = hipsIdx == null ? null : _restByNode[hipsIdx];
    if (hipsRest == null) {
      return 1.0;
    }

    final hipsY = hipsRest.worldPosition.y;
    if (hipsY.abs() > 1e-4) {
      return hipsY.abs();
    }

    // Fallback for pelvis-origin rigs where `hips` sits at `y == 0` and feet
    // extend downward into negative Y.
    var minFootY = hipsY;
    var foundFoot = false;
    for (final footBone in const [
      HumanoidBone3D.leftFoot,
      HumanoidBone3D.rightFoot,
      HumanoidBone3D.leftToes,
      HumanoidBone3D.rightToes,
      HumanoidBone3D.leftLowerLeg,
      HumanoidBone3D.rightLowerLeg,
    ]) {
      final fIdx = mapping[footBone];
      final fRest = fIdx == null ? null : _restByNode[fIdx];
      if (fRest != null) {
        if (!foundFoot || fRest.worldPosition.y < minFootY) {
          minFootY = fRest.worldPosition.y;
          foundFoot = true;
        }
      }
    }
    final span = (hipsY - minFootY).abs();
    return span > 1e-4 ? span : 1.0;
  }

  static Map<int, _BoneRestTransform> _computeRestPose(Model model) {
    final workspace = ModelPoseWorkspace.forModel(model);
    model.evaluateInto(AnimationState(), workspace);

    final worldRotByNode = <int, Quaternion>{};
    for (final processed in workspace.orderedNodes) {
      worldRotByNode[processed.node.nodeIndex] = _extractUnitRotation(
        processed.combinedTransform,
      );
    }

    final result = <int, _BoneRestTransform>{};
    for (final processed in workspace.orderedNodes) {
      final node = processed.node;
      final parentIdx = node.parentNodeIndex;
      final parentRot = parentIdx != null
          ? (worldRotByNode[parentIdx] ?? Quaternion.identity())
          : Quaternion.identity();
      result[node.nodeIndex] = _BoneRestTransform(
        nodeIndex: node.nodeIndex,
        localTranslation: node.restTranslation.clone(),
        localRotation: node.restRotation.clone(),
        localScale: node.restScale.clone(),
        worldPosition: processed.combinedTransform.getTranslation(),
        worldRotation: worldRotByNode[node.nodeIndex]!,
        parentWorldRotation: parentRot.clone(),
      );
    }
    return result;
  }

  static Quaternion _extractUnitRotation(Matrix4 m) {
    final s = m.storage;
    var c0x = s[0];
    var c0y = s[1];
    var c0z = s[2];
    var c1x = s[4];
    var c1y = s[5];
    var c1z = s[6];
    var c2x = s[8];
    var c2y = s[9];
    var c2z = s[10];

    final l0 = math.sqrt(c0x * c0x + c0y * c0y + c0z * c0z);
    final l1 = math.sqrt(c1x * c1x + c1y * c1y + c1z * c1z);
    final l2 = math.sqrt(c2x * c2x + c2y * c2y + c2z * c2z);
    if (l0 > 1e-12) {
      c0x /= l0;
      c0y /= l0;
      c0z /= l0;
    }
    if (l1 > 1e-12) {
      c1x /= l1;
      c1y /= l1;
      c1z /= l1;
    }
    if (l2 > 1e-12) {
      c2x /= l2;
      c2y /= l2;
      c2z /= l2;
    }

    final rotMat = Matrix3(c0x, c0y, c0z, c1x, c1y, c1z, c2x, c2y, c2z);
    final q = Quaternion.fromRotation(rotMat);
    if (q.length2 > 1e-12) {
      q.normalize();
    } else {
      q.setValues(0.0, 0.0, 0.0, 1.0);
    }
    return q;
  }
}

enum _BoneSide() {
  none,
  left,
  right,
}

class _CandidateBoneName({
  required final int nodeIndex,
  required final String rawLower,
  required final String stem,
  required final _BoneSide side,
}) {
  factory _CandidateBoneName.parse(int nodeIndex, String raw) {
    final rawLower = raw.trim().toLowerCase();
    var work = rawLower;

    // Strip common rig namespace prefixes (`mixamorig:`, `DEF-`, `J_Bip_`,
    // `Bip01_`).
    final colonIdx = work.lastIndexOf(':');
    if (colonIdx != -1 && colonIdx + 1 < work.length) {
      work = work.substring(colonIdx + 1);
    }
    for (final prefix in const [
      'mixamorig_',
      'mixamorig',
      'def-',
      'def_',
      'org-',
      'mch-',
      'bip01_',
      'bip001_',
      'valvebiped_',
    ]) {
      if (work.startsWith(prefix) && work.length > prefix.length) {
        work = work.substring(prefix.length);
        break;
      }
    }

    var side = _BoneSide.none;
    if (work.startsWith('j_bip_')) {
      final rest = work.substring(6);
      if (rest.startsWith('l_')) {
        side = _BoneSide.left;
        work = rest.substring(2);
      } else if (rest.startsWith('r_')) {
        side = _BoneSide.right;
        work = rest.substring(2);
      } else if (rest.startsWith('c_')) {
        work = rest.substring(2);
      }
    }

    // Detect explicit prefix/suffix side tokens (`left`, `right`, `.l`, `_l`,
    // `-l`).
    if (side == _BoneSide.none) {
      if (work.startsWith('left_') || work.startsWith('left')) {
        side = _BoneSide.left;
        work = work.startsWith('left_') ? work.substring(5) : work.substring(4);
      } else if (work.startsWith('right_') || work.startsWith('right')) {
        side = _BoneSide.right;
        work = work.startsWith('right_')
            ? work.substring(6)
            : work.substring(5);
      } else if (work.endsWith('.l') ||
          work.endsWith('_l') ||
          work.endsWith('-l')) {
        side = _BoneSide.left;
        work = work.substring(0, work.length - 2);
      } else if (work.endsWith('.r') ||
          work.endsWith('_r') ||
          work.endsWith('-r')) {
        side = _BoneSide.right;
        work = work.substring(0, work.length - 2);
      } else if (work.startsWith('l_') || work.startsWith('l.')) {
        side = _BoneSide.left;
        work = work.substring(2);
      } else if (work.startsWith('r_') || work.startsWith('r.')) {
        side = _BoneSide.right;
        work = work.substring(2);
      } else if (work.endsWith('left')) {
        side = _BoneSide.left;
        work = work.substring(0, work.length - 4);
      } else if (work.endsWith('right')) {
        side = _BoneSide.right;
        work = work.substring(0, work.length - 5);
      }
    }

    final stem = work.replaceAll(_nonAlphaNum, '');
    return _CandidateBoneName(
      nodeIndex: nodeIndex,
      rawLower: rawLower,
      stem: stem,
      side: side,
    );
  }

  static final RegExp _nonAlphaNum = RegExp('[^a-z0-9]');
}
