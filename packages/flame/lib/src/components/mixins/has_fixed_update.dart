import 'package:flame/src/components/core/component.dart';

/// Mixin for [Component]s that run deterministic fixed-timestep simulation
/// ticks before variable-rate [Component.update] frames when
/// `FlameGame.fixedTimeStep` is configured.
mixin HasFixedUpdate on Component {
  /// Advances simulation state by a constant [fixedDt] (in seconds).
  ///
  /// During [Component.render], read `game.renderInterpolationAlpha` (`0..1`)
  /// to blend between the previous and current fixed-step states on
  /// high-refresh (`120Hz+`) displays.
  void fixedUpdate(double fixedDt);
}
