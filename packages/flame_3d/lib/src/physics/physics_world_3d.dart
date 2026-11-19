import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flame/components.dart' show Component, HasWorldRef;
import 'package:flame_3d/camera.dart' show World3D;
import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
import 'package:meta/meta.dart';

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

  void _integrateBodyPose(RigidBody3D b, double dt) {
    final hasCom = b.hasCenterOfMassOffset;
    if (hasCom) {
      _comScratch.setFrom(b.worldCenterOfMass);
    }

    final lv = b.linearVelocity;
    if (hasCom) {
      _comScratch.addScaled(lv, dt);
    } else if (lv.x != 0.0 || lv.y != 0.0 || lv.z != 0.0) {
      final pos = b.bodyPosition;
      pos.setValues(pos.x + lv.x * dt, pos.y + lv.y * dt, pos.z + lv.z * dt);
    }

    final av = b.angularVelocity;
    final wLen = av.length;
    if (wLen > 1e-9) {
      final angle = wLen * dt;
      final half = 0.5 * angle;
      final s = math.sin(half) / wLen;
      final dqx = av.x * s;
      final dqy = av.y * s;
      final dqz = av.z * s;
      final dqw = math.cos(half);

      final q = b.bodyRotation;
      final qx = q.x;
      final qy = q.y;
      final qz = q.z;
      final qw = q.w;

      final nx = dqw * qx + dqx * qw + dqy * qz - dqz * qy;
      final ny = dqw * qy - dqx * qz + dqy * qw + dqz * qx;
      final nz = dqw * qz + dqx * qy - dqy * qx + dqz * qw;
      final nw = dqw * qw - dqx * qx - dqy * qy - dqz * qz;
      final invNorm = 1.0 / math.sqrt(nx * nx + ny * ny + nz * nz + nw * nw);
      q.setValues(nx * invNorm, ny * invNorm, nz * invNorm, nw * invNorm);
      b.updateWorldInertia();
    }

    if (hasCom) {
      _ContactConstraint3D._rotateByQuat(
        b.bodyRotation,
        b.localCenterOfMass,
        _rotOffsetScratch,
      );
      b.bodyPosition.setValues(
        _comScratch.x - _rotOffsetScratch.x,
        _comScratch.y - _rotOffsetScratch.y,
        _comScratch.z - _rotOffsetScratch.z,
      );
    }
  }

  void _integrateBodyWithCcd(
    RigidBody3D b,
    double totalDt,
    double rCcd,
    CollisionSystem3D? colSys,
  ) {
    var sphere = _ccdSphere;
    if (sphere == null || sphere.radius != rCcd) {
      sphere = _ccdSphere = SphereShape3D(radius: rCcd);
    }
    var remDt = totalDt;
    const maxImpacts = 3;

    for (var sub = 0; remDt > 1e-7; sub++) {
      _ccdDelta
        ..setFrom(b.linearVelocity)
        ..scale(remDt);
      final sweepLen = _ccdDelta.length;
      if (sweepLen <= math.max(1e-4, rCcd * 0.25)) {
        _integrateBodyPose(b, remDt);
        return;
      }

      final com = b.worldCenterOfMass;
      final startX = com.x;
      final startY = com.y;
      final startZ = com.z;
      _ccdStartMat
        ..setIdentity()
        ..setTranslationRaw(startX, startY, startZ);

      final endX = startX + _ccdDelta.x;
      final endY = startY + _ccdDelta.y;
      final endZ = startZ + _ccdDelta.z;
      _ccdSweptAabb
        ..min.setValues(
          math.min(startX, endX) - rCcd,
          math.min(startY, endY) - rCcd,
          math.min(startZ, endZ) - rCcd,
        )
        ..max.setValues(
          math.max(startX, endX) + rCcd,
          math.max(startY, endY) + rCcd,
          math.max(startZ, endZ) + rCcd,
        );

      _ccdBody = b;
      _ccdBestHit = null;
      _ccdHitBody = null;
      _ccdHitCollider = null;
      _ccdMaxToi = 1.0;

      // 1. Swept TOI against RigidBody3D obstacles in `broadphaseTree`.
      broadphaseTree.queryAabbCallback(_ccdSweptAabb, _onCcdBody);
      // 2. Swept TOI against the solid colliders of the collision system.
      if (colSys != null) {
        colSys.broadphaseTree.queryAabbCallback(_ccdSweptAabb, _onCcdCollider);
      }
      _ccdBody = null;

      final impact = _ccdBestHit;
      if (impact == null || impact.toi >= 1.0) {
        _integrateBodyPose(b, remDt);
        return;
      }

      final skinDist = math.min(0.002, rCcd * 0.05);
      final safeToi = math.max(0.0, impact.toi - skinDist / sweepLen);
      _integrateBodyPose(b, safeToi * remDt);

      // Refresh `b`'s proxy in the broadphase tree after moving to impact.
      final proxy = _bodyProxies[b];
      if (proxy != null) {
        b.refreshCachedWorldAabb();
        broadphaseTree.update(proxy, b.cachedWorldAabb);
      }

      if (sub >= maxImpacts) {
        // Out of impact budget: stop at the obstacle for the rest of the
        // step; the discrete contacts of the next step take over.
        return;
      }

      // Resolve the impact like a contact (restitution, friction, and the
      // effective mass at the contact point).
      final other = _ccdHitBody ?? _colliderProxy(_ccdHitCollider!);
      other.wakeUp();
      // `impact.normal` points from the obstacle toward `b`, so the A-to-B
      // normal (`b -> other`) is `-impact.normal`.
      final n = impact.normal;
      final p = impact.point;
      final c = _ccdConstraint
        ..loadSinglePoint(
          b,
          other,
          -n.x,
          -n.y,
          -n.z,
          p.x,
          p.y,
          p.z,
          0.001,
          restitutionVelocityThreshold,
        )
        ..prepare(_scratchVec, remDt, warmStart: false);
      for (var it = 0; it < velocityIterations; it++) {
        c.solveVelocity(_scratchVec);
      }

      final consumed = math.max(impact.toi, 0.05).clamp(0.0, 1.0);
      remDt *= 1.0 - consumed;
    }
  }

  void _sweepAgainstBody(int _, RigidBody3D other) {
    final b = _ccdBody!;
    if (identical(other, b) ||
        !b.canCollideWith(other) ||
        _jointBlocksCollision(b, other)) {
      return;
    }
    if (!_boxesOverlap(_ccdSweptAabb, other.cachedWorldAabb)) {
      return;
    }
    final hit = ShapeCast3D.castShapeAgainstShape(
      shapeA: _ccdSphere!,
      startTransformA: _ccdStartMat,
      delta: _ccdDelta,
      shapeB: other.shape,
      transformB: other.bodyWorldMatrix,
      maxToi: _ccdMaxToi,
      component: other.hostComponent,
    );
    if (hit == null || hit.toi > _ccdMaxToi) {
      return;
    }
    final prevBody = _ccdHitBody;
    // Equal times of impact: the lower creation id wins, whatever the order
    // in which the tree visits the candidates.
    if (hit.toi == _ccdMaxToi &&
        _ccdBestHit != null &&
        (_ccdHitCollider != null ||
            (prevBody != null &&
                prevBody.deterministicId < other.deterministicId))) {
      return;
    }
    _ccdMaxToi = hit.toi;
    _ccdBestHit = hit;
    _ccdHitBody = other;
    _ccdHitCollider = null;
  }

  void _sweepAgainstCollider(int _, Collider3D collider) {
    final b = _ccdBody!;
    if (!_isSolidColliderFor(collider, b)) {
      return;
    }
    if (!_boxesOverlap(_ccdSweptAabb, collider.colliderWorldAabb)) {
      return;
    }
    final hit = ShapeCast3D.castShapeAgainstShape(
      shapeA: _ccdSphere!,
      startTransformA: _ccdStartMat,
      delta: _ccdDelta,
      shapeB: collider.shape,
      transformB: collider.colliderWorldMatrix,
      maxToi: _ccdMaxToi,
      component: collider.hostComponent,
      collider: collider,
    );
    if (hit == null || hit.toi > _ccdMaxToi) {
      return;
    }
    final prevCollider = _ccdHitCollider;
    if (hit.toi == _ccdMaxToi &&
        _ccdBestHit != null &&
        (prevCollider == null ||
            (_colliderOrder[prevCollider] ?? 0) <
                (_colliderOrder[collider] ?? 0))) {
      return;
    }
    _ccdMaxToi = hit.toi;
    _ccdBestHit = hit;
    _ccdHitBody = null;
    _ccdHitCollider = collider;
  }

  CollisionSystem3D? _resolveCollisionSystem() {
    if (collisionSystem != null) {
      return collisionSystem;
    }
    final root = parent;
    if (root != null) {
      for (final child in root.children) {
        if (child is CollisionSystem3D) {
          return child;
        }
      }
    }
    return null;
  }

  /// Rebuilds [_activeBodies] (sorted by creation id) when the registered set
  /// changed. A world that has a parent but is not mounted (a component tree
  /// built without a game) searches its parent's subtree on every step.
  void _refreshBodies() {
    final root = parent;
    final walk = root != null && !isMounted;
    if (!walk && !_bodiesDirty) {
      return;
    }
    _bodiesDirty = false;
    _activeBodies.clear();
    final seen = _seenBodiesScratch..clear();
    for (var i = 0; i < _manualBodies.length; i++) {
      final b = _manualBodies[i];
      if (seen.add(b)) {
        _activeBodies.add(b);
      }
    }
    for (final b in _mountedBodies) {
      if (seen.add(b)) {
        _activeBodies.add(b);
      }
    }
    if (walk) {
      _walkStack
        ..clear()
        ..add(root);
      while (_walkStack.isNotEmpty) {
        final comp = _walkStack.removeLast();
        if (comp is RigidBody3D && seen.add(comp)) {
          _activeBodies.add(comp);
        }
        _walkStack.addAll(comp.children);
      }
    }
    // Deterministic ordering by `deterministicId`.
    _activeBodies.sort(_compareIds);

    // Drop broadphase proxies of bodies that left the world.
    if (_bodyProxies.length > _activeBodies.length || walk) {
      _staleBodiesScratch.clear();
      for (final b in _bodyProxies.keys) {
        if (!seen.contains(b)) {
          _staleBodiesScratch.add(b);
        }
      }
      for (var i = 0; i < _staleBodiesScratch.length; i++) {
        final proxy = _bodyProxies.remove(_staleBodiesScratch[i]);
        if (proxy != null) {
          broadphaseTree.remove(proxy);
        }
      }
    }
  }

  static int _compareIds(RigidBody3D a, RigidBody3D b) =>
      a.deterministicId.compareTo(b.deterministicId);

  void _syncBroadphaseTree() {
    for (var i = 0; i < _activeBodies.length; i++) {
      final b = _activeBodies[i];
      final moved = b.refreshCachedWorldAabb();
      final existing = _bodyProxies[b];
      if (existing == null) {
        _bodyProxies[b] = broadphaseTree.insert(b, b.cachedWorldAabb);
      } else if (moved) {
        broadphaseTree.update(existing, b.cachedWorldAabb);
      }
    }
  }

  /// Synchronizes the collision system's tree and the deterministic order of
  /// its colliders (their position in `collectColliders`).
  void _syncColliders(CollisionSystem3D? colSys) {
    if (colSys == null) {
      return;
    }
    final colliders = colSys.syncBroadphase();
    var same =
        identical(colSys, _orderedSystem) &&
        colliders.length == _colliderOrderList.length;
    for (var i = 0; same && i < colliders.length; i++) {
      same = identical(colliders[i], _colliderOrderList[i]);
    }
    if (same) {
      return;
    }
    _orderedSystem = colSys;
    _colliderOrderList
      ..clear()
      ..addAll(colliders);
    _colliderOrder.clear();
    for (var i = 0; i < colliders.length; i++) {
      _colliderOrder[colliders[i]] = i;
    }
    // Forget proxies of colliders that are gone.
    _staleColliderScratch.clear();
    for (final c in _colliderProxies.keys) {
      if (!_colliderOrder.containsKey(c)) {
        _staleColliderScratch.add(c);
      }
    }
    for (final c in _staleColliderScratch) {
      final proxy = _colliderProxies.remove(c);
      if (proxy != null) {
        _proxyColliders.remove(proxy);
      }
    }
  }

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

  /// The static infinite-mass body standing in for [collider] in contacts.
  RigidBody3D _colliderProxy(Collider3D collider) {
    var proxy = _colliderProxies[collider];
    if (proxy == null) {
      proxy = RigidBody3D(
        shape: collider.shape,
        bodyType: BodyType3D.static,
        syncParent: false,
      );
      _colliderProxies[collider] = proxy;
      _proxyColliders[proxy] = collider;
    }
    proxy.material = collider.material;
    return proxy;
  }

  bool _jointBlocksCollision(RigidBody3D a, RigidBody3D b) {
    for (var i = 0; i < _joints.length; i++) {
      final j = _joints[i];
      if (!j.collideConnected &&
          ((identical(j.bodyA, a) && identical(j.bodyB, b)) ||
              (identical(j.bodyA, b) && identical(j.bodyB, a)))) {
        return true;
      }
    }
    return false;
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

  void _collectBodyCandidate(int _, RigidBody3D cand) {
    final bodyA = _queryBody!;
    if (cand.deterministicId <= bodyA.deterministicId) {
      return;
    }
    if (!bodyA.canCollideWith(cand)) {
      return;
    }
    if (_isInactive(bodyA) && _isInactive(cand)) {
      return;
    }
    if (!_boxesOverlap(bodyA.cachedWorldAabb, cand.cachedWorldAabb)) {
      return;
    }
    if (_jointBlocksCollision(bodyA, cand)) {
      return;
    }
    _pairCandidates.add(cand);
  }

  void _collectColliderCandidate(int _, Collider3D collider) {
    final body = _queryBody!;
    if (!_isSolidColliderFor(collider, body)) {
      return;
    }
    if (!_boxesOverlap(body.cachedWorldAabb, collider.colliderWorldAabb)) {
      return;
    }
    _colliderCandidates.add(collider);
  }

  int _compareColliderOrder(Collider3D a, Collider3D b) =>
      (_colliderOrder[a] ?? 0).compareTo(_colliderOrder[b] ?? 0);

  late final int Function(Collider3D, Collider3D) _colliderComparator =
      _compareColliderOrder;

  void _buildContactConstraints(CollisionSystem3D? colSys) {
    _constraints.clear();
    final wakeVelThresh2 =
        (sleepLinearThreshold * 2.0) * (sleepLinearThreshold * 2.0);

    for (var i = 0; i < _activeBodies.length; i++) {
      final bodyA = _activeBodies[i];
      _queryBody = bodyA;
      _pairCandidates.clear();
      broadphaseTree.queryAabbCallback(bodyA.cachedWorldAabb, _onBodyCandidate);
      if (_pairCandidates.length > 1) {
        _pairCandidates.sort(_compareIds);
      }

      for (var j = 0; j < _pairCandidates.length; j++) {
        final bodyB = _pairCandidates[j];
        final manifolds = Narrowphase3D.testAll(
          bodyA.shape,
          bodyA.bodyWorldMatrix,
          bodyB.shape,
          bodyB.bodyWorldMatrix,
        );
        if (manifolds.isEmpty) {
          continue;
        }
        _wakeOnContact(bodyA, bodyB, manifolds, wakeVelThresh2);
        _addPairConstraints(bodyA, bodyB, manifolds);
      }

      // Static colliders hold up awake dynamic bodies.
      if (colSys != null &&
          bodyA.bodyType == BodyType3D.dynamic &&
          !bodyA.isSleeping) {
        _colliderCandidates.clear();
        colSys.broadphaseTree.queryAabbCallback(
          bodyA.cachedWorldAabb,
          _onColliderCandidate,
        );
        if (_colliderCandidates.length > 1) {
          _colliderCandidates.sort(_colliderComparator);
        }
        for (var k = 0; k < _colliderCandidates.length; k++) {
          final collider = _colliderCandidates[k];
          final manifolds = Narrowphase3D.testAll(
            bodyA.shape,
            bodyA.bodyWorldMatrix,
            collider.shape,
            collider.colliderWorldMatrix,
          );
          if (manifolds.isEmpty) {
            continue;
          }
          _addPairConstraints(bodyA, _colliderProxy(collider), manifolds);
        }
      }
    }
    _queryBody = null;
    _sweepStalePairs();
  }

  void _wakeOnContact(
    RigidBody3D bodyA,
    RigidBody3D bodyB,
    List<CollisionManifold3D> manifolds,
    double wakeVelThresh2,
  ) {
    final aSleeping = bodyA.bodyType == BodyType3D.dynamic && bodyA.isSleeping;
    final bSleeping = bodyB.bodyType == BodyType3D.dynamic && bodyB.isSleeping;
    if (aSleeping == bSleeping) {
      return;
    }
    final sleeper = aSleeping ? bodyA : bodyB;
    final other = aSleeping ? bodyB : bodyA;
    if (other.bodyType == BodyType3D.kinematic) {
      // A moving kinematic body pushes whatever it touches.
      sleeper.wakeUp();
      return;
    }
    if (other.bodyType != BodyType3D.dynamic) {
      return;
    }
    var deepest = 0.0;
    for (var m = 0; m < manifolds.length; m++) {
      deepest = math.max(deepest, manifolds[m].penetrationDepth);
    }
    final dvx = bodyB.linearVelocity.x - bodyA.linearVelocity.x;
    final dvy = bodyB.linearVelocity.y - bodyA.linearVelocity.y;
    final dvz = bodyB.linearVelocity.z - bodyA.linearVelocity.z;
    // A partner that is moving (its sleep timer was reset, or it was just
    // woken) wakes the sleeper, so a touching group wakes as a whole.
    if (other.sleepTimer == 0.0 ||
        dvx * dvx + dvy * dvy + dvz * dvz > wakeVelThresh2 ||
        deepest > 0.01) {
      bodyA.wakeUp();
      bodyB.wakeUp();
    }
  }

  void _addPairConstraints(
    RigidBody3D bodyA,
    RigidBody3D bodyB,
    List<CollisionManifold3D> manifolds,
  ) {
    final pair = _acquirePair(bodyA, bodyB)..lastTick = _tick;
    for (var m = 0; m < manifolds.length; m++) {
      final c = pair.constraintAt(m)
        ..load(
          bodyA,
          bodyB,
          manifolds[m],
          m,
          restitutionVelocityThreshold,
          math.max(0.002, 2.0 * linearSlop),
        );
      _constraints.add(c);
    }
    pair.manifoldCount = manifolds.length;
  }

  _ContactPair3D _acquirePair(RigidBody3D bodyA, RigidBody3D bodyB) {
    var list = _pairsByBodyA[bodyA];
    if (list != null) {
      for (var i = 0; i < list.length; i++) {
        if (identical(list[i].bodyB, bodyB)) {
          return list[i];
        }
      }
    } else {
      list = _pairsByBodyA[bodyA] = <_ContactPair3D>[];
    }
    final pair = _pairPool.isNotEmpty
        ? _pairPool.removeLast()
        : _ContactPair3D();
    pair.reset(bodyA, bodyB);
    list.add(pair);
    _pairList.add(pair);
    return pair;
  }

  void _sweepStalePairs() {
    final tick = _tick;
    var write = 0;
    for (var i = 0; i < _pairList.length; i++) {
      final pair = _pairList[i];
      if (pair.lastTick == tick) {
        _pairList[write++] = pair;
        continue;
      }
      final list = _pairsByBodyA[pair.bodyA];
      if (list != null) {
        list.remove(pair);
        if (list.isEmpty) {
          _pairsByBodyA.remove(pair.bodyA);
        }
      }
      _pairPool.add(pair);
    }
    _pairList.length = write;
  }

  /// Internal snapshot hook: the warm-start history of every contact pair,
  /// with bodies given as indices into [bodies] and static colliders as
  /// `colliderFlag | index` into the collision system's collider order.
  @internal
  List<WarmContactRecord3D> exportWarmStartRecords(List<RigidBody3D> bodies) {
    final index = <RigidBody3D, int>{
      for (var i = 0; i < bodies.length; i++) bodies[i]: i,
    };
    final keyed = <(int, int, _ContactPair3D)>[];
    for (final pair in _pairList) {
      final a = index[pair.bodyA];
      if (a == null) {
        continue;
      }
      var b = index[pair.bodyB];
      if (b == null) {
        final collider = _proxyColliders[pair.bodyB];
        final order = collider == null ? null : _colliderOrder[collider];
        if (order == null) {
          continue;
        }
        b = WarmContactRecord3D.colliderFlag | order;
      }
      keyed.add((a, b, pair));
    }
    keyed.sort((x, y) => x.$1 != y.$1 ? x.$1 - y.$1 : x.$2 - y.$2);
    final records = <WarmContactRecord3D>[];
    for (final (a, b, pair) in keyed) {
      for (var m = 0; m < pair.manifoldCount; m++) {
        final c = pair.constraintAt(m);
        for (var k = 0; k < c.prevCount; k++) {
          const stride = _ContactConstraint3D.historyStride;
          records.add(
            WarmContactRecord3D(
              bodyA: a,
              bodyB: b,
              manifold: m,
              featureId: c.prevIds[k],
              values: Float64List.sublistView(
                c.prevImpulses,
                k * stride,
                (k + 1) * stride,
              ),
            ),
          );
        }
      }
    }
    return records;
  }

  /// Internal snapshot hook restoring the simulation clock and the warm-start
  /// history exported by [exportWarmStartRecords], with record bodies looked
  /// up in [bodies] (`null` entries are skipped).
  @internal
  void restoreInternalState({
    required int tick,
    required double accumulator,
    required List<RigidBody3D?> bodies,
    required List<WarmContactRecord3D> warmRecords,
  }) {
    _tick = tick;
    _accumulator = accumulator;
    for (final pair in _pairList) {
      _pairPool.add(pair);
    }
    _pairList.clear();
    _pairsByBodyA.clear();

    final colSys = _resolveCollisionSystem();
    _syncColliders(colSys);
    for (final r in warmRecords) {
      if (r.bodyA < 0 || r.bodyA >= bodies.length) {
        continue;
      }
      final a = bodies[r.bodyA];
      if (a == null) {
        continue;
      }
      RigidBody3D? b;
      if ((r.bodyB & WarmContactRecord3D.colliderFlag) != 0) {
        final order = r.bodyB & ~WarmContactRecord3D.colliderFlag;
        if (order < _colliderOrderList.length) {
          b = _colliderProxy(_colliderOrderList[order]);
        }
      } else if (r.bodyB >= 0 && r.bodyB < bodies.length) {
        b = bodies[r.bodyB];
      }
      if (b == null) {
        continue;
      }
      final pair = _acquirePair(a, b)..lastTick = tick;
      if (r.manifold + 1 > pair.manifoldCount) {
        pair.manifoldCount = r.manifold + 1;
      }
      pair.constraintAt(r.manifold).appendHistory(r.featureId, r.values, 0);
    }
    _bodiesDirty = true;
    _refreshBodies();
    _syncBroadphaseTree();
  }

  static bool _boxesOverlap(Aabb3 a, Aabb3 b) {
    return a.min.x <= b.max.x &&
        a.max.x >= b.min.x &&
        a.min.y <= b.max.y &&
        a.max.y >= b.min.y &&
        a.min.z <= b.max.z &&
        a.max.z >= b.min.z;
  }
}

