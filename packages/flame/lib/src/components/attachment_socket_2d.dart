import 'dart:math' as math;

import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/extensions/vector2.dart';

/// Named 2D attachment socket (`hand_r`, `head_top`, `muzzle`, `banner_tip`)
/// transforming local offsets by a host [PositionComponent]'s position, angle,
/// and scale.
class AttachmentSocket2D({
  required this.name,
  Vector2? localOffset,
  this.localAngle = 0.0,
  Vector2? localScale,
}) {
  /// Unique socket identifier on the parent actor.
  final String name;

  /// Socket offset in parent-local coordinates.
  final Vector2 localOffset = localOffset?.clone() ?? Vector2.zero();

  /// Socket rotation offset in radians relative to parent angle.
  double localAngle;

  /// Socket scale multiplier relative to parent scale.
  final Vector2 localScale = localScale?.clone() ?? Vector2.all(1.0);

  /// Writes the world/parent-space socket position for [host] into [out]
  /// without allocating.
  Vector2 computeSocketPosition(PositionComponent host, {Vector2? out}) {
    final result = out ?? Vector2.zero();
    final sx = localOffset.x * host.scale.x;
    final sy = localOffset.y * host.scale.y;
    final c = math.cos(host.angle);
    final s = math.sin(host.angle);
    result.setValues(
      host.position.x + sx * c - sy * s,
      host.position.y + sx * s + sy * c,
    );
    return result;
  }

  /// Synchronizes [follower]'s `position`, `angle`, and `scale` to this socket
  /// on [host].
  void syncFollower(PositionComponent host, PositionComponent follower) {
    computeSocketPosition(host, out: follower.position);
    follower.angle = host.angle + localAngle;
    follower.scale.setValues(
      host.scale.x * localScale.x,
      host.scale.y * localScale.y,
    );
  }
}
