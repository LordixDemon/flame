import 'dart:math' as math;

import 'package:flame_3d/camera.dart' show Ray;
import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:flame_3d/src/physics/physics_solver_math_3d.dart';
import 'package:meta/meta.dart';

/// Local pontoon sample point used by [BuoyancyVolume3D] to evaluate submerged
/// Archimedes displacement, water drag, and wave-slope torque on a
/// [RigidBody3D].
class BuoyancyPontoon3D({
  required Vector3 localPosition,
  final double radius = 0.25,
  final double volumeWeight = 1.0,
}) {
  this
    : assert(radius > 0, 'radius must be positive'),
      assert(volumeWeight >= 0, 'volumeWeight must be non-negative');

  /// Sample point in the rigid body's local space.
  final Vector3 localPosition = localPosition.clone();
}

/// Multi-pontoon Archimedes buoyancy and wave hydrodynamics solver for
/// submerged [RigidBody3D]s.
///
/// Applied by a [PhysicsWorld3D] every step when registered with
/// `PhysicsWorld3D.addBuoyancyVolume`, or when mounted anywhere under the
/// world's parent (it registers itself on mount and unregisters on removal);
/// or invoked manually via [applyToBodies].
class BuoyancyVolume3D({
  final double Function(double x, double z, double time)? waterSurfaceHeight,
  var double baseWaterLevel = 0.0,
  var double fluidDensity = 2.5,
  var double linearDrag = 2.2,
  var double angularDrag = 1.8,
  var double waveTorqueStrength = 1.5,
  var double waveNormalSampleStep = 0.2,
  Vector3? flowVelocity,
  this.bounds,
  List<BuoyancyPontoon3D>? defaultPontoons,
  super.position,
  super.scale,
  super.rotation,
  super.children,
}) extends Component3D {
  /// Ambient water current velocity (`m/s`).
  final Vector3 flowVelocity = flowVelocity?.clone() ?? Vector3.zero();

  /// Optional world-space bounding box of this water volume (`null` means an
  /// unbounded horizontal ocean).
  Aabb3? bounds;

  /// Optional default local pontoons used when a body has no custom pontoons
  /// registered via [setBodyPontoons].
  final List<BuoyancyPontoon3D>? defaultPontoons = defaultPontoons != null
      ? List.unmodifiable(defaultPontoons)
      : null;

  /// Elapsed simulation time (seconds) passed into [sampleWaterHeight].
  double elapsedTime = 0.0;

  /// The physics worlds this volume registered with when it mounted.
  @internal
  final List<PhysicsWorld3D> enclosingPhysicsWorlds = [];

  @override
  void onMount() {
    super.onMount();
    PhysicsWorld3D.attachToEnclosingWorlds(this);
  }

  @override
  void onRemove() {
    for (var i = 0; i < enclosingPhysicsWorlds.length; i++) {
      enclosingPhysicsWorlds[i].unregisterMountedComponent(this);
    }
    enclosingPhysicsWorlds.clear();
    super.onRemove();
  }

  final Map<RigidBody3D, List<BuoyancyPontoon3D>> _customPontoons = {};
  final Map<Shape3D, List<BuoyancyPontoon3D>> _autoPontoonCache = {};

  final Vector3 _worldPt = Vector3.zero();
  final Vector3 _waveNormal = Vector3.zero();
  final Vector3 _forceDir = Vector3.zero();
  final Vector3 _ptVel = Vector3.zero();
  final Vector3 _relVel = Vector3.zero();
  final Vector3 _force = Vector3.zero();
  final Vector3 _bodyUp = Vector3.zero();
  final Vector3 _torque = Vector3.zero();
  final Aabb3 _shapeAabb = Aabb3();

  /// Assigns explicit multi-pontoon sample points for [body].
  void setBodyPontoons(RigidBody3D body, List<BuoyancyPontoon3D> pontoons) {
    assert(pontoons.isNotEmpty, 'pontoons must not be empty');
    _customPontoons[body] = List.unmodifiable(pontoons);
  }

  /// Evaluates the water surface `Y` height at world `(x, z)` at [time]
  /// (defaults to [elapsedTime]).
  double sampleWaterHeight(double x, double z, [double? time]) {
    final t = time ?? elapsedTime;
    final fn = waterSurfaceHeight;
    return fn != null ? fn(x, z, t) : baseWaterLevel;
  }

  /// Evaluates the unit upward wave surface normal at `(x, z)` via central
  /// finite differences.
  Vector3 sampleWaveNormal(
    double x,
    double z, {
    double? time,
    Vector3? out,
  }) {
    final res = out ?? Vector3.zero();
    final t = time ?? elapsedTime;
    if (waterSurfaceHeight == null) {
      res.setValues(0.0, 1.0, 0.0);
      return res;
    }
    final eps = math.max(1e-3, waveNormalSampleStep);
    final dhdx =
        (sampleWaterHeight(x + eps, z, t) - sampleWaterHeight(x - eps, z, t)) /
        (2.0 * eps);
    final dhdz =
        (sampleWaterHeight(x, z + eps, t) - sampleWaterHeight(x, z - eps, t)) /
        (2.0 * eps);
    final invLen = 1.0 / math.sqrt(dhdx * dhdx + 1.0 + dhdz * dhdz);
    res.setValues(-dhdx * invLen, invLen, -dhdz * invLen);
    return res;
  }

  /// Advances [elapsedTime] by [dt] and applies Archimedes upward buoyancy,
  /// hydrodynamic drag, and wave-normal alignment torque to all submerged
  /// dynamic bodies in [bodies].
  void applyToBodies(
    Iterable<RigidBody3D> bodies,
    double dt, {
    double gravityMagnitude = 9.81,
  }) {
    if (dt <= 0.0 || fluidDensity <= 0.0) {
      return;
    }
    elapsedTime += dt;
    final g = math.max(0.0, gravityMagnitude);
    final volBounds = bounds;
    final hasWaveFn = waterSurfaceHeight != null;
    final waterLevel = baseWaterLevel;
    final bodyList = bodies is List<RigidBody3D> ? bodies : null;
    final count = bodyList?.length ?? 0;

    if (bodyList != null) {
      for (var bIdx = 0; bIdx < count; bIdx++) {
        _applyToSingleBody(
          bodyList[bIdx],
          g,
          volBounds,
          hasWaveFn,
          waterLevel,
        );
      }
    } else {
      for (final body in bodies) {
        _applyToSingleBody(body, g, volBounds, hasWaveFn, waterLevel);
      }
    }
  }

  void _applyToSingleBody(
    RigidBody3D body,
    double g,
    Aabb3? volBounds,
    bool hasWaveFn,
    double waterLevel,
  ) {
    if (body.bodyType != BodyType3D.dynamic || body.inverseMass <= 0.0) {
      return;
    }
    body.refreshCachedWorldAabb();
    final bodyBox = body.cachedWorldAabb;
    if (volBounds != null && !aabbOverlaps(volBounds, bodyBox)) {
      return;
    }
    if (!hasWaveFn &&
        !_customPontoons.containsKey(body) &&
        defaultPontoons == null &&
        bodyBox.min.y > waterLevel) {
      return;
    }

    final pontoons = _resolvePontoons(body);
    var totalWeight = 0.0;
    for (var i = 0; i < pontoons.length; i++) {
      totalWeight += pontoons[i].volumeWeight;
    }
    if (totalWeight <= 1e-12) {
      return;
    }

    final totalVolume = math.max(1e-4, body.shape.estimateLocalVolume());
    final mat = body.bodyWorldMatrix.storage;
    final com = body.worldCenterOfMass;

    var submergenceSum = 0.0;
    var avgWaveNx = 0.0;
    var avgWaveNy = 0.0;
    var avgWaveNz = 0.0;

    for (var i = 0; i < pontoons.length; i++) {
      final p = pontoons[i];
      final lp = p.localPosition;
      final wx = mat[0] * lp.x + mat[4] * lp.y + mat[8] * lp.z + mat[12];
      final wy = mat[1] * lp.x + mat[5] * lp.y + mat[9] * lp.z + mat[13];
      final wz = mat[2] * lp.x + mat[6] * lp.y + mat[10] * lp.z + mat[14];

      if (volBounds != null &&
          (wx < volBounds.min.x ||
              wx > volBounds.max.x ||
              wz < volBounds.min.z ||
              wz > volBounds.max.z)) {
        continue;
      }

      final surfaceY = sampleWaterHeight(wx, wz, elapsedTime);
      final depth = surfaceY - (wy - p.radius);
      if (depth <= 0.0) {
        continue;
      }
      final subFraction = (depth / (2.0 * p.radius)).clamp(0.0, 1.0);
      submergenceSum += subFraction;

      sampleWaveNormal(wx, wz, time: elapsedTime, out: _waveNormal);
      avgWaveNx += _waveNormal.x * subFraction;
      avgWaveNy += _waveNormal.y * subFraction;
      avgWaveNz += _waveNormal.z * subFraction;

      final pontoonVol =
          totalVolume * (p.volumeWeight / totalWeight) * subFraction;
      // Clamp extreme upward acceleration on ultra-light bodies.
      final rawBuoyancy = fluidDensity * g * pontoonVol;
      final maxSafeForce =
          body.mass * math.max(40.0, g * 6.0) * (p.volumeWeight / totalWeight);
      final buoyancyMag = math.min(rawBuoyancy, maxSafeForce);

      // Blend vertical Archimedes lift slightly toward wave normal so passing
      // swells push and tilt floating hulls realistically.
      _forceDir.setValues(
        _waveNormal.x * 0.25,
        0.75 + _waveNormal.y * 0.25,
        _waveNormal.z * 0.25,
      );
      _forceDir.normalize();

      _worldPt.setValues(wx, wy, wz);
      final rx = wx - com.x;
      final ry = wy - com.y;
      final rz = wz - com.z;
      final av = body.angularVelocity;
      final lv = body.linearVelocity;
      _ptVel.setValues(
        lv.x + (av.y * rz - av.z * ry),
        lv.y + (av.z * rx - av.x * rz),
        lv.z + (av.x * ry - av.y * rx),
      );
      _relVel.setValues(
        _ptVel.x - flowVelocity.x,
        _ptVel.y - flowVelocity.y,
        _ptVel.z - flowVelocity.z,
      );

      final pontoonMass = body.mass * (p.volumeWeight / totalWeight);
      final dragCoeff = linearDrag * subFraction * pontoonMass;
      _force.setValues(
        _forceDir.x * buoyancyMag - _relVel.x * dragCoeff,
        _forceDir.y * buoyancyMag - _relVel.y * dragCoeff,
        _forceDir.z * buoyancyMag - _relVel.z * dragCoeff,
      );
      body.applyForce(_force, worldPoint: _worldPt);
    }

    if (submergenceSum > 1e-5) {
      final avgSub = (submergenceSum / pontoons.length).clamp(0.0, 1.0);
      // Rotational hydrodynamic damping + wave-normal alignment torque.
      final angDamp = angularDrag * avgSub * body.mass * 0.35;
      _torque.setValues(
        -body.angularVelocity.x * angDamp,
        -body.angularVelocity.y * angDamp,
        -body.angularVelocity.z * angDamp,
      );

      final nLen = math.sqrt(
        avgWaveNx * avgWaveNx + avgWaveNy * avgWaveNy + avgWaveNz * avgWaveNz,
      );
      if (nLen > 1e-8 && waveTorqueStrength > 0.0) {
        final wnx = avgWaveNx / nLen;
        final wny = avgWaveNy / nLen;
        final wnz = avgWaveNz / nLen;
        _bodyUp.setValues(mat[4], mat[5], mat[6]);
        if (_bodyUp.length2 > 1e-12) {
          _bodyUp.normalize();
          final cx = _bodyUp.y * wnz - _bodyUp.z * wny;
          final cy = _bodyUp.z * wnx - _bodyUp.x * wnz;
          final cz = _bodyUp.x * wny - _bodyUp.y * wnx;
          final kWave = waveTorqueStrength * avgSub * body.mass;
          _torque.x += cx * kWave;
          _torque.y += cy * kWave;
          _torque.z += cz * kWave;
        }
      }
      body.applyTorque(_torque);
    }
  }

  List<BuoyancyPontoon3D> _resolvePontoons(RigidBody3D body) {
    final custom = _customPontoons[body];
    if (custom != null) {
      return custom;
    }
    if (defaultPontoons != null && defaultPontoons!.isNotEmpty) {
      return defaultPontoons!;
    }
    return _autoPontoonCache[body.shape] ??= _generatePontoonsForShape(
      body.shape,
      _shapeAabb,
    );
  }

  static List<BuoyancyPontoon3D> _generatePontoonsForShape(
    Shape3D shape,
    Aabb3 boxScratch,
  ) {
    if (shape is SphereShape3D) {
      final r = shape.radius;
      final off = r * 0.45;
      final pr = math.max(0.05, r * 0.65);
      return List.unmodifiable([
        BuoyancyPontoon3D(localPosition: Vector3(-off, 0.0, -off), radius: pr),
        BuoyancyPontoon3D(localPosition: Vector3(off, 0.0, -off), radius: pr),
        BuoyancyPontoon3D(localPosition: Vector3(-off, 0.0, off), radius: pr),
        BuoyancyPontoon3D(localPosition: Vector3(off, 0.0, off), radius: pr),
      ]);
    }
    shape.computeLocalAabb(out: boxScratch);
    final hx = math.max(0.05, 0.5 * (boxScratch.max.x - boxScratch.min.x));
    final hy = math.max(0.05, 0.5 * (boxScratch.max.y - boxScratch.min.y));
    final hz = math.max(0.05, 0.5 * (boxScratch.max.z - boxScratch.min.z));
    final cx = 0.5 * (boxScratch.min.x + boxScratch.max.x);
    final cy = 0.5 * (boxScratch.min.y + boxScratch.max.y);
    final cz = 0.5 * (boxScratch.min.z + boxScratch.max.z);
    final ox = hx * 0.7;
    final oz = hz * 0.7;
    return List.unmodifiable([
      BuoyancyPontoon3D(
        localPosition: Vector3(cx - ox, cy, cz - oz),
        radius: hy,
      ),
      BuoyancyPontoon3D(
        localPosition: Vector3(cx + ox, cy, cz - oz),
        radius: hy,
      ),
      BuoyancyPontoon3D(
        localPosition: Vector3(cx - ox, cy, cz + oz),
        radius: hy,
      ),
      BuoyancyPontoon3D(
        localPosition: Vector3(cx + ox, cy, cz + oz),
        radius: hy,
      ),
    ]);
  }
}