/// One warm-started contact point of a [PhysicsWorld3D] as stored in a
/// [PhysicsSnapshot3D]: bodies are indices into the snapshot's body records.
///
/// [values] holds [valueCount] doubles: the normal impulse, the friction
/// impulse `(x, y, z)` and the point's offset on body A in A's frame.
@internal
class WarmContactRecord3D({
  required final int bodyA,
  required final int bodyB,
  required final int manifold,
  required final int featureId,
  required Float64List values,
}) {
  /// Number of doubles in [values].
  static const int valueCount = _ContactConstraint3D.historyStride;

  /// Normal impulse, friction impulse and contact offset (a copy).
  final Float64List values = Float64List.fromList(values);

  /// Set in [bodyB] when it names a static collider instead of a body.
  static const int colliderFlag = 0x40000000;
}

/// Persistent contact state between two bodies (one constraint per manifold),
/// kept while they touch so impulses carry over to the next step.
class _ContactPair3D() {
  late RigidBody3D bodyA;
  late RigidBody3D bodyB;
  int lastTick = -1;
  int manifoldCount = 0;
  final List<_ContactConstraint3D> _manifolds = [];

  void reset(RigidBody3D a, RigidBody3D b) {
    bodyA = a;
    bodyB = b;
    lastTick = -1;
    manifoldCount = 0;
    for (var i = 0; i < _manifolds.length; i++) {
      _manifolds[i].clearHistory();
    }
  }

