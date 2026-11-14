import 'dart:ui' show Offset, Rect;

import 'package:flame/src/camera/world.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:vector_math/vector_math.dart';

/// Shape geometry of a [TriggerZoneComponent] sensor.
enum TriggerZoneShape() {
  rectangle,
  circle,
}

/// Fast, zero-narrowphase spatial presence sensor (`onEntityEntered`,
/// `onEntityStay`, `onEntityExited`, `entitiesInside`) backed automatically by
/// `World.spatialIndex` when enabled or direct world child bounds otherwise.
class TriggerZoneComponent({
  super.position,
  super.size,
  super.anchor,
  super.priority,
  super.key,
  this.zoneShape = TriggerZoneShape.rectangle,
  double? radius,
  this.entityFilter,
  this.onEntityEntered,
  this.onEntityStay,
  this.onEntityExited,
}) extends PositionComponent {
  /// Rectangular or circular trigger footprint.
  final TriggerZoneShape zoneShape;

  /// Explicit radius used when `zoneShape == TriggerZoneShape.circle`
  /// (defaults to `size.x * 0.5`).
  double? customRadius = radius;

  /// Optional filter selecting which [PositionComponent]s can activate this
  /// sensor.
  final bool Function(PositionComponent candidate)? entityFilter;

  /// Fired once when an entity enters the zone.
  final void Function(PositionComponent entity)? onEntityEntered;

  /// Fired every tick while an entity remains inside the zone.
  final void Function(PositionComponent entity, double dt)? onEntityStay;

  /// Fired once when an entity leaves the zone or unmounts.
  final void Function(PositionComponent entity)? onEntityExited;

  Set<PositionComponent> _insidePrev = <PositionComponent>{};
  Set<PositionComponent> _insideCurr = <PositionComponent>{};
  final List<PositionComponent> _queryScratch = <PositionComponent>[];
  final Vector2 _centerScratch = Vector2.zero();
  final Vector2 _otherCenterScratch = Vector2.zero();

  /// Read-only view of entities currently inside this trigger zone.
  Set<PositionComponent> get entitiesInside =>
      Set<PositionComponent>.unmodifiable(_insidePrev);

  /// Whether at least one matching entity currently occupies this zone.
  bool get isOccupied => _insidePrev.isNotEmpty;

  double get _effectiveRadius => customRadius ?? (size.x * 0.5);

  Rect _worldBounds() {
    final cx = position.x + (0.5 - anchor.x) * size.x;
    final cy = position.y + (0.5 - anchor.y) * size.y;
    if (zoneShape == TriggerZoneShape.circle) {
      final r = _effectiveRadius;
      return Rect.fromLTRB(cx - r, cy - r, cx + r, cy + r);
    }
    return Rect.fromCenter(
      center: Offset(cx, cy),
      width: size.x,
      height: size.y,
    );
  }

  /// Evaluates presence against [candidates] (automatically called against
  /// enclosing `World` children during [update]).
  void evaluateCandidates(Iterable<PositionComponent> candidates, double dt) {
    _insideCurr.clear();
    final bounds = _worldBounds();
    _centerScratch.setValues(bounds.center.dx, bounds.center.dy);
    final rad = _effectiveRadius;
    final radSq = rad * rad;

    for (final candidate in candidates) {
      if (identical(candidate, this) || candidate.isRemoving) {
        continue;
      }
      if (entityFilter != null && !entityFilter!(candidate)) {
        continue;
      }
      final otherCx =
          candidate.position.x + (0.5 - candidate.anchor.x) * candidate.size.x;
      final otherCy =
          candidate.position.y + (0.5 - candidate.anchor.y) * candidate.size.y;
      _otherCenterScratch.setValues(otherCx, otherCy);
      final halfW = candidate.size.x * 0.5;
      final halfH = candidate.size.y * 0.5;

      final bool overlaps;
      if (zoneShape == TriggerZoneShape.circle) {
        final clampedX = _centerScratch.x.clamp(
          otherCx - halfW,
          otherCx + halfW,
        );
        final clampedY = _centerScratch.y.clamp(
          otherCy - halfH,
          otherCy + halfH,
        );
        final dx = _centerScratch.x - clampedX;
        final dy = _centerScratch.y - clampedY;
        overlaps = (dx * dx + dy * dy) <= radSq;
      } else {
        final otherRect = Rect.fromCenter(
          center: Offset(otherCx, otherCy),
          width: candidate.size.x,
          height: candidate.size.y,
        );
        overlaps = bounds.overlaps(otherRect);
      }

      if (overlaps) {
        _insideCurr.add(candidate);
        if (!_insidePrev.contains(candidate)) {
          onEntityEntered?.call(candidate);
        }
        onEntityStay?.call(candidate, dt);
      }
    }

    for (final prev in _insidePrev) {
      if (!_insideCurr.contains(prev)) {
        onEntityExited?.call(prev);
      }
    }

    final swap = _insidePrev;
    _insidePrev = _insideCurr;
    _insideCurr = swap;
  }

  @override
  void update(double dt) {
    super.update(dt);
    final world = findParent<World>();
    if (world == null) {
      return;
    }
    if (world.spatialIndexEnabled) {
      _queryScratch.clear();
      world.querySpatialRect(_worldBounds(), _queryScratch);
      evaluateCandidates(_queryScratch, dt);
    } else {
      evaluateCandidates(world.children.whereType<PositionComponent>(), dt);
    }
  }

  @override
  void onRemove() {
    _insidePrev.clear();
    _insideCurr.clear();
    _queryScratch.clear();
    super.onRemove();
  }
}
