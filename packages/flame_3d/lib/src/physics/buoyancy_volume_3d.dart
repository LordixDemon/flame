import 'dart:math' as math;

import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
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
}) extends Component3D implements PhysicsForceSolver3D {
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
  PhysicsForceStage3D get forceStage => PhysicsForceStage3D.preIntegration;

  @override
  void applyForces(PhysicsWorld3D world, double dt) => applyToBodies(
    world.activeBodies,
    dt,
    gravityMagnitude: world.gravity.length,
  );

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
