import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Standardized quality tiers for declarative scene and rendering scaling.
enum GraphicsQualityTier(final int rank) {
  /// Maximum battery efficiency and minimum GPU fillrate.
  low(0),

  /// Balanced mobile/laptop preset with modest shadows and post-processing.
  medium(1),

  /// Full-fidelity default preset for modern desktop and flagship mobile GPUs.
  high(2),

  /// Supersampled high-density preset with extended LOD and particle density.
  ultra(3),

  /// User-customized [GraphicsProfile] evaluated against
  /// [GraphicsSettingsController.customBaseTier] for tier-gated components.
  custom(2);

  /// Returns `true` when this tier satisfies [minimumTier].
  bool meetsMinimum(GraphicsQualityTier minimumTier) =>
      rank >= minimumTier.rank;
}

/// Immutable graphics configuration snapshot controlling resolution scaling,
/// HiDPI caps, shadows, post-processing, particle density, and scene LOD bias.
@immutable
class const GraphicsProfile({
  this.renderScale = 1.0,
  this.maxDevicePixelRatio = 3.0,
  this.shadowsEnabled = true,
  this.shadowOpacityScale = 1.0,
  this.postProcessEnabled = true,
  this.auxiliaryPassScale = 0.75,
  this.particleDensity = 1.0,
  this.lodBias = 0.0,
  this.ambientMotionEnabled = true,
  this.antiAliasing = true,
}) {
  /// Internal world render resolution multiplier (`0.25 .. 2.5`).
  final double renderScale;

  /// Upper bound applied to hardware `FlutterView.devicePixelRatio` so extreme
  /// `3.0x–4.0x` Retina/mobile displays do not exhaust fillrate on lower tiers.
  final double maxDevicePixelRatio;

  /// Whether 2D/3D cast shadows (`Shadow3DDecorator`, `BatchMeshRenderer3D`)
  /// are rendered.
  final bool shadowsEnabled;

  /// Global opacity multiplier (`0.0 .. 1.0`) applied to cast shadows.
  final double shadowOpacityScale;

  /// Whether camera and scene `PostProcessPipeline` effects are active.
  final bool postProcessEnabled;

  /// Resolution multiplier (`0.125 .. 1.0`) for auxiliary bloom/blur passes.
  final double auxiliaryPassScale;

  /// Global spawn-rate and burst-count multiplier (`0.0 .. 2.0`) for particles.
  final double particleDensity;

  /// Additive bias (`-1.0 .. +1.0`) shifting `HasSceneLod` and `MeshLodChain3D`
  /// selection thresholds (`< 0` favors lower-poly LODs earlier; `> 0` holds
  /// high-detail geometry further out).
  final double lodBias;

  /// Whether optional ambient motion (swaying foliage, subtle props) is active.
  final bool ambientMotionEnabled;

  /// Whether anti-aliased edges and smooth upscale filtering are enabled.
  final bool antiAliasing;

  /// Battery-friendly preset for integrated/older mobile GPUs.
  static const GraphicsProfile low = GraphicsProfile(
    renderScale: 0.65,
    maxDevicePixelRatio: 1.5,
    shadowsEnabled: false,
    shadowOpacityScale: 0.0,
    postProcessEnabled: false,
    auxiliaryPassScale: 0.25,
    particleDensity: 0.35,
    lodBias: -0.45,
    ambientMotionEnabled: false,
    antiAliasing: false,
  );

  /// Balanced preset for mid-range mobile and ultrabook displays.
  static const GraphicsProfile medium = GraphicsProfile(
    renderScale: 0.85,
    maxDevicePixelRatio: 2.0,
    shadowOpacityScale: 0.75,
    auxiliaryPassScale: 0.5,
    particleDensity: 0.65,
    lodBias: -0.15,
  );

  /// Crisp native-resolution preset for desktop and modern ProMotion devices.
  static const GraphicsProfile high = GraphicsProfile(
    maxDevicePixelRatio: 2.5,
  );

  /// Supersampled showcase preset with boosted LOD retention and particles.
  static const GraphicsProfile ultra = GraphicsProfile(
    renderScale: 1.25,
    maxDevicePixelRatio: 3.5,
    auxiliaryPassScale: 1.0,
    particleDensity: 1.35,
    lodBias: 0.35,
  );

  /// Returns the canonical preset for [tier] (`high` for `custom`).
  static GraphicsProfile forTier(GraphicsQualityTier tier) {
    return switch (tier) {
      GraphicsQualityTier.low => low,
      GraphicsQualityTier.medium => medium,
      GraphicsQualityTier.high => high,
      GraphicsQualityTier.ultra => ultra,
      GraphicsQualityTier.custom => high,
    };
  }

  /// Creates a modified copy of this profile.
  GraphicsProfile copyWith({
    double? renderScale,
    double? maxDevicePixelRatio,
    bool? shadowsEnabled,
    double? shadowOpacityScale,
    bool? postProcessEnabled,
    double? auxiliaryPassScale,
    double? particleDensity,
    double? lodBias,
    bool? ambientMotionEnabled,
    bool? antiAliasing,
  }) {
    return GraphicsProfile(
      renderScale: renderScale ?? this.renderScale,
      maxDevicePixelRatio: maxDevicePixelRatio ?? this.maxDevicePixelRatio,
      shadowsEnabled: shadowsEnabled ?? this.shadowsEnabled,
      shadowOpacityScale: shadowOpacityScale ?? this.shadowOpacityScale,
      postProcessEnabled: postProcessEnabled ?? this.postProcessEnabled,
      auxiliaryPassScale: auxiliaryPassScale ?? this.auxiliaryPassScale,
      particleDensity: particleDensity ?? this.particleDensity,
      lodBias: lodBias ?? this.lodBias,
      ambientMotionEnabled: ambientMotionEnabled ?? this.ambientMotionEnabled,
      antiAliasing: antiAliasing ?? this.antiAliasing,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is GraphicsProfile &&
        other.renderScale == renderScale &&
        other.maxDevicePixelRatio == maxDevicePixelRatio &&
        other.shadowsEnabled == shadowsEnabled &&
        other.shadowOpacityScale == shadowOpacityScale &&
        other.postProcessEnabled == postProcessEnabled &&
        other.auxiliaryPassScale == auxiliaryPassScale &&
        other.particleDensity == particleDensity &&
        other.lodBias == lodBias &&
        other.ambientMotionEnabled == ambientMotionEnabled &&
        other.antiAliasing == antiAliasing;
  }

  @override
  int get hashCode => Object.hash(
    renderScale,
    maxDevicePixelRatio,
    shadowsEnabled,
    shadowOpacityScale,
    postProcessEnabled,
    auxiliaryPassScale,
    particleDensity,
    lodBias,
    ambientMotionEnabled,
    antiAliasing,
  );
}

/// Hysteresis-driven Dynamic Resolution & Particle Scaling (DRS) governor.
///
/// Observes CPU/GPU frame durations relative to the active target frame budget
/// and smoothly steps down [dynamicRenderScaleMultiplier] and
/// [dynamicParticleMultiplier] during sustained load spikes, restoring them
/// once headroom stabilizes.
class DynamicQualityGovernor({
  var bool enabled = false,
  var double minRenderScale = 0.60,
  var double maxRenderScale = 1.0,
  var double minParticleScale = 0.45,
  var double scaleStepDown = 0.10,
  var double scaleStepUp = 0.05,
  var double highWatermarkRatio = 0.92,
  var double lowWatermarkRatio = 0.60,
  var int overBudgetFramesThreshold = 8,
  var int underBudgetFramesThreshold = 45,
  var double cooldownSeconds = 1.5,
}) {
  double _renderScaleMultiplier = 1.0;
  double _particleMultiplier = 1.0;
  int _overBudgetStreak = 0;
  int _underBudgetStreak = 0;
  double _cooldownRemaining = 0.0;
  int _adjustmentCount = 0;

  /// Current dynamic resolution multiplier in
  /// `[minRenderScale .. maxRenderScale]`.
  double get dynamicRenderScaleMultiplier => _renderScaleMultiplier;

  /// Current dynamic particle density multiplier in
  /// `[minParticleScale .. 1.0]`.
  double get dynamicParticleMultiplier => _particleMultiplier;

  /// Total number of upward or downward DRS steps applied since creation/reset.
  int get adjustmentCount => _adjustmentCount;

  /// Remaining cooldown time (in seconds) before another DRS step may trigger.
  double get cooldownRemainingSeconds => _cooldownRemaining;

  /// Resets dynamic multipliers back to `1.0` and clears streak counters.
  void reset() {
    _renderScaleMultiplier = maxRenderScale.clamp(minRenderScale, 2.0);
    _particleMultiplier = 1.0;
    _overBudgetStreak = 0;
    _underBudgetStreak = 0;
    _cooldownRemaining = 0.0;
  }

  /// Feeds a single frame measurement into the governor and returns `true`
  /// when dynamic scaling multipliers changed.
  bool observeFrame({
    required double frameTimeMs,
    required double targetBudgetMs,
    required double dtSeconds,
  }) {
    if (!enabled || targetBudgetMs <= 0.0 || frameTimeMs <= 0.0) {
      return false;
    }
    if (_cooldownRemaining > 0.0) {
      _cooldownRemaining = math.max(0.0, _cooldownRemaining - dtSeconds);
    }

    final ratio = frameTimeMs / targetBudgetMs;
    if (ratio > highWatermarkRatio) {
      _overBudgetStreak++;
      _underBudgetStreak = 0;
      if (_cooldownRemaining <= 0.0 &&
          _overBudgetStreak >= overBudgetFramesThreshold) {
        _overBudgetStreak = 0;
        final nextScale = math.max(
          minRenderScale,
          _renderScaleMultiplier - scaleStepDown,
        );
        final nextParticles = math.max(
          minParticleScale,
          _particleMultiplier - scaleStepDown * 1.2,
        );
        if ((nextScale - _renderScaleMultiplier).abs() > 1e-4 ||
            (nextParticles - _particleMultiplier).abs() > 1e-4) {
          _renderScaleMultiplier = nextScale;
          _particleMultiplier = nextParticles;
          _cooldownRemaining = cooldownSeconds;
          _adjustmentCount++;
          return true;
        }
      }
    } else if (ratio < lowWatermarkRatio) {
      _underBudgetStreak++;
      _overBudgetStreak = 0;
      if (_cooldownRemaining <= 0.0 &&
          _underBudgetStreak >= underBudgetFramesThreshold) {
        _underBudgetStreak = 0;
        final nextScale = math.min(
          maxRenderScale,
          _renderScaleMultiplier + scaleStepUp,
        );
        final nextParticles = math.min(
          1.0,
          _particleMultiplier + scaleStepUp * 1.2,
        );
        if ((nextScale - _renderScaleMultiplier).abs() > 1e-4 ||
            (nextParticles - _particleMultiplier).abs() > 1e-4) {
          _renderScaleMultiplier = nextScale;
          _particleMultiplier = nextParticles;
          _cooldownRemaining = cooldownSeconds;
          _adjustmentCount++;
          return true;
        }
      }
    } else {
      _overBudgetStreak = 0;
      _underBudgetStreak = 0;
    }
    return false;
  }
}

/// Reactive controller managing [GraphicsQualityTier], [GraphicsProfile], and
/// [DynamicQualityGovernor] on `FlameGame.graphics`.
class GraphicsSettingsController({
  GraphicsQualityTier initialTier = GraphicsQualityTier.high,
  GraphicsProfile? customProfile,
  DynamicQualityGovernor? governor,
}) extends ChangeNotifier {
  GraphicsQualityTier _tier = initialTier;
  GraphicsQualityTier _customBaseTier = GraphicsQualityTier.high;
  GraphicsProfile _profile =
      customProfile ?? GraphicsProfile.forTier(initialTier);
  int _version = 0;

  /// Dynamic resolution & particle density governor bound to this controller.
  final DynamicQualityGovernor governor = governor ?? DynamicQualityGovernor();

  /// Monotonically increasing state version incremented on every tier, profile,
  /// or DRS change.
  int get version => _version;

  /// Active quality tier.
  GraphicsQualityTier get tier => _tier;

  /// Equivalent comparison tier used when [tier] is
  /// [GraphicsQualityTier.custom].
  GraphicsQualityTier get customBaseTier => _customBaseTier;

  /// Active base [GraphicsProfile] before [governor] multipliers.
  GraphicsProfile get profile => _profile;

  /// Effective comparison tier (`customBaseTier` when `tier == custom`).
  GraphicsQualityTier get effectiveComparisonTier =>
      _tier == GraphicsQualityTier.custom ? _customBaseTier : _tier;

  /// Returns `true` when [requiredTier] is `null` or satisfied by the active
  /// quality tier.
  bool meetsTier(GraphicsQualityTier? requiredTier) {
    if (requiredTier == null) {
      return true;
    }
    return effectiveComparisonTier.meetsMinimum(requiredTier);
  }

  /// Effective world render scale combining [GraphicsProfile.renderScale] and
  /// [DynamicQualityGovernor.dynamicRenderScaleMultiplier].
  double get effectiveRenderScale {
    final drs = governor.enabled ? governor.dynamicRenderScaleMultiplier : 1.0;
    return (_profile.renderScale * drs).clamp(0.25, 2.5);
  }

  /// Effective particle spawn multiplier combining
  /// [GraphicsProfile.particleDensity] and
  /// [DynamicQualityGovernor.dynamicParticleMultiplier].
  double get effectiveParticleDensity {
    final drs = governor.enabled ? governor.dynamicParticleMultiplier : 1.0;
    return (_profile.particleDensity * drs).clamp(0.0, 2.0);
  }

  /// Upper cap applied to hardware `devicePixelRatio`.
  double get effectiveMaxDevicePixelRatio => _profile.maxDevicePixelRatio;

  /// Whether cast shadows are enabled under the active profile.
  bool get effectiveShadowsEnabled => _profile.shadowsEnabled;

  /// Global shadow opacity multiplier (`0.0` when shadows are disabled).
  double get effectiveShadowOpacityScale =>
      _profile.shadowsEnabled ? _profile.shadowOpacityScale : 0.0;

  /// Whether post-processing stages are globally enabled.
  bool get effectivePostProcessEnabled => _profile.postProcessEnabled;

  /// Resolution multiplier for auxiliary post-processing passes.
  double get effectiveAuxiliaryPassScale => _profile.auxiliaryPassScale;

  /// Additive LOD threshold bias.
  double get effectiveLodBias => _profile.lodBias;

  /// Whether ambient decorative motion is enabled.
  bool get effectiveAmbientMotionEnabled => _profile.ambientMotionEnabled;

  /// Whether anti-aliasing is enabled.
  bool get effectiveAntiAliasing => _profile.antiAliasing;

  /// Switches to a built-in [nextTier] preset and notifies listeners if
  /// changed.
  void setTier(GraphicsQualityTier nextTier) {
    final nextProfile = nextTier == GraphicsQualityTier.custom
        ? _profile
        : GraphicsProfile.forTier(nextTier);
    if (_tier == nextTier && _profile == nextProfile) {
      return;
    }
    _tier = nextTier;
    _profile = nextProfile;
    governor.reset();
    _version++;
    notifyListeners();
  }

  /// Applies an explicit [customProfile] under [GraphicsQualityTier.custom].
  void setCustomProfile(
    GraphicsProfile customProfile, {
    GraphicsQualityTier baseTier = GraphicsQualityTier.high,
  }) {
    if (_tier == GraphicsQualityTier.custom &&
        _customBaseTier == baseTier &&
        _profile == customProfile) {
      return;
    }
    _tier = GraphicsQualityTier.custom;
    _customBaseTier = baseTier;
    _profile = customProfile;
    governor.reset();
    _version++;
    notifyListeners();
  }

  /// Feeds a measured frame duration into [governor] and notifies listeners
  /// when dynamic scaling multipliers adjust.
  bool recordFrameSample({
    required double frameTimeMs,
    required double targetBudgetMs,
    required double dtSeconds,
  }) {
    final changed = governor.observeFrame(
      frameTimeMs: frameTimeMs,
      targetBudgetMs: targetBudgetMs,
      dtSeconds: dtSeconds,
    );
    if (changed) {
      _version++;
      notifyListeners();
    }
    return changed;
  }
}
