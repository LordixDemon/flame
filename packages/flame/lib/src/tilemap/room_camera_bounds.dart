import 'dart:math' as math;
import 'dart:ui';

import 'package:vector_math/vector_math.dart';

/// Camera framing override volume inside a map (e.g. boss room, scenic vista,
/// narrow hallway).
class CameraZone({
  required this.id,
  required this.triggerBounds,
  Rect? clampBounds,
  this.targetZoom,
  this.lockCenter,
  this.priority = 0,
}) {
  final String id;
  final Rect triggerBounds;

  /// Optional custom camera clamping bounds while inside this zone (defaults to
  /// [triggerBounds]).
  final Rect clampBounds = clampBounds ?? triggerBounds;

  /// Optional target camera zoom while inside this zone.
  final double? targetZoom;

  /// Optional fixed world focal point when the camera should lock onto a stage.
  final Vector2? lockCenter;

  /// Higher-priority zones win when overlapping.
  final int priority;
}

/// Smart RPG camera room-bounds solver that:
/// 1. Clamps the camera center so the viewport never leaks outside
///    [roomBounds],
/// 2. **Auto-centers small interiors** along X and/or Y whenever
///    `roomBounds.width <= viewportWorldWidth` or
///    `roomBounds.height <= viewportWorldHeight` (eliminating left/right snap
///    oscillation in small RPG inns/shops!),
/// 3. Smoothly transitions between overlapping [CameraZone]s.
class RoomCameraBounds({
  required this.roomBounds,
  this.smoothingRate = 12.0,
}) {
  Rect roomBounds;
  double smoothingRate;

  final List<CameraZone> _zones = <CameraZone>[];
  final Vector2 _smoothedCenter = Vector2.zero();
  double _smoothedZoom = 1.0;
  bool _primed = false;

  void addZone(CameraZone zone) {
    _zones.add(zone);
    _zones.sort((a, b) => b.priority.compareTo(a.priority));
  }

  bool removeZone(String id) {
    final before = _zones.length;
    _zones.removeWhere((z) => z.id == id);
    return _zones.length != before;
  }

  /// Returns the highest-priority [CameraZone] containing `(worldX, worldY)`,
  /// or `null` if none match.
  CameraZone? activeZoneAt(double worldX, double worldY) {
    final pt = Offset(worldX, worldY);
    for (var i = 0; i < _zones.length; i++) {
      if (_zones[i].triggerBounds.contains(pt)) {
        return _zones[i];
      }
    }
    return null;
  }

  /// Pure clamped camera center for `desiredX`/`desiredY` inside [bounds]
  /// given a camera viewport covering `(viewportWorldWidth,
  /// viewportWorldHeight)` in world units, written into [outCenter] with `0`
  /// heap allocations.
  static void clampOrCenter({
    required Rect bounds,
    required double desiredX,
    required double desiredY,
    required double viewportWorldWidth,
    required double viewportWorldHeight,
    required Vector2 outCenter,
  }) {
    final halfW = viewportWorldWidth * 0.5;
    final halfH = viewportWorldHeight * 0.5;

    final double cx;
    if (bounds.width <= viewportWorldWidth) {
      cx = bounds.left + bounds.width * 0.5;
    } else {
      cx = desiredX.clamp(bounds.left + halfW, bounds.right - halfW);
    }

    final double cy;
    if (bounds.height <= viewportWorldHeight) {
      cy = bounds.top + bounds.height * 0.5;
    } else {
      cy = desiredY.clamp(bounds.top + halfH, bounds.bottom - halfH);
    }

    outCenter.setValues(cx, cy);
  }

  /// Evaluates the smoothed camera center and zoom for [focusPoint] over [dt],
  /// writing the target camera world position into [outCameraPos] and returning
  /// the smoothed zoom factor.
  double step({
    required Vector2 focusPoint,
    required double baseZoom,
    required double viewportPixelWidth,
    required double viewportPixelHeight,
    required double dt,
    required Vector2 outCameraPos,
  }) {
    final zone = activeZoneAt(focusPoint.x, focusPoint.y);
    final goalZoom = zone?.targetZoom ?? baseZoom;

    if (!_primed || dt <= 0.0 || smoothingRate <= 0.0) {
      _smoothedZoom = goalZoom;
    } else {
      final k = 1.0 - math.exp(-smoothingRate * dt);
      _smoothedZoom += (goalZoom - _smoothedZoom) * k;
    }

    final safeZoom = _smoothedZoom <= 1e-4 ? 1.0 : _smoothedZoom;
    final viewWorldW = viewportPixelWidth / safeZoom;
    final viewWorldH = viewportPixelHeight / safeZoom;

    final activeBounds = zone?.clampBounds ?? roomBounds;
    final targetX = zone?.lockCenter?.x ?? focusPoint.x;
    final targetY = zone?.lockCenter?.y ?? focusPoint.y;

    clampOrCenter(
      bounds: activeBounds,
      desiredX: targetX,
      desiredY: targetY,
      viewportWorldWidth: viewWorldW,
      viewportWorldHeight: viewWorldH,
      outCenter: outCameraPos,
    );

    if (!_primed || dt <= 0.0 || smoothingRate <= 0.0) {
      _smoothedCenter.setFrom(outCameraPos);
      _primed = true;
    } else {
      final k = 1.0 - math.exp(-smoothingRate * dt);
      _smoothedCenter.setValues(
        _smoothedCenter.x + (outCameraPos.x - _smoothedCenter.x) * k,
        _smoothedCenter.y + (outCameraPos.y - _smoothedCenter.y) * k,
      );
      outCameraPos.setFrom(_smoothedCenter);
    }
    return _smoothedZoom;
  }

  /// Snaps internal smoothing history on instant map teleports.
  void resetSmoothing() {
    _primed = false;
  }
}