/// Configuration of a single wheel and raycast suspension strut on a
/// [RaycastVehicle3D].
class WheelSpec3D({
  required Vector3 connectionPointLocal,
  Vector3? suspensionDirectionLocal,
  Vector3? axleDirectionLocal,
  final double restLength = 0.4,
  final double maxTravel = 0.25,
  final double springStiffness = 35.0,
  final double damperCompression = 4.5,
  final double damperRelaxation = 5.5,
  final double wheelRadius = 0.35,
  final double frictionSlip = 2.2,
  final bool isSteerable = false,
  final bool isDrive = true,
  final bool isBraking = true,
}) {
  this
    : assert(restLength >= 0, 'restLength must be non-negative'),
      assert(wheelRadius > 0, 'wheelRadius must be positive'),
      assert(springStiffness >= 0, 'springStiffness must be non-negative');

  /// Strut attachment point in the chassis's local space.
  final Vector3 connectionPointLocal = connectionPointLocal.clone();

  /// Downward suspension ray direction in chassis local space (`(0, -1, 0)` by
  /// default).
  final Vector3 suspensionDirectionLocal =
      (suspensionDirectionLocal?.clone() ?? Vector3(0.0, -1.0, 0.0))
        ..normalize();

  /// Wheel axle direction in chassis local space (`(1, 0, 0)` when not
  /// given).
  ///
  /// When given, the wheel rolls perpendicular to it: its unsteered forward
  /// direction is `axle x up` (up being against [suspensionDirectionLocal]),
  /// reversed when that points away from the vehicle's `forwardAxisLocal`.
  /// When not given, the wheel rolls along the vehicle's `forwardAxisLocal`.
  final Vector3 axleDirectionLocal =
      (axleDirectionLocal?.clone() ?? Vector3(1.0, 0.0, 0.0))..normalize();

  /// Whether [axleDirectionLocal] was given (and steers the rolling
  /// direction).
  final bool hasCustomAxle = axleDirectionLocal != null;
}

