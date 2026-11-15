import 'dart:math' as math;

/// Secondary-motion 2D inertial spring bone for capes, hair, hanging signs,
/// charms, antennae, and tails.
///
/// Tracks an anchor target in world space and computes damped inertial lag
/// `(offsetX, offsetY)` and angular swing (`swingAngleRad`) with zero heap
/// allocations per frame.
class SpringBone2D({
  this.stiffness = 180.0,
  this.dampingRatio = 0.65,
  this.inertiaScale = 1.0,
  this.maxDisplacement = 36.0,
  this.gravityX = 0.0,
  this.gravityY = 0.0,
  this.length = 24.0,
}) {
  /// Hooke spring stiffness (`> 0`).
  double stiffness;

  /// Damping ratio (`1.0` = critical, `< 1.0` = bouncy/underdamped).
  double dampingRatio;

  /// Multiplier controlling how strongly anchor motion excites the spring.
  double inertiaScale;

  /// Maximum displacement radius from the rest anchor.
  double maxDisplacement;

  /// Constant external force X (e.g. wind).
  double gravityX;

  /// Constant external force Y (e.g. gravity).
  double gravityY;

  /// Reference bone length used to convert displacement into [swingAngleRad].
  double length;

  bool _initialized = false;
  double _prevAnchorX = 0.0;
  double _prevAnchorY = 0.0;
  double _dispX = 0.0;
  double _dispY = 0.0;
  double _velX = 0.0;
  double _velY = 0.0;

  /// Current world/local spring tip offset X from the rest target.
  double get offsetX => _dispX;

  /// Current world/local spring tip offset Y from the rest target.
  double get offsetY => _dispY;

  /// Angular deflection (in radians) derived from [offsetX] and [length].
  double get swingAngleRad => length > 1e-4 ? math.atan2(_dispX, length) : 0.0;

  /// Resets the spring state at `(anchorX, anchorY)`.
  void reset(double anchorX, double anchorY) {
    _initialized = true;
    _prevAnchorX = anchorX;
    _prevAnchorY = anchorY;
    _dispX = 0.0;
    _dispY = 0.0;
    _velX = 0.0;
    _velY = 0.0;
  }

  /// Steps the inertial spring towards `(anchorX, anchorY)` over [dt] seconds.
  void update(double dt, double anchorX, double anchorY) {
    if (!_initialized) {
      reset(anchorX, anchorY);
      return;
    }
    if (dt <= 0.0) {
      return;
    }
    final stepDt = math.min(dt, 1.0 / 20.0);
    final anchorDx = (anchorX - _prevAnchorX) * inertiaScale;
    final anchorDy = (anchorY - _prevAnchorY) * inertiaScale;
    _prevAnchorX = anchorX;
    _prevAnchorY = anchorY;

    // Anchor movement injects opposite relative displacement into the tip.
    _dispX -= anchorDx;
    _dispY -= anchorDy;

    final k = math.max(1.0, stiffness);
    final c = 2.0 * dampingRatio.clamp(0.05, 4.0) * math.sqrt(k);
    final ax = -k * _dispX - c * _velX + gravityX;
    final ay = -k * _dispY - c * _velY + gravityY;

    _velX += ax * stepDt;
    _velY += ay * stepDt;
    _dispX += _velX * stepDt;
    _dispY += _velY * stepDt;

    final distSq = _dispX * _dispX + _dispY * _dispY;
    if (maxDisplacement > 0 && distSq > maxDisplacement * maxDisplacement) {
      final inv = maxDisplacement / math.sqrt(distSq);
      _dispX *= inv;
      _dispY *= inv;
    }
  }
}

/// Secondary-motion 3D inertial spring bone for articulated `canvas3d` props
/// (banners, roofs, tokens, antennae, floating bobbers).
class SpringBone3D({
  this.stiffness = 180.0,
  this.dampingRatio = 0.65,
  this.inertiaScale = 1.0,
  this.maxDisplacement = 1.5,
}) {
  /// Hooke spring stiffness (`> 0`).
  double stiffness;

  /// Damping ratio (`1.0` = critical, `< 1.0` = underdamped).
  double dampingRatio;

  /// Multiplier controlling how strongly anchor motion excites the spring.
  double inertiaScale;

  /// Maximum 3D displacement distance in world units.
  double maxDisplacement;

  bool _initialized = false;
  double _prevX = 0.0;
  double _prevY = 0.0;
  double _prevZ = 0.0;
  double _dx = 0.0;
  double _dy = 0.0;
  double _dz = 0.0;
  double _vx = 0.0;
  double _vy = 0.0;
  double _vz = 0.0;

  /// Current 3D spring displacement X.
  double get offsetX => _dx;

  /// Current 3D spring displacement Y.
  double get offsetY => _dy;

  /// Current 3D spring displacement Z.
  double get offsetZ => _dz;

  /// Resets the 3D spring at `(x, y, z)`.
  void reset(double x, double y, double z) {
    _initialized = true;
    _prevX = x;
    _prevY = y;
    _prevZ = z;
    _dx = 0.0;
    _dy = 0.0;
    _dz = 0.0;
    _vx = 0.0;
    _vy = 0.0;
    _vz = 0.0;
  }

  /// Steps the 3D spring given new anchor `(x, y, z)` over [dt] seconds.
  void update(double dt, double x, double y, double z) {
    if (!_initialized) {
      reset(x, y, z);
      return;
    }
    if (dt <= 0.0) {
      return;
    }
    final stepDt = math.min(dt, 1.0 / 20.0);
    _dx -= (x - _prevX) * inertiaScale;
    _dy -= (y - _prevY) * inertiaScale;
    _dz -= (z - _prevZ) * inertiaScale;
    _prevX = x;
    _prevY = y;
    _prevZ = z;

    final k = math.max(1.0, stiffness);
    final c = 2.0 * dampingRatio.clamp(0.05, 4.0) * math.sqrt(k);
    _vx += (-k * _dx - c * _vx) * stepDt;
    _vy += (-k * _dy - c * _vy) * stepDt;
    _vz += (-k * _dz - c * _vz) * stepDt;
    _dx += _vx * stepDt;
    _dy += _vy * stepDt;
    _dz += _vz * stepDt;

    final d2 = _dx * _dx + _dy * _dy + _dz * _dz;
    if (maxDisplacement > 0 && d2 > maxDisplacement * maxDisplacement) {
      final inv = maxDisplacement / math.sqrt(d2);
      _dx *= inv;
      _dy *= inv;
      _dz *= inv;
    }
  }
}
