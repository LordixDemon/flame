import 'dart:math' as math;
import 'dart:ui' show Rect;

import 'package:flame/src/camera/viewfinder.dart';
import 'package:flame/src/camera/viewport.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/position_component.dart';
import 'package:flame/src/effects/provider_interfaces.dart';
import 'package:vector_math/vector_math.dart';

/// This behavior will make the [owner] follow the [target].
///
/// Here, both the owner and the target are [PositionProvider]s, which could be
/// either [PositionComponent]s, or camera's [Viewfinder]/[Viewport], or any
/// other objects, including custom implementations.
///
/// The [maxSpeed] parameter controls the maximum speed with which the [owner]
/// is allowed to move as it pursues the [target]. By default, the max speed is
/// infinite, allowing the owner to stay on top of the target all the time.
///
/// Optional [smoothing] (`> 0`) applies framerate-independent exponential
/// damping `1 - exp(-smoothing * dt)` (still capped by `maxSpeed * dt`).
/// Optional [deadzone] specifies a local rectangle around [owner] within which
/// target movement does not pull the [owner]. Optional [leadFactor] (`>= 0`,
/// in seconds) projects the target's velocity forward up to [maxLeadDistance]
/// so the camera leads moving targets smoothly.
///
/// The flags [horizontalOnly]/[verticalOnly] allow constraining the [owner]'s
/// movement to the horizontal/vertical directions respectively.
class FollowBehavior({
  required final ReadOnlyPositionProvider _target,
  var PositionProvider? _owner,
  double maxSpeed = double.infinity,
  final double? smoothing,
  final Rect? deadzone,
  final double leadFactor = 0.0,
  final double maxLeadDistance = 240.0,
  final bool horizontalOnly = false,
  final bool verticalOnly = false,
  super.priority,
  super.key,
}) extends Component {
  this
    : assert(maxSpeed > 0, 'maxSpeed must be positive: $maxSpeed'),
      assert(
        smoothing == null || smoothing > 0,
        'smoothing must be positive when provided: $smoothing',
      ),
      assert(leadFactor >= 0, 'leadFactor must be non-negative: $leadFactor'),
      assert(
        maxLeadDistance >= 0,
        'maxLeadDistance must be non-negative: $maxLeadDistance',
      ),
      assert(
        !(horizontalOnly && verticalOnly),
        'The behavior cannot be both horizontalOnly and verticalOnly',
      );

  ReadOnlyPositionProvider get target => _target;
  PositionProvider get owner => _owner!;
  double get maxSpeed => _speed;
  final double _speed = maxSpeed;

  final _tempDelta = Vector2.zero();
  final _prevTargetPos = Vector2.zero();
  bool _hasPrevTarget = false;

  @override
  void onMount() {
    if (_owner == null) {
      assert(
        parent is PositionProvider,
        'Can only apply this behavior to a PositionProvider',
      );
      _owner = parent! as PositionProvider;
    }
    _prevTargetPos.setFrom(target.position);
    _hasPrevTarget = true;
  }

  @override
  void update(double dt) {
    final targetPos = target.position;
    if (!_hasPrevTarget) {
      _prevTargetPos.setFrom(targetPos);
      _hasPrevTarget = true;
    }

    final rawDx = targetPos.x - owner.position.x;
    final rawDy = targetPos.y - owner.position.y;
    final dz = deadzone;
    final insideHorizDeadzone =
        dz != null && rawDx >= dz.left && rawDx <= dz.right;
    final insideVertDeadzone =
        dz != null && rawDy >= dz.top && rawDy <= dz.bottom;

    var goalX = targetPos.x;
    var goalY = targetPos.y;
    if (leadFactor > 0.0 && dt > 1e-6) {
      var lx = insideHorizDeadzone
          ? 0.0
          : ((targetPos.x - _prevTargetPos.x) / dt) * leadFactor;
      var ly = insideVertDeadzone
          ? 0.0
          : ((targetPos.y - _prevTargetPos.y) / dt) * leadFactor;
      final leadLen = math.sqrt(lx * lx + ly * ly);
      if (leadLen > maxLeadDistance && leadLen > 0.0) {
        final clampScale = maxLeadDistance / leadLen;
        lx *= clampScale;
        ly *= clampScale;
      }
      goalX += lx;
      goalY += ly;
    }
    _prevTargetPos.setFrom(targetPos);

    var dx = verticalOnly ? 0.0 : goalX - owner.position.x;
    var dy = horizontalOnly ? 0.0 : goalY - owner.position.y;

    if (dz != null) {
      if (!verticalOnly) {
        if (dx < dz.left) {
          dx -= dz.left;
        } else if (dx > dz.right) {
          dx -= dz.right;
        } else {
          dx = 0.0;
        }
      }
      if (!horizontalOnly) {
        if (dy < dz.top) {
          dy -= dz.top;
        } else if (dy > dz.bottom) {
          dy -= dz.bottom;
        } else {
          dy = 0.0;
        }
      }
    }

    _tempDelta.setValues(dx, dy);
    var distance = _tempDelta.length;
    if (distance == 0.0) {
      return;
    }

    if (smoothing != null && dt >= 0.0) {
      final alpha = 1.0 - math.exp(-smoothing! * dt);
      _tempDelta.scale(alpha);
      distance *= alpha;
    }

    final deltaOffset = _speed * dt;
    if (distance > deltaOffset) {
      _tempDelta.scale(deltaOffset / distance);
    }
    if (_tempDelta.x != 0 || _tempDelta.y != 0) {
      owner.position = _tempDelta..add(owner.position);
    }
  }
}
