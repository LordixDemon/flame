import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/src/canvas3d/raycast_3d.dart';

/// Orthonormal 3D view/projection camera rig for isometric, dimetric, and
/// perspective-assisted 3D worlds rendered onto Flutter's 2D `Canvas`.
///
/// At rest (`orbitYawDeltaRad == 0`, `pitchDeltaRad == 0`), the orthonormal
/// basis reproduces exact `2:1` isometric projection while supporting smooth
/// 3D elevation tilt, azimuth orbit, height perspective parallax, and exact
/// 2D-to-3D ray unprojection (`unprojectWorldRay`).
class CameraRig3D({
  this.cellHalfW = 44.0,
  this.cellHalfH = 22.0,
  this.groundOriginY = -18.0,
  this.baseAzimuthRad = math.pi * 0.25,
  this.baseElevationRad = math.pi / 6.0,
}) {
  /// Horizontal half-width in pixels of one ground cell.
  final double cellHalfW;

  /// Vertical half-height in pixels of one ground cell.
  final double cellHalfH;

  /// Screen/world Y coordinate corresponding to `(0, 0, 0)`.
  final double groundOriginY;

  /// Rest azimuth angle around Z in radians (default `pi / 4` = `45°`).
  final double baseAzimuthRad;

  /// Rest elevation angle above ground in radians (default `pi / 6` = `30°`).
  final double baseElevationRad;

  /// Focal scale (`cellHalfW * sqrt(2)`) mapping unit 3D basis to pixels.
  late final double focalScalePx = cellHalfW * math.sqrt2;

  /// Current 2D camera look-at X in world coordinates.
  double camWorldX = 0.0;

  /// Current 2D camera look-at Y in world coordinates.
  late double camWorldY = groundOriginY;

  /// Current 2D camera zoom factor.
  double camZoom = 1.0;

  /// Smooth 3D azimuth offset around Z in radians.
  double orbitYawDeltaRad = 0.0;

  /// Smooth 3D elevation pitch offset in radians.
  double pitchDeltaRad = 0.0;

  double _rightX = math.sqrt1_2;
  double _rightY = -math.sqrt1_2;

  double _downX = 0.5 * math.sqrt1_2;
  double _downY = 0.5 * math.sqrt1_2;
  double _downZ = -0.8660254037844386;

  double _viewX = 0.6123724356957945;
  double _viewY = 0.6123724356957945;
  double _viewZ = 0.5;
  int _basisVersion = 0;

  this {
    _recomputeBasis();
  }

  /// Monotonically increasing counter incremented whenever the 3D camera
  /// azimuth or elevation basis vectors change.
  int get basisVersion => _basisVersion;

  /// Scene-to-camera unit vector `(viewX, viewY, viewZ)`.
  double get viewX => _viewX;
  double get viewY => _viewY;
  double get viewZ => _viewZ;

  /// Camera-right unit vector `(rightX, rightY, 0)`.
  double get rightX => _rightX;
  double get rightY => _rightY;

  /// Camera-up unit vector `(upX, upY, upZ)`.
  double get upX => -_downX;
  double get upY => -_downY;
  double get upZ => -_downZ;

  /// Vertical pixel scale per 3D Z unit for the current camera elevation.
  double get zPixelsPerCell => -_downZ * focalScalePx;

  /// Height-perspective expansion factor (grows gently during close-up zooms).
  double get perspectiveStrength =>
      (0.022 + (camZoom - 1.0).clamp(0.0, 1.8) * 0.015).clamp(0.018, 0.048);

  /// Updates camera focus, zoom, and 3D orbit/pitch deltas, recomputing the
  /// orthonormal basis only when angles change.
  void update({
    required double camX,
    required double camY,
    required double zoom,
    double orbitYawDelta = 0.0,
    double pitchDelta = 0.0,
  }) {
    camWorldX = camX;
    camWorldY = camY;
    camZoom = zoom;
    final clampedYaw = orbitYawDelta.clamp(-0.45, 0.45);
    final clampedPitch = pitchDelta.clamp(-0.24, 0.28);
    if (clampedYaw != orbitYawDeltaRad || clampedPitch != pitchDeltaRad) {
      orbitYawDeltaRad = clampedYaw;
      pitchDeltaRad = clampedPitch;
      _recomputeBasis();
    }
  }

  void _recomputeBasis() {
    final az = baseAzimuthRad + orbitYawDeltaRad;
    final el = (baseElevationRad + pitchDeltaRad).clamp(0.18, 1.15);
    final ca = math.cos(az);
    final sa = math.sin(az);
    final cp = math.cos(el);
    final sp = math.sin(el);

    _rightX = sa;
    _rightY = -ca;

    _downX = ca * sp;
    _downY = sa * sp;
    _downZ = -cp;

    _viewX = ca * cp;
    _viewY = sa * cp;
    _viewZ = sp;
    _basisVersion++;
  }

  /// Projects ground grid coordinates `(gx, gy)` (`z = 0`) to 2D world pixels.
  Offset gridToScreen(double gx, double gy) {
    final sx = (gx - gy) * cellHalfW;
    final sy = (gx + gy) * cellHalfH + groundOriginY;
    return Offset(sx, sy);
  }

  /// Inverse ground projection from 2D world pixels back to `(gx, gy)` on
  /// `z = 0`.
  (double, double) screenToGrid(Offset worldPoint) {
    final dx = worldPoint.dx / cellHalfW;
    final dy = (worldPoint.dy - groundOriginY) / cellHalfH;
    return ((dx + dy) * 0.5, (dy - dx) * 0.5);
  }

  /// Projects a local 3D offset `(rx, ry, rz)` anchored at [anchorWorld] into
  /// canvas coordinates relative to [canvasOrigin] with zero heap allocations.
  (double, double) projectAnchored({
    required Offset anchorWorld,
    required Offset canvasOrigin,
    required double rx,
    required double ry,
    required double rz,
  }) {
    final gx = anchorWorld.dx + (_rightX * rx + _rightY * ry) * focalScalePx;
    final gy = anchorWorld.dy + (_downX * rx + _downY * ry) * focalScalePx;
    final persp = rz * perspectiveStrength;
    final sx = gx + (gx - camWorldX) * persp - canvasOrigin.dx;
    final sy =
        gy +
        _downZ * rz * focalScalePx +
        (gy - camWorldY) * persp * 0.55 -
        canvasOrigin.dy;
    return (sx, sy);
  }

  /// Projects an absolute 3D point `(wx, wy, wz)` into 2D world coordinates.
  Offset projectWorldPoint(double wx, double wy, double wz) {
    final anchor = gridToScreen(wx, wy);
    final (sx, sy) = projectAnchored(
      anchorWorld: anchor,
      canvasOrigin: Offset.zero,
      rx: 0.0,
      ry: 0.0,
      rz: wz,
    );
    return Offset(sx, sy);
  }

  /// View-space depth along the scene-to-camera axis (larger = closer).
  double viewDepth(double wx, double wy, double wz) =>
      wx * _viewX + wy * _viewY + wz * _viewZ;

  /// Transforms a world-space normal `(nx, ny, nz)` into camera view-space
  /// `(vx, vy, vz)` where `vz` faces the camera (`0..1` front-facing).
  (double, double, double) worldNormalToView(double nx, double ny, double nz) {
    final vx = nx * _rightX + ny * _rightY;
    final vy = -(nx * _downX + ny * _downY + nz * _downZ);
    final vz = nx * _viewX + ny * _viewY + nz * _viewZ;
    return (vx, vy, vz);
  }

  /// Unprojects a 2D world tap [worldTap] into an exact [Ray3D] accounting for
  /// camera elevation, azimuth, and height perspective parallax.
  Ray3D unprojectWorldRay(
    Offset worldTap, {
    double cameraDistance = 18.0,
  }) {
    final (groundX, groundY) = screenToGrid(worldTap);
    final p1 = perspectiveStrength;
    final invX1 = 1.0 / (1.0 + p1);
    final invY1 = 1.0 / (1.0 + p1 * 0.55);

    final gx1 = (worldTap.dx + camWorldX * p1) * invX1;
    final gy1 =
        (worldTap.dy - _downZ * focalScalePx + camWorldY * p1 * 0.55) * invY1;
    final (xAtZ1, yAtZ1) = screenToGrid(Offset(gx1, gy1));

    var dirX = groundX - xAtZ1;
    var dirY = groundY - yAtZ1;
    var dirZ = -1.0;
    final len = math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ);
    if (len > 1e-7) {
      dirX /= len;
      dirY /= len;
      dirZ /= len;
    }

    return Ray3D(
      ox: groundX - dirX * cameraDistance,
      oy: groundY - dirY * cameraDistance,
      oz: -dirZ * cameraDistance,
      dx: dirX,
      dy: dirY,
      dz: dirZ,
    );
  }
}