  _ContactConstraint3D constraintAt(int index) {
    while (_manifolds.length <= index) {
      _manifolds.add(_ContactConstraint3D());
    }
    final c = _manifolds[index];
    if (index >= manifoldCount) {
      // A manifold slot unused last step carries no history.
      c.clearHistory();
    }
    return c;
  }
}

class _ContactPointState() {
  final Vector3 localOffsetA = Vector3.zero();
  final Vector3 localOffsetB = Vector3.zero();
  final Vector3 rA = Vector3.zero();
  final Vector3 rB = Vector3.zero();
  double depth = 0.0;
  // Gap along the normal at creation (`> 0`: apart, a speculative point).
  double separation = 0.0;
  int featureId = 0;

  double effMassN = 0.0;
  double effMassT1 = 0.0;
  double effMassT2 = 0.0;
  double bounceTargetVn = 0.0;

  double jn = 0.0;
  double jt1 = 0.0;
  double jt2 = 0.0;

  // Last step's impulse of the point with the same feature id, if any.
  bool hasWarm = false;
  double warmJn = 0.0;
  double warmJtx = 0.0;
  double warmJty = 0.0;
  double warmJtz = 0.0;
}

class _ContactConstraint3D() {
  late RigidBody3D bodyA;
  late RigidBody3D bodyB;
  int manifoldIndex = 0;
  final Vector3 normal = Vector3.zero();
  final Vector3 t1 = Vector3.zero();
  final Vector3 t2 = Vector3.zero();
  double restitution = 0.0;
  double friction = 0.0;
  double restitutionThreshold = 0.5;

