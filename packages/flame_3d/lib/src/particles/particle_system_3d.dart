import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Color;

import 'package:flame/game.dart' show Game;
import 'package:flame/math.dart' show SeededRng;
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/src/extensions/clip_space.dart';
import 'package:flame_3d/src/extensions/geometry_math.dart';
import 'package:meta/meta.dart';

part 'particle_system_emitter_3d.dart';
part 'particle_simulation_3d.dart';

/// The space a [ParticleSystem3D] simulates its particles in.
enum ParticleSpace() {
  /// Particles live in the world: once spawned they no longer follow the
  /// system, so a moving system leaves a trail.
  world,

  /// Particles live in the system's local space and move, turn and scale
  /// with it.
  local,
}

/// Whether a [ParticleSystem3D] sorts its particles before drawing them.
enum ParticleSort() {
  /// Back to front when the material blends in an order dependent way
  /// (alpha or premultiplied alpha blending), otherwise not.
  auto,

  /// Never sorted: the order in which particles are drawn is unspecified.
  none,

  /// Always back to front.
  backToFront,
}

/// What a [ParticleSystem3D] does with particles spawned while it is full.
enum ParticleOverflow() {
  /// They are not spawned.
  drop,

  /// They replace live particles, in turn, so that a burst is never lost.
  recycle,
}

