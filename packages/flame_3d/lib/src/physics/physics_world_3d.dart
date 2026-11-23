import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/components.dart' show Component, HasWorldRef;
import 'package:flame_3d/camera.dart' show World3D;
import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/src/collisions/collision_manifold_3d.dart'
    show MutableManifoldBuffer3D;
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:flame_3d/src/physics/physics_solver_math_3d.dart';
import 'package:meta/meta.dart';

part 'physics_world_broadphase_3d.dart';
part 'physics_world_ccd_3d.dart';
part 'physics_world_contact_solver_3d.dart';
part 'physics_world_snapshot_access_3d.dart';

/// Deterministic fixed-timestep Sequential Impulse 3D rigid-body physics world.
///
/// Simulates dynamic, kinematic, and static [RigidBody3D] components with:
/// - Incremental [DynamicAabbTree3D] broadphase,
/// - Continuous Collision Detection (`RigidBody3D.ccdEnabled`) via swept TOI,
/// - World inverse inertia tensor updates (`R * I_local^-1 * R^T`) and
///   composite [CompoundShape3D] centers of mass,
/// - Multi-point normal + isotropic 2-tangent Coulomb friction impulses with
///   warm-starting (contact points matched by feature id from one step to the
///   next) and [PhysicsMaterial3D] combine modes,
/// - Restitution bounce & split-impulse / NGS Baumgarte position correction,
/// - Solid static [Collider3D]s of the [collisionSystem] (non-trigger
///   colliders with `isStatic: true`),
/// - [Joint3D] constraints, [BuoyancyVolume3D], [RaycastVehicle3D], and
/// - Binary CRC32-verified rollback snapshots ([saveSnapshot] /
///   [restoreSnapshot]).
///
/// The bodies simulated are those registered with [addBody] plus every
/// [RigidBody3D] mounted anywhere under this world's parent (registered when
/// they mount, not searched for every step).
class PhysicsWorld3D({
  Vector3? gravity,
  var double fixedTimeStep = 1.0 / 60.0,
  var int maxSubSteps = 4,
  var int velocityIterations = 8,
  var int positionIterations = 3,
  var double sleepLinearThreshold = 0.08,
  var double sleepAngularThreshold = 0.12,
  var double sleepTimeThreshold = 0.5,
  var double restitutionVelocityThreshold = 0.5,
  var double linearSlop = 0.004,
  var bool autoStep = true,
  this.collisionSystem,
  super.priority,
}) extends Component with HasWorldRef<World3D> {
  this
    : assert(fixedTimeStep > 0, 'fixedTimeStep must be positive'),
      assert(maxSubSteps >= 1, 'maxSubSteps must be >= 1'),
      assert(linearSlop >= 0, 'linearSlop must be non-negative');

  /// Constant gravitational acceleration (`m/s^2`), `(0, -9.81, 0)` by default.
  final Vector3 gravity = gravity?.clone() ?? Vector3(0.0, -9.81, 0.0);

  /// Optional [CollisionSystem3D] whose static, non-trigger colliders are
  /// solid for rigid bodies (contacts and continuous collision detection) and
  /// whose colliders are hit by vehicle wheel rays. When `null`, the first
  /// [CollisionSystem3D] among this world's siblings is used.
  CollisionSystem3D? collisionSystem;

  /// Incremental SAH broadphase tree over active [RigidBody3D]s.
  final DynamicAabbTree3D<RigidBody3D> broadphaseTree =
      DynamicAabbTree3D<RigidBody3D>();

  int _tick = 0;
  double _accumulator = 0.0;

  final List<RigidBody3D> _manualBodies = [];
  final Set<RigidBody3D> _mountedBodies = {};
  final Set<BuoyancyVolume3D> _mountedVolumes = {};
  bool _bodiesDirty = true;
  final List<Joint3D> _joints = [];
  final List<BuoyancyVolume3D> _buoyancyVolumes = [];
  final List<RaycastVehicle3D> _vehicles = [];
  final List<RigidBody3D> _activeBodies = [];
  final Map<RigidBody3D, int> _bodyProxies = {};
  final Set<RigidBody3D> _seenBodiesScratch = {};
  final List<RigidBody3D> _staleBodiesScratch = [];
  final List<Component> _walkStack = [];
  final List<RigidBody3D> _pairCandidates = [];
  final List<_ContactConstraint3D> _constraints = [];
  final MutableManifoldBuffer3D _manifoldBuffer = MutableManifoldBuffer3D();

  // Persistent contact pairs (warm-start history), keyed by body A.
  final Map<RigidBody3D, List<_ContactPair3D>> _pairsByBodyA = {};
  final List<_ContactPair3D> _pairList = [];
  final List<_ContactPair3D> _pairPool = [];

  // Static colliders as infinite-mass contact partners.
  final Map<Collider3D, RigidBody3D> _colliderProxies = {};
  final Map<RigidBody3D, Collider3D> _proxyColliders = {};
  final Map<Collider3D, int> _colliderOrder = {};
  final List<Collider3D> _colliderOrderList = [];
  final List<Collider3D> _colliderCandidates = [];
  CollisionSystem3D? _orderedSystem;

  RigidBody3D? _queryBody;
  late final void Function(int, RigidBody3D) _onBodyCandidate =
      _collectBodyCandidate;
  late final void Function(int, Collider3D) _onColliderCandidate =
      _collectColliderCandidate;
  late final void Function(int, RigidBody3D) _onCcdBody = _sweepAgainstBody;
  late final void Function(int, Collider3D) _onCcdCollider =
      _sweepAgainstCollider;

  final Vector3 _scratchVec = Vector3.zero();
  final Vector3 _scratchTorque = Vector3.zero();
  final Vector3 _comScratch = Vector3.zero();
  final Vector3 _rotOffsetScratch = Vector3.zero();
  final Matrix4 _ccdStartMat = Matrix4.identity();
  final Aabb3 _ccdSweptAabb = Aabb3();
  final Vector3 _ccdDelta = Vector3.zero();
  final _ContactConstraint3D _ccdConstraint = _ContactConstraint3D();
  SphereShape3D? _ccdSphere;
  RigidBody3D? _ccdBody;
  ShapeCastHit3D? _ccdBestHit;
  RigidBody3D? _ccdHitBody;
  Collider3D? _ccdHitCollider;
  double _ccdMaxToi = 1.0;

  /// Monotonic count of completed [step] invocations (saved/restored by
  /// [saveSnapshot] and [restoreSnapshot]).
  int get tick => _tick;

  /// Current fixed-timestep sub-step accumulator (seconds).
  double get accumulator => _accumulator;

  /// Active constraints registered via [addJoint].
  List<Joint3D> get joints => List.unmodifiable(_joints);

  /// Registered [BuoyancyVolume3D] solvers stepped automatically in [step]:
  /// those added with [addBuoyancyVolume] and those mounted under this
  /// world's parent.
  List<BuoyancyVolume3D> get buoyancyVolumes =>
      List.unmodifiable(_buoyancyVolumes);

  /// Registered [RaycastVehicle3D] controllers stepped automatically in [step].
  List<RaycastVehicle3D> get vehicles => List.unmodifiable(_vehicles);

  /// Explicitly registers [body] for standalone simulation outside a mounted
  /// [World3D].
  void addBody(RigidBody3D body) {
    if (!_manualBodies.contains(body)) {
      _manualBodies.add(body);
      _bodiesDirty = true;
    }
  }

  /// Removes a manually registered [body].
  void removeBody(RigidBody3D body) {
    if (_manualBodies.remove(body)) {
      _bodiesDirty = true;
    }
    if (!_mountedBodies.contains(body)) {
      final proxy = _bodyProxies.remove(body);
      if (proxy != null) {
        broadphaseTree.remove(proxy);
      }
    }
  }

  /// Registers a [Joint3D] constraint between two rigid bodies.
  void addJoint(Joint3D joint) {
    if (!_joints.contains(joint)) {
      _joints.add(joint);
      joint.bodyA.wakeUp();
      joint.bodyB.wakeUp();
    }
  }

  /// Unregisters [joint].
  void removeJoint(Joint3D joint) {
    _joints.remove(joint);
    joint.bodyA.wakeUp();
    joint.bodyB.wakeUp();
  }

  /// Registers a [BuoyancyVolume3D] to apply Archimedes forces each [step].
  void addBuoyancyVolume(BuoyancyVolume3D volume) {
    if (!_buoyancyVolumes.contains(volume)) {
      _buoyancyVolumes.add(volume);
    }
  }

  /// Unregisters [volume].
  void removeBuoyancyVolume(BuoyancyVolume3D volume) {
    _buoyancyVolumes.remove(volume);
    _mountedVolumes.remove(volume);
  }

  /// Registers a [RaycastVehicle3D] to step suspension & tire impulses each
  /// [step].
  void addVehicle(RaycastVehicle3D vehicle) {
    if (!_vehicles.contains(vehicle)) {
      _vehicles.add(vehicle);
    }
  }

  /// Unregisters [vehicle].
  void removeVehicle(RaycastVehicle3D vehicle) {
    _vehicles.remove(vehicle);
  }

  /// Encodes the complete deterministic simulation state of this world into a
  /// compact binary `Uint8List` with `'P3DS'` magic and CRC32 checksum.
  Uint8List saveSnapshot() => PhysicsSnapshot3D.encodeWorld(this);

  /// Restores the complete simulation state previously encoded by
  /// [saveSnapshot], throwing [FormatException] on magic or CRC32 mismatch.
  ///
  /// Restoring into this world or into an identically built one (same bodies
  /// created in the same order, same settings) reproduces the run bit for
  /// bit; see `PhysicsSnapshot3D.restoreWorld` for how bodies are matched and
  /// for [matchByOrder].
  void restoreSnapshot(Uint8List bytes, {bool matchByOrder = false}) =>
      PhysicsSnapshot3D.restoreWorld(this, bytes, matchByOrder: matchByOrder);

  /// Collects all active rigid bodies in deterministic `deterministicId` order.
  List<RigidBody3D> collectBodies([List<RigidBody3D>? out]) {
    _refreshBodies();
    final res = out ?? <RigidBody3D>[];
    if (!identical(res, _activeBodies)) {
      res
        ..clear()
        ..addAll(_activeBodies);
    }
    return res;
  }

  @override
  void onMount() {
    super.onMount();
    // Register the bodies and buoyancy volumes already mounted under the
    // parent; later ones register themselves when they mount.
    final root = parent;
    if (root != null) {
      _walkStack
        ..clear()
        ..add(root);
      while (_walkStack.isNotEmpty) {
        final comp = _walkStack.removeLast();
        if (comp is RigidBody3D || comp is BuoyancyVolume3D) {
          registerMountedComponent(comp);
        }
        _walkStack.addAll(comp.children);
      }
    }
  }

  @override
  void onRemove() {
    for (final b in _mountedBodies) {
      b.enclosingPhysicsWorlds.remove(this);
    }
    _mountedBodies.clear();
    for (final v in _mountedVolumes) {
      v.enclosingPhysicsWorlds.remove(this);
      _buoyancyVolumes.remove(v);
    }
    _mountedVolumes.clear();
    _bodiesDirty = true;
    super.onRemove();
  }

  /// Registers [component] (a [RigidBody3D] or a [BuoyancyVolume3D]) mounted
  /// under this world's parent. Called by those components when they mount.
  @internal
  void registerMountedComponent(Component component) {
    if (component is RigidBody3D) {
      if (_mountedBodies.add(component)) {
        component.enclosingPhysicsWorlds.add(this);
        _bodiesDirty = true;
      }
    } else if (component is BuoyancyVolume3D) {
      if (!_buoyancyVolumes.contains(component)) {
        _mountedVolumes.add(component);
        component.enclosingPhysicsWorlds.add(this);
        _buoyancyVolumes.add(component);
      }
    }
  }

  /// Unregisters a component registered by [registerMountedComponent]. Called
  /// by the component when it is removed.
  @internal
  void unregisterMountedComponent(Component component) {
    if (component is RigidBody3D) {
      if (_mountedBodies.remove(component)) {
        _bodiesDirty = true;
        if (!_manualBodies.contains(component)) {
          final proxy = _bodyProxies.remove(component);
          if (proxy != null) {
            broadphaseTree.remove(proxy);
          }
        }
      }
    } else if (component is BuoyancyVolume3D) {
      if (_mountedVolumes.remove(component)) {
        _buoyancyVolumes.remove(component);
      }
    }
  }

  /// Registers [component] with every [PhysicsWorld3D] whose parent is an
  /// ancestor of [component] (the worlds that simulate it).
  @internal
  static void attachToEnclosingWorlds(Component component) {
    var ancestor = component.parent;
    while (ancestor != null) {
      for (final sibling in ancestor.children) {
        if (sibling is PhysicsWorld3D) {
          sibling.registerMountedComponent(component);
        }
      }
      ancestor = ancestor.parent;
    }
  }

  /// Deterministically places, orients, and throws [bodies] (such as polyhedral
  /// dice) from [origin] using [seed].
  void throwDice3D(
    List<RigidBody3D> bodies, {
    required int seed,
    Vector3? origin,
    double spacing = 0.85,
    Vector3? throwVelocity,
    double velocityJitter = 0.6,
    double minSpinSpeed = 10.0,
    double maxSpinSpeed = 22.0,
  }) {
    final rng = SeededRng3D(seed);
    final baseOrigin = origin ?? Vector3(0.0, 3.0, 2.5);
    final baseVel = throwVelocity ?? Vector3(0.0, -1.5, -4.5);
    final halfSpan = (bodies.length - 1) * 0.5 * spacing;

    for (var i = 0; i < bodies.length; i++) {
      final b = bodies[i];
      b.wakeUp();

      final offsetX = i * spacing - halfSpan + rng.rangeDouble(-0.05, 0.05);
      final offsetY = rng.rangeDouble(-0.05, 0.05);
      final offsetZ = rng.rangeDouble(-0.05, 0.05);
      b.bodyPosition.setValues(
        baseOrigin.x + offsetX,
        baseOrigin.y + offsetY,
        baseOrigin.z + offsetZ,
      );

      // Uniform deterministic random orientation on SO(3) (Shoemake method).
      final u1 = rng.nextDouble();
      final u2 = rng.nextDouble() * math.pi * 2.0;
      final u3 = rng.nextDouble() * math.pi * 2.0;
      final s1 = math.sqrt(1.0 - u1);
      final s2 = math.sqrt(u1);
      b.bodyRotation.setValues(
        s1 * math.sin(u2),
        s1 * math.cos(u2),
        s2 * math.sin(u3),
        s2 * math.cos(u3),
      );
      b.updateWorldInertia();

      b.linearVelocity.setValues(
        baseVel.x + rng.rangeDouble(-velocityJitter, velocityJitter),
        baseVel.y +
            rng.rangeDouble(-velocityJitter * 0.5, velocityJitter * 0.5),
        baseVel.z + rng.rangeDouble(-velocityJitter, velocityJitter),
      );

      final uz = rng.rangeDouble(-1.0, 1.0);
      final rHoriz = math.sqrt(math.max(0.0, 1.0 - uz * uz));
      final az = rng.rangeDouble(0.0, math.pi * 2.0);
      final spinMag = rng.rangeDouble(minSpinSpeed, maxSpinSpeed);
      b.angularVelocity.setValues(
        rHoriz * math.cos(az) * spinMag,
        rHoriz * math.sin(az) * spinMag,
        uz * spinMag,
      );
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (!autoStep || dt <= 0.0) {
      return;
    }
    _accumulator += dt;
    var subSteps = 0;
    while (_accumulator >= fixedTimeStep && subSteps < maxSubSteps) {
      step(fixedTimeStep);
      _accumulator -= fixedTimeStep;
      subSteps++;
    }
    if (subSteps == maxSubSteps && _accumulator > fixedTimeStep) {
      _accumulator = _accumulator % fixedTimeStep;
    }
  }

  /// Advances the 3D rigid-body simulation by exactly one deterministic step of
  /// [dt] seconds.
  void step(double dt) {
    if (dt <= 0.0) {
      return;
    }
    _tick++;
    _refreshBodies();
    if (_activeBodies.isEmpty) {
      return;
    }

    // Apply registered Archimedes buoyancy volumes before force integration.
    if (_buoyancyVolumes.isNotEmpty) {
      final gMag = gravity.length;
      for (var i = 0; i < _buoyancyVolumes.length; i++) {
        _buoyancyVolumes[i].applyToBodies(
          _activeBodies,
          dt,
          gravityMagnitude: gMag,
        );
      }
    }

    // Keep bodies connected by a joint awake together if either is awake.
    for (var i = 0; i < _joints.length; i++) {
      final j = _joints[i];
      final a = j.bodyA;
      final b = j.bodyB;
      if (a.bodyType == BodyType3D.dynamic &&
          b.bodyType == BodyType3D.dynamic &&
          a.isSleeping != b.isSleeping) {
        a.wakeUp();
        b.wakeUp();
      }
    }

    // 1. Symplectic Euler force & torque integration + implicit Padé damping.
    for (var i = 0; i < _activeBodies.length; i++) {
      final b = _activeBodies[i];
      b.updateWorldInertia();
      if (b.bodyType != BodyType3D.dynamic) {
        b.clearAccumulators();
        continue;
      }
      if (b.isSleeping) {
        b.clearAccumulators();
        continue;
      }

      final invM = b.inverseMass;
      final f = b.accumulatedForce;
      b.linearVelocity.setValues(
        b.linearVelocity.x + (gravity.x + f.x * invM) * dt,
        b.linearVelocity.y + (gravity.y + f.y * invM) * dt,
        b.linearVelocity.z + (gravity.z + f.z * invM) * dt,
      );

      final t = b.accumulatedTorque;
      if (t.x != 0.0 || t.y != 0.0 || t.z != 0.0) {
        b.multiplyWorldInvInertia(t.x, t.y, t.z, _scratchTorque);
        b.angularVelocity.addScaled(_scratchTorque, dt);
      }

      if (b.linearDamping > 0.0) {
        b.linearVelocity.scale(1.0 / (1.0 + dt * b.linearDamping));
      }
      if (b.angularDamping > 0.0) {
        b.angularVelocity.scale(1.0 / (1.0 + dt * b.angularDamping));
      }
      b.clearAccumulators();
    }

    // Apply registered RaycastVehicle3D suspension, drive, and anti-slip.
    final colSys = _resolveCollisionSystem();
    if (_vehicles.isNotEmpty) {
      for (var i = 0; i < _vehicles.length; i++) {
        _vehicles[i].stepVehicle(
          dt,
          bodies: _activeBodies,
          collisionSystem: colSys,
          gravityMagnitude: gravity.length,
        );
      }
    }

    // 2. Sync broadphase trees & build narrowphase contact constraints.
    _syncBroadphaseTree();
    _syncColliders(colSys);
    _buildContactConstraints(colSys);

    // 3. Prepare joints & warm-start resting contacts.
    for (var i = 0; i < _joints.length; i++) {
      _joints[i].prepare(dt);
    }
    for (var i = 0; i < _constraints.length; i++) {
      _constraints[i].prepare(_scratchVec, dt, warmStart: true);
    }

    // 4. Sequential Impulse velocity solver iterations.
    for (var iter = 0; iter < velocityIterations; iter++) {
      for (var j = 0; j < _joints.length; j++) {
        _joints[j].solveVelocity(dt);
      }
      for (var c = 0; c < _constraints.length; c++) {
        _constraints[c].solveVelocity(_scratchVec);
      }
    }

    // Store accumulated impulses for next step's warm-starting.
    for (var i = 0; i < _constraints.length; i++) {
      _constraints[i].saveWarmImpulses();
    }

    // 5. Symplectic Euler position & orientation integration (+ swept CCD).
    for (var i = 0; i < _activeBodies.length; i++) {
      final b = _activeBodies[i];
      if (b.bodyType == BodyType3D.static) {
        continue;
      }
      if (b.bodyType == BodyType3D.dynamic && b.isSleeping) {
        continue;
      }

      if (b.bodyType == BodyType3D.dynamic && b.ccdEnabled) {
        final rCcd = b.ccdSweptSphereRadius;
        final disp = b.linearVelocity.length * dt;
        final ccdThreshold = math.max(1e-4, rCcd * 0.5);
        if (disp > ccdThreshold) {
          _integrateBodyWithCcd(b, dt, rCcd, colSys);
          continue;
        }
      }

      _integrateBodyPose(b, dt);
    }

    // 6. Split-impulse / NGS position correction iterations.
    for (var iter = 0; iter < positionIterations; iter++) {
      for (var j = 0; j < _joints.length; j++) {
        _joints[j].solvePosition();
      }
      for (var c = 0; c < _constraints.length; c++) {
        _constraints[c].solvePosition(linearSlop);
      }
    }

    // 7. Sleep timers; bodies touching through contacts or joints form an
    // island that falls asleep only as a whole.
    _updateSleep(dt);
  }

  Int32List _islandParent = Int32List(16);
  Float64List _islandTimer = Float64List(16);
  Uint8List _islandCanSleep = Uint8List(16);

  int _findIsland(int i) {
    var r = i;
    while (_islandParent[r] != r) {
      r = _islandParent[r];
    }
    var c = i;
    while (_islandParent[c] != r) {
      final next = _islandParent[c];
      _islandParent[c] = r;
      c = next;
    }
    return r;
  }

  void _unionIslands(RigidBody3D a, RigidBody3D b) {
    final ia = a.solverIndex;
    final ib = b.solverIndex;
    if (ia < 0 || ib < 0) {
      return;
    }
    final ra = _findIsland(ia);
    final rb = _findIsland(ib);
    if (ra != rb) {
      if (ra < rb) {
        _islandParent[rb] = ra;
      } else {
        _islandParent[ra] = rb;
      }
    }
  }

  void _updateSleep(double dt) {
    final n = _activeBodies.length;
    if (_islandParent.length < n) {
      _islandParent = Int32List(n * 2);
      _islandTimer = Float64List(n * 2);
      _islandCanSleep = Uint8List(n * 2);
    }
    final linThresh2 = sleepLinearThreshold * sleepLinearThreshold;
    final angThresh2 = sleepAngularThreshold * sleepAngularThreshold;
    for (var i = 0; i < n; i++) {
      final b = _activeBodies[i];
      _islandParent[i] = i;
      final awake = b.bodyType == BodyType3D.dynamic && !b.isSleeping;
      b.solverIndex = awake ? i : -1;
      if (!awake) {
        continue;
      }
      if (b.linearVelocity.length2 <= linThresh2 &&
          b.angularVelocity.length2 <= angThresh2) {
        b.sleepTimer += dt;
      } else {
        b.sleepTimer = 0.0;
      }
    }
    for (var c = 0; c < _constraints.length; c++) {
      final con = _constraints[c];
      if (con.useA && con.useB) {
        _unionIslands(con.bodyA, con.bodyB);
      }
    }
    for (var j = 0; j < _joints.length; j++) {
      _unionIslands(_joints[j].bodyA, _joints[j].bodyB);
    }
    for (var i = 0; i < n; i++) {
      _islandTimer[i] = double.infinity;
      _islandCanSleep[i] = 1;
    }
    for (var i = 0; i < n; i++) {
      final b = _activeBodies[i];
      if (b.solverIndex < 0) {
        continue;
      }
      final r = _findIsland(i);
      if (b.sleepTimer < _islandTimer[r]) {
        _islandTimer[r] = b.sleepTimer;
      }
      if (!b.canSleep) {
        _islandCanSleep[r] = 0;
      }
    }
    for (var i = 0; i < n; i++) {
      final b = _activeBodies[i];
      if (b.solverIndex < 0) {
        continue;
      }
      final r = _findIsland(i);
      if (_islandCanSleep[r] == 1 && _islandTimer[r] >= sleepTimeThreshold) {
        b.putToSleep();
      }
      b.solverIndex = -1;
    }
  }

  static int _compareIds(RigidBody3D a, RigidBody3D b) =>
      a.deterministicId.compareTo(b.deterministicId);

  final List<Collider3D> _staleColliderScratch = [];

  /// Whether [collider] is solid for [body]: a static, non-trigger collider
  /// whose layers match and which does not belong to the body's host.
  static bool _isSolidColliderFor(Collider3D collider, RigidBody3D body) {
    return collider.isStatic &&
        !collider.isTrigger &&
        (collider.collisionLayer & body.collisionMask) != 0 &&
        (body.collisionLayer & collider.collisionMask) != 0 &&
        !identical(collider.hostComponent, body.hostComponent);
  }

  /// Whether [b] takes no part in contacts this step on its own: static,
  /// asleep, or kinematic without velocity.
  static bool _isInactive(RigidBody3D b) {
    switch (b.bodyType) {
      case BodyType3D.static:
        return true;
      case BodyType3D.dynamic:
        return b.isSleeping;
      case BodyType3D.kinematic:
        return b.linearVelocity.length2 == 0.0 &&
            b.angularVelocity.length2 == 0.0;
    }
  }

  late final int Function(Collider3D, Collider3D) _colliderComparator =
      _compareColliderOrder;

  /// Exports warm-start records sorted deterministically for snapshots.
  @internal
  List<WarmContactRecord3D> exportWarmStartRecords(List<RigidBody3D> bodies) =>
      _exportWarmStartRecordsImpl(bodies);

  /// Restores tick, accumulator, and warm-start state from a snapshot.
  @internal
  void restoreInternalState({
    required int tick,
    required double accumulator,
    required List<RigidBody3D?> bodies,
    required List<WarmContactRecord3D> warmRecords,
  }) => _restoreInternalStateImpl(
    tick: tick,
    accumulator: accumulator,
    bodies: bodies,
    warmRecords: warmRecords,
  );
}