  // Whether each body takes impulses (dynamic and awake), and its inverse
  // mass as seen by this contact: a sleeping or static partner counts as
  // infinitely heavy, consistently in effective masses and impulses.
  bool useA = false;
  bool useB = false;
  double imA = 0.0;
  double imB = 0.0;

  final List<_ContactPointState> _points = [];
  int pointCount = 0;

  // Impulses at the end of the previous step, per point: feature id, then
  // `jn, jtx, jty, jtz` and the point's offset on body A in A's frame.
  static const int historyStride = 7;
  Int32List prevIds = Int32List(4);
  Float64List prevImpulses = Float64List(4 * historyStride);
  int prevCount = 0;

  /// Distance within which a point without a matching feature id takes over
  /// the impulse of the nearest unmatched point of the previous step.
  double matchDistance = 0.008;

  static final Vector3 _offA = Vector3.zero();
  static final Vector3 _offB = Vector3.zero();
  static final Vector3 _posRA = Vector3.zero();
  static final Vector3 _posRB = Vector3.zero();

  void clearHistory() {
    prevCount = 0;
  }

  void appendHistory(int id, Float64List values, int offset) {
    _ensureHistory(prevCount + 1);
    prevIds[prevCount] = id;
    prevImpulses.setRange(
      prevCount * historyStride,
      (prevCount + 1) * historyStride,
      values,
      offset,
    );
    prevCount++;
  }

