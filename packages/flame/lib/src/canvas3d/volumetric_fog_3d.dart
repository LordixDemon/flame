import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/src/cache/memory_cache.dart';
import 'package:flame/src/canvas3d/camera_rig_3d.dart';
import 'package:flame/src/canvas3d/primitives_3d.dart';
import 'package:flame/src/canvas3d/scene_environment_3d.dart';
import 'package:flame/src/components/core/component.dart';
import 'package:flame/src/components/mixins/has_visibility.dart';
import 'package:flame/src/game/game.dart';
import 'package:flame/src/math/simplex_noise_2d.dart';
import 'package:flutter/painting.dart';

/// Zero-allocation 3D volumetric billowing fog and rolling cloud-bank engine.
///
/// Simulates up to [capacity] 3D turbulent cloud parcels in `(wx, wy, wz)`
/// world space with:
/// - Horizontal/3D wind advection (including direct camera-approaching flow via
///   [setApproachSpeedTowardCamera]),
/// - 3D Simplex curl-like billowing turbulence and ground-hugging roll
///   vorticity (`wz >= groundFloorZ`),
/// - True pinhole perspective swelling (`1 / camZ`) + Beer–Lambert near-lens
///   transmittance fade (`[nearFadeStart .. nearFadeEnd]`) so giant clouds
///   engulf the screen and pass smoothly through the lens without popping,
/// - Height self-shadowing, directional sun crest scattering, and volumetric
///   in-scattering from `SceneEnvironment3D` `PointLight3D` torches/lanterns,
/// - Back-to-front Ciura Shell depth sorting and **1 single GPU
///   `Canvas.drawRawAtlas` draw call**.
class VolumetricFogVolume3D({
  this.capacity = 320,
  int seed = 8841,
  this.baseColor = const Color(0xFFD6E4F0),
  this.highlightColor = const Color(0xFFF4F9FF),
  this.shadowColor = const Color(0xFF5D738A),
  this.density = 0.58,
  this.advectVx = 0.0,
  this.advectVy = 0.0,
  this.advectVz = 0.0,
  this.curlStrength = 0.85,
  this.curlScale = 0.28,
  this.curlTimeScale = 0.42,
  this.billowRollSpeed = 0.48,
  this.groundFloorZ = 0.0,
  this.ceilingZ = 3.6,
  this.nearFadeStart = 0.45,
  this.nearFadeEnd = 2.8,
  this.farFadeStart = 26.0,
  this.farSpawnDepth = 34.0,
  this.corridorHalfWidth = 9.5,
  this.recycleLoop = true,
  this.lightScatteringIntensity = 1.15,
}) {
  this
    : assert(capacity > 0, 'capacity must be positive'),
      assert(
        nearFadeEnd > nearFadeStart,
        'nearFadeEnd must be greater than nearFadeStart',
      ) {
    _wx = Float32List(capacity);
    _wy = Float32List(capacity);
    _wz = Float32List(capacity);
    _baseRadius = Float32List(capacity);
    _parcelDensity = Float32List(capacity);
    _angle = Float32List(capacity);
    _spin = Float32List(capacity);
    _phase = Float32List(capacity);
    _variant = Uint8List(capacity);

    _projX = Float32List(capacity);
    _projY = Float32List(capacity);
    _projRadiusPx = Float32List(capacity);
    _projDepth = Float32List(capacity);
    _projColor = Int32List(capacity);
    _sortIndices = Uint16List(capacity);

    _atlasTransforms = Float32List(capacity * 4);
    _atlasRects = Float32List(capacity * 4);
    _atlasColors = Int32List(capacity);

    _rng = math.Random(seed);
    _noise = SimplexNoise2D(seed: seed ^ 0x3c6ef372);
    _seed = seed;
  }

  /// Maximum number of 3D cloud parcels stored in SoA typed buffers.
  final int capacity;

  /// Mid-tone color of illuminated fog billows.
  Color baseColor;

  /// Silver-lining / upper crest highlight color scattered by directional sun
  /// or moonlight.
  Color highlightColor;

  /// Deep ambient self-shadow color at the lower base of dense fog banks.
  Color shadowColor;

  /// Global optical opacity multiplier (`0.0 .. 1.0+`).
  double density;

  /// Mean advection velocity along world X (units/s).
  double advectVx;

  /// Mean advection velocity along world Y (units/s).
  double advectVy;

  /// Mean advection velocity along world Z (units/s).
  double advectVz;

  /// Magnitude of 3D turbulent billowing velocity perturbations.
  double curlStrength;

  /// Spatial frequency of 3D billowing noise.
  double curlScale;

  /// Temporal evolution rate of 3D billowing noise.
  double curlTimeScale;

  /// Forward rolling angular velocity (rad/s) imparted by vertical shear.
  double billowRollSpeed;

  /// Minimum world height `z` over which ground fog rolls without sinking.
  double groundFloorZ;

  /// Soft upper ceiling `z` where rising fog billows flatten and spread.
  double ceilingZ;

  /// Camera-space distance at which a cloud parcel completes its near-lens
  /// transmittance fade (`0` opacity) and recycles when [recycleLoop] is true.
  double nearFadeStart;

  /// Camera-space distance below which near-lens transmittance begins softening
  /// cloud alpha so giant foreground puffs never pop abruptly.
  double nearFadeEnd;

  /// Camera-space distance where far horizon fade-in starts.
  double farFadeStart;

  /// Far horizon camera-space depth where recycled cloud parcels respawn.
  double farSpawnDepth;

  /// Half-width in world units of the camera-aligned recycling corridor.
  double corridorHalfWidth;

  /// Whether parcels passing closer than [nearFadeStart] automatically wrap
  /// back to [farSpawnDepth] to sustain an endless rolling fog bank.
  bool recycleLoop;

  /// Multiplier for volumetric internal glow from `SceneEnvironment3D`
  /// `PointLight3D` sources (torches, braziers, lanterns).
  double lightScatteringIntensity;

  static const int _cols = 4;
  static const int _rows = 2;
  static const int _variantCount = _cols * _rows;
  static const int _cellSize = 128;
  static const int _atlasW = _cols * _cellSize;
  static const int _atlasH = _rows * _cellSize;
  static const double _halfCell = (_cellSize - 4.0) * 0.5;

  static const List<int> _ciuraGaps = <int>[301, 132, 57, 23, 10, 4, 1];

  static final Float32List _variantSrcL = Float32List(_variantCount);
  static final Float32List _variantSrcT = Float32List(_variantCount);
  static final Float32List _variantSrcR = Float32List(_variantCount);
  static final Float32List _variantSrcB = Float32List(_variantCount);
  static bool _rectsInitialized = false;

  static void _ensureVariantRects() {
    if (_rectsInitialized) {
      return;
    }
    for (var i = 0; i < _variantCount; i++) {
      final c = i % _cols;
      final r = i ~/ _cols;
      _variantSrcL[i] = c * _cellSize + 2.0;
      _variantSrcT[i] = r * _cellSize + 2.0;
      _variantSrcR[i] = (c + 1) * _cellSize - 2.0;
      _variantSrcB[i] = (r + 1) * _cellSize - 2.0;
    }
    _rectsInitialized = true;
  }

  static final MemoryCache<int, ui.Image> _cloudAtlasCache =
      MemoryCache<int, ui.Image>(
        cacheSize: 8,
        onEvict: (_, img) => img.dispose(),
      );

  /// Disposes cached procedural 3D volumetric cloud atlases.
  static void clearAtlasCache() => _cloudAtlasCache.clearCache();

  static ui.Image _obtainCloudAtlas(int seed) {
    _ensureVariantRects();
    final key = seed & 0xffff;
    final cached = _cloudAtlasCache.getValue(key);
    if (cached != null) {
      return cached;
    }

    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    final paint = ui.Paint();

    for (var idx = 0; idx < _variantCount; idx++) {
      final col = idx % _cols;
      final row = idx ~/ _cols;
      final cx = col * _cellSize + _cellSize * 0.5;
      final cy = row * _cellSize + _cellSize * 0.5;
      final noise = SimplexNoise2D(seed: seed + idx * 193);

      // 18 multi-scale fBm-perturbed cumulus lobes for rich billowing edges.
      const lobes = 18;
      for (var l = 0; l < lobes; l++) {
        final double lx;
        final double ly;
        final double rad;
        final double alpha;
        if (l == 0) {
          lx = cx;
          ly = cy;
          rad = _cellSize * 0.35;
          alpha = 0.56;
        } else {
          final u = (l - 1) / (lobes - 1);
          final baseA = u * math.pi * 2.0 + idx * 0.61;
          final fbm = noise.fbm(
            math.cos(baseA) * 1.65 + idx * 0.7,
            math.sin(baseA) * 1.65 - idx * 0.5,
            octaves: 3,
          );
          final jitterA = noise.sample(l * 0.83, idx * 1.37) * 0.34;
          final ang = baseA + jitterA;
          final dist = _cellSize * (0.12 + 0.16 * (0.5 + 0.5 * fbm));
          lx = cx + math.cos(ang) * dist;
          ly = cy + math.sin(ang) * dist * 0.88;
          rad = _cellSize * (0.17 + 0.10 * (0.5 - 0.5 * fbm));
          alpha = (0.20 + 0.16 * (1.0 - u * 0.3)).clamp(0.10, 0.38);
        }

        final aCore = (alpha * 255).round().clamp(0, 255);
        final aMid = (alpha * 120).round().clamp(0, 255);
        paint.shader = ui.Gradient.radial(
          ui.Offset(lx, ly),
          rad,
          <ui.Color>[
            ui.Color.fromARGB(aCore, 255, 255, 255),
            ui.Color.fromARGB(aMid, 255, 255, 255),
            const ui.Color(0x00FFFFFF),
          ],
          const <double>[0.0, 0.54, 1.0],
        );
        canvas.drawCircle(ui.Offset(lx, ly), rad, paint);
      }
    }

    final picture = recorder.endRecording();
    final image = picture.toImageSync(_atlasW, _atlasH);
    picture.dispose();
    _cloudAtlasCache.setValue(key, image);
    return image;
  }

  late final int _seed;
  late final math.Random _rng;
  late final SimplexNoise2D _noise;

  late final Float32List _wx;
  late final Float32List _wy;
  late final Float32List _wz;
  late final Float32List _baseRadius;
  late final Float32List _parcelDensity;
  late final Float32List _angle;
  late final Float32List _spin;
  late final Float32List _phase;
  late final Uint8List _variant;

  late final Float32List _projX;
  late final Float32List _projY;
  late final Float32List _projRadiusPx;
  late final Float32List _projDepth;
  late final Int32List _projColor;
  late final Uint16List _sortIndices;

  late final Float32List _atlasTransforms;
  late final Float32List _atlasRects;
  late final Int32List _atlasColors;

  final Paint _atlasPaint = Paint()
    ..isAntiAlias = true
    ..filterQuality = FilterQuality.medium;

  int _activeCount = 0;
  double _simTime = 0.0;

  // Frame telemetry:
  int _lastRenderedCount = 0;
  int _lastDrawCalls = 0;
  double _nearestParcelDepth = double.infinity;
  double _maxScreenRadiusPx = 0.0;
  double _screenCenterCoverage = 0.0;

  /// Number of active 3D cloud parcels in the volume.
  int get activeParcelCount => _activeCount;

  /// Number of visible cloud parcels drawn during the last [render] pass.
  int get lastRenderedParcelCount => _lastRenderedCount;

  /// Number of GPU draw calls issued during the last [render] (`0` or `1`).
  int get lastDrawCalls => _lastDrawCalls;

  /// Minimum camera-space forward depth `camZ` among visible parcels in the
  /// last [render] pass (decreases as fog billows approach the screen).
  double get nearestParcelCameraDepth => _nearestParcelDepth;

  /// Largest projected screen-space cloud puff radius (in pixels) rendered in
  /// the last [render] pass.
  double get maxScreenRadiusPx => _maxScreenRadiusPx;

  /// Estimated optical coverage (`0.0 .. 1.0`) accumulated near the viewport
  /// center during the last [render] pass.
  double get screenCenterCoverageEstimate => _screenCenterCoverage;

  /// Clears all active fog parcels.
  void clear() {
    if (_activeCount > 0) {
      _activeCount = 0;
      Game.notifyVisualMutation();
    }
  }

  /// Sets 3D advection velocity `(advectVx, advectVy, advectVz)` so the fog
  /// bank rolls directly toward [camera]'s lens at [speed] units/s.
  ///
  /// [opticalAxisBlend] (`0.0 .. 1.0`, default `0.85`) blends pure horizontal
  /// ground drift (`0.0`) with the camera's 3D sightline (`1.0`) and ensures
  /// [ceilingZ] has enough vertical headroom for billowing clouds to reach an
  /// elevated perspective lens dead-center rather than passing underneath it.
  void setApproachSpeedTowardCamera(
    CameraRig3D camera,
    double speed, {
    double opticalAxisBlend = 0.85,
  }) {
    final blend = opticalAxisBlend.clamp(0.0, 1.0);
    final vx = camera.viewX;
    final vy = camera.viewY;
    final vz = camera.viewZ;
    final hLen = math.sqrt(vx * vx + vy * vy);
    final hx = hLen > 1e-6 ? vx / hLen : 1.0;
    final hy = hLen > 1e-6 ? vy / hLen : 0.0;

    final dirX = hx + (vx - hx) * blend;
    final dirY = hy + (vy - hy) * blend;
    final dirZ = vz * blend;
    final dirLen = math.sqrt(dirX * dirX + dirY * dirY + dirZ * dirZ);
    if (dirLen > 1e-6) {
      advectVx = (dirX / dirLen) * speed;
      advectVy = (dirY / dirLen) * speed;
      advectVz = (dirZ / dirLen) * speed;
    } else {
      advectVx = speed;
      advectVy = 0.0;
      advectVz = 0.0;
    }
    if (blend > 0.0 && speed > 0.0) {
      final eyeZ = camera.cameraDistance * vz * blend + 3.2;
      if (ceilingZ < eyeZ) {
        ceilingZ = eyeZ;
      }
    }
  }

  /// Spawns a single 3D cloud parcel at `(x, y, z)`.
  int spawnParcel({
    required double x,
    required double y,
    required double z,
    double radius = 1.65,
    double parcelDensity = 0.65,
    double? angle,
    double? spin,
  }) {
    if (_activeCount >= capacity) {
      return -1;
    }
    final slot = _activeCount++;
    _wx[slot] = x;
    _wy[slot] = y;
    _wz[slot] = z;
    _baseRadius[slot] = radius;
    _parcelDensity[slot] = parcelDensity.clamp(0.05, 1.5);
    _angle[slot] = angle ?? (_rng.nextDouble() * math.pi * 2.0);
    _spin[slot] = spin ?? ((_rng.nextDouble() - 0.5) * 0.35);
    _phase[slot] = _rng.nextDouble() * math.pi * 2.0;
    _variant[slot] = _rng.nextInt(_variantCount);
    Game.notifyVisualMutation();
    return slot;
  }

  /// Populates a camera-aligned 3D corridor from [minCamDepth] to [maxCamDepth]
  /// with clustered billowing cloud banks.
  void populateCorridor(
    CameraRig3D camera, {
    int? count,
    double minCamDepth = 2.4,
    double maxCamDepth = 32.0,
    double? halfWidth,
    double minZ = 0.15,
    double maxZ = 2.6,
    double radiusMin = 1.35,
    double radiusMax = 2.85,
  }) {
    clear();
    final targetCount = (count ?? capacity).clamp(1, capacity);
    final hw = halfWidth ?? corridorHalfWidth;
    corridorHalfWidth = hw;
    farSpawnDepth = math.max(farSpawnDepth, maxCamDepth);

    final (tx, ty) = camera.screenToGrid(
      Offset(camera.camWorldX, camera.camWorldY),
    );
    final hx = camera.viewX;
    final hy = camera.viewY;
    final hLen = math.max(1e-5, math.sqrt(hx * hx + hy * hy));
    final fwdX = hx / hLen;
    final fwdY = hy / hLen;
    final rightX = camera.rightX;
    final rightY = camera.rightY;

    // Group parcels into organic multi-lobe cloud clusters (4..5 puffs per
    // cluster) so fog arrives in distinct billowing clouds rather than uniform
    // white noise!
    var spawned = 0;
    var clusterIdx = 0;
    while (spawned < targetCount) {
      final uDepth = (clusterIdx * 0.61803398875) % 1.0;
      final clusterCamZ = minCamDepth + uDepth * (maxCamDepth - minCamDepth);
      final clusterLat = (_rng.nextDouble() * 2.0 - 1.0) * hw * 0.88;
      final localZ = minZ + _rng.nextDouble() * (maxZ - minZ) * 0.72;
      final alongRay = camera.cameraDistance - clusterCamZ;
      // Distant fog (`alongRay <= 0`) hugs the ground; foreground fog
      // (`alongRay > 0`) follows the camera sightline up toward the lens.
      final sightLift = alongRay > 0.0 ? alongRay * camera.viewZ * 0.82 : 0.0;
      final clusterZ = (groundFloorZ + sightLift + localZ).clamp(
        groundFloorZ + 0.05,
        ceilingZ,
      );
      final along =
          (camera.cameraDistance - clusterCamZ - clusterZ * camera.viewZ) /
          hLen;
      final cx = tx + fwdX * along + rightX * clusterLat;
      final cy = ty + fwdY * along + rightY * clusterLat;

      final clusterSize = 4 + (clusterIdx % 3);
      for (var m = 0; m < clusterSize && spawned < targetCount; m++) {
        final ox = (_rng.nextDouble() - 0.5) * 2.4;
        final oy = (_rng.nextDouble() - 0.5) * 2.4;
        final oz = (_rng.nextDouble() - 0.35) * 0.95;
        final pz = (clusterZ + oz).clamp(groundFloorZ + 0.05, ceilingZ);
        spawnParcel(
          x: cx + ox,
          y: cy + oy,
          z: pz,
          radius: radiusMin + _rng.nextDouble() * (radiusMax - radiusMin),
          parcelDensity: 0.52 + _rng.nextDouble() * 0.44,
        );
        spawned++;
      }
      clusterIdx++;
    }
  }

  /// Spawns a dense, dramatic wall of billowing cloud clusters starting far in
  /// the background (`[startCamDepth .. startCamDepth + thickness]`) ready to
  /// roll straight toward the screen.
  void spawnApproachingWavefront(
    CameraRig3D camera, {
    int? count,
    double startCamDepth = 20.0,
    double thickness = 11.0,
    double? halfWidth,
    double minZ = 0.12,
    double maxZ = 2.75,
    double approachSpeed = 4.6,
  }) {
    setApproachSpeedTowardCamera(camera, approachSpeed);
    populateCorridor(
      camera,
      count: count,
      minCamDepth: startCamDepth,
      maxCamDepth: startCamDepth + math.max(1.0, thickness),
      halfWidth: halfWidth,
      minZ: minZ,
      maxZ: maxZ,
      radiusMin: 1.55,
      radiusMax: 3.15,
    );
  }

  /// Advances 3D advection, curl-like billowing turbulence, rolling vorticity,
  /// and optional camera-corridor recycling.
  void update(double dt, {CameraRig3D? camera}) {
    if (_activeCount == 0 || dt <= 0.0) {
      return;
    }
    Game.notifyVisualMutation();
    final step = dt.clamp(0.0, 0.1);
    _simTime += step;

    final cScale = curlScale;
    final cStrength = curlStrength;
    final tScroll = _simTime * curlTimeScale;
    final zSpan = math.max(0.25, ceilingZ - groundFloorZ);

    var tx = 0.0;
    var ty = 0.0;
    var fwdX = 0.70710678;
    var fwdY = 0.70710678;
    var hLen = 1.0;
    if (camera != null && recycleLoop) {
      final gridTarget = camera.screenToGrid(
        Offset(camera.camWorldX, camera.camWorldY),
      );
      tx = gridTarget.$1;
      ty = gridTarget.$2;
      final vx = camera.viewX;
      final vy = camera.viewY;
      hLen = math.max(1e-5, math.sqrt(vx * vx + vy * vy));
      fwdX = vx / hLen;
      fwdY = vy / hLen;
    }

    for (var i = 0; i < _activeCount; i++) {
      var x = _wx[i];
      var y = _wy[i];
      var z = _wz[i];

      var vx = advectVx;
      var vy = advectVy;
      var vz = advectVz;

      if (cStrength != 0.0) {
        final sx = x * cScale + tScroll;
        final sy = y * cScale - tScroll * 0.75;
        final sz = z * cScale + _phase[i];
        // Divergence-free-inspired 3D cross-plane swirl:
        final n1 = _noise.sample(sx, sy + 0.17);
        final n2 = _noise.sample(sy + 3.1, sz);
        final n3 = _noise.sample(sz + 7.4, sx - 1.9);
        vx += (n1 - n2 * 0.5) * cStrength;
        vy += (n2 + n1 * 0.5) * cStrength;
        vz += n3 * cStrength * 0.42;
      }

      x += vx * step;
      y += vy * step;
      z += vz * step;

      // Ground-hugging cushion and soft inversion ceiling:
      if (z < groundFloorZ + 0.06) {
        z = groundFloorZ + 0.06 + (groundFloorZ + 0.06 - z) * 0.25;
      } else if (z > ceilingZ) {
        z = ceilingZ - (z - ceilingZ) * 0.35;
      }

      // Forward rolling shear (crests roll faster than ground belly):
      final heightFrac = ((z - groundFloorZ) / zSpan).clamp(0.0, 1.0);
      _angle[i] +=
          (_spin[i] + billowRollSpeed * (0.35 + 0.65 * heightFrac)) * step;

      if (camera != null && recycleLoop) {
        final (_, _, camZ) = camera.worldToCameraSpace(x, y, z);
        if (camZ <= nearFadeStart) {
          final lat = (_rng.nextDouble() * 2.0 - 1.0) * corridorHalfWidth;
          final baseSpan = math.min(zSpan, 3.2);
          final respawnZ =
              groundFloorZ + 0.12 + _rng.nextDouble() * (baseSpan * 0.78);
          final respawnDepth = farSpawnDepth - _rng.nextDouble() * 2.8;
          final along =
              (camera.cameraDistance - respawnDepth - respawnZ * camera.viewZ) /
              hLen;
          x = tx + fwdX * along + camera.rightX * lat;
          y = ty + fwdY * along + camera.rightY * lat;
          z = respawnZ;
        }
      }

      _wx[i] = x;
      _wy[i] = y;
      _wz[i] = z;
    }
  }

  static double _smoothstep(double edge0, double edge1, double x) {
    final span = edge1 - edge0;
    if (span.abs() < 1e-6) {
      return x >= edge1 ? 1.0 : 0.0;
    }
    final t = ((x - edge0) / span).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }

  /// Projects, illuminates, depth-sorts, and draws the entire 3D volumetric
  /// fog volume in **1 `Canvas.drawRawAtlas` call**.
  void render(
    Canvas canvas,
    CameraRig3D camera, {
    DirectionalLight3D? sunLight,
    SceneEnvironment3D? environment,
    Offset canvasOrigin = Offset.zero,
    Size? viewportSize,
  }) {
    _lastRenderedCount = 0;
    _lastDrawCalls = 0;
    _nearestParcelDepth = double.infinity;
    _maxScreenRadiusPx = 0.0;
    _screenCenterCoverage = 0.0;

    if (_activeCount == 0 || density <= 1e-3) {
      return;
    }

    final atlas = _obtainCloudAtlas(_seed);
    final isPerspective =
        camera.projectionMode == CameraProjectionMode3D.perspective;
    final perspFocal = camera.perspectiveFocalLengthPx;
    final axoFocal = camera.focalScalePx;
    final nearClip = math.max(camera.nearClip, nearFadeStart * 0.5);
    final zSpan = math.max(0.25, ceilingZ - groundFloorZ);

    final baseR = baseColor.r;
    final baseG = baseColor.g;
    final baseB = baseColor.b;
    final hiR = highlightColor.r;
    final hiG = highlightColor.g;
    final hiB = highlightColor.b;
    final shR = shadowColor.r;
    final shG = shadowColor.g;
    final shB = shadowColor.b;

    // Forward-scattering silver-lining boost when looking toward the sun:
    var sunScatterBoost = 0.25;
    if (sunLight != null) {
      final vDotL =
          -(camera.viewX * sunLight.dirX +
              camera.viewY * sunLight.dirY +
              camera.viewZ * sunLight.dirZ);
      final hg = ((vDotL + 1.0) * 0.5).clamp(0.0, 1.0);
      sunScatterBoost = 0.20 + 0.55 * hg * hg * sunLight.diffuseIntensity;
    }

    final vpW = viewportSize?.width ?? 1280.0;
    final vpH = viewportSize?.height ?? 800.0;
    final centerScreenX = camera.camWorldX - canvasOrigin.dx;
    final centerScreenY = camera.camWorldY - canvasOrigin.dy;
    final cullHalfW = vpW * 0.85;
    final cullHalfH = vpH * 0.85;

    final plCount = environment?.pointLightCount ?? 0;
    final plX = environment?.lightX;
    final plY = environment?.lightY;
    final plZ = environment?.lightZ;
    final plRad = environment?.lightRadius;
    final plInvRadSq = environment?.lightInvRadiusSq;
    final plR = environment?.lightR;
    final plG = environment?.lightG;
    final plB = environment?.lightB;

    var visibleCount = 0;
    var transmittanceCenter = 1.0;

    for (var i = 0; i < _activeCount; i++) {
      final wx = _wx[i];
      final wy = _wy[i];
      final wz = _wz[i];

      final (camX, camY, camZ) = camera.worldToCameraSpace(wx, wy, wz);
      if (camZ <= nearClip || camZ >= farSpawnDepth + 2.0) {
        continue;
      }

      // Near-lens Beer-Lambert fade + far horizon fade:
      final nearFade = _smoothstep(nearFadeStart, nearFadeEnd, camZ);
      final farFade = 1.0 - _smoothstep(farFadeStart, farSpawnDepth, camZ);
      final breath = 1.0 + 0.13 * math.sin(_simTime * 1.25 + _phase[i]);
      final worldRad = _baseRadius[i] * breath;

      double sx;
      double sy;
      double radiusPx;
      if (isPerspective) {
        final invZ = perspFocal / camZ;
        sx = camera.camWorldX + camX * invZ - canvasOrigin.dx;
        sy = camera.camWorldY + camY * invZ - canvasOrigin.dy;
        radiusPx = (worldRad * invZ).clamp(2.0, vpW * 0.95);
      } else {
        final p = camera.projectWorldPoint(wx, wy, wz);
        sx = p.dx - canvasOrigin.dx;
        sy = p.dy - canvasOrigin.dy;
        radiusPx = worldRad * axoFocal * camera.camZoom;
      }

      // Frustum cull with generous cloud radius margin:
      if ((sx - centerScreenX).abs() > cullHalfW + radiusPx ||
          (sy - centerScreenY).abs() > cullHalfH + radiusPx) {
        continue;
      }

      final alpha = (density * _parcelDensity[i] * nearFade * farFade).clamp(
        0.0,
        0.92,
      );
      final aByte = (alpha * 255.0).round();
      if (aByte <= 2) {
        continue;
      }

      if (camZ < _nearestParcelDepth) {
        _nearestParcelDepth = camZ;
      }
      if (radiusPx > _maxScreenRadiusPx) {
        _maxScreenRadiusPx = radiusPx;
      }

      // Center-screen optical thickness integration:
      final dcx = sx - centerScreenX;
      final dcy = sy - centerScreenY;
      final distCenterSq = dcx * dcx + dcy * dcy;
      if (distCenterSq < radiusPx * radiusPx) {
        final radialWeight = 1.0 - math.sqrt(distCenterSq) / radiusPx;
        transmittanceCenter *= (1.0 - alpha * radialWeight * 0.65).clamp(
          0.0,
          1.0,
        );
      }

      // Vertical self-shadowing + crest sun scattering:
      final hFrac = ((wz - groundFloorZ) / zSpan).clamp(0.0, 1.0);
      var rLin = shR + (baseR - shR) * (0.28 + 0.72 * hFrac);
      var gLin = shG + (baseG - shG) * (0.28 + 0.72 * hFrac);
      var bLin = shB + (baseB - shB) * (0.28 + 0.72 * hFrac);

      final crest = (hFrac * sunScatterBoost).clamp(0.0, 0.85);
      rLin += (hiR - rLin) * crest;
      gLin += (hiG - gLin) * crest;
      bLin += (hiB - bLin) * crest;

      // Volumetric internal glow from nearby 3D point lights (torches/braziers):
      if (plCount > 0 && lightScatteringIntensity > 0.0) {
        for (var l = 0; l < plCount; l++) {
          final reach = plRad![l] * 1.35;
          final dx = plX![l] - wx;
          if (dx > reach || dx < -reach) {
            continue;
          }
          final dy = plY![l] - wy;
          if (dy > reach || dy < -reach) {
            continue;
          }
          final dz = plZ![l] - wz;
          if (dz > reach || dz < -reach) {
            continue;
          }
          final dSq = dx * dx + dy * dy + dz * dz;
          final rSq = reach * reach;
          if (dSq < rSq) {
            final t = 1.0 - dSq / rSq;
            final scatter =
                t *
                t *
                lightScatteringIntensity *
                (0.55 + 0.45 * plInvRadSq![l].clamp(0.05, 1.0));
            rLin += plR![l] * scatter;
            gLin += plG![l] * scatter;
            bLin += plB![l] * scatter;
          }
        }
      }

      final rByte = (rLin.clamp(0.0, 1.0) * 255.0).round();
      final gByte = (gLin.clamp(0.0, 1.0) * 255.0).round();
      final bByte = (bLin.clamp(0.0, 1.0) * 255.0).round();

      _projX[visibleCount] = sx;
      _projY[visibleCount] = sy;
      _projRadiusPx[visibleCount] = radiusPx;
      _projDepth[visibleCount] = camZ;
      _projColor[visibleCount] =
          (aByte << 24) | (rByte << 16) | (gByte << 8) | bByte;
      _sortIndices[visibleCount] = i;
      // Temporarily store compact visible slot order in `_sortIndices`:
      visibleCount++;
    }

    if (visibleCount == 0) {
      return;
    }

    // Re-index `_sortIndices` to `0 .. visibleCount - 1` while preserving each
    // visible parcel's original index via packed `(visibleSlot)` lookup. To
    // keep `_angle` and `_variant` accessible without allocating, pack original
    // parcel index in upper 16 bits? Capacity can exceed 256, so let's sort a
    // compact permutation over `0 .. visibleCount - 1` where `_sortIndices`
    // stores the original parcel index and `_proj*` is indexed by parcel `i`!
    // Wait: let's write projected fields directly at parcel index `i` so
    // `_sortIndices[0..visibleCount-1]` holds parcel index `i` directly!
    _sortProjectedByDescendingDepth(visibleCount);

    for (var s = 0; s < visibleCount; s++) {
      final slot = _sortIndices[s];
      final origParcel = _packedOrigParcel[s];
      final scale = _projRadiusPx[slot] / _halfCell;
      final ang = _angle[origParcel];
      final scos = math.cos(ang) * scale;
      final ssin = math.sin(ang) * scale;
      final cx = _projX[slot];
      final cy = _projY[slot];

      final tBase = s * 4;
      _atlasTransforms[tBase] = scos;
      _atlasTransforms[tBase + 1] = ssin;
      _atlasTransforms[tBase + 2] = cx - (scos - ssin) * _halfCell;
      _atlasTransforms[tBase + 3] = cy - (ssin + scos) * _halfCell;

      final v = _variant[origParcel];
      _atlasRects[tBase] = _variantSrcL[v];
      _atlasRects[tBase + 1] = _variantSrcT[v];
      _atlasRects[tBase + 2] = _variantSrcR[v];
      _atlasRects[tBase + 3] = _variantSrcB[v];

      _atlasColors[s] = _projColor[slot];
    }

    canvas.drawRawAtlas(
      atlas,
      Float32List.sublistView(_atlasTransforms, 0, visibleCount * 4),
      Float32List.sublistView(_atlasRects, 0, visibleCount * 4),
      Int32List.sublistView(_atlasColors, 0, visibleCount),
      BlendMode.modulate,
      null,
      _atlasPaint,
    );

    _lastRenderedCount = visibleCount;
    _lastDrawCalls = 1;
    _screenCenterCoverage = (1.0 - transmittanceCenter).clamp(0.0, 1.0);
  }

  late final Uint16List _packedOrigParcel = Uint16List(capacity);

  void _sortProjectedByDescendingDepth(int count) {
    // At entry, `_sortIndices[k]` holds the original parcel index for visible
    // item `k`, while `_proj*[k]` holds projected data at visible slot `k`.
    for (var k = 0; k < count; k++) {
      _packedOrigParcel[k] = _sortIndices[k];
      _sortIndices[k] = k;
    }

    for (var g = 0; g < _ciuraGaps.length; g++) {
      final gap = _ciuraGaps[g];
      if (gap >= count) {
        continue;
      }
      for (var i = gap; i < count; i++) {
        final curSlot = _sortIndices[i];
        final curOrig = _packedOrigParcel[i];
        final curDepth = _projDepth[curSlot];
        var j = i;
        while (j >= gap && _projDepth[_sortIndices[j - gap]] < curDepth) {
          _sortIndices[j] = _sortIndices[j - gap];
          _packedOrigParcel[j] = _packedOrigParcel[j - gap];
          j -= gap;
        }
        _sortIndices[j] = curSlot;
        _packedOrigParcel[j] = curOrig;
      }
    }
  }
}

