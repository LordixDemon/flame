import 'dart:math' as math;
import 'dart:ui';

import 'package:flame/components.dart';
import 'package:flame/game.dart';

/// Discrete level-of-detail tiers ordered from highest visual fidelity to
/// distance-culled.
enum LodLevel(final int detailRank) {
  /// Full-detail geometry, shaders, and sub-animations.
  high(4),

  /// Reduced detail for mid-distance viewing.
  medium(3),

  /// Simplified silhouette for zoomed-out overview cameras.
  low(2),

  /// Minimal flat icon/billboard impostor at extreme distance.
  impostor(1),

  /// Sub-pixel / too small to contribute visually; skipped during render.
  culled(0),
}

/// Screen-space pixel size + camera zoom + `GraphicsProfile.lodBias` level-of-
/// detail selector with hysteresis to prevent LOD boundary popping.
mixin HasSceneLod on PositionComponent {
  /// Minimum projected screen extent (in logical pixels) for [LodLevel.high].
  double highLodMinPixels = 96.0;

  /// Minimum projected screen extent (in logical pixels) for [LodLevel.medium].
  double mediumLodMinPixels = 44.0;

  /// Minimum projected screen extent (in logical pixels) for [LodLevel.low].
  double lowLodMinPixels = 16.0;

  /// Minimum projected screen extent (in logical pixels) for
  /// [LodLevel.impostor]; below this threshold [LodLevel.culled] is selected.
  double impostorLodMinPixels = 4.0;

  /// Fractional hysteresis band (`0.0 .. 0.45`) preventing rapid oscillation
  /// when camera zoom hovers near a pixel threshold.
  double lodHysteresisRatio = 0.12;

  /// Whether [renderTree] automatically skips drawing when [lodLevel] resolves
  /// to [LodLevel.culled].
  bool skipRenderWhenLodCulled = true;

  LodLevel _lodLevel = LodLevel.high;
  double _lastProjectedPixels = 0.0;
  int _lodTransitionCount = 0;

  /// Currently active [LodLevel].
  LodLevel get lodLevel => _lodLevel;

  /// Most recently evaluated screen-space pixel size (biased by `lodBias`).
  double get lastProjectedScreenPixels => _lastProjectedPixels;

  /// Total number of [LodLevel] transitions observed by this component.
  int get lodTransitionCount => _lodTransitionCount;

  /// Hook invoked whenever [lodLevel] transitions from [previous] to [current].
  void onLodChanged(LodLevel previous, LodLevel current) {}

  /// Evaluates and updates [lodLevel] for [cameraZoom] and optional [lodBias]
  /// (`-1.0 .. +1.0`).
  LodLevel evaluateLod({
    required double cameraZoom,
    double lodBias = 0.0,
  }) {
    final extent = math.max(
      (size.x * scale.x).abs(),
      (size.y * scale.y).abs(),
    );
    final effectiveExtent = extent > 0.0 ? extent : 32.0;
    final biasFactor = math.pow(2.0, lodBias.clamp(-2.0, 2.0)).toDouble();
    final px = effectiveExtent * math.max(0.001, cameraZoom) * biasFactor;
    _lastProjectedPixels = px;

    final h = lodHysteresisRatio.clamp(0.0, 0.45);
    final current = _lodLevel;

    double thresholdForUpgrade(double base) => base * (1.0 + h);
    double thresholdForDowngrade(double base) => base * (1.0 - h);

    final highT = current.detailRank >= LodLevel.high.detailRank
        ? thresholdForDowngrade(highLodMinPixels)
        : thresholdForUpgrade(highLodMinPixels);
    final medT = current.detailRank >= LodLevel.medium.detailRank
        ? thresholdForDowngrade(mediumLodMinPixels)
        : thresholdForUpgrade(mediumLodMinPixels);
    final lowT = current.detailRank >= LodLevel.low.detailRank
        ? thresholdForDowngrade(lowLodMinPixels)
        : thresholdForUpgrade(lowLodMinPixels);
    final impT = current.detailRank >= LodLevel.impostor.detailRank
        ? thresholdForDowngrade(impostorLodMinPixels)
        : thresholdForUpgrade(impostorLodMinPixels);

    final LodLevel resolved;
    if (px >= highT) {
      resolved = LodLevel.high;
    } else if (px >= medT) {
      resolved = LodLevel.medium;
    } else if (px >= lowT) {
      resolved = LodLevel.low;
    } else if (px >= impT) {
      resolved = LodLevel.impostor;
    } else {
      resolved = LodLevel.culled;
    }

    if (resolved != current) {
      _lodLevel = resolved;
      _lodTransitionCount++;
      onLodChanged(current, resolved);
    }
    return resolved;
  }

  @override
  void renderTree(Canvas canvas) {
    final camera = CameraComponent.currentCamera;
    if (camera != null) {
      final game = findGame();
      final bias = game is FlameGame ? game.graphics.effectiveLodBias : 0.0;
      final level = evaluateLod(
        cameraZoom: camera.viewfinder.zoom,
        lodBias: bias,
      );
      if (skipRenderWhenLodCulled && level == LodLevel.culled) {
        return;
      }
    }
    super.renderTree(canvas);
  }
}
