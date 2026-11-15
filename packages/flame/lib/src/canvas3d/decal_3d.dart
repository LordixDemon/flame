import 'dart:ui';

import 'package:flame/src/canvas3d/batch_mesh_renderer_3d.dart';
import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/canvas3d/material_3d.dart';
import 'package:flame/src/canvas3d/mesh_3d.dart';

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
  this.sortOrder = 1,
  this.depthBias = 0.02,
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

  /// Explicit draw-order bucket (`1` by default so floor decals always draw on
  /// top of `sortOrder == 0` floor tiles without z-fighting).
  int sortOrder;

  /// Additional view-depth bias applied during triangle sorting.
  double depthBias;

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
      sortOrder: sortOrder,
      depthBias: depthBias,
    );
  }
}
