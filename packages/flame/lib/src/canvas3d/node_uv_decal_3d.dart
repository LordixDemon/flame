import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/src/canvas3d/batch_mesh_renderer_3d.dart';
import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/canvas3d/mesh_3d.dart';

/// Hierarchical 3D scene-graph node for articulated `canvas3d` props (windmill
/// sails, clock hands, turret barrels, vehicle wheels, hinged chests).
///
/// Composes parent-to-child translation, Z-yaw rotation, and scale cleanly
/// without per-frame heap allocations, and submits its entire subtree into a
/// [BatchMeshRenderer3D] in a single traversal.
class Node3D({
  this.name = '',
  this.mesh,
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

  /// Local X offset in parent coordinates.
  double localX;

  /// Local Y offset in parent coordinates.
  double localY;

  /// Local Z offset in parent coordinates.
  double localZ;

  /// Local yaw around `+Z` in radians.
  double localYawRad;

  /// Local pitch around `+Y` in radians.
  double localPitchRad;

  /// Local roll around `+X` in radians.
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

  /// Attaches [child] under this node.
  void addChild(Node3D child) {
    assert(!identical(child, this), 'Cannot parent a Node3D to itself');
    child._parent?.removeChild(child);
    child._parent = this;
    _children.add(child);
  }

  /// Detaches [child] from this node.
  bool removeChild(Node3D child) {
    if (_children.remove(child)) {
      child._parent = null;
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

  /// Recursively updates world transforms down the hierarchy.
  void updateWorldTransforms() {
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
    } else {
      final sx = localX * p._worldScaleX;
      final sy = localY * p._worldScaleY;
      final sz = localZ * p._worldScaleZ;
      final c = math.cos(p._worldYawRad);
      final s = math.sin(p._worldYawRad);
      _worldX = p._worldX + sx * c - sy * s;
      _worldY = p._worldY + sx * s + sy * c;
      _worldZ = p._worldZ + sz;
      _worldYawRad = p._worldYawRad + localYawRad;
      _worldScaleX = p._worldScaleX * localScaleX;
      _worldScaleY = p._worldScaleY * localScaleY;
      _worldScaleZ = p._worldScaleZ * localScaleZ;
      _worldOpacity = (p._worldOpacity * opacity).clamp(0.0, 1.0);
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
        yawRad: _worldYawRad,
        pitchRad: localPitchRad,
        rollRad: localRollRad,
        tint: tint,
        opacity: _worldOpacity,
        emissive: emissive,
        uvRectPx: uvRectPx,
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
    );
  }
}
