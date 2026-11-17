import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/src/canvas3d/primitives_3d.dart';
import 'package:flame/src/game/game.dart';

/// 3D projection mode for [CameraRig3D].
enum CameraProjectionMode3D() {
  /// Isometric / dimetric orthonormal projection with subtle height parallax
  /// (default).
  axonometric,

  /// True pinhole perspective projection (`1 / camZ` foreshortening, true
  /// vanishing points, and Sutherland–Hodgman near-plane clipping in
  /// `BatchMeshRenderer3D`).
  perspective,
}

/// Orthonormal 3D view/projection camera rig for isometric, dimetric, and
/// true perspective 3D worlds rendered onto Flutter's 2D `Canvas`.
///
/// At rest (`orbitYawDeltaRad == 0`, `pitchDeltaRad == 0`), the orthonormal
/// basis reproduces exact `2:1` isometric projection. On top of that the rig
/// offers a smooth elevation tilt and azimuth turn of every drawn object, a
/// true pinhole [CameraProjectionMode3D.perspective] with configurable
/// [fovYRad] / [cameraDistance] / [nearClip], and 2D-to-3D ray unprojection
/// ([unprojectWorldRay]).
///
/// ## Axonometric convention: anchors stay on the lattice, deltas tilt objects
///
/// In [CameraProjectionMode3D.axonometric] every drawn object has a ground
/// *anchor* `(worldX, worldY)`. Anchors always project through the fixed
/// `2:1` lattice of [gridToScreen], whatever [orbitYawDeltaRad] and
/// [pitchDeltaRad] are. The deltas only rotate the camera basis that
/// [projectAnchored] applies to offsets *relative to the anchor* (and
/// [pitchDeltaRad] also changes how many pixels one unit of height is worth).
///
/// So each object turns and tilts in place about its own anchor. The scene as
/// a whole does not orbit and the ground lattice does not move: with non-zero
/// deltas this is a tilt of every object, not an orbit of the camera. It also
/// means the projection is not a function of the world point alone. One world
/// point reached as "anchor A plus offset" and as "anchor B plus offset" lands
/// on two different pixels, a long mesh swings about its anchor while the
/// lattice under it stays put, and [projectWorldPoint], which treats a point
/// as its own anchor, does not react to [orbitYawDeltaRad] at all. Keep the
/// deltas small (the rig clamps them, see [update]) and use them as a sway.
///
/// For a camera that really orbits the scene, use
/// [CameraProjectionMode3D.perspective]: there every world point goes through
/// one pinhole camera, the deltas turn the whole scene about the look-at
/// target, and [unprojectWorldRay] is the exact inverse of
/// [projectWorldPoint].
///
/// The rig calls `Game.notifyVisualMutation` whenever a property that changes
/// the picture really changes, so on-demand rendering repaints.
class CameraRig3D({
  this.cellHalfW = 44.0,
  this.cellHalfH = 22.0,
  this.groundOriginY = -18.0,
  this.baseAzimuthRad = math.pi * 0.25,
  this.baseElevationRad = math.pi / 6.0,
  CameraProjectionMode3D projectionMode = CameraProjectionMode3D.axonometric,
  double cameraDistance = 18.0,
  double? fovYRad,
  this.referenceHalfHeightPx = 360.0,
  double nearClip = 0.15,
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

  /// Reference viewport half-height in pixels used when [fovYRad] is set.
  final double referenceHalfHeightPx;

  CameraProjectionMode3D _projectionMode = projectionMode;
  double _cameraDistance = cameraDistance;
  double? _fovYRad = fovYRad;
  double _nearClip = nearClip;

  /// Active 3D projection mode (`axonometric` or `perspective`).
  CameraProjectionMode3D get projectionMode => _projectionMode;
  set projectionMode(CameraProjectionMode3D value) {
    if (_projectionMode != value) {
      _projectionMode = value;
      _basisVersion++;
      Game.notifyVisualMutation();
    }
  }

  /// Distance in 3D world units from the look-at target along `view` to the
  /// perspective pinhole eye (`> nearClip`).
  double get cameraDistance => _cameraDistance;
  set cameraDistance(double value) {
    final clamped = math.max(_nearClip + 0.05, value);
    if ((_cameraDistance - clamped).abs() > 1e-6) {
      _cameraDistance = clamped;
      _basisVersion++;
      Game.notifyVisualMutation();
    }
  }

  /// Optional vertical field-of-view angle in radians for
  /// [CameraProjectionMode3D.perspective]. When `null`, focal length matches
  /// `cameraDistance * focalScalePx` so geometry at the look-at target matches
  /// `axonometric` scale 1:1.
  double? get fovYRad => _fovYRad;
  set fovYRad(double? value) {
    if (_fovYRad != value) {
      _fovYRad = value;
      _basisVersion++;
      Game.notifyVisualMutation();
    }
  }

  /// Near-plane clipping distance (`> 0.01`) in front of the perspective eye.
  double get nearClip => _nearClip;
  set nearClip(double value) {
    final clamped = math.max(0.01, value);
    if ((_nearClip - clamped).abs() > 1e-6) {
      _nearClip = clamped;
      if (_cameraDistance < _nearClip + 0.05) {
        _cameraDistance = _nearClip + 0.05;
      }
      _basisVersion++;
      Game.notifyVisualMutation();
    }
  }

  /// Effective pinhole focal length in pixels for
  /// [CameraProjectionMode3D.perspective].
  double get perspectiveFocalLengthPx {
    final fov = _fovYRad;
    if (fov != null) {
      final halfFov = (fov * 0.5).clamp(0.05, 1.45);
      return (referenceHalfHeightPx / math.tan(halfFov)) * camZoom;
    }
    return _cameraDistance * focalScalePx;
  }

  /// Focal scale (`cellHalfW * sqrt(2)`) mapping unit 3D basis to pixels.
  late final double focalScalePx = cellHalfW * math.sqrt2;

  /// Largest azimuth delta in radians, either way, that the rig accepts.
  static const double maxOrbitYawDeltaRad = 0.45;

  /// Lowest elevation delta in radians that the rig accepts.
  static const double minPitchDeltaRad = -0.24;

  /// Highest elevation delta in radians that the rig accepts.
  static const double maxPitchDeltaRad = 0.28;

  double _camWorldX = 0.0;
  late double _camWorldY = groundOriginY;
  double _camZoom = 1.0;
  double _orbitYawDeltaRad = 0.0;
  double _pitchDeltaRad = 0.0;

  /// Current 2D camera look-at X in world coordinates.
  double get camWorldX => _camWorldX;
  set camWorldX(double value) {
    if (_camWorldX != value) {
      _camWorldX = value;
      Game.notifyVisualMutation();
    }
  }

  /// Current 2D camera look-at Y in world coordinates.
  double get camWorldY => _camWorldY;
  set camWorldY(double value) {
    if (_camWorldY != value) {
      _camWorldY = value;
      Game.notifyVisualMutation();
    }
  }

  /// Current 2D camera zoom factor: how many screen pixels one canvas unit of
  /// the projected output covers.
  double get camZoom => _camZoom;
  set camZoom(double value) {
    if (_camZoom != value) {
      _camZoom = value;
      Game.notifyVisualMutation();
    }
  }

  /// Azimuth offset around Z in radians, clamped to
  /// `+-`[maxOrbitYawDeltaRad]. See the class documentation for what it turns
  /// in each projection mode.
  double get orbitYawDeltaRad => _orbitYawDeltaRad;
  set orbitYawDeltaRad(double value) {
    if (_setAngleDeltas(value, _pitchDeltaRad)) {
      Game.notifyVisualMutation();
    }
  }

  /// Elevation offset in radians, clamped to
  /// `[`[minPitchDeltaRad]` .. `[maxPitchDeltaRad]`]`. The resulting elevation
  /// (`baseElevationRad + pitchDeltaRad`) is further kept within
  /// `[0.18 .. 1.15]` radians.
  double get pitchDeltaRad => _pitchDeltaRad;
  set pitchDeltaRad(double value) {
    if (_setAngleDeltas(_orbitYawDeltaRad, value)) {
      Game.notifyVisualMutation();
    }
  }

  bool _setAngleDeltas(double orbitYawDelta, double pitchDelta) {
    final clampedYaw = orbitYawDelta.clamp(
      -maxOrbitYawDeltaRad,
      maxOrbitYawDeltaRad,
    );
    final clampedPitch = pitchDelta.clamp(minPitchDeltaRad, maxPitchDeltaRad);
    if (clampedYaw == _orbitYawDeltaRad && clampedPitch == _pitchDeltaRad) {
      return false;
    }
    _orbitYawDeltaRad = clampedYaw;
    _pitchDeltaRad = clampedPitch;
    _recomputeBasis();
    return true;
  }

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
  /// orthonormal basis (and bumping [basisVersion]) only when angles change.
  ///
  /// [orbitYawDelta] is clamped to `+-`[maxOrbitYawDeltaRad] and [pitchDelta]
  /// to `[`[minPitchDeltaRad]` .. `[maxPitchDeltaRad]`]`.
  void update({
    required double camX,
    required double camY,
    required double zoom,
    double orbitYawDelta = 0.0,
    double pitchDelta = 0.0,
  }) {
    var changed = false;
    if (_camWorldX != camX) {
      _camWorldX = camX;
      changed = true;
    }
    if (_camWorldY != camY) {
      _camWorldY = camY;
      changed = true;
    }
    if (_camZoom != zoom) {
      _camZoom = zoom;
      changed = true;
    }
    if (_setAngleDeltas(orbitYawDelta, pitchDelta)) {
      changed = true;
    }
    if (changed) {
      Game.notifyVisualMutation();
    }
  }

  void _recomputeBasis() {
    final az = baseAzimuthRad + _orbitYawDeltaRad;
    final el = (baseElevationRad + _pitchDeltaRad).clamp(0.18, 1.15);
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

  /// Transforms an absolute 3D world point `(wx, wy, wz)` into pinhole
  /// camera-space `(camX, camY, camZ)` where `+camX` is screen-right, `+camY`
  /// is screen-down, and `camZ > 0` is forward distance in front of the
  /// perspective eye (`camZ == cameraDistance` at the look-at target).
  (double camX, double camY, double camZ) worldToCameraSpace(
    double wx,
    double wy,
    double wz,
  ) {
    final (targetX, targetY) = screenToGrid(Offset(camWorldX, camWorldY));
    final dx = wx - targetX;
    final dy = wy - targetY;
    final dz = wz;
    final camX = dx * _rightX + dy * _rightY;
    final camY = dx * _downX + dy * _downY + dz * _downZ;
    final camZ = _cameraDistance - (dx * _viewX + dy * _viewY + dz * _viewZ);
    return (camX, camY, camZ);
  }

  /// Projects a pinhole camera-space point `(camX, camY, camZ)` onto the 2D
  /// canvas relative to [canvasOrigin].
  (double sx, double sy) projectCameraSpace(
    double camX,
    double camY,
    double camZ, {
    Offset canvasOrigin = Offset.zero,
  }) {
    final safeZ = math.max(_nearClip, camZ);
    final invZ = perspectiveFocalLengthPx / safeZ;
    return (
      camWorldX + camX * invZ - canvasOrigin.dx,
      camWorldY + camY * invZ - canvasOrigin.dy,
    );
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
    if (_projectionMode == CameraProjectionMode3D.perspective) {
      final (ax, ay) = screenToGrid(anchorWorld);
      final (camX, camY, camZ) = worldToCameraSpace(ax + rx, ay + ry, rz);
      return projectCameraSpace(camX, camY, camZ, canvasOrigin: canvasOrigin);
    }
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
    if (_projectionMode == CameraProjectionMode3D.perspective) {
      final (camX, camY, camZ) = worldToCameraSpace(wx, wy, wz);
      final (sx, sy) = projectCameraSpace(camX, camY, camZ);
      return Offset(sx, sy);
    }
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

  /// Unprojects a 2D world tap [worldTap] into a [Ray3D].
  ///
  /// In [CameraProjectionMode3D.perspective] the ray leaves the pinhole eye
  /// and is the exact inverse of [projectWorldPoint]; [anchorWorld] is not
  /// needed and is ignored.
  ///
  /// In [CameraProjectionMode3D.axonometric] the answer depends on what the
  /// tapped pixel shows (see the class documentation):
  ///
  /// - Without [anchorWorld] the ray inverts [projectWorldPoint]: it runs
  ///   through the world points that, taken as their own anchors, are drawn
  ///   at [worldTap]. It follows [pitchDeltaRad]; [orbitYawDeltaRad] does not
  ///   move such points and so does not move this ray.
  /// - With [anchorWorld] (the [gridToScreen] position of an object's anchor)
  ///   the ray inverts [projectAnchored] for that anchor: it runs through the
  ///   points of that object that are drawn at [worldTap], following both
  ///   deltas. Use it to pick an object that was drawn about that anchor.
  ///
  /// The axonometric height parallax is not a straight-line projection, so
  /// no ray can invert it at every height: this one is exact at `z = 0` and
  /// `z = 1` and drifts by roughly `0.6 * z * (z - 1)` pixels elsewhere at
  /// rest zoom (about a pixel at `z = 2`).
  ///
  /// The ray starts [cameraDistance] (default: this rig's distance) before the
  /// ground point along its direction.
  Ray3D unprojectWorldRay(
    Offset worldTap, {
    double? cameraDistance,
    Offset? anchorWorld,
  }) {
    final effDist = cameraDistance ?? _cameraDistance;
    if (_projectionMode == CameraProjectionMode3D.perspective) {
      final (targetX, targetY) = screenToGrid(Offset(camWorldX, camWorldY));
      final ox = targetX + _viewX * effDist;
      final oy = targetY + _viewY * effDist;
      final oz = _viewZ * effDist;

      final f = perspectiveFocalLengthPx;
      final u = (worldTap.dx - camWorldX) / f;
      final v = (worldTap.dy - camWorldY) / f;

      var dirX = u * _rightX + v * _downX - _viewX;
      var dirY = u * _rightY + v * _downY - _viewY;
      var dirZ = v * _downZ - _viewZ;
      final len = math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ);
      if (len > 1e-7) {
        final inv = 1.0 / len;
        dirX *= inv;
        dirY *= inv;
        dirZ *= inv;
      }
      return Ray3D(ox: ox, oy: oy, oz: oz, dx: dirX, dy: dirY, dz: dirZ);
    }

    // Where a point at height 1 must sit, before the height parallax and
    // lift are applied, to be drawn at the tap.
    final p1 = perspectiveStrength;
    final invX1 = 1.0 / (1.0 + p1);
    final invY1 = 1.0 / (1.0 + p1 * 0.55);
    final gx1 = (worldTap.dx + camWorldX * p1) * invX1;
    final gy1 =
        (worldTap.dy - _downZ * focalScalePx + camWorldY * p1 * 0.55) * invY1;

    final double groundX;
    final double groundY;
    final double xAtZ1;
    final double yAtZ1;
    if (anchorWorld != null) {
      // Solve the rotated camera basis for the offsets from the anchor.
      final (ax, ay) = screenToGrid(anchorWorld);
      final invDet =
          1.0 / ((_rightX * _downY - _rightY * _downX) * focalScalePx);
      final u0 = worldTap.dx - anchorWorld.dx;
      final v0 = worldTap.dy - anchorWorld.dy;
      groundX = ax + (u0 * _downY - _rightY * v0) * invDet;
      groundY = ay + (_rightX * v0 - _downX * u0) * invDet;
      final u1 = gx1 - anchorWorld.dx;
      final v1 = gy1 - anchorWorld.dy;
      xAtZ1 = ax + (u1 * _downY - _rightY * v1) * invDet;
      yAtZ1 = ay + (_rightX * v1 - _downX * u1) * invDet;
    } else {
      (groundX, groundY) = screenToGrid(worldTap);
      (xAtZ1, yAtZ1) = screenToGrid(Offset(gx1, gy1));
    }

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
      ox: groundX - dirX * effDist,
      oy: groundY - dirY * effDist,
      oz: -dirZ * effDist,
      dx: dirX,
      dy: dirY,
      dz: dirZ,
    );
  }
}