/// {@template particle_system_3d}
/// A particle system: it spawns particles from its [emitters] (and from
/// [burst], [emit] and [spawn]), simulates them on the CPU and draws them,
/// depth tested against the rest of the scene, so that particles pass behind
/// and in front of models.
///
/// ## Look
///
/// A system draws either billboards or meshes:
///
/// - with a [material] (a [ParticleMaterial]), each particle is a quad that
///   faces the camera (spherical, cylindrical, stretched along the velocity,
///   or flat), built in the vertex shader;
/// - with a [mesh], each particle is a copy of the mesh, scaled by its size
///   and tumbling about its spin axis (coins, debris, confetti), drawn with
///   the materials of the mesh's surfaces, any instanced material such as
///   `StylizedMaterial`, `SpatialMaterial` or `UnlitMaterial`.
///
/// Either way all the particles of the system are drawn with one instanced
/// draw (per surface of the mesh), whatever their number.
///
/// ## Simulation
///
/// Particles live in [space] (the world by default). Each step they are
/// pulled by [gravity] (scaled per particle by the emitter's
/// `gravityScale`) and [wind], swirled by [turbulence], drawn to
/// [attractors], slowed by [drag], and bounce off the [ground], which reports
/// each bounce to [onGroundHit]. Over its life, a particle's size follows
/// [sizeOverLife], its color [colorOverLife] and [opacityOverLife], its
/// spin [spinOverLife] and its rotation [rotationOverLife]; [flipbook] picks
/// the flipbook frames of a textured [ParticleMaterial].
///
/// All the state is kept in struct-of-arrays typed lists ([particles])
/// allocated with the system, for [capacity] particles: simulating and
/// drawing allocate nothing. The [random] generator is seeded with `seed`, so
/// that a system fed the same time steps produces the same particles.
///
/// ## Bounds
///
/// The world-space [aabb] of the system covers its particles (and their
/// size), and is kept up to date as they move, for culling and for the
/// bounds of the scene.
///
/// ```dart
/// final sparks = ParticleSystem3D(
///   capacity: 512,
///   material: ParticleMaterial(
///     billboard: ParticleBillboard.velocity,
///     renderState: RenderState.additive,
///   ),
///   emitters: [
///     ParticleEmitter3D(
///       shape: const ConeEmitterShape3D(angle: 0.5),
///       speed: (3, 6),
///       lifespan: (0.4, 0.8),
///       size: (0.04, 0.06),
///       colors: const [Color(0xFFFFC870)],
///     ),
///   ],
///   gravity: Vector3(0, -9.8, 0),
///   ground: ParticleGround3D(),
///   velocityStretch: 0.05,
///   opacityOverLife: ParticleCurve(1, 0),
/// );
/// world.add(sparks);
/// sparks.burst(40, at: Vector3(0, 1, 0));
/// ```
/// {@endtemplate}
class ParticleSystem3D({
  /// The maximum number of particles alive at once. Storage for all of them
  /// is allocated with the system.
  final int capacity = 1024,

  /// The material of billboard particles; exactly one of [material] and
  /// [mesh] must be given.
  final ParticleMaterial? material,

  /// The mesh of mesh particles; exactly one of [material] and [mesh] must be
  /// given.
  final Mesh? mesh,
  List<ParticleEmitter3D> emitters = const [],

  /// The space particles are simulated in.
  final ParticleSpace space = ParticleSpace.world,
  int seed = 0x5EED1234,

  /// Whether the emitters' timelines run. Bursts asked for with [burst],
  /// [emit] and [spawn] happen anyway.
  var bool emitting = true,

  /// Whether the simulation is frozen: nothing moves, ages or spawns until it
  /// is resumed. Paused particles are still drawn.
  var bool paused = false,

  /// Whether the system removes itself from its parent once [isFinished].
  var bool removeOnFinish = false,

  /// What happens to particles spawned while the system is full.
  var ParticleOverflow overflow = ParticleOverflow.drop,

  /// A multiplier of the number of particles the emitters spawn (rates and
  /// bursts), for graphics quality settings.
  var double density = 1,
  Vector3? gravity,

  /// How fast particles slow down, per second: each second their velocity is
  /// divided by about `1 + drag`.
  var double drag = 0,
  Vector3? wind,

  /// A swirling flow pushing the particles around.
  var ParticleTurbulence3D? turbulence,

  /// A plane the particles bounce off.
  var ParticleGround3D? ground,
  List<ParticleAttractor3D> attractors = const [],

  /// The size of a particle over its life, as a multiple of its spawn size.
  var ParticleCurve? sizeOverLife,

  /// The color of a particle over its life, multiplied by its spawn color.
  var ColorRamp? colorOverLife,

  /// The opacity of a particle over its life, multiplying its alpha (clamped
  /// to 0..1).
  var ParticleCurve? opacityOverLife,

  /// The spin of a particle over its life, as a multiple of its spawn spin.
  var ParticleCurve? spinOverLife,

  /// An angle, in radians, added to the rotation of a particle over its
  /// life.
  var ParticleCurve? rotationOverLife,

  /// How much [ParticleBillboard.velocity] billboards stretch with speed:
  /// their height is multiplied by `1 + speed * velocityStretch`, at most
  /// [maxStretch].
  var double velocityStretch = 0,

  /// The maximum stretch of [ParticleBillboard.velocity] billboards.
  var double maxStretch = 4,

  /// How the flipbook frames of a textured [ParticleMaterial] are picked.
  var ParticleFlipbook3D? flipbook,

  /// Whether particles are sorted back to front before they are drawn.
  var ParticleSort sort = ParticleSort.auto,
  Vector3? spinAxis,
  Vector4? instanceData,

  /// Called after a simulation step for each particle that bounced off the
  /// [ground] (or hit it, with [ParticleGround3D.killOnHit]): its position on
  /// the ground and the speed at which it hit. The vector is reused; copy it
  /// to keep it. The callback may spawn particles.
  var void Function(Vector3 position, double speed)? onGroundHit,

  /// The longest simulation step, in seconds: longer frames are simulated in
  /// several steps (at most eight).
  var double maxStep = 1 / 30,
  super.position,
  super.rotation,
  super.scale,
  super.children,
}) extends Object3D {
  /// {@macro particle_system_3d}
  this
    : assert(capacity > 0, 'capacity must be positive'),
      assert(
        (material == null) != (mesh == null),
        'exactly one of material and mesh must be given',
      ),
      assert(attractors.length <= 32, 'at most 32 attractors are supported'),
      assert(maxStep > 0, 'maxStep must be positive');

  /// The emitters particles spawn from; the list can be changed at any time.
  final List<ParticleEmitter3D> emitters = List.of(emitters);

  /// A constant acceleration of every particle (scaled by its gravity scale),
  /// in the simulation space.
  final Vector3 gravity = gravity?.clone() ?? Vector3.zero();

  /// A constant acceleration of every particle (not scaled by its gravity
  /// scale), such as a breeze, in the simulation space.
  final Vector3 wind = wind?.clone() ?? Vector3.zero();

  /// The points particles are drawn to; the list can be changed at any time
  /// (at most 32 attractors).
  final List<ParticleAttractor3D> attractors = List.of(attractors);

  /// The axis mesh particles spin about, in the simulation space; when
  /// `null`, each particle spins about an axis of its own, chosen at random.
  final Vector3? spinAxis = spinAxis?.normalized();

  /// Four floats copied into the per-instance data (`instanceData`) of every
  /// particle, which the material interprets: a `StylizedMaterial` reads a
  /// glow, a highlight, a wind strength and a fade from them.
  final Vector4 instanceData = instanceData?.clone() ?? Vector4.zero();

  /// The random generator every random value of the system comes from.
  final SeededRng random = SeededRng(seed);

  /// The live particles. Treat them as read-only, unless you know what you
  /// are doing.
  final ParticleBuffer3D particles = ParticleBuffer3D(capacity);

  final CurlNoise3D _curlNoise = CurlNoise3D(seed);
  final Map<ParticleEmitter3D, _EmitterState> _states = Map.identity();

  // The instances of the last draw, VertexLayout.instanceStrideInFloats
  // floats per particle.
  final Float32List _instances = Float32List(
    capacity * VertexLayout.instanceStrideInFloats,
  );

  // Sorting: depth keys, the drawing order and the radix sort's scratch.
  final Uint16List _keys = Uint16List(capacity);
  final Float32List _depths = Float32List(capacity);
  final Int32List _order = Int32List(capacity);
  final Int32List _orderScratch = Int32List(capacity);
  final Int32List _counts = Int32List(256);

  // Ground hits of the last step: x, y, z and speed.
  final Float32List _hits = Float32List(capacity * 4);
  int _hitCount = 0;
  final Int32List _arrivals = Int32List(32);

  // The world origin of the system at the end of the last update, now, and
  // its velocity.
  final Vector3 _lastOrigin = Vector3.zero();
  final Vector3 _origin = Vector3.zero();
  final Vector3 _originVelocity = Vector3.zero();
  bool _hasOrigin = false;
  double _motionStart = 0;
  double _motionEnd = 1;

  // The bounds of the particle centers, in the simulation space.
  double _minX = 0;
  double _minY = 0;
  double _minZ = 0;
  double _maxX = 0;
  double _maxY = 0;
  double _maxZ = 0;
  bool _hasRawBounds = false;
  // Whether the bounds were last published with no particles.
  bool _publishedEmpty = false;
  // The largest width or height of the particles spawned since the system
  // was last empty.
  double _maxExtent = 0;

  final Aabb3 _bounds = Aabb3();
  final Aabb3 _localBounds = Aabb3();
  final Matrix4 _inverse = Matrix4.zero();
  final Vector3 _center = Vector3.zero();

  // Scratch vectors for spawning and callbacks.
  final Vector3 _position = Vector3.zero();
  final Vector3 _direction = Vector3.zero();
  final Vector3 _axis = Vector3.zero();
  final Vector3 _curl = Vector3.zero();
  final Vector3 _hitPosition = Vector3.zero();

  ParticleCurve? _maxCurve;
  double _maxCurveValue = 1;
  double _meshRadius = -1;

  double _time = 0;
  int _recycleCursor = 0;
  bool _everSpawned = false;
  bool _muted = false;
  int _stateVersion = 0;
  int _sortSerial = 0;
  int _cachedSortVersion = -1;
  int _cachedSortWorldVer = -1;
  bool _cachedSortLocal = false;
  final Float32List _cachedSortView = Float32List(16);
  int _cachedPackVersion = -1;
  int _cachedPackSortSerial = -1;
  int _cachedPackWorldVer = -1;
  bool _cachedPackLocal = false;
  bool _cachedPackSorted = false;
  Material? _cachedPackMaterial;
  ParticleFlipbook3D? _cachedPackFlipbook;
  int _cachedPackFrames = -1;
  bool _cachedPackBlending = false;
  ParticleCurve? _cachedSizeCurve;
  ColorRamp? _cachedColorRamp;
  ParticleCurve? _cachedOpacityCurve;
  ParticleCurve? _cachedRotationCurve;
  double _cachedVelStretch = -1;
  double _cachedMaxStretch = -1;
  double _cachedInstD0 = 0;
  double _cachedInstD1 = 0;
  double _cachedInstD2 = 0;
  double _cachedInstD3 = 0;

  static final ParticleEmitter3D _defaultEmitter = ParticleEmitter3D();

  /// The number of live particles.
  int get particleCount => particles.length;

  /// The time the system has simulated, in seconds.
  double get time => _time;

  /// Whether every emitter finished its timeline and no particle is alive.
  ///
  /// A system without emitters is finished once particles it spawned all
  /// died. Emitters with an endless rate never finish.
  bool get isFinished {
    if (particles.length > 0) {
      return false;
    }
    if (emitters.isEmpty) {
      return _everSpawned;
    }
    for (var i = 0; i < emitters.length; i++) {
      if (!_stateFor(emitters[i]).completed) {
        return false;
      }
    }
    return true;
  }

  /// The bounds of the particles (including their size) in the simulation
  /// space, or `null` when there are none.
  Aabb3? get particleBounds => particles.length == 0 ? null : _bounds;

  /// Starts (or resumes) the emitters' timelines; the timelines of emitters
  /// that finished start again from the beginning.
  void start() {
    for (var i = 0; i < emitters.length; i++) {
      final state = _stateFor(emitters[i]);
      if (state.completed) {
        state.restart();
      }
    }
    emitting = true;
  }

  /// Stops the emitters' timelines; live particles keep moving.
  void stop() => emitting = false;

  /// Removes every live particle.
  ///
  /// Like [burst], [spawn] and [prewarm], it marks the world as changed
  /// (`World3D.sceneVersion`) when it changes what the system draws, from
  /// any point of the frame, so that a retained `Scene3DComponent` shows the
  /// change on the next frame.
  void clear() {
    if (particles.length > 0) {
      _markDrawChanged();
    } else {
      _stateVersion++;
    }
    particles.clear();
    _hasRawBounds = false;
    _maxExtent = 0;
    _hitCount = 0;
    _publishedEmpty = true;
    markAabbDirty();
  }

  /// Removes every live particle and restarts the emitters' timelines.
  void reset() {
    clear();
    for (final state in _states.values) {
      state.restart();
    }
    _time = 0;
    _hasOrigin = false;
  }

  /// Simulates [seconds] of the system's life at once, in steps of [step]
  /// seconds, as if it had been running already (a fire that is already
  /// burning). Ground hits and arrivals are not reported.
  void prewarm(double seconds, {double step = 1 / 30}) {
    assert(step > 0, 'step must be positive');
    _syncOrigin(0);
    _motionStart = 1;
    _motionEnd = 1;
    _muted = true;
    try {
      var remaining = seconds;
      while (remaining > 1e-9) {
        final h = math.min(step, remaining);
        _advance(h, 0);
        remaining -= h;
      }
    } finally {
      _muted = false;
    }
    _lastOrigin.setFrom(_origin);
    _publishBounds();
    _markDrawChanged();
  }

  /// Spawns [count] particles (times [density]) at once with the spawn rules
  /// of [emitter] (the first of [emitters] by default), at [at] (in the
  /// simulation space; the system's origin by default), all of [color] when
  /// given. Returns the number of particles spawned.
  int burst(
    int count, {
    Vector3? at,
    ParticleEmitter3D? emitter,
    Color? color,
  }) {
    if (count <= 0 || density <= 0) {
      return 0;
    }
    final source =
        emitter ?? (emitters.isNotEmpty ? emitters.first : _defaultEmitter);
    final scaled = density == 1
        ? count
        : math.max(1, (count * density).round());
    double x;
    double y;
    double z;
    if (at != null) {
      x = at.x;
      y = at.y;
      z = at.z;
    } else if (space == ParticleSpace.world) {
      final m = worldTransformMatrix.storage;
      x = m[12];
      y = m[13];
      z = m[14];
    } else {
      x = 0;
      y = 0;
      z = 0;
    }
    var spawned = 0;
    for (var i = 0; i < scaled; i++) {
      if (!_spawn(source, x, y, z, 0, color)) {
        break;
      }
      spawned++;
    }
    if (spawned > 0) {
      _publishBounds();
      _markDrawChanged();
    }
    return spawned;
  }

  /// Spawns [count] particles with the spawn rules of the first emitter at
  /// the system's origin, see [burst].
  int emit(int count) => burst(count);

  /// Spawns one particle at [position] (in the simulation space) with the
  /// given values. Returns whether it was spawned.
  bool spawn({
    required Vector3 position,
    Vector3? velocity,
    double lifespan = 1,
    double size = 0.1,
    double aspect = 1,
    Color color = const Color(0xFFFFFFFF),
    double rotation = 0,
    double spin = 0,
    double gravityScale = 1,
    Vector3? axis,
  }) {
    final index = _slot();
    if (index < 0) {
      return false;
    }
    final b = particles;
    b.posX[index] = position.x;
    b.posY[index] = position.y;
    b.posZ[index] = position.z;
    b.velX[index] = velocity?.x ?? 0;
    b.velY[index] = velocity?.y ?? 0;
    b.velZ[index] = velocity?.z ?? 0;
    b.age[index] = 0;
    b.invLifespan[index] = 1 / math.max(lifespan, 1e-4);
    b.width[index] = size;
    b.height[index] = size * aspect;
    b.rotation[index] = rotation;
    b.spin[index] = spin;
    if (axis != null && axis.length2 > 0) {
      final length = axis.length;
      b.axisX[index] = axis.x / length;
      b.axisY[index] = axis.y / length;
      b.axisZ[index] = axis.z / length;
    } else {
      _spinAxisInto(index);
    }
    b.gravityScale[index] = gravityScale;
    b.seed[index] = random.nextDouble();
    b.color[index] = color.toARGB32();
    b.attractorFlags[index] = 0;
    _spawned(index);
    _publishBounds();
    _markDrawChanged();
    return true;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (paused || !(dt > 0)) {
      return;
    }
    final hadParticles = particles.length > 0;
    final frame = math.min(dt, 0.25);
    final steps = math.max(1, math.min(8, (frame / maxStep).ceil()));
    final h = frame / steps;
    _syncOrigin(frame);
    final distance = _origin.distanceTo(_lastOrigin) / steps;
    for (var s = 0; s < steps; s++) {
      _motionStart = s / steps;
      _motionEnd = (s + 1) / steps;
      _advance(h, distance);
    }
    _lastOrigin.setFrom(_origin);
    _publishBounds();
    if (hadParticles || particles.length > 0) {
      _markDrawChanged();
    }
    if (removeOnFinish && isFinished) {
      removeFromParent();
    }
  }

  /// The largest value of [sizeOverLife] (cached), for the bounds.
  double get _sizeCurveMax {
    final curve = sizeOverLife;
    if (curve == null) {
      return 1;
    }
    if (!identical(curve, _maxCurve)) {
      var max = 0.0;
      for (var i = 0; i <= 64; i++) {
        max = math.max(max, curve.transform(i / 64).abs());
      }
      _maxCurve = curve;
      _maxCurveValue = max;
    }
    return _maxCurveValue;
  }

  /// The largest distance of the mesh's vertices from its origin (cached).
  double get _radiusOfMesh {
    if (_meshRadius < 0) {
      final box = mesh!.aabb;
      final x = math.max(box.min.x.abs(), box.max.x.abs());
      final y = math.max(box.min.y.abs(), box.max.y.abs());
      final z = math.max(box.min.z.abs(), box.max.z.abs());
      _meshRadius = math.sqrt(x * x + y * y + z * z);
    }
    return _meshRadius;
  }

  /// The uniform scale of the world transform (the cube root of the volume
  /// it scales by).
  static double _uniformScale(Float32List m) => uniformScale3x3(m);

  @override
  bool get usesDefaultFrustumVisibility => runtimeType == ParticleSystem3D;

  @override
  Aabb3? computeLocalAabb() {
    if (particles.length == 0 || !_hasRawBounds) {
      return null;
    }
    if (space == ParticleSpace.local) {
      return _bounds;
    }
    // The bounds are in world space; the component expects local ones.
    final determinant = _inverse.copyInverse(worldTransformMatrix);
    if (determinant == 0) {
      return null;
    }
    return _localBounds
      ..setFrom(_bounds)
      ..transform(_inverse);
  }

  /// Whether the particles are sorted back to front for the next draw.
  bool get sortsParticles {
    switch (sort) {
      case ParticleSort.none:
        return false;
      case ParticleSort.backToFront:
        return true;
      case ParticleSort.auto:
        final material = this.material;
        if (material != null) {
          return material.needsSorting;
        }
        final mesh = this.mesh!;
        for (var i = 0; i < mesh.surfaceCount; i++) {
          final state = mesh.surfaces.elementAt(i).material.renderState;
          if (ParticleMaterial.blendsInOrder(state)) {
            return true;
          }
        }
        return false;
    }
  }

  @override
  void draw(covariant RenderContext3D context) {
    final count = particles.length;
    if (count == 0) {
      return;
    }
    final material = this.material;
    final shadowPass = context.isShadowPass;
    final prepass = context.isDepthNormalPass;
    // Billboards are never drawn into shadow maps, which read each instance
    // as a model matrix, which the instances of billboards are not; opaque
    // ones are drawn into the depth-normal prepass by the depth-normal
    // material of their material. Mesh particles are drawn into both, when a
    // material of their mesh casts shadows (or, for the prepass, is opaque).
    if (material != null &&
        (shadowPass || (prepass && material.depthNormalMaterial == null))) {
      return;
    }
    if (shadowPass && !_castsShadows) {
      return;
    }
    if (prepass && material == null && !_hasOpaqueSurface) {
      return;
    }
    RenderProfile.lap(RenderPhase.recording);
    final sorted = sortsParticles;
    final isLocal = space == ParticleSpace.local;
    final worldVer = isLocal ? worldTransformVersion : 0;
    if (sorted) {
      final viewStorage = context.view.storage;
      if (_cachedSortVersion != _stateVersion ||
          _cachedSortLocal != isLocal ||
          _cachedSortWorldVer != worldVer ||
          !sameMatrix16Approx(viewStorage, _cachedSortView)) {
        _sortBackToFront(context.view);
        _cachedSortVersion = _stateVersion;
        _cachedSortLocal = isLocal;
        _cachedSortWorldVer = worldVer;
        for (var i = 0; i < 16; i++) {
          _cachedSortView[i] = viewStorage[i];
        }
        _sortSerial++;
      }
    }

    final frames = material?.frameCount ?? 0;
    final blending = material?.frameBlending ?? false;
    final instData = instanceData.storage;
    final d0 = instData[0];
    final d1 = instData[1];
    final d2 = instData[2];
    final d3 = instData[3];
    final packStale =
        _cachedPackVersion != _stateVersion ||
        _cachedPackSorted != sorted ||
        (sorted && _cachedPackSortSerial != _sortSerial) ||
        _cachedPackLocal != isLocal ||
        _cachedPackWorldVer != worldVer ||
        !identical(_cachedPackMaterial, material) ||
        !identical(_cachedPackFlipbook, flipbook) ||
        _cachedPackFrames != frames ||
        _cachedPackBlending != blending ||
        !identical(_cachedSizeCurve, sizeOverLife) ||
        !identical(_cachedColorRamp, colorOverLife) ||
        !identical(_cachedOpacityCurve, opacityOverLife) ||
        !identical(_cachedRotationCurve, rotationOverLife) ||
        _cachedVelStretch != velocityStretch ||
        _cachedMaxStretch != maxStretch ||
        _cachedInstD0 != d0 ||
        _cachedInstD1 != d1 ||
        _cachedInstD2 != d2 ||
        _cachedInstD3 != d3;

    if (packStale) {
      if (material != null) {
        _writeBillboards(sorted, material);
      } else {
        _writeMeshes(sorted);
      }
      _cachedPackVersion = _stateVersion;
      _cachedPackSorted = sorted;
      _cachedPackSortSerial = _sortSerial;
      _cachedPackLocal = isLocal;
      _cachedPackWorldVer = worldVer;
      _cachedPackMaterial = material;
      _cachedPackFlipbook = flipbook;
      _cachedPackFrames = frames;
      _cachedPackBlending = blending;
      _cachedSizeCurve = sizeOverLife;
      _cachedColorRamp = colorOverLife;
      _cachedOpacityCurve = opacityOverLife;
      _cachedRotationCurve = rotationOverLife;
      _cachedVelStretch = velocityStretch;
      _cachedMaxStretch = maxStretch;
      _cachedInstD0 = d0;
      _cachedInstD1 = d1;
      _cachedInstD2 = d2;
      _cachedInstD3 = d3;
    }

    final center = _center
      ..setFrom(_bounds.min)
      ..add(_bounds.max)
      ..scale(0.5);
    if (isLocal) {
      worldTransformMatrix.transform3(center);
    }
    RenderProfile.lap(RenderPhase.particles);
    if (material != null) {
      context.drawInstances(
        _quad,
        material: material,
        instances: _instances,
        count: count,
        center: center,
      );
    } else {
      final mesh = this.mesh!;
      for (final surface in mesh.surfaces) {
        context.drawInstances(
          surface,
          instances: _instances,
          count: count,
          center: center,
        );
      }
    }
    if (!shadowPass && !prepass) {
      context.device.stats.particles += count;
    }
  }

  /// Whether one of the materials of the mesh is opaque, so that the
  /// depth-normal prepass draws the particles.
  bool get _hasOpaqueSurface {
    final mesh = this.mesh!;
    for (final surface in mesh.surfaces) {
      if (!surface.material.renderState.translucent) {
        return true;
      }
    }
    return false;
  }

  /// Whether the material, or one of the materials of the mesh, casts
  /// shadows: otherwise the particles are not drawn into shadow maps.
  bool get _castsShadows {
    final material = this.material;
    if (material != null) {
      return material.castsShadows;
    }
    final mesh = this.mesh!;
    for (final surface in mesh.surfaces) {
      if (surface.material.castsShadows) {
        return true;
      }
    }
    return false;
  }

  /// The instance data of the last draw, for tests and custom renderers.
  @visibleForTesting
  Float32List get instanceBuffer => _instances;

  /// The order of the particles in the last sorted draw.
  @visibleForTesting
  Int32List get drawOrder => _order;

  /// The quad every billboard is drawn with: corners in `[-0.5, 0.5]`,
  /// texture coordinates with `v` growing downwards.
  static final Surface _quad = Surface.fromBuffers(
    vertices: Float32List.fromList(const [
      -0.5, -0.5, 0, 0, 1, //
      0.5, -0.5, 0, 1, 1, //
      0.5, 0.5, 0, 1, 0, //
      -0.5, 0.5, 0, 0, 0, //
    ]),
    indices: Uint16List.fromList(const [0, 1, 2, 2, 3, 0]),
    layout: quadLayout,
  );

  /// The vertex layout of the quad billboards are drawn with: a corner
  /// position and texture coordinates.
  static final VertexLayout quadLayout = VertexLayout(const [
    VertexAttribute(VertexLayout.positionAttribute, 3),
    VertexAttribute('vertexTexCoord', 2),
  ]);
}