  void _ensureHistory(int count) {
    if (prevIds.length < count) {
      final cap = count * 2;
      prevIds = Int32List(cap)..setRange(0, prevCount, prevIds);
      prevImpulses = Float64List(cap * historyStride)
        ..setRange(0, prevCount * historyStride, prevImpulses);
    }
  }

  void load(
    RigidBody3D a,
    RigidBody3D b,
    CollisionManifold3D manifold,
    int mIdx,
    double threshold,
    double matchDist,
  ) {
    matchDistance = matchDist;
    final n = manifold.normal;
    _begin(a, b, mIdx, threshold, n.x, n.y, n.z);
    final contacts = manifold.contacts;
    for (var i = 0; i < contacts.length; i++) {
      final cp = contacts[i];
      final pa = cp.pointA;
      final pb = cp.pointB;
      _addPoint(
        pa.x,
        pa.y,
        pa.z,
        pb.x,
        pb.y,
        pb.z,
        cp.penetrationDepth,
        cp.featureId,
      );
    }
    _matchHistory();
  }

  void loadSinglePoint(
    RigidBody3D a,
    RigidBody3D b,
    double nx,
    double ny,
    double nz,
    double px,
    double py,
    double pz,
    double depth,
    double threshold,
  ) {
    _begin(a, b, 0, threshold, nx, ny, nz);
    prevCount = 0;
    _addPoint(px, py, pz, px, py, pz, depth, 0);
  }

  void _begin(
    RigidBody3D a,
    RigidBody3D b,
    int mIdx,
    double threshold,
    double nx,
    double ny,
    double nz,
  ) {
    bodyA = a;
    bodyB = b;
    manifoldIndex = mIdx;
    restitutionThreshold = threshold;
    normal.setValues(nx, ny, nz);
    if (nx.abs() < 0.9) {
      t1.setValues(0.0, -nz, ny);
    } else {
      t1.setValues(-nz, 0.0, nx);
    }
    t1.normalize();
    t2.setValues(
      ny * t1.z - nz * t1.y,
      nz * t1.x - nx * t1.z,
      nx * t1.y - ny * t1.x,
    );
    restitution = _resolveRestitution(a, b);
    friction = _resolveFriction(a, b);
    useA =
        a.bodyType == BodyType3D.dynamic &&
        !a.isSleeping &&
        a.inverseMass > 0.0;
    useB =
        b.bodyType == BodyType3D.dynamic &&
        !b.isSleeping &&
        b.inverseMass > 0.0;
    imA = useA ? a.inverseMass : 0.0;
    imB = useB ? b.inverseMass : 0.0;
    pointCount = 0;
  }

