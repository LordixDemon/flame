import 'dart:ui';

/// Rectangular interior roof or tall-canopy occlusion zone that smoothly fades
/// its layer opacity to [hiddenOpacity] when the tracked player/focus point
/// enters [bounds], and reports whether an actor is visually occluded behind
/// tall cover for silhouette rendering.
class RoofOcclusionZone({
  required this.id,
  required this.bounds,
  this.hiddenOpacity = 0.0,
  this.visibleOpacity = 1.0,
  this.fadeSpeedPerSecond = 6.0,
}) {
  final String id;
  Rect bounds;
  final double hiddenOpacity;
  final double visibleOpacity;
  final double fadeSpeedPerSecond;

  double _currentOpacity = 1.0;
  bool _inside = false;

  /// Current interpolated roof opacity (`hiddenOpacity .. visibleOpacity`).
  double get currentOpacity => _currentOpacity;

  /// Whether the tracked actor is currently inside this roof zone.
  bool get isActorInside => _inside;

  /// Steps smooth roof fade for [dt] given world-space actor foot `(x, y)`.
  /// Returns `true` if [currentOpacity] changed this tick.
  bool updateForActor(double x, double y, double dt) {
    _inside = bounds.contains(Offset(x, y));
    final target = _inside ? hiddenOpacity : visibleOpacity;
    if ((_currentOpacity - target).abs() <= 1e-5) {
      _currentOpacity = target;
      return false;
    }
    final step = fadeSpeedPerSecond * dt;
    if (_currentOpacity < target) {
      _currentOpacity = (_currentOpacity + step).clamp(
        hiddenOpacity,
        visibleOpacity,
      );
    } else {
      _currentOpacity = (_currentOpacity - step).clamp(
        hiddenOpacity,
        visibleOpacity,
      );
    }
    return true;
  }
}

/// Manages a collection of [RoofOcclusionZone]s and tall-wall silhouette
/// occluder rectangles on a map.
class RoofCutawayController() {
  final List<RoofOcclusionZone> _zones = <RoofOcclusionZone>[];
  final List<Rect> _silhouetteBlockers = <Rect>[];

  List<RoofOcclusionZone> get zones => List<RoofOcclusionZone>.unmodifiable(
    _zones,
  );

  void addRoofZone(RoofOcclusionZone zone) => _zones.add(zone);

  void addSilhouetteBlocker(Rect blockerWorldRect) =>
      _silhouetteBlockers.add(blockerWorldRect);

  /// Updates all roof zones for actor `(x, y)` over [dt], returning `true` if
  /// any roof opacity animated this frame (for `IdleRenderMode.onDemand`).
  bool update(double x, double y, double dt) {
    var mutated = false;
    for (var i = 0; i < _zones.length; i++) {
      if (_zones[i].updateForActor(x, y, dt)) {
        mutated = true;
      }
    }
    return mutated;
  }

  /// Returns `true` when [actorBounds] overlaps any registered tall wall/tree
  /// canopy silhouette blocker while NOT inside a faded-out interior roof.
  bool isActorOccludedForSilhouette(Rect actorBounds) {
    for (var i = 0; i < _silhouetteBlockers.length; i++) {
      if (_silhouetteBlockers[i].overlaps(actorBounds)) {
        return true;
      }
    }
    return false;
  }
}
