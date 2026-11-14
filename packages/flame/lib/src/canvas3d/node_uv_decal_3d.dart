import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/src/canvas3d/batch_mesh_renderer_3d.dart';
import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/canvas3d/deformable_mesh_3d.dart';
import 'package:flame/src/canvas3d/material_3d.dart';
import 'package:flame/src/canvas3d/mesh_3d.dart';
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
class Node3D({
  this.name = '',
  this.mesh,
  this.material,
  this.localX = 0.0,
  this.localY = 0.0,
  this.localZ = 0.0,
  this.localYawRad = 0.0,
  this.localPitchRad = 0.0,
  this.localRollRad = 0.0,
  this.localScaleX = 1.0,
  this.localScaleY = 1.0,
  this.localScaleZ = 1.0,
  this.tint = const Color(0xFFFFFFFF),
  this.opacity = 1.0,
  this.emissive = 0.0,
  this.uvRectPx,
  this.castGroundShadow = false,
  this.visible = true,
}) {
  /// Optional debug or lookup label (e.g. `'blade_hub'`, `'minute_hand'`).
  final String name;

  /// Optional 3D mesh attached to this node (`null` for pure pivot nodes).
  Mesh3D? mesh;

  /// Optional per-node [Material3D] override inside `BatchMeshRenderer3D`.
  Material3D? material;

  /// Local X offset in parent coordinates.
  double localX;

  /// Local Y offset in parent coordinates.
  double localY;

  /// Local Z offset in parent coordinates.
  double localZ;

  /// Local yaw around `+Z` in radians (used when [hasLocalQuaternion] is
  /// `false`).
  double localYawRad;

  /// Local pitch around `+Y` in radians (used when [hasLocalQuaternion] is
  /// `false`).
  double localPitchRad;

  /// Local roll around `+X` in radians (used when [hasLocalQuaternion] is
  /// `false`).
  double localRollRad;

  /// Local X scale multiplier.
  double localScaleX;

  /// Local Y scale multiplier.
  double localScaleY;

  /// Local Z scale multiplier.
  double localScaleZ;

  /// Base diffuse color tint for [mesh].
  Color tint;

  /// Opacity multiplier (`0.0 .. 1.0`), propagated multiplicatively down child
  /// nodes.
  double opacity;

  /// Self-illumination term (`0.0 .. 1.0`).
  double emissive;

  /// Optional atlas pixel UV sub-rectangle mapped over `mesh.uvs`.
  Rect? uvRectPx;

  /// Whether this node's [mesh] casts a ground shadow.
  bool castGroundShadow;

  /// Whether this node and its subtree are visible.
  bool visible;

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
  double _worldYawRad = 0.0;
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

  /// Computed world yaw (radians) after [updateWorldTransforms].
  double get worldYawRad => _worldYawRad;

  /// Computed world X scale after [updateWorldTransforms].
  double get worldScaleX => _worldScaleX;

  /// Computed world Y scale after [updateWorldTransforms].
  double get worldScaleY => _worldScaleY;

  /// Computed world Z scale after [updateWorldTransforms].
  double get worldScaleZ => _worldScaleZ;

  /// Row-major `3x3` world rotation matrix computed by [updateWorldTransforms].
  Float32List get worldRotationMatrix => _worldRot;

  /// Transforms a point `(lx, ly, lz)` in this node's local space into 3D world
  /// coordinates `(wx, wy, wz)` using the latest [updateWorldTransforms].
  (double wx, double wy, double wz) worldPointForLocal(
    double lx,
    double ly,
    double lz,
  ) {
    final sx = lx * _worldScaleX;
    final sy = ly * _worldScaleY;
    final sz = lz * _worldScaleZ;
    return (
      _worldX + _worldRot[0] * sx + _worldRot[1] * sy + _worldRot[2] * sz,
      _worldY + _worldRot[3] * sx + _worldRot[4] * sy + _worldRot[5] * sz,
      _worldZ + _worldRot[6] * sx + _worldRot[7] * sy + _worldRot[8] * sz,
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
        yawRad: localYawRad,
        pitchRad: localPitchRad,
        rollRad: localRollRad,
        out: _localRot,
      );
    }

    final p = _parent;
    if (p == null) {
      _worldX = localX;
      _worldY = localY;
      _worldZ = localZ;
      _worldYawRad = localYawRad;
      _worldScaleX = localScaleX;
      _worldScaleY = localScaleY;
      _worldScaleZ = localScaleZ;
      _worldOpacity = opacity.clamp(0.0, 1.0);
      _worldRot.setRange(0, 9, _localRot);
    } else {
      final sx = localX * p._worldScaleX;
      final sy = localY * p._worldScaleY;
      final sz = localZ * p._worldScaleZ;
      final pr = p._worldRot;
      _worldX = p._worldX + pr[0] * sx + pr[1] * sy + pr[2] * sz;
      _worldY = p._worldY + pr[3] * sx + pr[4] * sy + pr[5] * sz;
      _worldZ = p._worldZ + pr[6] * sx + pr[7] * sy + pr[8] * sz;
      _worldYawRad = p._worldYawRad + localYawRad;
      _worldScaleX = p._worldScaleX * localScaleX;
      _worldScaleY = p._worldScaleY * localScaleY;
      _worldScaleZ = p._worldScaleZ * localScaleZ;
      _worldOpacity = (p._worldOpacity * opacity).clamp(0.0, 1.0);
      Quaternion3D.multiplyMatrix3(pr, 0, _localRot, 0, _worldRot, 0);
    }

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
    if (!visible || _worldOpacity <= 0.0) {
      return;
    }
    final m = mesh;
    if (m != null) {
      renderer.enqueueMesh(
        m,
        camera: camera,
        worldX: _worldX,
        worldY: _worldY,
        worldZ: _worldZ,
        canvasOrigin: canvasOrigin,
        scaleX: _worldScaleX,
        scaleY: _worldScaleY,
        scaleZ: _worldScaleZ,
        rotationMatrix3: _worldRot,
        tint: tint,
        opacity: _worldOpacity,
        emissive: emissive,
        uvRectPx: uvRectPx,
        material: material,
        castGroundShadow: castGroundShadow,
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

/// Oriented 3D surface decal (selection rings, scorch marks, tile runes,
/// footprints, arrows) rendered cleanly inside [BatchMeshRenderer3D] with
/// elevation [normalBias] to prevent depth-sort z-fighting against floors.
class Decal3D({
  required this.worldX,
  required this.worldY,
  this.worldZ = 0.0,
  this.sizeX = 1.0,
  this.sizeY = 1.0,
  this.yawRad = 0.0,
  this.pitchRad = 0.0,
  this.rollRad = 0.0,
  this.normalBias = 0.02,
  this.tint = const Color(0xFFFFFFFF),
  this.opacity = 1.0,
  this.emissive = 0.35,
  this.uvRectPx,
  this.material,
}) {
  static final Mesh3D _unitQuad = Mesh3D.plane();

  /// Decal center X in 3D world space.
  double worldX;

  /// Decal center Y in 3D world space.
  double worldY;

  /// Decal surface Z in 3D world space.
  double worldZ;

  /// Decal width along local X.
  double sizeX;

  /// Decal length along local Y.
  double sizeY;

  /// Yaw rotation around `+Z` in radians.
  double yawRad;

  /// Pitch rotation around `+Y` in radians.
  double pitchRad;

  /// Roll rotation around `+X` in radians.
  double rollRad;

  /// Small `+Z`/normal lift preventing coplanar triangle sort flicker.
  double normalBias;

  /// Decal color tint.
  Color tint;

  /// Decal opacity (`0.0 .. 1.0`).
  double opacity;

  /// Self-illumination boost (`0.0 .. 1.0`) so selection rings stay crisp.
  double emissive;

  /// Optional atlas pixel UV sub-rectangle mapped onto the decal quad.
  Rect? uvRectPx;

  /// Optional per-decal [Material3D] (e.g. `Material3D.texture(...,
  /// blendMode: BlendMode.plus)` for additive runes/rings).
  Material3D? material;

  /// Enqueues this decal into [renderer] without allocating a new mesh.
  void enqueue(
    BatchMeshRenderer3D renderer, {
    required CameraRig3D camera,
    Offset canvasOrigin = Offset.zero,
  }) {
    if (opacity <= 0.0 || sizeX <= 0.0 || sizeY <= 0.0) {
      return;
    }
    renderer.enqueueMesh(
      _unitQuad,
      camera: camera,
      worldX: worldX,
      worldY: worldY,
      worldZ: worldZ + normalBias,
      canvasOrigin: canvasOrigin,
      scaleX: sizeX,
      scaleY: sizeY,
      yawRad: yawRad,
      pitchRad: pitchRad,
      rollRad: rollRad,
      tint: tint,
      opacity: opacity,
      emissive: emissive,
      uvRectPx: uvRectPx,
      material: material,
    );
  }
}