/// Ready-to-mount Flame [Component] that simulates and renders a
/// [VolumetricFogVolume3D] bound to a [CameraRig3D] and optional
/// [DirectionalLight3D] / [SceneEnvironment3D].
class VolumetricFogComponent3D({
  required this.volume,
  required this.camera,
  this.sunLight,
  this.environment,
  this.canvasOrigin = Offset.zero,
  this.viewportSizeProvider,
  super.priority = 5000,
  super.cameraMask,
  super.key,
}) extends Component with HasVisibility {
  /// Underlying SoA 3D volumetric fog simulation and renderer.
  final VolumetricFogVolume3D volume;

  /// Active 3D camera rig used for perspective/axonometric projection and
  /// corridor recycling.
  final CameraRig3D camera;

  /// Optional directional sun/moon light for crest forward scattering.
  DirectionalLight3D? sunLight;

  /// Optional 3D scene environment providing `PointLight3D` volumetric glow.
  SceneEnvironment3D? environment;

  /// Canvas origin offset passed to [VolumetricFogVolume3D.render].
  Offset canvasOrigin;

  /// Optional callback supplying the active viewport size in logical pixels.
  Size Function()? viewportSizeProvider;

  @override
  void update(double dt) {
    super.update(dt);
    volume.update(dt, camera: camera);
  }

  @override
  void render(Canvas canvas) {
    volume.render(
      canvas,
      camera,
      sunLight: sunLight,
      environment: environment,
      canvasOrigin: canvasOrigin,
      viewportSize: viewportSizeProvider?.call(),
    );
  }
}