  void _addPoint(
    double pax,
    double pay,
    double paz,
    double pbx,
    double pby,
    double pbz,
    double depth,
    int featureId,
  ) {
    if (_points.length <= pointCount) {
      _points.add(_ContactPointState());
    }
    final p = _points[pointCount++];
    final posA = bodyA.bodyPosition;
    final posB = bodyB.bodyPosition;
    final comA = bodyA.worldCenterOfMass;
    p.rA.setValues(pax - comA.x, pay - comA.y, paz - comA.z);
    final comB = bodyB.worldCenterOfMass;
    p.rB.setValues(pbx - comB.x, pby - comB.y, pbz - comB.z);
    _offA.setValues(pax - posA.x, pay - posA.y, paz - posA.z);
    _offB.setValues(pbx - posB.x, pby - posB.y, pbz - posB.z);
    _unrotateByQuat(bodyA.bodyRotation, _offA, p.localOffsetA);
    _unrotateByQuat(bodyB.bodyRotation, _offB, p.localOffsetB);
    p
      ..depth = depth
      ..separation =
          (pbx - pax) * normal.x +
          (pby - pay) * normal.y +
          (pbz - paz) * normal.z
      ..featureId = featureId
      ..hasWarm = false
      ..jn = 0.0
      ..jt1 = 0.0
      ..jt2 = 0.0;
  }

  /// Gives each point last step's impulse of the point with the same feature
  /// id; then each point still without one takes the impulse of the nearest
  /// remaining point of the previous step within [matchDistance] (on body A).
  /// Each previous point is used once.
  void _matchHistory() {
    if (prevCount == 0) {
      return;
    }
    var consumed = 0;
    for (var i = 0; i < pointCount; i++) {
      final p = _points[i];
      for (var k = 0; k < prevCount && k < 30; k++) {
        if ((consumed & (1 << k)) == 0 && prevIds[k] == p.featureId) {
          _takeHistory(p, k);
          consumed |= 1 << k;
          break;
        }
      }
    }
    final maxD2 = matchDistance * matchDistance;
    for (var i = 0; i < pointCount; i++) {
      final p = _points[i];
      if (p.hasWarm) {
        continue;
      }
      var match = -1;
      var bestD2 = maxD2;
      final la = p.localOffsetA;
      for (var k = 0; k < prevCount && k < 30; k++) {
        if ((consumed & (1 << k)) != 0) {
          continue;
        }
        final o = k * historyStride;
        final dx = prevImpulses[o + 4] - la.x;
        final dy = prevImpulses[o + 5] - la.y;
        final dz = prevImpulses[o + 6] - la.z;
        final d2 = dx * dx + dy * dy + dz * dz;
        if (d2 < bestD2) {
          bestD2 = d2;
          match = k;
        }
      }
      if (match >= 0) {
        _takeHistory(p, match);
        consumed |= 1 << match;
      }
    }
  }

  void _takeHistory(_ContactPointState p, int k) {
    final o = k * historyStride;
    p
      ..hasWarm = true
      ..warmJn = prevImpulses[o]
      ..warmJtx = prevImpulses[o + 1]
      ..warmJty = prevImpulses[o + 2]
      ..warmJtz = prevImpulses[o + 3];
  }

  static double _resolveRestitution(RigidBody3D a, RigidBody3D b) {
    final mA = a.material;
    final mB = b.material;
    if (mA == null && mB == null) {
      return math.max(a.restitution, b.restitution);
    }
    final modeA = mA?.restitutionCombine ?? PhysicsCombineMode3D.maximum;
    final modeB = mB?.restitutionCombine ?? PhysicsCombineMode3D.maximum;
    final mode = modeA.index >= modeB.index ? modeA : modeB;
    return mode
        .combine(
          mA?.restitution ?? a.restitution,
          mB?.restitution ?? b.restitution,
        )
        .clamp(0.0, 1.0);
  }

  static double _resolveFriction(RigidBody3D a, RigidBody3D b) {
    final mA = a.material;
    final mB = b.material;
    if (mA == null && mB == null) {
      return math.sqrt(math.max(0.0, a.friction * b.friction));
    }
    final modeA = mA?.frictionCombine ?? PhysicsCombineMode3D.average;
    final modeB = mB?.frictionCombine ?? PhysicsCombineMode3D.average;
    final mode = modeA.index >= modeB.index ? modeA : modeB;
    return math.max(
      0.0,
      mode.combine(mA?.friction ?? a.friction, mB?.friction ?? b.friction),
    );
  }

  void prepare(Vector3 scratch, double dt, {required bool warmStart}) {
    final invDt = dt > 0.0 ? 1.0 / dt : 0.0;
    for (var i = 0; i < pointCount; i++) {
      final p = _points[i];
      p.effMassN = _axisMass(p.rA, p.rB, normal, scratch);
      p.effMassT1 = _axisMass(p.rA, p.rB, t1, scratch);
      p.effMassT2 = _axisMass(p.rA, p.rB, t2, scratch);

      // Measure pre-impact normal velocity BEFORE warm-starting!
      final vnPre = _relVelDot(p.rA, p.rB, normal);
      if (p.separation > 0.0) {
        // Speculative point: it may close its gap during this step, no more.
        p.bounceTargetVn = -p.separation * invDt;
        if (warmStart && p.hasWarm && p.warmJn > 0.0) {
          _applyWarm(p, scratch);
        } else {
          p
            ..jn = 0.0
            ..jt1 = 0.0
            ..jt2 = 0.0;
        }
        continue;
      }
      if (vnPre < -restitutionThreshold && restitution > 0.0) {
        p
          ..bounceTargetVn = -restitution * vnPre
          ..jn = 0.0
          ..jt1 = 0.0
          ..jt2 = 0.0;
        continue;
      }
      p.bounceTargetVn = 0.0;
      // Warm-start resting contacts only so bounces stay exact.
      if (warmStart && p.hasWarm) {
        _applyWarm(p, scratch);
      } else {
        p
          ..jn = 0.0
          ..jt1 = 0.0
          ..jt2 = 0.0;
      }
    }
  }

  void _applyWarm(_ContactPointState p, Vector3 scratch) {
    p
      ..jn = p.warmJn
      ..jt1 = p.warmJtx * t1.x + p.warmJty * t1.y + p.warmJtz * t1.z
      ..jt2 = p.warmJtx * t2.x + p.warmJty * t2.y + p.warmJtz * t2.z;
    final ix = normal.x * p.jn + t1.x * p.jt1 + t2.x * p.jt2;
    final iy = normal.y * p.jn + t1.y * p.jt1 + t2.y * p.jt2;
    final iz = normal.z * p.jn + t1.z * p.jt1 + t2.z * p.jt2;
    _applyImpulse(p.rA, p.rB, ix, iy, iz, scratch);
  }