/// Per-wheel live telemetry updated every step by [RaycastVehicle3D].
class WheelState3D() {
  /// Whether this wheel's suspension ray contacted ground on the last step.
  bool isGrounded = false;

  /// Current suspension length from attachment to wheel hub (`m`).
  double suspensionLength = 0.0;

  /// Current spring compression `restLength - suspensionLength` (`m`).
  double compression = 0.0;

  /// Normal suspension impulse (`N*s`) applied on the last step.
  double suspensionImpulse = 0.0;

  /// Ratio `[0..1]` of available lateral traction remaining (`0` = full skid).
  double skidInfo = 1.0;

  /// Cumulative rolling angle (radians) of the wheel around its axle.
  double rotationRad = 0.0;

  /// Current steering angle (radians) of this wheel.
  double steerAngleRad = 0.0;

  /// World-space ground contact point.
  final Vector3 contactPoint = Vector3.zero();

  /// World-space ground contact normal.
  final Vector3 contactNormal = Vector3(0.0, 1.0, 0.0);

  /// World-space hub center of this wheel.
  final Vector3 wheelWorldPosition = Vector3.zero();
}

/// N-wheel (4-wheel standard) raycast suspension vehicle controller attached to
/// a [RigidBody3D] chassis.
///
/// Computes spring-damper suspension impulses, steered forward drive & braking
/// impulses, and lateral anti-slip cornering impulses against rigid bodies in
/// [PhysicsWorld3D] and optional [CollisionSystem3D] colliders.
class RaycastVehicle3D({
  required final RigidBody3D chassis,
  required List<WheelSpec3D> wheels,
  Vector3? forwardAxisLocal,
  var double engineForce = 12.0,
  var double maxBrakeForce = 10.0,
  var double maxSteerAngleRad = 0.6,
  var double rollInfluence = 0.25,
  var bool massNormalizedSuspension = true,
}) {
  this : assert(wheels.isNotEmpty, 'RaycastVehicle3D requires >= 1 wheel') {
    for (var i = 0; i < this.wheels.length; i++) {
      wheelStates[i].suspensionLength = this.wheels[i].restLength;
    }
  }

  /// Convenience factory creating a standard 4-wheel car setup (front steerable
  /// wheels + 4WD or RWD drive).
  factory RaycastVehicle3D.fourWheel({
    required RigidBody3D chassis,
    double halfTrackWidth = 0.85,
    double halfWheelbase = 1.25,
    double connectionHeight = 0.0,
    double restLength = 0.4,
    double wheelRadius = 0.35,
    double springStiffness = 35.0,
    double frictionSlip = 2.5,
    double engineForce = 14.0,
    double maxBrakeForce = 12.0,
    double maxSteerAngleRad = 0.55,
    bool allWheelDrive = true,
    Vector3? forwardAxisLocal,
  }) {
    final fwd = (forwardAxisLocal?.clone() ?? Vector3(0.0, 0.0, 1.0))
      ..normalize();
    // Wheels sit along the forward axis and the side axis `up x forward`
    // (local Y up), the side axis turned toward +X (or +Z).
    final side = Vector3(0.0, 1.0, 0.0).cross(fwd);
    if (side.length2 <= 1e-12) {
      side.setValues(1.0, 0.0, 0.0);
    }
    side.normalize();
    if (side.x < -1e-9 || (side.x.abs() <= 1e-9 && side.z < 0.0)) {
      side.negate();
    }
    Vector3 corner(double along, double across) => Vector3(
      fwd.x * along + side.x * across,
      fwd.y * along + side.y * across + connectionHeight,
      fwd.z * along + side.z * across,
    );
    return RaycastVehicle3D(
      chassis: chassis,
      forwardAxisLocal: fwd,
      engineForce: engineForce,
      maxBrakeForce: maxBrakeForce,
      maxSteerAngleRad: maxSteerAngleRad,
      wheels: [
        // Front-left
        WheelSpec3D(
          connectionPointLocal: corner(halfWheelbase, -halfTrackWidth),
          restLength: restLength,
          wheelRadius: wheelRadius,
          springStiffness: springStiffness,
          frictionSlip: frictionSlip,
          isSteerable: true,
          isDrive: allWheelDrive,
        ),
        // Front-right
        WheelSpec3D(
          connectionPointLocal: corner(halfWheelbase, halfTrackWidth),
          restLength: restLength,
          wheelRadius: wheelRadius,
          springStiffness: springStiffness,
          frictionSlip: frictionSlip,
          isSteerable: true,
          isDrive: allWheelDrive,
        ),
        // Rear-left
        WheelSpec3D(
          connectionPointLocal: corner(-halfWheelbase, -halfTrackWidth),
          restLength: restLength,
          wheelRadius: wheelRadius,
          springStiffness: springStiffness,
          frictionSlip: frictionSlip,
        ),
        // Rear-right
        WheelSpec3D(
          connectionPointLocal: corner(-halfWheelbase, halfTrackWidth),
          restLength: restLength,
          wheelRadius: wheelRadius,
          springStiffness: springStiffness,
          frictionSlip: frictionSlip,
        ),
      ],
    );
  }

  /// Immutable wheel configurations.
  final List<WheelSpec3D> wheels = List.unmodifiable(wheels);

  late final int _driveCount = math.max(
    1,
    wheels.where((w) => w.isDrive).length,
  );

  /// Live per-wheel suspension, contact, spin, and skid state.
  final List<WheelState3D> wheelStates = List.unmodifiable(
    List<WheelState3D>.generate(wheels.length, (_) => WheelState3D()),
  );

  /// Forward direction in [chassis] local space (`(0, 0, 1)` by default).
  final Vector3 forwardAxisLocal =
      (forwardAxisLocal?.clone() ?? Vector3(0.0, 0.0, 1.0))..normalize();

  /// Throttle input (`[-1.0 .. +1.0]`, positive drives forward).
  double throttle = 0.0;

  /// Steering input (`[-1.0 .. +1.0]`, scaled by [maxSteerAngleRad]).
  double steering = 0.0;

  /// Brake input (`[0.0 .. 1.0]`).
  double brake = 0.0;

  final Ray _ray = Ray();
  final Quaternion _steerQuat = Quaternion.identity();
  final Vector3 _connWorld = Vector3.zero();
  final Vector3 _suspDirWorld = Vector3.zero();
  final Vector3 _upWorld = Vector3.zero();
  final Vector3 _fwdWorld = Vector3.zero();
  final Vector3 _steeredFwd = Vector3.zero();
  final Vector3 _wheelFwd = Vector3.zero();
  final Vector3 _wheelSide = Vector3.zero();
  final Vector3 _rContact = Vector3.zero();
  final Vector3 _rApply = Vector3.zero();
  final Vector3 _applyPt = Vector3.zero();
  final Vector3 _vContact = Vector3.zero();
  final Vector3 _impScratch = Vector3.zero();
  final Vector3 _inertiaScratch = Vector3.zero();
  final Vector3 _axleScratch = Vector3.zero();

  /// Number of wheels currently touching ground.
  int get groundedWheelCount {
    var count = 0;
    for (var i = 0; i < wheelStates.length; i++) {
      if (wheelStates[i].isGrounded) {
        count++;
      }
    }
    return count;
  }

  /// Current forward speed (`m/s`) of [chassis] along [forwardAxisLocal].
  double get forwardSpeed {
    rotateVectorByQuat(chassis.bodyRotation, forwardAxisLocal, _fwdWorld);
    return chassis.linearVelocity.dot(_fwdWorld);
  }

  late final bool Function(RigidBody3D) _wheelBodyFilter = _filterWheelBody;
  late final (double, Vector3)? Function(RigidBody3D, Ray, double)
  _wheelBodyNarrowphase = _narrowphaseWheelBody;
  late final bool Function(Collider3D) _wheelColliderFilter =
      _filterWheelCollider;
  late final (double, Vector3)? Function(Collider3D, Ray, double)
  _wheelColliderNarrowphase = _narrowphaseWheelCollider;

  bool _filterWheelBody(RigidBody3D other) {
    if (identical(other, chassis) ||
        identical(other.hostComponent, chassis.hostComponent)) {
      return false;
    }
    return (other.collisionLayer & chassis.collisionMask) != 0;
  }

  (double, Vector3)? _narrowphaseWheelBody(
    RigidBody3D other,
    Ray unitRay,
    double limit,
  ) {
    if (!rayHitsAabb(unitRay, other.cachedWorldAabb, limit)) {
      return null;
    }
    return other.shape.raycast(
      unitRay,
      other.bodyWorldMatrix,
      maxDistance: limit,
    );
  }

  bool _filterWheelCollider(Collider3D c) {
    if (c.isTrigger || identical(c.hostComponent, chassis.hostComponent)) {
      return false;
    }
    return (c.collisionLayer & chassis.collisionMask) != 0;
  }

  (double, Vector3)? _narrowphaseWheelCollider(
    Collider3D c,
    Ray unitRay,
    double limit,
  ) {
    if (!rayHitsAabb(unitRay, c.cachedWorldAabb, limit)) {
      return null;
    }
    return c.shape.raycast(
      unitRay,
      c.colliderWorldMatrix,
      maxDistance: limit,
    );
  }

  /// Evaluates wheel raycasts and applies suspension, drive, brake, and lateral
  /// anti-slip impulses to [chassis] for timestep [dt].
  ///
  /// [gravityMagnitude] sets the minimum tire load (a share of the chassis
  /// weight); a [PhysicsWorld3D] passes the length of its gravity. When
  /// [bodyBroadphase] is supplied, wheel raycasts query the dynamic BVH
  /// directly instead of scanning all [bodies].
  void stepVehicle(
    double dt, {
    required Iterable<RigidBody3D> bodies,
    CollisionSystem3D? collisionSystem,
    DynamicAabbTree3D<RigidBody3D>? bodyBroadphase,
    double gravityMagnitude = 9.81,
  }) {
    if (dt <= 0.0 ||
        chassis.bodyType != BodyType3D.dynamic ||
        chassis.inverseMass <= 0.0) {
      return;
    }
    if (throttle.abs() > 1e-4 || steering.abs() > 1e-4 || brake > 1e-4) {
      chassis.wakeUp();
    }
    if (chassis.isSleeping) {
      return;
    }

    if (collisionSystem != null && bodyBroadphase == null) {
      collisionSystem.syncBroadphase();
    }

    chassis.updateWorldInertia();
    final qChassis = chassis.bodyRotation;
    final posChassis = chassis.bodyPosition;
    final com = chassis.worldCenterOfMass;
    final mScale = massNormalizedSuspension ? chassis.mass : 1.0;

    // Pass 1: Raycast & suspension spring-damper impulses.
    for (var i = 0; i < wheels.length; i++) {
      final spec = wheels[i];
      final state = wheelStates[i];

      rotateVectorByQuat(qChassis, spec.connectionPointLocal, _connWorld);
      _connWorld.add(posChassis);
      rotateVectorByQuat(
        qChassis,
        spec.suspensionDirectionLocal,
        _suspDirWorld,
      );
      _suspDirWorld.normalize();
      _upWorld
        ..setFrom(_suspDirWorld)
        ..negate();

      state.steerAngleRad = spec.isSteerable
          ? steering.clamp(-1.0, 1.0) * maxSteerAngleRad
          : 0.0;

      final maxRayDist = spec.restLength + spec.wheelRadius;
      _ray.origin.setFrom(_connWorld);
      _ray.direction.setFrom(_suspDirWorld);

      final hit = _castWheelRay(
        _ray,
        maxRayDist,
        bodies: bodies,
        collisionSystem: collisionSystem,
        bodyBroadphase: bodyBroadphase,
      );

      if (hit == null) {
        state.isGrounded = false;
        state.suspensionLength = spec.restLength;
        state.compression = 0.0;
        state.suspensionImpulse = 0.0;
        state.skidInfo = 1.0;
        state.wheelWorldPosition
          ..setFrom(_connWorld)
          ..addScaled(_suspDirWorld, spec.restLength);
        state.rotationRad += (forwardSpeed / spec.wheelRadius) * dt;
        continue;
      }

      final (hitDist, hitNormal) = hit;
      state.isGrounded = true;
      state.contactNormal.setFrom(hitNormal);
      state.contactPoint
        ..setFrom(_connWorld)
        ..addScaled(_suspDirWorld, hitDist);

      final minLen = math.max(0.0, spec.restLength - spec.maxTravel);
      final maxLen = spec.restLength + spec.maxTravel;
      final suspLen = (hitDist - spec.wheelRadius).clamp(minLen, maxLen);
      state.suspensionLength = suspLen;
      state.compression = math.max(0.0, spec.restLength - suspLen);
      state.wheelWorldPosition
        ..setFrom(_connWorld)
        ..addScaled(_suspDirWorld, suspLen);

      _rContact
        ..setFrom(state.contactPoint)
        ..sub(com);
      velocityAtLever(chassis, _rContact, _vContact);

      final proj = hitNormal.dot(_upWorld);
      final vn = _vContact.dot(hitNormal);
      final damper = vn < 0.0 ? spec.damperCompression : spec.damperRelaxation;

      var force =
          (state.compression * spec.springStiffness - vn * damper) * mScale;
      if (proj > 0.2) {
        force *= 1.0 / proj;
      }
      final jSusp = math
          .max(0.0, force * dt)
          .clamp(0.0, chassis.mass * 30.0 * dt);
      state.suspensionImpulse = jSusp;

      if (jSusp > 1e-12) {
        _impScratch
          ..setFrom(hitNormal)
          ..scale(jSusp);
        chassis.applyImpulse(_impScratch, worldPoint: state.contactPoint);
      }
    }

    // Pass 2: Forward drive, braking, and lateral anti-slip impulses.
    final driveCount = _driveCount;
    for (var i = 0; i < wheels.length; i++) {
      final spec = wheels[i];
      final state = wheelStates[i];
      if (!state.isGrounded) {
        continue;
      }

      rotateVectorByQuat(
        qChassis,
        spec.suspensionDirectionLocal,
        _suspDirWorld,
      );
      _upWorld
        ..setFrom(_suspDirWorld)
        ..negate()
        ..normalize();
      rotateVectorByQuat(qChassis, forwardAxisLocal, _fwdWorld);
      if (spec.hasCustomAxle) {
        // Roll perpendicular to the wheel's own axle.
        rotateVectorByQuat(qChassis, spec.axleDirectionLocal, _axleScratch);
        _axleScratch.crossInto(_upWorld, _steeredFwd);
        if (_steeredFwd.length2 > 1e-12) {
          _steeredFwd.normalize();
          // Turned toward the vehicle's forward axis unless (nearly)
          // perpendicular to it, where the sign would follow float noise.
          if (_steeredFwd.dot(_fwdWorld) < -1e-3) {
            _steeredFwd.negate();
          }
          _fwdWorld.setFrom(_steeredFwd);
        }
      }

      if (state.steerAngleRad.abs() > 1e-6) {
        _steerQuat.setAxisAngle(_upWorld, state.steerAngleRad);
        rotateVectorByQuat(_steerQuat, _fwdWorld, _steeredFwd);
      } else {
        _steeredFwd.setFrom(_fwdWorld);
      }

      // Project steered forward onto the contact tangent plane.
      final n = state.contactNormal;
      _wheelFwd
        ..setFrom(_steeredFwd)
        ..addScaled(n, -_steeredFwd.dot(n));
      if (_wheelFwd.length2 <= 1e-10) {
        _wheelFwd.setFrom(_steeredFwd);
      }
      _wheelFwd.normalize();

      _wheelSide
        ..setFrom(n.cross(_wheelFwd))
        ..normalize();

      // Roll-center blended application point prevents unrealistic high-CG
      // tipping while preserving pitch/roll weight transfer and yaw steering.
      final cp = state.contactPoint;
      final comNow = chassis.worldCenterOfMass;
      final rawRx = cp.x - comNow.x;
      final rawRy = cp.y - comNow.y;
      final rawRz = cp.z - comNow.z;
      final upProj =
          rawRx * _upWorld.x + rawRy * _upWorld.y + rawRz * _upWorld.z;
      final reducedUp = upProj * rollInfluence.clamp(0.0, 1.0);
      _rApply.setValues(
        rawRx + _upWorld.x * (reducedUp - upProj),
        rawRy + _upWorld.y * (reducedUp - upProj),
        rawRz + _upWorld.z * (reducedUp - upProj),
      );
      _applyPt
        ..setFrom(comNow)
        ..add(_rApply);

      _rContact.setValues(rawRx, rawRy, rawRz);
      velocityAtLever(chassis, _rContact, _vContact);

      final vFwd = _vContact.dot(_wheelFwd);
      final vSide = _vContact.dot(_wheelSide);
      state.rotationRad += (vFwd / spec.wheelRadius) * dt;

      final kFwd = computeSingleBodyAxisK(
        chassis,
        _rApply,
        _wheelFwd,
        _inertiaScratch,
      );
      final kSide = computeSingleBodyAxisK(
        chassis,
        _rApply,
        _wheelSide,
        _inertiaScratch,
      );

      var jLong = 0.0;
      if (spec.isDrive && throttle.abs() > 1e-5) {
        jLong +=
            (throttle.clamp(-1.0, 1.0) * engineForce * mScale / driveCount) *
            dt;
      }
      if (spec.isBraking && brake > 1e-5 && kFwd > 1e-12) {
        final maxBrk =
            (brake.clamp(0.0, 1.0) * maxBrakeForce * mScale / wheels.length) *
            dt;
        final stopImp = -(vFwd / kFwd);
        jLong += stopImp.clamp(-maxBrk, maxBrk);
      }

      final normalLoad = math.max(
        state.suspensionImpulse,
        (chassis.mass * gravityMagnitude / wheels.length) * dt * 0.5,
      );
      final maxFriction = spec.frictionSlip * normalLoad;
      jLong = jLong.clamp(-maxFriction, maxFriction);

      var jSide = 0.0;
      if (kSide > 1e-12) {
        final desiredSide = -(vSide / kSide) * 0.85;
        final availLat = math.sqrt(
          math.max(0.0, maxFriction * maxFriction - 0.5 * jLong * jLong),
        );
        if (desiredSide.abs() > availLat && desiredSide.abs() > 1e-9) {
          state.skidInfo = availLat / desiredSide.abs();
          jSide = desiredSide.sign * availLat;
        } else {
          state.skidInfo = 1.0;
          jSide = desiredSide;
        }
      }

      if (jLong.abs() > 1e-12 || jSide.abs() > 1e-12) {
        _impScratch.setValues(
          _wheelFwd.x * jLong + _wheelSide.x * jSide,
          _wheelFwd.y * jLong + _wheelSide.y * jSide,
          _wheelFwd.z * jLong + _wheelSide.z * jSide,
        );
        chassis.applyImpulse(_impScratch, worldPoint: _applyPt);
      }
    }
  }

  (double distance, Vector3 normal)? _castWheelRay(
    Ray ray,
    double maxDist, {
    required Iterable<RigidBody3D> bodies,
    CollisionSystem3D? collisionSystem,
    DynamicAabbTree3D<RigidBody3D>? bodyBroadphase,
  }) {
    var bestDist = maxDist;
    Vector3? bestNormal;

    if (bodyBroadphase != null) {
      final bHit = bodyBroadphase.raycast(
        ray,
        maxDistance: bestDist,
        filter: _wheelBodyFilter,
        narrowphase: _wheelBodyNarrowphase,
      );
      if (bHit != null && bHit.normal != null && bHit.distance <= bestDist) {
        bestDist = bHit.distance;
        bestNormal = bHit.normal;
      }
    } else if (bodies is List<RigidBody3D>) {
      for (var i = 0; i < bodies.length; i++) {
        final other = bodies[i];
        if (!_filterWheelBody(other)) {
          continue;
        }
        other.refreshCachedWorldAabb();
        if (!rayHitsAabb(ray, other.cachedWorldAabb, bestDist)) {
          continue;
        }
        final hit = other.shape.raycast(
          ray,
          other.bodyWorldMatrix,
          maxDistance: bestDist,
        );
        if (hit != null && hit.$1 <= bestDist) {
          bestDist = hit.$1;
          bestNormal = hit.$2;
        }
      }
    } else {
      for (final other in bodies) {
        if (!_filterWheelBody(other)) {
          continue;
        }
        other.refreshCachedWorldAabb();
        if (!rayHitsAabb(ray, other.cachedWorldAabb, bestDist)) {
          continue;
        }
        final hit = other.shape.raycast(
          ray,
          other.bodyWorldMatrix,
          maxDistance: bestDist,
        );
        if (hit != null && hit.$1 <= bestDist) {
          bestDist = hit.$1;
          bestNormal = hit.$2;
        }
      }
    }

    if (collisionSystem != null) {
      final cHit = collisionSystem.broadphaseTree.raycast(
        ray,
        maxDistance: bestDist,
        filter: _wheelColliderFilter,
        narrowphase: _wheelColliderNarrowphase,
      );
      if (cHit != null && cHit.normal != null && cHit.distance <= bestDist) {
        bestDist = cHit.distance;
        bestNormal = cHit.normal;
      }
    }

    return bestNormal == null ? null : (bestDist, bestNormal);
  }
}
