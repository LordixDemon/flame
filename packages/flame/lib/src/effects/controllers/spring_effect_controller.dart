import 'dart:math' as math;

import 'package:flame/src/effects/controllers/effect_controller.dart';

/// Analytical physically-based damped harmonic oscillator [EffectController].
///
/// Solves `m * x'' + c * x' + k * (x - 1) = 0` with `x(0) = 0` and
/// `x'(0) = initialVelocity` in closed form (supporting underdamped overshoot
/// `progress > 1`, critically damped, and overdamped regimes) with zero
/// per-step drift and deterministic settle [duration].
class SpringEffectController({
  /// Simulated mass `m`.
  final double mass = 1.0,

  /// Hooke stiffness `k`.
  final double stiffness = 220.0,

  /// Viscous damping coefficient `c`.
  final double damping = 16.0,

  /// Initial normalized velocity `dx/dt` at `t = 0`.
  final double initialVelocity = 0.0,

  /// Settling threshold within `1.0` where motion snaps to completion.
  final double settleEpsilon = 1e-3,
}) extends EffectController {
  this
    : assert(mass > 0, 'mass must be positive: $mass'),
      assert(stiffness > 0, 'stiffness must be positive: $stiffness'),
      assert(damping > 0, 'damping must be positive: $damping'),
      assert(
        settleEpsilon > 0 && settleEpsilon < 0.25,
        'settleEpsilon must be in (0, 0.25): $settleEpsilon',
      ),
      super.empty() {
    _omega0 = math.sqrt(stiffness / mass);
    _zeta = damping / (2.0 * math.sqrt(stiffness * mass));
    if (_zeta < 1.0 - 1e-6) {
      _omegaD = _omega0 * math.sqrt(1.0 - _zeta * _zeta);
      _bCoeff = (initialVelocity - _zeta * _omega0) / _omegaD;
      _r1 = 0.0;
      _r2 = 0.0;
      _c1 = 0.0;
      _c2 = 0.0;
    } else if (_zeta <= 1.0 + 1e-6) {
      _omegaD = 0.0;
      _bCoeff = initialVelocity - _omega0;
      _r1 = 0.0;
      _r2 = 0.0;
      _c1 = 0.0;
      _c2 = 0.0;
    } else {
      _omegaD = 0.0;
      _bCoeff = 0.0;
      final s = math.sqrt(_zeta * _zeta - 1.0);
      _r1 = -_omega0 * (_zeta - s);
      _r2 = -_omega0 * (_zeta + s);
      _c1 = (initialVelocity + _r2) / (_r1 - _r2);
      _c2 = -1.0 - _c1;
    }
    _duration = _computeSettleDuration();
  }

  /// Creates an underdamped spring with lively overshoot (`dampingRatio < 1`).
  factory SpringEffectController.bouncy({
    double mass = 1.0,
    double stiffness = 260.0,
    double dampingRatio = 0.48,
    double initialVelocity = 0.0,
    double settleEpsilon = 1e-3,
  }) {
    assert(dampingRatio > 0, 'dampingRatio must be positive: $dampingRatio');
    return SpringEffectController(
      mass: mass,
      stiffness: stiffness,
      damping: 2.0 * dampingRatio * math.sqrt(stiffness * mass),
      initialVelocity: initialVelocity,
      settleEpsilon: settleEpsilon,
    );
  }

  /// Creates a responsive low-overshoot tactile UI/game spring.
  factory SpringEffectController.snappy({
    double mass = 1.0,
    double stiffness = 380.0,
    double dampingRatio = 0.72,
    double initialVelocity = 0.0,
    double settleEpsilon = 1e-3,
  }) {
    assert(dampingRatio > 0, 'dampingRatio must be positive: $dampingRatio');
    return SpringEffectController(
      mass: mass,
      stiffness: stiffness,
      damping: 2.0 * dampingRatio * math.sqrt(stiffness * mass),
      initialVelocity: initialVelocity,
      settleEpsilon: settleEpsilon,
    );
  }

  /// Creates a fastest non-oscillating (`dampingRatio == 1.0`) spring.
  factory SpringEffectController.criticallyDamped({
    double mass = 1.0,
    double stiffness = 300.0,
    double initialVelocity = 0.0,
    double settleEpsilon = 1e-3,
  }) {
    return SpringEffectController(
      mass: mass,
      stiffness: stiffness,
      damping: 2.0 * math.sqrt(stiffness * mass),
      initialVelocity: initialVelocity,
      settleEpsilon: settleEpsilon,
    );
  }

  late final double _omega0;
  late final double _zeta;
  late final double _omegaD;
  late final double _bCoeff;
  late final double _r1;
  late final double _r2;
  late final double _c1;
  late final double _c2;
  late final double _duration;

  double _elapsed = 0.0;

  /// Dimensionless damping ratio `c / (2 * sqrt(k * m))`.
  double get dampingRatio => _zeta;

  @override
  double get duration => _duration;

  @override
  bool get completed => _elapsed >= _duration;

  @override
  double get progress {
    if (_elapsed <= 0.0) {
      return 0.0;
    }
    if (_elapsed >= _duration) {
      return 1.0;
    }
    return 1.0 + _displacementError(_elapsed);
  }

  double _displacementError(double t) {
    if (_zeta < 1.0 - 1e-6) {
      final env = math.exp(-_zeta * _omega0 * t);
      return env * (-math.cos(_omegaD * t) + _bCoeff * math.sin(_omegaD * t));
    }
    if (_zeta <= 1.0 + 1e-6) {
      return math.exp(-_omega0 * t) * (-1.0 + _bCoeff * t);
    }
    return _c1 * math.exp(_r1 * t) + _c2 * math.exp(_r2 * t);
  }

  double _envelopeAt(double t) {
    if (_zeta < 1.0 - 1e-6) {
      final amp = math.sqrt(1.0 + _bCoeff * _bCoeff);
      return amp * math.exp(-_zeta * _omega0 * t);
    }
    if (_zeta <= 1.0 + 1e-6) {
      final disp = _displacementError(t).abs();
      final vel =
          (math.exp(-_omega0 * t) * (_omega0 + _bCoeff * (1.0 - _omega0 * t)))
              .abs() /
          _omega0;
      return math.max(disp, vel);
    }
    final disp = _displacementError(t).abs();
    final vel =
        (_c1 * _r1 * math.exp(_r1 * t) + _c2 * _r2 * math.exp(_r2 * t)).abs() /
        _omega0;
    return math.max(disp, vel);
  }

  double _computeSettleDuration() {
    var hi = 0.25;
    while (_envelopeAt(hi) > settleEpsilon && hi < 60.0) {
      hi *= 2.0;
    }
    var lo = 0.0;
    for (var i = 0; i < 32; i++) {
      final mid = (lo + hi) * 0.5;
      if (_envelopeAt(mid) <= settleEpsilon) {
        hi = mid;
      } else {
        lo = mid;
      }
    }
    return hi;
  }

  @override
  double advance(double dt) {
    final next = _elapsed + dt;
    if (next >= _duration) {
      final leftover = next - _duration;
      _elapsed = _duration;
      return leftover;
    }
    _elapsed = next;
    return 0.0;
  }

  @override
  double recede(double dt) {
    final next = _elapsed - dt;
    if (next <= 0.0) {
      final leftover = -next;
      _elapsed = 0.0;
      return leftover;
    }
    _elapsed = next;
    return 0.0;
  }

  @override
  void setToStart() {
    _elapsed = 0.0;
  }

  @override
  void setToEnd() {
    _elapsed = _duration;
  }
}
