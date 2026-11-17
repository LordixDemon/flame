import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/src/canvas3d/batch_mesh_renderer_3d.dart';
import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/canvas3d/material_3d.dart';
import 'package:flame/src/canvas3d/mesh_3d.dart';
import 'package:flame/src/canvas3d/quaternion_3d.dart';
import 'package:flame/src/game/game.dart';

/// Hierarchical 3D scene-graph node for articulated `canvas3d` props (tilting
/// cups, character limbs, windmill sails, clock hands, turret barrels, hinged
/// chests).
///
/// Composes full 3D parent-to-child translation, `3x3` orthonormal rotation
/// (both Euler `(yaw, pitch, roll)` and gimbal-lock-free quaternions via
/// [setLocalQuaternion]), and scale without per-frame heap allocations, and
/// submits its entire subtree into a [BatchMeshRenderer3D] in a single
/// traversal.
///
/// A node's world transform is the exact matrix product
/// `parent * translation * rotation * scale`. A rotated child of a
/// non-uniformly scaled parent is therefore stretched along the parent's axes
/// (it shears), which [worldLinearMatrix] captures; [worldRotationMatrix] and
/// [worldScaleX] / [worldScaleY] / [worldScaleZ] are the separate rotation and
/// per-axis scale products, which describe the same transform only while no
/// rotation sits between two different non-uniform scales.
///
/// Every property that changes what is drawn calls
/// `Game.notifyVisualMutation` when its value really changes, so on-demand
/// rendering repaints.
class Node3D({
  this.name = '',
  Mesh3D? mesh,
  Material3D? material,
  double localX = 0.0,
  double localY = 0.0,
  double localZ = 0.0,
  double localYawRad = 0.0,
  double localPitchRad = 0.0,
  double localRollRad = 0.0,
  double localScaleX = 1.0,
  double localScaleY = 1.0,
  double localScaleZ = 1.0,
  Color tint = const Color(0xFFFFFFFF),
  double opacity = 1.0,
  double emissive = 0.0,
  Rect? uvRectPx,
  int sortOrder = 0,
  double depthBias = 0.0,
  bool castGroundShadow = false,
  bool visible = true,
}) {
  /// Optional debug or lookup label (e.g. `'blade_hub'`, `'minute_hand'`).
  final String name;

  Mesh3D? _mesh = mesh;
  Material3D? _material = material;
  double _localX = localX;
  double _localY = localY;
  double _localZ = localZ;
  double _localYawRad = localYawRad;
  double _localPitchRad = localPitchRad;
  double _localRollRad = localRollRad;
  double _localScaleX = localScaleX;
  double _localScaleY = localScaleY;
  double _localScaleZ = localScaleZ;
  Color _tint = tint;
  double _opacity = opacity;
  double _emissive = emissive;
  Rect? _uvRectPx = uvRectPx;
  int _sortOrder = sortOrder;
  double _depthBias = depthBias;
  bool _castGroundShadow = castGroundShadow;
  bool _visible = visible;

  /// Optional 3D mesh attached to this node (`null` for pure pivot nodes).
  Mesh3D? get mesh => _mesh;
  set mesh(Mesh3D? value) {
    if (!identical(_mesh, value)) {
      _mesh = value;
      Game.notifyVisualMutation();
    }
  }

  /// Optional per-node [Material3D] override inside `BatchMeshRenderer3D`.
  Material3D? get material => _material;
  set material(Material3D? value) {
    if (_material != value) {
      _material = value;
      Game.notifyVisualMutation();
    }
  }

  /// Local X offset in parent coordinates.
  double get localX => _localX;
  set localX(double value) {
    if (_localX != value) {
      _localX = value;
      Game.notifyVisualMutation();
    }
  }

  /// Local Y offset in parent coordinates.
  double get localY => _localY;
  set localY(double value) {
    if (_localY != value) {
      _localY = value;
      Game.notifyVisualMutation();
    }
  }

  /// Local Z offset in parent coordinates.
  double get localZ => _localZ;
  set localZ(double value) {
    if (_localZ != value) {
      _localZ = value;
      Game.notifyVisualMutation();
    }
  }

  /// Local yaw around `+Z` in radians (used when [hasLocalQuaternion] is
  /// `false`).
  double get localYawRad => _localYawRad;
  set localYawRad(double value) {
    if (_localYawRad != value) {
      _localYawRad = value;
      Game.notifyVisualMutation();
    }
  }

  /// Local pitch around `+Y` in radians (used when [hasLocalQuaternion] is
  /// `false`).
  double get localPitchRad => _localPitchRad;
  set localPitchRad(double value) {
    if (_localPitchRad != value) {
      _localPitchRad = value;
      Game.notifyVisualMutation();
    }
  }

  /// Local roll around `+X` in radians (used when [hasLocalQuaternion] is
  /// `false`).
  double get localRollRad => _localRollRad;
  set localRollRad(double value) {
    if (_localRollRad != value) {
      _localRollRad = value;
      Game.notifyVisualMutation();
    }
  }

  /// Local X scale multiplier.
  double get localScaleX => _localScaleX;
  set localScaleX(double value) {
    if (_localScaleX != value) {
      _localScaleX = value;
      Game.notifyVisualMutation();
    }
  }

  /// Local Y scale multiplier.
  double get localScaleY => _localScaleY;
  set localScaleY(double value) {
    if (_localScaleY != value) {
      _localScaleY = value;
      Game.notifyVisualMutation();
    }
  }

  /// Local Z scale multiplier.
  double get localScaleZ => _localScaleZ;
  set localScaleZ(double value) {
    if (_localScaleZ != value) {
      _localScaleZ = value;
      Game.notifyVisualMutation();
    }
  }

  /// Base diffuse color tint for [mesh].
  Color get tint => _tint;
  set tint(Color value) {
    if (_tint != value) {
      _tint = value;
      Game.notifyVisualMutation();
    }
  }

  /// Opacity multiplier (`0.0 .. 1.0`), propagated multiplicatively down child
  /// nodes.
  double get opacity => _opacity;
  set opacity(double value) {
    if (_opacity != value) {
      _opacity = value;
      Game.notifyVisualMutation();
    }
  }

  /// Self-illumination term (`0.0 .. 1.0`).
  double get emissive => _emissive;
  set emissive(double value) {
    if (_emissive != value) {
      _emissive = value;
      Game.notifyVisualMutation();
    }
  }

  /// Optional atlas pixel UV sub-rectangle mapped over `mesh.uvs`.
  Rect? get uvRectPx => _uvRectPx;
  set uvRectPx(Rect? value) {
    if (_uvRectPx != value) {
      _uvRectPx = value;
      Game.notifyVisualMutation();
    }
  }

  /// Explicit render pass sort order inside `BatchMeshRenderer3D` (smaller
  /// draws behind; larger draws on top).
  int get sortOrder => _sortOrder;
  set sortOrder(int value) {
    if (_sortOrder != value) {
      _sortOrder = value;
      Game.notifyVisualMutation();
    }
  }

  /// Per-node depth sort bias added to view-space triangle depth.
  double get depthBias => _depthBias;
  set depthBias(double value) {
    if (_depthBias != value) {
      _depthBias = value;
      Game.notifyVisualMutation();
    }
  }

  /// Whether this node's [mesh] casts a ground shadow.
  bool get castGroundShadow => _castGroundShadow;
  set castGroundShadow(bool value) {
    if (_castGroundShadow != value) {
      _castGroundShadow = value;
      Game.notifyVisualMutation();
    }
  }

  /// Whether this node and its subtree are visible.
  bool get visible => _visible;
  set visible(bool value) {
    if (_visible != value) {
      _visible = value;
      Game.notifyVisualMutation();
    }
  }

  bool _useQuaternion = false;
  double _qx = 0.0;
  double _qy = 0.0;
  double _qz = 0.0;
  double _qw = 1.0;

  Node3D? _parent;
  final List<Node3D> _children = <Node3D>[];

  double _worldX = 0.0;
  double _worldY = 0.0;
  double _worldZ = 0.0;
  double _worldScaleX = 1.0;
  double _worldScaleY = 1.0;
  double _worldScaleZ = 1.0;
  double _worldOpacity = 1.0;
  final Float32List _localRot = Float32List(9)
    ..[0] = 1.0
    ..[4] = 1.0
    ..[8] = 1.0;
  final Float32List _worldRot = Float32List(9)
    ..[0] = 1.0
    ..[4] = 1.0
    ..[8] = 1.0;
  final Float32List _worldLinear = Float32List(9)
    ..[0] = 1.0
    ..[4] = 1.0
    ..[8] = 1.0;

  /// Whether local orientation is driven by an explicit unit quaternion set via
  /// [setLocalQuaternion] instead of `(localYawRad, localPitchRad,
  /// localRollRad)`.
  bool get hasLocalQuaternion => _useQuaternion;

  /// Active local quaternion `(qx, qy, qz, qw)` when [hasLocalQuaternion] is
  /// `true`.
  (double, double, double, double) get localQuaternion => (_qx, _qy, _qz, _qw);

  /// Overrides local Euler angles with a gimbal-lock-free quaternion
  /// `(qx, qy, qz, qw)`.
  void setLocalQuaternion(double qx, double qy, double qz, double qw) {
    final (nx, ny, nz, nw) = Quaternion3D.normalize(qx, qy, qz, qw);
    if (_useQuaternion && _qx == nx && _qy == ny && _qz == nz && _qw == nw) {
      return;
    }
    _qx = nx;
    _qy = ny;
    _qz = nz;
    _qw = nw;
    _useQuaternion = true;
    Game.notifyVisualMutation();
  }

  /// Reverts local rotation mode back to `(localYawRad, localPitchRad,
  /// localRollRad)`.
  void clearLocalQuaternion() {
    if (_useQuaternion) {
      _useQuaternion = false;
      Game.notifyVisualMutation();
    }
  }

  /// Parent node in the 3D hierarchy (`null` if root).
  Node3D? get parent => _parent;

  /// Read-only view of child nodes.
  List<Node3D> get children => List<Node3D>.unmodifiable(_children);

  /// Computed world X after [updateWorldTransforms].
  double get worldX => _worldX;

  /// Computed world Y after [updateWorldTransforms].
  double get worldY => _worldY;

  /// Computed world Z after [updateWorldTransforms].
  double get worldZ => _worldZ;

  /// Heading of this node around world `+Z` in radians, in `(-pi, pi]`, after
  /// [updateWorldTransforms]: the direction its local `+X` axis points to in
  /// the ground plane.
  ///
  /// It reflects the whole world rotation, however it was composed (Euler
  /// angles or quaternions, on this node or on its ancestors). It is `0.0`
  /// when the local `+X` axis points straight up or down.
  double get worldYawRad => math.atan2(_worldRot[3], _worldRot[0]);

  /// Product of the X scales from the root down to this node, after
  /// [updateWorldTransforms].
  double get worldScaleX => _worldScaleX;

  /// Product of the Y scales from the root down to this node, after
  /// [updateWorldTransforms].
  double get worldScaleY => _worldScaleY;

  /// Product of the Z scales from the root down to this node, after
  /// [updateWorldTransforms].
  double get worldScaleZ => _worldScaleZ;

  /// Row-major `3x3` world rotation matrix computed by [updateWorldTransforms]:
  /// the product of the rotations from the root down to this node, without
  /// any scale.
  Float32List get worldRotationMatrix => _worldRot;

  /// Row-major `3x3` linear part of the exact world transform computed by
  /// [updateWorldTransforms]: rotation and scale of this node and of all its
  /// ancestors, including the shear a rotated child gets from a
  /// non-uniformly scaled parent.
  ///
  /// Pass it as `rotationMatrix3` (with scale `1`) to
  /// `BatchMeshRenderer3D.enqueueMesh` to draw a mesh exactly where
  /// [worldPointForLocal] puts its vertices.
  Float32List get worldLinearMatrix => _worldLinear;

  /// Transforms a point `(lx, ly, lz)` in this node's local space into 3D world
  /// coordinates `(wx, wy, wz)` using the latest [updateWorldTransforms].
  (double wx, double wy, double wz) worldPointForLocal(
    double lx,
    double ly,
    double lz,
  ) {
    final m = _worldLinear;
    return (
      _worldX + m[0] * lx + m[1] * ly + m[2] * lz,
      _worldY + m[3] * lx + m[4] * ly + m[5] * lz,
      _worldZ + m[6] * lx + m[7] * ly + m[8] * lz,
    );
  }

  /// Attaches [child] under this node.
  void addChild(Node3D child) {
    assert(!identical(child, this), 'Cannot parent a Node3D to itself');
    child._parent?.removeChild(child);
    child._parent = this;
    _children.add(child);
    Game.notifyVisualMutation();
  }

  /// Detaches [child] from this node.
  bool removeChild(Node3D child) {
    if (_children.remove(child)) {
      child._parent = null;
      Game.notifyVisualMutation();
      return true;
    }
    return false;
  }

  /// Finds the first descendant (or self) matching [targetName].
  Node3D? findByName(String targetName) {
    if (name == targetName) {
      return this;
    }
    for (var i = 0; i < _children.length; i++) {
      final hit = _children[i].findByName(targetName);
      if (hit != null) {
        return hit;
      }
    }
    return null;
  }

  /// Recursively updates full 3D world transforms (translation, `3x3` rotation
  /// including parent pitch/roll/quaternion, and scale) down the hierarchy.
  void updateWorldTransforms() {
    if (_useQuaternion) {
      Quaternion3D.writeMatrix3(_qx, _qy, _qz, _qw, _localRot);
    } else {
      Quaternion3D.writeEulerMatrix3(
        yawRad: _localYawRad,
        pitchRad: _localPitchRad,
        rollRad: _localRollRad,
        out: _localRot,
      );
    }

    final p = _parent;
    if (p == null) {
      _worldX = _localX;
      _worldY = _localY;
      _worldZ = _localZ;
      _worldScaleX = _localScaleX;
      _worldScaleY = _localScaleY;
      _worldScaleZ = _localScaleZ;
      _worldOpacity = _opacity.clamp(0.0, 1.0);
      _worldRot.setRange(0, 9, _localRot);
      _worldLinear.setRange(0, 9, _localRot);
    } else {
      final pl = p._worldLinear;
      _worldX = p._worldX + pl[0] * _localX + pl[1] * _localY + pl[2] * _localZ;
      _worldY = p._worldY + pl[3] * _localX + pl[4] * _localY + pl[5] * _localZ;
      _worldZ = p._worldZ + pl[6] * _localX + pl[7] * _localY + pl[8] * _localZ;
      _worldScaleX = p._worldScaleX * _localScaleX;
      _worldScaleY = p._worldScaleY * _localScaleY;
      _worldScaleZ = p._worldScaleZ * _localScaleZ;
      _worldOpacity = (p._worldOpacity * _opacity).clamp(0.0, 1.0);
      Quaternion3D.multiplyMatrix3(p._worldRot, 0, _localRot, 0, _worldRot, 0);
      Quaternion3D.multiplyMatrix3(pl, 0, _localRot, 0, _worldLinear, 0);
    }
    // Local scale acts in this node's own axes: it scales the columns.
    final m = _worldLinear;
    m[0] *= _localScaleX;
    m[3] *= _localScaleX;
    m[6] *= _localScaleX;
    m[1] *= _localScaleY;
    m[4] *= _localScaleY;
    m[7] *= _localScaleY;
    m[2] *= _localScaleZ;
    m[5] *= _localScaleZ;
    m[8] *= _localScaleZ;

    for (var i = 0; i < _children.length; i++) {
      _children[i].updateWorldTransforms();
    }
  }

  /// Updates transforms and submits all visible meshes in this hierarchy into
  /// [renderer].
  void enqueueHierarchy(
    BatchMeshRenderer3D renderer, {
    required CameraRig3D camera,
    Offset canvasOrigin = Offset.zero,
    double groundZ = 0.0,
  }) {
    if (_parent == null) {
      updateWorldTransforms();
    }
    _enqueueRecursive(
      renderer,
      camera: camera,
      canvasOrigin: canvasOrigin,
      groundZ: groundZ,
    );
  }

  void _enqueueRecursive(
    BatchMeshRenderer3D renderer, {
    required CameraRig3D camera,
    required Offset canvasOrigin,
    required double groundZ,
  }) {
    if (!_visible || _worldOpacity <= 0.0) {
      return;
    }
    final m = _mesh;
    if (m != null) {
      renderer.enqueueMesh(
        m,
        camera: camera,
        worldX: _worldX,
        worldY: _worldY,
        worldZ: _worldZ,
        canvasOrigin: canvasOrigin,
        // The linear matrix already holds every scale of the chain.
        rotationMatrix3: _worldLinear,
        tint: _tint,
        opacity: _worldOpacity,
        emissive: _emissive,
        uvRectPx: _uvRectPx,
        material: _material,
        sortOrder: _sortOrder,
        depthBias: _depthBias,
        castGroundShadow: _castGroundShadow,
        groundZ: groundZ,
      );
    }
    for (var i = 0; i < _children.length; i++) {
      _children[i]._enqueueRecursive(
        renderer,
        camera: camera,
        canvasOrigin: canvasOrigin,
        groundZ: groundZ,
      );
    }
  }
}
