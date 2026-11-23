import 'package:flame/components.dart' show HasFixedUpdate;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';

/// Mixin on [Component3D] providing zero-allocation fixed-timestep transform
/// interpolation (`position`, `scale`, and shortest-hemisphere `Quaternion`
/// Slerp) for smooth high-refresh-rate (`90Hz` / `120Hz` / `144Hz`) rendering
/// over fixed-rate physics.
///
/// With `FlameGame.fixedTimeStep` and [HasFixedUpdate], one call is needed:
/// [captureFixedState] at the start of `fixedUpdate`. The mixin then blends
/// the transform in [update] with the game's `renderInterpolationAlpha`
/// (while [autoInterpolate] is `true`), and shows the simulated transform of
/// a component whose fixed step was skipped in the last frame:
///
/// ```dart
/// class Ball extends MeshComponent
///     with HasFixedUpdate, FixedTransformInterpolation3D {
///   Ball({required super.mesh});
///
///   final Vector3 velocity = Vector3(2, 0, 0);
///
///   @override
///   void fixedUpdate(double fixedDt) {
///     captureFixedState();
///     position.addScaled(velocity, fixedDt);
///   }
/// }
/// ```
///
/// When something else steps the simulation (for example a
/// `PhysicsWorld3D` stepped by hand), call [captureFixedState] before each
/// step, [commitFixedState] after it, and [applyInterpolationAlpha] with that
/// stepper's alpha before rendering.
mixin FixedTransformInterpolation3D on Component3D {
  final Vector3 _prevPosition = Vector3.zero();
  final Quaternion _prevRotation = Quaternion.identity();
  final Vector3 _prevScale = Vector3.all(1);

  final Vector3 _currPosition = Vector3.zero();
  final Quaternion _currRotation = Quaternion.identity();
  final Vector3 _currScale = Vector3.all(1);

  bool _hasFixedState = false;
  bool _isInterpolated = false;
  bool _capturedSinceApply = false;

  /// Whether [update] applies `FlameGame.renderInterpolationAlpha` by itself
  /// for a component with [HasFixedUpdate] in a game with a
  /// `fixedTimeStep`.
  bool autoInterpolate = true;

  /// Whether the component's live transform currently holds an interpolated
  /// render pose awaiting [restoreSimulatedState].
  bool get isInterpolated => _isInterpolated;

  @override
  void onMount() {
    super.onMount();
    teleportFixedState();
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!autoInterpolate || this is! HasFixedUpdate) {
      return;
    }
    final game = findGame();
    if (game == null || game.fixedTimeStep == null) {
      return;
    }
    if (!_capturedSinceApply && game.lastFrameFixedSteps > 0) {
      // Fixed steps ran this frame but this component's did not (a paused
      // time scale, disabled ticks, nothing to simulate): show its simulated
      // transform, and keep showing it, instead of sliding between two old
      // states.
      restoreSimulatedState();
      teleportFixedState();
      return;
    }
    applyInterpolationAlpha(game.renderInterpolationAlpha);
  }

  /// Snapshots the current simulated transform as the previous fixed-tick
  /// baseline before stepping physics.
  void captureFixedState() {
    if (_isInterpolated) {
      restoreSimulatedState();
    }
    _prevPosition.setFrom(position);
    _prevRotation
      ..setFrom(rotation)
      ..normalize();
    _prevScale.setFrom(scale);
    _currPosition.setFrom(position);
    _currRotation.setFrom(_prevRotation);
    _currScale.setFrom(scale);
    _hasFixedState = true;
    _capturedSinceApply = true;
  }

  /// Records the newly simulated fixed-tick transform after stepping physics.
  void commitFixedState() {
    _currPosition.setFrom(position);
    _currRotation
      ..setFrom(rotation)
      ..normalize();
    _currScale.setFrom(scale);
    _hasFixedState = true;
    _isInterpolated = false;
  }

  /// Snaps both previous and current fixed-tick states to the component's live
  /// transform so instant teleports or spawns never streak across frames.
  void teleportFixedState() {
    _prevPosition.setFrom(position);
    _prevRotation
      ..setFrom(rotation)
      ..normalize();
    _prevScale.setFrom(scale);
    _currPosition.setFrom(position);
    _currRotation.setFrom(_prevRotation);
    _currScale.setFrom(scale);
    _hasFixedState = true;
    _isInterpolated = false;
  }

  /// Applies the interpolated render pose for [alpha] in `[0..1]` between the
  /// previous and current fixed-tick transforms.
  void applyInterpolationAlpha(double alpha) {
    if (!_hasFixedState) {
      teleportFixedState();
      return;
    }
    if (!_isInterpolated) {
      commitFixedState();
    }
    final t = alpha.clamp(0.0, 1.0);
    _isInterpolated = true;
    _capturedSinceApply = false;

    position.setValues(
      _prevPosition.x + (_currPosition.x - _prevPosition.x) * t,
      _prevPosition.y + (_currPosition.y - _prevPosition.y) * t,
      _prevPosition.z + (_currPosition.z - _prevPosition.z) * t,
    );
    scale.setValues(
      _prevScale.x + (_currScale.x - _prevScale.x) * t,
      _prevScale.y + (_currScale.y - _prevScale.y) * t,
      _prevScale.z + (_currScale.z - _prevScale.z) * t,
    );
    AnimationInterpolation.slerpQuaternionsInto(
      _prevRotation,
      _currRotation,
      t,
      rotation,
    );
  }

  /// Restores the exact simulated fixed-tick transform after rendering so
  /// subsequent physics ticks never accumulate render-interpolation values.
  void restoreSimulatedState() {
    if (!_hasFixedState || !_isInterpolated) {
      return;
    }
    position.setFrom(_currPosition);
    rotation.setValues(
      _currRotation.x,
      _currRotation.y,
      _currRotation.z,
      _currRotation.w,
    );
    scale.setFrom(_currScale);
    _isInterpolated = false;
  }
}
