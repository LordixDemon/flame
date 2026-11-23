import 'dart:math' as math;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:flame_3d/src/physics/physics_solver_math_3d.dart';

part 'joint_cone_twist_3d.dart';
part 'joint_distance_ball_3d.dart';
part 'joint_generic_6dof_3d.dart';
part 'joint_hinge_slider_3d.dart';

/// Base class for 3D constraints connecting two [RigidBody3D] instances inside
/// a [PhysicsWorld3D].
abstract class Joint3D({
  required final RigidBody3D bodyA,
  required final RigidBody3D bodyB,
  final bool collideConnected = false,
}) {
  /// Precomputes lever arms and effective mass matrices at the start of a step.
  void prepare(double dt);

  /// Iteratively enforces velocity-level constraint equations.
  void solveVelocity(double dt);

  /// Iteratively corrects residual positional/angular drift.
  void solvePosition();
}