  void solveVelocity(Vector3 scratch) {
    // Friction first, within the cone of the current normal impulses, then
    // the normal impulses, so non-penetration has the last word.
    if (friction > 0.0) {
      for (var i = 0; i < pointCount; i++) {
        final p = _points[i];
        if (p.jn <= 0.0) {
          continue;
        }
        final vt1 = _relVelDot(p.rA, p.rB, t1);
        final vt2 = _relVelDot(p.rA, p.rB, t2);
        final candT1 = p.jt1 - p.effMassT1 * vt1;
        final candT2 = p.jt2 - p.effMassT2 * vt2;
        final maxFriction = friction * p.jn;
        final mag2 = candT1 * candT1 + candT2 * candT2;

        double nextT1;
        double nextT2;
        if (mag2 > maxFriction * maxFriction && mag2 > 1e-24) {
          final scale = maxFriction / math.sqrt(mag2);
          nextT1 = candT1 * scale;
          nextT2 = candT2 * scale;
        } else {
          nextT1 = candT1;
          nextT2 = candT2;
        }

        final dJt1 = nextT1 - p.jt1;
        final dJt2 = nextT2 - p.jt2;
        p.jt1 = nextT1;
        p.jt2 = nextT2;
        if (dJt1.abs() > 1e-14 || dJt2.abs() > 1e-14) {
          _applyImpulse(
            p.rA,
            p.rB,
            t1.x * dJt1 + t2.x * dJt2,
            t1.y * dJt1 + t2.y * dJt2,
            t1.z * dJt1 + t2.z * dJt2,
            scratch,
          );
        }
      }
    }

    for (var i = 0; i < pointCount; i++) {
      final p = _points[i];
      final vn = _relVelDot(p.rA, p.rB, normal);
      var dJn = p.effMassN * (p.bounceTargetVn - vn);
      final prevJn = p.jn;
      p.jn = math.max(0.0, prevJn + dJn);
      dJn = p.jn - prevJn;
      if (dJn.abs() > 1e-14) {
        _applyImpulse(
          p.rA,
          p.rB,
          normal.x * dJn,
          normal.y * dJn,
          normal.z * dJn,
          scratch,
        );
      }
    }
  }

  static final Vector3 _posScratch = Vector3.zero();

  void solvePosition(double slop) {
    if (!useA && !useB) {
      return;
    }
    final baumgarte = 0.25 / math.max(1, pointCount);
    final offA = _offA;
    final offB = _offB;
    final rA = _posRA;
    final rB = _posRB;
    final scratch = _posScratch;

    for (var i = 0; i < pointCount; i++) {
      final p = _points[i];
      _rotateByQuat(bodyA.bodyRotation, p.localOffsetA, offA);
      _rotateByQuat(bodyB.bodyRotation, p.localOffsetB, offB);
      final wAx = bodyA.bodyPosition.x + offA.x;
      final wAy = bodyA.bodyPosition.y + offA.y;
      final wAz = bodyA.bodyPosition.z + offA.z;
      final wBx = bodyB.bodyPosition.x + offB.x;
      final wBy = bodyB.bodyPosition.y + offB.y;
      final wBz = bodyB.bodyPosition.z + offB.z;

      // Current penetration along `normal` (`(wA - wB) . normal > 0`).
      final pen =
          (wAx - wBx) * normal.x +
          (wAy - wBy) * normal.y +
          (wAz - wBz) * normal.z;
      final corr = math.min(0.15, math.max(0.0, pen - slop) * baumgarte);
      if (corr <= 1e-7) {
        continue;
      }

      final comA = bodyA.worldCenterOfMass;
      rA.setValues(wAx - comA.x, wAy - comA.y, wAz - comA.z);
      final comB = bodyB.worldCenterOfMass;
      rB.setValues(wBx - comB.x, wBy - comB.y, wBz - comB.z);

      final massN = _axisMass(rA, rB, normal, scratch);
      if (massN <= 0.0) {
        continue;
      }
      final pImpulse = massN * corr;
      final px = normal.x * pImpulse;
      final py = normal.y * pImpulse;
      final pz = normal.z * pImpulse;

      if (useA) {
        final posA = bodyA.bodyPosition;
        posA.setValues(
          posA.x - px * imA,
          posA.y - py * imA,
          posA.z - pz * imA,
        );
        final tx = rA.y * pz - rA.z * py;
        final ty = rA.z * px - rA.x * pz;
        final tz = rA.x * py - rA.y * px;
        bodyA.multiplyWorldInvInertia(-tx, -ty, -tz, scratch);
        _applyDeltaQuat(bodyA, scratch);
      }
      if (useB) {
        final posB = bodyB.bodyPosition;
        posB.setValues(
          posB.x + px * imB,
          posB.y + py * imB,
          posB.z + pz * imB,
        );
        final tx = rB.y * pz - rB.z * py;
        final ty = rB.z * px - rB.x * pz;
        final tz = rB.x * py - rB.y * px;
        bodyB.multiplyWorldInvInertia(tx, ty, tz, scratch);
        _applyDeltaQuat(bodyB, scratch);
      }
    }
  }

  void saveWarmImpulses() {
    prevCount = 0;
    _ensureHistory(pointCount);
    for (var i = 0; i < pointCount; i++) {
      final p = _points[i];
      prevIds[i] = p.featureId;
      final o = i * historyStride;
      prevImpulses[o] = p.jn;
      prevImpulses[o + 1] = t1.x * p.jt1 + t2.x * p.jt2;
      prevImpulses[o + 2] = t1.y * p.jt1 + t2.y * p.jt2;
      prevImpulses[o + 3] = t1.z * p.jt1 + t2.z * p.jt2;
      prevImpulses[o + 4] = p.localOffsetA.x;
      prevImpulses[o + 5] = p.localOffsetA.y;
      prevImpulses[o + 6] = p.localOffsetA.z;
    }
    prevCount = pointCount;
  }

