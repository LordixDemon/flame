import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/src/canvas3d/batch_mesh_renderer_3d.dart';
import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/canvas3d/material_3d.dart';
import 'package:flame/src/canvas3d/mesh_3d.dart';

/// 3D orientation behavior for [SpriteBillboard3D] inside
/// [BatchMeshRenderer3D].
enum BillboardOrientationMode3D() {
  /// Rotates around world vertical `+Z` to face the camera horizontally while
  /// remaining strictly vertical (`up = (0, 0, 1)`). Classic HD-2D character /
  /// tree / torch mode.
  cylindricalZ,

  /// Aligns completely parallel to the camera projection plane
  /// (`right = camera.right`, `up = camera.up`). Ideal for spherical spell
  /// orbs, flares, and floating icons.
  sphericalCameraPlane,

  /// Tilts backward partially from vertical `+Z` toward `camera.up` by
  /// `SpriteBillboard3D.standeeTiltFactor` (`0..1`), preventing sprites from
  /// looking foreshortened under steep overhead camera angles while keeping
  /// their feet grounded at `worldZ`.
  tiltedStandee,
}

/// Upright 2D pixel-art / flipbook sprite quad living natively inside the 3D
/// [BatchMeshRenderer3D] pipeline (the core HD-2D rendering primitive).
///
/// Unlike 2D overlay sprites, [SpriteBillboard3D]:
/// - Interleaves into exact 3D triangle Z-sorting between 3D buildings/walls,
/// - Clips cleanly against `CameraRig3D.nearClip` in perspective mode,
/// - Receives 3D `DirectionalLight3D`, `PointLight3D`, and
///   `SceneEnvironment3D` atmospheric fog,
/// - Projects angled 3D ground shadows onto `groundZ`!
class SpriteBillboard3D({
  required this.worldX,
  required this.worldY,
  this.worldZ = 0.0,
  this.width = 1.0,
  this.height = 1.0,
  this.anchorX = 0.5,
  this.anchorY = 1.0,
  this.orientation = BillboardOrientationMode3D.cylindricalZ,
  this.standeeTiltFactor = 0.45,
  this.rollRad = 0.0,
  this.flipH = false,
  this.flipV = false,
  this.tint = const Color(0xFFFFFFFF),
  this.opacity = 1.0,
  this.emissive = 0.35,
  this.normalUpBias = 0.35,
  this.uvRectPx,
  this.material,
  this.sortOrder = 0,
  this.depthBias = 0.0,
  this.castGroundShadow = true,
  this.shadowColor = const Color(0xFF16131F),
  this.shadowOpacity = 0.24,
  this.visible = true,
}) {
  double worldX;
  double worldY;
  double worldZ;

  /// Width in 3D world units along camera-right.
  double width;

  /// Height in 3D world units along billboard-up.
  double height;

  /// Horizontal pivot in `[0..1]` (`0.5` = horizontally centered).
  double anchorX;

  /// Vertical pivot in `[0..1]` (`1.0` = bottom feet rest at [worldZ], `0.5` =
  /// centered).
  double anchorY;

  BillboardOrientationMode3D orientation;

  /// Blend factor `[0..1]` between `(0, 0, 1)` and `camera.up` when
  /// [orientation] is [BillboardOrientationMode3D.tiltedStandee].
  double standeeTiltFactor;

  /// In-plane roll angle in radians around the billboard's view-facing normal.
  double rollRad;

  bool flipH;
  bool flipV;

  Color tint;
  double opacity;

  /// Self-illumination (`0..1`) keeping pixel-art colors vibrant under grazing
  /// sun angles.
  double emissive;

  /// Upward normal blend (`0..1`) softening harsh back-lighting on flat sprite
  /// cards.
  double normalUpBias;

  /// Source pixel sub-rectangle inside `material.texture` (e.g. current
  /// animation frame).
  Rect? uvRectPx;

  /// Texture or unshaded [Material3D] used to shade this billboard.
  Material3D? material;

  int sortOrder;
  double depthBias;
  bool castGroundShadow;
  Color shadowColor;
  double shadowOpacity;
  bool visible;

  // Pre-allocated scratch buffers (`0` per-frame heap allocations!):
  final Float32List _positions = Float32List(12);
  final Float32List _normals = Float32List(12);
  final Float32List _uvs = Float32List(8);
  static final Uint16List _indices = Uint16List.fromList(const <int>[
    0,
    2,
    1,
    0,
    3,
    2,
  ]);
  static final Float32List _identityRot3 = Float32List.fromList(const <double>[
    1,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    1,
  ]);

  /// Convenience helper setting [uvRectPx] to frame [frameIndex] inside a
  /// uniform sprite grid (`columns` wide, each cell `frameWidthPx *
  /// frameHeightPx`).
  void setFlipbookFrame({
    required int frameIndex,
    required int columns,
    required double frameWidthPx,
    required double frameHeightPx,
    double marginPxX = 0.0,
    double marginPxY = 0.0,
  }) {
    final safeCols = math.max(1, columns);
    final safeFrame = math.max(0, frameIndex);
    final col = safeFrame % safeCols;
    final row = safeFrame ~/ safeCols;
    uvRectPx = Rect.fromLTWH(
      marginPxX + col * frameWidthPx,
      marginPxY + row * frameHeightPx,
      frameWidthPx,
      frameHeightPx,
    );
  }

  /// Enqueues this 3D sprite billboard into [renderer] with `0` heap
  /// allocations.
  void enqueue(
    BatchMeshRenderer3D renderer, {
    required CameraRig3D camera,
    Offset canvasOrigin = Offset.zero,
    double groundZ = 0.0,
  }) {
    if (!visible || opacity <= 0.0 || width <= 0.0 || height <= 0.0) {
      return;
    }

    // 1. Base right & up axes in 3D world space:
    var rx = camera.rightX;
    var ry = camera.rightY;
    var rz = 0.0;

    double ux;
    double uy;
    double uz;
    switch (orientation) {
      case BillboardOrientationMode3D.cylindricalZ:
        ux = 0.0;
        uy = 0.0;
        uz = 1.0;
      case BillboardOrientationMode3D.sphericalCameraPlane:
        ux = camera.upX;
        uy = camera.upY;
        uz = camera.upZ;
      case BillboardOrientationMode3D.tiltedStandee:
        final t = standeeTiltFactor.clamp(0.0, 1.0);
        final bx = camera.upX * t;
        final by = camera.upY * t;
        final bz = (1.0 - t) + camera.upZ * t;
        final len = math.sqrt(bx * bx + by * by + bz * bz);
        if (len > 1e-6) {
          ux = bx / len;
          uy = by / len;
          uz = bz / len;
        } else {
          ux = 0.0;
          uy = 0.0;
          uz = 1.0;
        }
    }

    // 2. Optional in-plane roll around billboard normal:
    if (rollRad.abs() > 1e-6) {
      final c = math.cos(rollRad);
      final s = math.sin(rollRad);
      final nrx = rx * c + ux * s;
      final nry = ry * c + uy * s;
      final nrz = rz * c + uz * s;
      final nux = -rx * s + ux * c;
      final nuy = -ry * s + uy * c;
      final nuz = -rz * s + uz * c;
      rx = nrx;
      ry = nry;
      rz = nrz;
      ux = nux;
      uy = nuy;
      uz = nuz;
    }

    // 3. Local quad extents around (anchorX, anchorY):
    // anchorY == 1.0 -> bottom at u0 = 0.0, top at u1 = +height!
    final x0 = -anchorX * width;
    final x1 = (1.0 - anchorX) * width;
    final y0 = -(1.0 - anchorY) * height;
    final y1 = anchorY * height;

    void writeVert(int slot, double sRight, double sUp) {
      final p = slot * 3;
      _positions[p] = rx * sRight + ux * sUp;
      _positions[p + 1] = ry * sRight + uy * sUp;
      _positions[p + 2] = rz * sRight + uz * sUp;
    }

    // v0: bottom-left, v1: bottom-right, v2: top-right, v3: top-left
    writeVert(0, x0, y0);
    writeVert(1, x1, y0);
    writeVert(2, x1, y1);
    writeVert(3, x0, y1);

    // 4. Lighting normal facing camera blended slightly toward +Z:
    final upBias = normalUpBias.clamp(0.0, 1.0);
    var nx = camera.viewX * (1.0 - upBias);
    var ny = camera.viewY * (1.0 - upBias);
    var nz = camera.viewZ * (1.0 - upBias) + upBias;
    final nLen = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nLen > 1e-6) {
      nx /= nLen;
      ny /= nLen;
      nz /= nLen;
    } else {
      nx = 0.0;
      ny = 0.0;
      nz = 1.0;
    }
    for (var v = 0; v < 4; v++) {
      final p = v * 3;
      _normals[p] = nx;
      _normals[p + 1] = ny;
      _normals[p + 2] = nz;
    }

    // 5. Normalized [0..1] UVs (remapped into uvRectPx by BatchMeshRenderer3D):
    final uLeft = flipH ? 1.0 : 0.0;
    final uRight = flipH ? 0.0 : 1.0;
    final vBottom = flipV ? 0.0 : 1.0;
    final vTop = flipV ? 1.0 : 0.0;

    _uvs[0] = uLeft;
    _uvs[1] = vBottom;
    _uvs[2] = uRight;
    _uvs[3] = vBottom;
    _uvs[4] = uRight;
    _uvs[5] = vTop;
    _uvs[6] = uLeft;
    _uvs[7] = vTop;

    final boundR = math.sqrt(width * width + height * height);
    final minLocalZ = math.min(
      math.min(_positions[2], _positions[5]),
      math.min(_positions[8], _positions[11]),
    );
    final maxLocalZ = math.max(
      math.max(_positions[2], _positions[5]),
      math.max(_positions[8], _positions[11]),
    );

    renderer.enqueueDeformedBuffers(
      positions: _positions,
      normals: _normals,
      indices: _indices,
      uvs: _uvs,
      boundingRadius: boundR,
      minZ: minLocalZ,
      maxZ: maxLocalZ,
      camera: camera,
      worldX: worldX,
      worldY: worldY,
      worldZ: worldZ,
      canvasOrigin: canvasOrigin,
      rotationMatrix3: _identityRot3,
      tint: tint,
      opacity: opacity,
      emissive: emissive,
      uvRectPx: uvRectPx,
      material: material,
      sortOrder: sortOrder,
      depthBias: depthBias,
      castGroundShadow: castGroundShadow,
      doubleSidedShadow: true,
      groundZ: groundZ,
      shadowColor: shadowColor,
      shadowOpacity: shadowOpacity,
    );
  }

  /// Static helper building a reusable upright [Mesh3D] plane in `(X, Z)` if a
  /// caller wants to attach a static standee mesh onto a `Node3D`.
  static Mesh3D buildVerticalPlaneMesh({
    double width = 1.0,
    double height = 1.0,
    double anchorY = 1.0,
  }) {
    final hx = width * 0.5;
    final z0 = -(1.0 - anchorY) * height;
    final z1 = anchorY * height;
    return Mesh3D(
      positions: Float32List.fromList(<double>[
        -hx,
        0.0,
        z0,
        hx,
        0.0,
        z0,
        hx,
        0.0,
        z1,
        -hx,
        0.0,
        z1,
      ]),
      normals: Float32List.fromList(const <double>[
        0.0,
        1.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        1.0,
        0.0,
        0.0,
        1.0,
        0.0,
      ]),
      uvs: Float32List.fromList(const <double>[
        0.0,
        1.0,
        1.0,
        1.0,
        1.0,
        0.0,
        0.0,
        0.0,
      ]),
      indices: Uint16List.fromList(const <int>[0, 2, 1, 0, 3, 2]),
    );
  }
}