  double _axisMass(Vector3 rA, Vector3 rB, Vector3 axis, Vector3 scratch) {
    var k = imA + imB;
    if (useA) {
      final cx = rA.y * axis.z - rA.z * axis.y;
      final cy = rA.z * axis.x - rA.x * axis.z;
      final cz = rA.x * axis.y - rA.y * axis.x;
      bodyA.multiplyWorldInvInertia(cx, cy, cz, scratch);
      k += cx * scratch.x + cy * scratch.y + cz * scratch.z;
    }
    if (useB) {
      final cx = rB.y * axis.z - rB.z * axis.y;
      final cy = rB.z * axis.x - rB.x * axis.z;
      final cz = rB.x * axis.y - rB.y * axis.x;
      bodyB.multiplyWorldInvInertia(cx, cy, cz, scratch);
      k += cx * scratch.x + cy * scratch.y + cz * scratch.z;
    }
    return k > 1e-12 ? 1.0 / k : 0.0;
  }

  double _relVelDot(Vector3 rA, Vector3 rB, Vector3 axis) {
    final vAx =
        bodyA.linearVelocity.x +
        (bodyA.angularVelocity.y * rA.z - bodyA.angularVelocity.z * rA.y);
    final vAy =
        bodyA.linearVelocity.y +
        (bodyA.angularVelocity.z * rA.x - bodyA.angularVelocity.x * rA.z);
    final vAz =
        bodyA.linearVelocity.z +
        (bodyA.angularVelocity.x * rA.y - bodyA.angularVelocity.y * rA.x);

    final vBx =
        bodyB.linearVelocity.x +
        (bodyB.angularVelocity.y * rB.z - bodyB.angularVelocity.z * rB.y);
    final vBy =
        bodyB.linearVelocity.y +
        (bodyB.angularVelocity.z * rB.x - bodyB.angularVelocity.x * rB.z);
    final vBz =
        bodyB.linearVelocity.z +
        (bodyB.angularVelocity.x * rB.y - bodyB.angularVelocity.y * rB.x);

    return (vBx - vAx) * axis.x + (vBy - vAy) * axis.y + (vBz - vAz) * axis.z;
  }

  void _applyImpulse(
    Vector3 rA,
    Vector3 rB,
    double px,
    double py,
    double pz,
    Vector3 scratch,
  ) {
    if (useA) {
      bodyA.linearVelocity.setValues(
        bodyA.linearVelocity.x - px * imA,
        bodyA.linearVelocity.y - py * imA,
        bodyA.linearVelocity.z - pz * imA,
      );
      final tx = rA.y * pz - rA.z * py;
      final ty = rA.z * px - rA.x * pz;
      final tz = rA.x * py - rA.y * px;
      bodyA.multiplyWorldInvInertia(tx, ty, tz, scratch);
      bodyA.angularVelocity.sub(scratch);
    }
    if (useB) {
      bodyB.linearVelocity.setValues(
        bodyB.linearVelocity.x + px * imB,
        bodyB.linearVelocity.y + py * imB,
        bodyB.linearVelocity.z + pz * imB,
      );
      final tx = rB.y * pz - rB.z * py;
      final ty = rB.z * px - rB.x * pz;
      final tz = rB.x * py - rB.y * px;
      bodyB.multiplyWorldInvInertia(tx, ty, tz, scratch);
      bodyB.angularVelocity.add(scratch);
    }
  }

  static final Vector3 _deltaComRotScratch = Vector3.zero();

  static void _applyDeltaQuat(RigidBody3D body, Vector3 dTheta) {
    final angle = dTheta.length;
    if (angle <= 1e-8) {
      return;
    }
    final hasCom = body.hasCenterOfMassOffset;
    var oldComX = 0.0;
    var oldComY = 0.0;
    var oldComZ = 0.0;
    if (hasCom) {
      final com = body.worldCenterOfMass;
      oldComX = com.x;
      oldComY = com.y;
      oldComZ = com.z;
    }

    final half = 0.5 * angle;
    final s = math.sin(half) / angle;
    final dqx = dTheta.x * s;
    final dqy = dTheta.y * s;
    final dqz = dTheta.z * s;
    final dqw = math.cos(half);

    final q = body.bodyRotation;
    final qx = q.x;
    final qy = q.y;
    final qz = q.z;
    final qw = q.w;

    final nx = dqw * qx + dqx * qw + dqy * qz - dqz * qy;
    final ny = dqw * qy - dqx * qz + dqy * qw + dqz * qx;
    final nz = dqw * qz + dqx * qy - dqy * qx + dqz * qw;
    final nw = dqw * qw - dqx * qx - dqy * qy - dqz * qz;
    final invNorm = 1.0 / math.sqrt(nx * nx + ny * ny + nz * nz + nw * nw);
    q.setValues(nx * invNorm, ny * invNorm, nz * invNorm, nw * invNorm);
    if (hasCom) {
      _rotateByQuat(q, body.localCenterOfMass, _deltaComRotScratch);
      body.bodyPosition.setValues(
        oldComX - _deltaComRotScratch.x,
        oldComY - _deltaComRotScratch.y,
        oldComZ - _deltaComRotScratch.z,
      );
    }
    body.updateWorldInertia();
  }

  static void _rotateByQuat(Quaternion q, Vector3 v, Vector3 out) {
    final qx = q.x;
    final qy = q.y;
    final qz = q.z;
    final qw = q.w;
    final tx = 2.0 * (qy * v.z - qz * v.y);
    final ty = 2.0 * (qz * v.x - qx * v.z);
    final tz = 2.0 * (qx * v.y - qy * v.x);
    out.setValues(
      v.x + qw * tx + (qy * tz - qz * ty),
      v.y + qw * ty + (qz * tx - qx * tz),
      v.z + qw * tz + (qx * ty - qy * tx),
    );
  }

  static void _unrotateByQuat(Quaternion q, Vector3 v, Vector3 out) {
    final qx = -q.x;
    final qy = -q.y;
    final qz = -q.z;
    final qw = q.w;
    final tx = 2.0 * (qy * v.z - qz * v.y);
    final ty = 2.0 * (qz * v.x - qx * v.z);
    final tz = 2.0 * (qx * v.y - qy * v.x);
    out.setValues(
      v.x + qw * tx + (qy * tz - qz * ty),
      v.y + qw * ty + (qz * tx - qx * tz),
      v.z + qw * tz + (qx * ty - qy * tx),
    );
  }
}
