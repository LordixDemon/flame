import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d_example/houses/board_grid.dart';
import 'package:flame_3d_example/showcase/showcase_meshes.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier;

/// Interactive feature flags and live telemetry state of [ShowcaseGame].
class ShowcaseController() extends ChangeNotifier {
  bool retainedStaticLayer = true;
  bool staticShadowCache = true;
  bool sharedShadowGroup = false;
  bool bloom = true;
  bool fog = true;
  bool outlines = true;
  bool wind = false;
  bool particles = true;
  bool ribbonsAndDecals = true;
  bool msaa4x = true;
  bool autoOrbitCamera = false;
  bool stressInstances = false;

  String activeClip = 'Idle';
  String lastHitSummary = 'Tap any 3D object to raycast its triangle BVH';
  ui.Image? snapshotImage;

  double fps = 60;
  double frameMsP50 = 16.6;
  double frameMsP95 = 16.6;

  void notifyChanged() => notifyListeners();

  @override
  void dispose() {
    snapshotImage?.dispose();
    snapshotImage = null;
    super.dispose();
  }
}

/// Comprehensive `flame_3d` testbed exercising all major engine subsystems in
/// two layered [Scene3DComponent]s over a 2D world:
///
/// - `staticLayer`: [Scene3DCacheMode.retained] +
///   [ShadowSettings.cacheWhenStatic], [ShadowCatcherMaterial] on 2D ground,
///   [InstancedGroup3D] with 16-color [StylizedMaterial.accentPalette],
///   [LodMeshComponent] towers, `WindSpace.worldScaled` foliage, two-tier
///   metallic/gem MatCaps, and PBR [SpatialMaterial] spheres;
/// - `dynamicLayer`: [BloomSettings] Kawase glow, [FogSettings] distance/height
///   mist, zero-alloc skinned [ModelComponent] with [AnimationPlayMode] &
///   `crossFadeToByName`, [BoneSocket3D] joint attachment, static & skinned
///   [OutlineMaterial], [DecalBatch3D] procedural & atlas decals,
///   [StrokeBatch3D] & [RibbonTrail3D] 3D ribbons, and [ParticleSystem3D]
///   billboard + mesh particles;
/// - Interactive `Surface.bvh` raycasting on tap and offscreen
///   `World3D.renderToImage` thumbnail snapshots.
class ShowcaseGame({ShowcaseController? controller})
    extends FlameGame
    with TapCallbacks, DragCallbacks, ScrollCallbacks, ScaleCallbacks {
  /// Controller driving feature toggles and HUD readouts.
  final ShowcaseController controller = controller ?? ShowcaseController();

  static const int boardCells = 14;
  static const double minZoom = 0.35;
  static const double maxZoom = 2.6;

  /// Dimetric board projection (cells of `88x44` logical px, `+Z` up).
  static final Scene3DProjection projection = Scene3DProjection.affine(
    origin: Vector2(0, -18),
    xAxis: Vector2(44, 22),
    yAxis: Vector2(-44, 22),
    zAxis: Vector2(0, -53.889),
    towardsViewer: Vector3(0.6124, 0.6124, 0.5),
    near: -45,
    far: 45,
  );

  static const List<String> animationClips = ['Idle', 'Swing', 'Spin'];

  final ShowcaseAssets showcaseAssets = ShowcaseAssets();
  final ShadowGroup shadowGroup = ShadowGroup();

  late final Scene3DComponent staticLayer;
  late final Scene3DComponent dynamicLayer;

  late final StylizedMaterial tileMaterial;
  late final StylizedMaterial windTreeMaterial;
  late final StylizedMaterial crystalMaterial;
  late final StylizedMaterial metalPedestalMaterial;
  late final StylizedMaterial automatonMaterial;
  late final OutlineMaterial staticOutlineMaterial;
  late final OutlineMaterial skinnedOutlineMaterial;

  late final InstancedGroup3D tileInstances;
  final List<LodMeshComponent> lodTowers = [];
  final List<MeshComponent> windTrees = [];

  late final ModelComponent automaton;
  late final ModelComponent automatonOutline;
  late final BoneSocket3D armTipSocket;
  late final LightComponent socketPointLight;
  late final RibbonTrail3D socketRibbon;

  late final MeshComponent orbitingSentinel;
  late final MeshComponent orbitingSentinelOutline;
  late final RibbonTrail3D sentinelRibbon;

  late final DecalBatch3D ringDecals;
  late final DecalBatch3D atlasDecals;
  late final StrokeBatch3D energyStrokes;

  late final ParticleSystem3D sparkParticles;
  late final ParticleSystem3D smokeParticles;
  late final ParticleSystem3D coinMeshParticles;

  late final ShadowSettings _staticShadows;
  late final ShadowSettings _dynamicShadows;
  late final FogSettings _fogSettings;
  late final BloomSettings _bloomSettings;

  double _time = 0;
  double _burstTimer = 0;
  double _startZoom = 1.0;
  int _clipIndex = 0;
  int? _highlightedInstance;

  Vector3? _lastHitPoint;
  Vector3? _lastHitNormal;

  final List<double> _frameDurationsMs = List<double>.filled(90, 16.6);
  int _frameRingCursor = 0;
  int _frameSamples = 0;
  double _hudRefreshTimer = 0;

  @override
  ui.Color backgroundColor() => const ui.Color(0xFF101722);

  @override
  Future<void> onLoad() async {
    _staticShadows = ShadowSettings(
      fit: ShadowFit.scene,
      strength: 0.78,
      color: const ui.Color(0xFF1A2548),
      cacheWhenStatic: controller.staticShadowCache,
      bounds: Aabb3.minMax(
        Vector3(-2, -2, -1),
        Vector3(boardCells + 2.0, boardCells + 2.0, 5),
      ),
    );
    _dynamicShadows = ShadowSettings(
      fit: ShadowFit.scene,
      strength: 0.78,
      color: const ui.Color(0xFF1A2548),
      bounds: Aabb3.minMax(
        Vector3(-2, -2, -1),
        Vector3(boardCells + 2.0, boardCells + 2.0, 5),
      ),
    );
    _fogSettings = FogSettings(
      color: const ui.Color(0xFF283C5E),
      start: 28,
      end: 95,
      baseHeight: 0.15,
      heightFalloff: 0.9,
      up: Vector3(0, 0, 1),
    );
    _bloomSettings = BloomSettings(
      threshold: 0.68,
      softKnee: 0.45,
      intensity: 0.85,
      radius: 1.5,
    );

    staticLayer = Scene3DComponent(
      projection: projection,
      msaa: controller.msaa4x ? Msaa.sample4 : Msaa.off,
      cacheMode: controller.retainedStaticLayer
          ? Scene3DCacheMode.retained
          : Scene3DCacheMode.none,
      priority: 1,
    );
    dynamicLayer = Scene3DComponent(
      projection: projection,
      msaa: controller.msaa4x ? Msaa.sample4 : Msaa.off,
      bloom: controller.bloom ? _bloomSettings : null,
      priority: 2,
    );

    world.addAll([
      BoardGrid(cells: boardCells, projection: projection),
      staticLayer,
      dynamicLayer,
    ]);

    _buildMaterials();
    _populateStaticLayer();
    _populateDynamicLayer();
    syncControllerState();

    camera.viewfinder.position = staticLayer.scenePointToLocal(
      Vector3(boardCells / 2, boardCells / 2, 0.5),
    );
  }

  void _buildMaterials() {
    tileMaterial = StylizedMaterial(
      accentPalette: ShowcaseAssets.accentPalette,
      matCapTexture: showcaseAssets.coatMatCap,
      matCapStrength: 0.45,
      matCapThreshold: 0.4,
      matCapGlossWeight: 0,
      gemMatCapTexture: showcaseAssets.gemMatCap,
      gemMatCapStrength: 0.85,
      gemThreshold: 1.3,
      emissiveColor: const ui.Color(0xFF90E8FF),
      emissiveBoostColor: const ui.Color(0xFFFFE066),
    )..renderState = const RenderState(cullMode: CullMode.backFace);

    windTreeMaterial = StylizedMaterial(
      windSpace: WindSpace.worldScaled,
      windDirection: Vector3(1, 0.35, 0),
      windUpAxis: Vector3(0, 0, 1),
      windAmplitude: 0.055,
      windFrequency: 2.4,
      windPhase: Vector3(0.65, 0.45, 0),
      windFlutterAmplitude: 0.014,
      windFlutterFrequency: 11.5,
      windGustAmplitude: 0.45,
      windGustFrequency: 0.9,
      windGustDirection: Vector3(1, 0.35, 0),
      windGustPhaseScale: 0.45,
    )..renderState = const RenderState(cullMode: CullMode.backFace);

    crystalMaterial = StylizedMaterial(
      matCapTexture: showcaseAssets.coatMatCap,
      matCapThreshold: 0.25,
      gemMatCapTexture: showcaseAssets.gemMatCap,
      emissiveColor: const ui.Color(0xFF5CE1E6),
      emissiveBoostColor: const ui.Color(0xFFFF70C8),
      emissiveStrength: 0.85,
    )..renderState = const RenderState(cullMode: CullMode.backFace);

    metalPedestalMaterial = StylizedMaterial(
      matCapTexture: showcaseAssets.goldMatCap,
      matCapThreshold: -1,
      matCapGlossWeight: 0,
      matCapMetallic: 1.0,
      specularStrength: 0.15,
    )..renderState = const RenderState(cullMode: CullMode.backFace);

    automatonMaterial = StylizedMaterial(
      matCapTexture: showcaseAssets.coatMatCap,
      matCapThreshold: 0.2,
      matCapStrength: 0.55,
      rimColor: const ui.Color(0xFF38BDF8),
      rimStrength: 0.28,
    );

    staticOutlineMaterial = OutlineMaterial(
      color: const ui.Color(0xFF00F5D4),
      thickness: 0.055,
      screenSpace: true,
    );
    skinnedOutlineMaterial = OutlineMaterial(
      color: const ui.Color(0xFFFFBE0B),
      thickness: 0.045,
      screenSpace: true,
    );
  }

  void _populateStaticLayer() {
    final upright = Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2);
    final sunDirection = Vector3(-0.48, -0.62, -0.92);

    staticLayer.world.addAll([
      LightComponent.hemisphere(
        skyColor: const ui.Color(0xFFB8D4F8),
        groundColor: const ui.Color(0xFF5D6B4D),
        intensity: 0.58,
        up: Vector3(0, 0, 1),
      ),
      LightComponent.directional(
        direction: sunDirection,
        color: const ui.Color(0xFFFFF4DC),
        intensity: 0.82,
        shadows: _staticShadows,
      ),
      MeshComponent(
        mesh: PlaneMesh(
          size: Vector2.all(boardCells + 2.0),
          material: ShadowCatcherMaterial(color: const ui.Color(0xA6141D38)),
        ),
        position: Vector3(boardCells / 2, boardCells / 2, 0),
        rotation: upright,
      ),
    ]);

    // 1. InstancedGroup3D with 16-color accentPalette.
    final tileMesh = showcaseAssets.buildAccentTileMesh(tileMaterial);
    tileInstances = InstancedGroup3D(mesh: tileMesh, initialCapacity: 1024);
    _rebuildTileInstances(stress: controller.stressInstances);
    staticLayer.world.add(tileInstances);

    // 2. 8 LodMeshComponent crystal towers around the arena.
    final highCrystal = showcaseAssets.buildCrystalTowerLodMesh(
      crystalMaterial,
      segments: 20,
      crystalTint: const ui.Color(0xFF48CAE4),
    );
    final midCrystal = showcaseAssets.buildCrystalTowerLodMesh(
      crystalMaterial,
      segments: 10,
      crystalTint: const ui.Color(0xFF48CAE4),
    );
    final lowCrystal = showcaseAssets.buildCrystalTowerLodMesh(
      crystalMaterial,
      segments: 5,
      crystalTint: const ui.Color(0xFF48CAE4),
    );
    final shadowCrystal = showcaseAssets.buildCrystalTowerLodMesh(
      crystalMaterial,
      segments: 4,
      crystalTint: const ui.Color(0xFFFFFFFF),
    );

    const towerCoords = [
      (2.5, 2.5),
      (11.5, 2.5),
      (2.5, 11.5),
      (11.5, 11.5),
      (7.0, 1.8),
      (7.0, 12.2),
      (1.8, 7.0),
      (12.2, 7.0),
    ];
    for (final (tx, ty) in towerCoords) {
      final tower = LodMeshComponent(
        position: Vector3(tx, ty, 0),
        shadowMesh: shadowCrystal,
        levels: [
          MeshLodLevel(mesh: highCrystal, minScreenHeightRatio: 0.32),
          MeshLodLevel(mesh: midCrystal, minScreenHeightRatio: 0.10),
          MeshLodLevel(mesh: lowCrystal),
        ],
      );
      lodTowers.add(tower);
      staticLayer.world.add(tower);
    }

    // 3. Wind-swaying StylizedMaterial trees (`WindSpace.worldScaled`).
    final treeMesh = showcaseAssets.buildWindTreeMesh(windTreeMaterial);
    final rng = math.Random(42);
    for (var i = 0; i < 16; i++) {
      final angle = (i / 16) * math.pi * 2;
      final radius = 4.8 + (i.isEven ? 0.55 : -0.35);
      final heightScale = 0.8 + rng.nextDouble() * 0.55;
      final tree = MeshComponent(
        mesh: treeMesh,
        position: Vector3(
          boardCells / 2 + math.cos(angle) * radius,
          boardCells / 2 + math.sin(angle) * radius,
          0,
        ),
        scale: Vector3(
          0.9 + rng.nextDouble() * 0.25,
          0.9 + rng.nextDouble() * 0.25,
          heightScale,
        ),
        rotation: Quaternion.axisAngle(
          Vector3(0, 0, 1),
          rng.nextDouble() * math.pi * 2,
        ),
      );
      windTrees.add(tree);
      staticLayer.world.add(tree);
    }

    // 4. Metallic MatCap + SpatialMaterial PBR showcase spheres.
    final goldSphere = SphereMesh(
      radius: 0.42,
      segments: 20,
      material: metalPedestalMaterial,
    );
    final pbrSphere = SphereMesh(
      radius: 0.42,
      segments: 20,
      material: SpatialMaterial(
        albedoColor: const ui.Color(0xFFE07A5F),
        metallic: 0.75,
        roughness: 0.25,
      )..renderState = const RenderState(cullMode: CullMode.backFace),
    );
    staticLayer.world.addAll([
      MeshComponent(
        mesh: goldSphere,
        position: Vector3(5.2, 5.2, 0.45),
        color: const ui.Color(0xFFFFD166),
      ),
      MeshComponent(
        mesh: pbrSphere,
        position: Vector3(8.8, 5.2, 0.45),
      ),
    ]);
  }

  void _rebuildTileInstances({required bool stress}) {
    tileInstances.clear();
    final m = Matrix4.identity();
    const paletteLen = 16;
    if (!stress) {
      // 12x12 courtyard grid (144 instances in 1 draw call).
      for (var ix = 0; ix < 12; ix++) {
        for (var iy = 0; iy < 12; iy++) {
          final cx = 1.5 + ix;
          final cy = 1.5 + iy;
          final dist = math.sqrt(
            (cx - boardCells / 2) * (cx - boardCells / 2) +
                (cy - boardCells / 2) * (cy - boardCells / 2),
          );
          final zScale = dist < 2.2 ? 0.28 : (0.45 + 0.35 * ((ix + iy) % 3));
          m
            ..setIdentity()
            ..setTranslationRaw(cx, cy, 0)
            ..scaleByDouble(0.85, 0.85, zScale, 1);
          final paletteIdx = (ix * 3 + iy * 5) % paletteLen;
          tileInstances.addInstance(
            transform: m,
            color: dist < 2.2
                ? const ui.Color(0xFFCBD5E1)
                : const ui.Color(0xFFE2E8F0),
            instanceData: Vector4(
              (ix + iy) % 7 == 0 ? 0.45 : 0.0,
              0.0,
              0.0,
              StylizedMaterial.packAccentAndFade(paletteIdx),
            ),
          );
        }
      }
    } else {
      // 32x32 dense stress lattice (1,024 instances in 1 draw call!).
      for (var ix = 0; ix < 32; ix++) {
        for (var iy = 0; iy < 32; iy++) {
          final cx = 0.4 + ix * (boardCells - 0.8) / 31;
          final cy = 0.4 + iy * (boardCells - 0.8) / 31;
          final zScale = 0.35 + 0.55 * ((ix * 7 + iy * 3) % 5) / 4;
          m
            ..setIdentity()
            ..setTranslationRaw(cx, cy, 0)
            ..scaleByDouble(0.38, 0.38, zScale, 1);
          final paletteIdx = (ix + iy) % paletteLen;
          tileInstances.addInstance(
            transform: m,
            color: const ui.Color(0xFFE2E8F0),
            instanceData: Vector4(
              (ix * iy) % 11 == 0 ? 0.6 : 0.0,
              0.0,
              0.0,
              StylizedMaterial.packAccentAndFade(paletteIdx),
            ),
          );
        }
      }
    }
    _highlightedInstance = null;
  }

  void _populateDynamicLayer() {
    dynamicLayer.world.addAll([
      LightComponent.hemisphere(
        skyColor: const ui.Color(0xFFB8D4F8),
        groundColor: const ui.Color(0xFF5D6B4D),
        intensity: 0.58,
        up: Vector3(0, 0, 1),
      ),
      LightComponent.directional(
        direction: Vector3(-0.48, -0.62, -0.92),
        color: const ui.Color(0xFFFFF4DC),
        intensity: 0.82,
        shadows: _dynamicShadows,
      ),
    ]);

    // 1. Procedural skinned ModelComponent + skinned Outline + BoneSocket3D.
    final models = showcaseAssets.buildArticulatedModels(
      bodyMaterial: automatonMaterial,
      outlineMaterial: skinnedOutlineMaterial,
    );
    final centerPos = Vector3(boardCells / 2, boardCells / 2, 0.18);
    final socketOrb = MeshComponent(
      mesh: SphereMesh(
        radius: 0.16,
        segments: 12,
        material: UnlitMaterial(albedoColor: const ui.Color(0xFF90F6FF))
          ..renderState = RenderState.opaque,
      ),
      castsShadows: false,
    );
    armTipSocket = BoneSocket3D.byName(
      'ArmTip',
      children: [socketOrb],
    );
    automaton = ModelComponent(
      model: models.shaded,
      position: centerPos.clone(),
      children: [armTipSocket],
    )..playAnimationByName('Idle');

    automatonOutline = ModelComponent(
      model: models.outlined,
      position: centerPos.clone(),
      castsShadows: false,
    )..playAnimationByName('Idle');

    socketPointLight = LightComponent.point(
      color: const ui.Color(0xFF38BDF8),
      intensity: 3.5,
      range: 4.5,
    );
    socketRibbon = RibbonTrail3D(
      target: armTipSocket,
      lifetime: 0.55,
      width: 0.22,
      minVertexDistance: 0.03,
      color: const ui.Color(0xFF38BDF8),
    );

    // 2. Orbiting sentinel with screen-space OutlineMaterial + RibbonTrail3D.
    final sentinelPos = Vector3(boardCells / 2 + 2.6, boardCells / 2, 1.35);
    orbitingSentinel = MeshComponent(
      mesh: SphereMesh(
        radius: 0.32,
        segments: 18,
        material: UnlitMaterial(albedoColor: const ui.Color(0xFFFF5D8F))
          ..renderState = RenderState.opaque,
      ),
      position: sentinelPos.clone(),
    );
    orbitingSentinelOutline = MeshComponent(
      mesh: SphereMesh(
        radius: 0.32,
        segments: 18,
        material: staticOutlineMaterial,
      ),
      position: sentinelPos.clone(),
      castsShadows: false,
    );
    sentinelRibbon = RibbonTrail3D(
      target: orbitingSentinel,
      lifetime: 0.75,
      width: 0.28,
      color: const ui.Color(0xFFFF5D8F),
    );

    // 3. DecalBatch3D (procedural rings + 2x2 UV atlas decals).
    ringDecals = DecalBatch3D(
      material: DecalMaterial(
        innerRadius: 0.68,
        softness: 0.10,
        depthBias: 0.001,
      ),
    );
    atlasDecals = DecalBatch3D(
      material: DecalMaterial(
        texture: showcaseAssets.decalAtlas,
        softness: 0.05,
        depthBias: 0.0012,
      ),
    );
    _populateBaseDecals();

    // 4. StrokeBatch3D (3D energy arcs between towers + hit normal ray).
    energyStrokes = StrokeBatch3D(
      material: RibbonMaterial3D(depthBias: 0.0005),
    );
    _rebuildEnergyStrokes(0);

    // 5. ParticleSystem3D (sparks with ground bounce, curl smoke, mesh coins).
    sparkParticles = ParticleSystem3D(
      capacity: 384,
      material: ParticleMaterial(
        billboard: ParticleBillboard.velocity,
        renderState: RenderState.additive,
      ),
      emitters: [
        ParticleEmitter3D(
          rate: 55,
          shape: const ConeEmitterShape3D(angle: 0.45),
          speed: (2.2, 4.4),
          lifespan: (0.55, 1.0),
          size: (0.06, 0.11),
          colors: const [
            ui.Color(0xFFFFD166),
            ui.Color(0xFFFF7B54),
            ui.Color(0xFF72EFDD),
          ],
        ),
      ],
      position: Vector3(5.2, 8.8, 0.35),
      rotation: Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2),
      gravity: Vector3(0, 0, -7.5),
      turbulence: const ParticleTurbulence3D(strength: 1.4, frequency: 0.9),
      ground: ParticleGround3D(
        normal: Vector3(0, 0, 1),
        height: 0.12,
        restitution: 0.45,
      ),
      velocityStretch: 0.06,
      opacityOverLife: ParticleCurve(1, 0),
    );

    smokeParticles =
        ParticlePresets3D.smoke(
            up: Vector3(0, 0, 1),
            scale: 0.75,
            rate: 10,
          )
          ..position = Vector3(8.8, 8.8, 0.35)
          ..prewarm(2.0);

    final coinMesh = CylinderMesh(
      radius: 0.5,
      height: 0.16,
      segments: 10,
      material: metalPedestalMaterial,
    );
    coinMeshParticles = ParticleSystem3D(
      capacity: 96,
      mesh: coinMesh,
      emitters: [
        ParticleEmitter3D(
          shape: const ConeEmitterShape3D(angle: 0.5),
          speed: (2.6, 4.2),
          lifespan: (1.4, 2.0),
          size: (0.16, 0.22),
          rotation: (0, math.pi * 2),
          spin: (-12, 12),
          colors: const [ui.Color(0xFFFFD166), ui.Color(0xFFFFE699)],
        ),
      ],
      position: Vector3(boardCells / 2, 4.2, 0.3),
      rotation: Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2),
      gravity: Vector3(0, 0, -9.2),
      ground: ParticleGround3D(
        normal: Vector3(0, 0, 1),
        height: 0.14,
        restitution: 0.42,
        settleRotation: true,
      ),
    )..burst(14);

    dynamicLayer.world.addAll([
      socketPointLight,
      automaton,
      automatonOutline,
      orbitingSentinel,
      orbitingSentinelOutline,
      ringDecals,
      atlasDecals,
      energyStrokes,
      socketRibbon,
      sentinelRibbon,
      sparkParticles,
      smokeParticles,
      coinMeshParticles,
    ]);
  }

  void _populateBaseDecals() {
    ringDecals.clear();
    atlasDecals.clear();
    final upZ = Vector3(0, 0, 1);

    ringDecals.addFlatDecal(
      center: Vector3(boardCells / 2, boardCells / 2, 0.02),
      width: 3.4,
      height: 3.4,
      normal: upZ,
      color: const ui.Color(0xCC38BDF8),
    );
    if (_lastHitPoint case final hp?) {
      ringDecals.addFlatDecal(
        center: Vector3(hp.x, hp.y, hp.z + 0.02),
        width: 1.15,
        height: 1.15,
        normal: _lastHitNormal ?? upZ,
        color: const ui.Color(0xFFFFBE0B),
      );
    }

    const atlasRects = [
      ui.Rect.fromLTWH(0.0, 0.0, 0.5, 0.5),
      ui.Rect.fromLTWH(0.5, 0.0, 0.5, 0.5),
      ui.Rect.fromLTWH(0.0, 0.5, 0.5, 0.5),
      ui.Rect.fromLTWH(0.5, 0.5, 0.5, 0.5),
    ];
    const runePositions = [
      (4.2, 4.2, ui.Color(0xD972EFDD)),
      (9.8, 4.2, ui.Color(0xD9FF70A6)),
      (4.2, 9.8, ui.Color(0xD9FFD166)),
      (9.8, 9.8, ui.Color(0xD9A855F7)),
    ];
    for (var i = 0; i < runePositions.length; i++) {
      final (rx, ry, rc) = runePositions[i];
      atlasDecals.addFlatDecal(
        center: Vector3(rx, ry, 0.025),
        width: 1.35,
        height: 1.35,
        angle: _time * 0.4 * (i.isEven ? 1 : -1),
        normal: upZ,
        color: rc,
        uvRect: atlasRects[i],
      );
    }
  }

  void _rebuildEnergyStrokes(double t) {
    energyStrokes.clear();
    if (!controller.ribbonsAndDecals) {
      return;
    }

    energyStrokes.beginStroke(color: const ui.Color(0xFF48CAE4));
    const arcSteps = 14;
    for (var i = 0; i <= arcSteps; i++) {
      final u = i / arcSteps;
      final x = 2.5 + (11.5 - 2.5) * u;
      final y = 2.5 + math.sin(u * math.pi) * 1.4;
      final z =
          2.15 +
          math.sin(u * math.pi) * 1.65 +
          0.12 * math.sin(t * 4.0 + u * 8.0);
      final pulse = 0.65 + 0.35 * math.sin(u * math.pi);
      energyStrokes.addPoint(
        x,
        y,
        z,
        halfWidth: 0.09 * pulse,
        opacity: 0.85 * pulse,
      );
    }
    energyStrokes.endStroke();

    if (_lastHitPoint != null && _lastHitNormal != null) {
      final p0 = _lastHitPoint!;
      final p1 = p0 + _lastHitNormal! * 1.35;
      energyStrokes.addPolyline(
        [p0, p1],
        width: 0.14,
        endWidth: 0.02,
        color: const ui.Color(0xFFFFBE0B),
        endOpacity: 0.25,
      );
    }
  }

  /// Applies all toggle states from [controller] to the live 3D layers.
  void syncControllerState() {
    if (!isLoaded) {
      return;
    }
    final msaa = controller.msaa4x ? Msaa.sample4 : Msaa.off;
    staticLayer
      ..msaa = msaa
      ..cacheMode = controller.retainedStaticLayer
          ? Scene3DCacheMode.retained
          : Scene3DCacheMode.none;
    dynamicLayer
      ..msaa = msaa
      ..bloom = controller.bloom ? _bloomSettings : null;

    _staticShadows.cacheWhenStatic = controller.staticShadowCache;
    if (controller.sharedShadowGroup) {
      staticLayer.world.shadowGroup = shadowGroup;
      dynamicLayer.world.shadowGroup = shadowGroup;
    } else {
      staticLayer.world.shadowGroup = null;
      dynamicLayer.world.shadowGroup = null;
    }

    dynamicLayer.world.fog = controller.fog ? _fogSettings : null;

    final outlineScale = controller.outlines ? 1.0 : 0.0;
    automatonOutline.scale.setValues(outlineScale, outlineScale, outlineScale);
    orbitingSentinelOutline.scale.setValues(
      outlineScale,
      outlineScale,
      outlineScale,
    );

    sparkParticles.paused = !controller.particles;
    smokeParticles.paused = !controller.particles;
    coinMeshParticles.paused = !controller.particles;

    socketRibbon.emitting = controller.ribbonsAndDecals;
    sentinelRibbon.emitting = controller.ribbonsAndDecals;
    if (!controller.ribbonsAndDecals) {
      socketRibbon.reset();
      sentinelRibbon.reset();
      ringDecals.clear();
      atlasDecals.clear();
      energyStrokes.clear();
    } else {
      _populateBaseDecals();
      _rebuildEnergyStrokes(_time);
    }

    final expectedInstances = controller.stressInstances ? 1024 : 144;
    if (tileInstances.length != expectedInstances) {
      _rebuildTileInstances(stress: controller.stressInstances);
    }

    staticLayer.markDirty();
    controller.notifyChanged();
  }

  /// Crossfades the articulated automaton to the next animation clip (`Idle` ->
  /// `Swing` -> `Spin`), supporting custom [mode] and [duration].
  void crossFadeNextClip({
    AnimationPlayMode mode = AnimationPlayMode.loop,
    double duration = 0.30,
  }) {
    _clipIndex = (_clipIndex + 1) % animationClips.length;
    final clipName = animationClips[_clipIndex];
    automaton.crossFadeToByName(clipName, duration: duration, mode: mode);
    automatonOutline.crossFadeToByName(
      clipName,
      duration: duration,
      mode: mode,
    );
    controller
      ..activeClip = clipName
      ..notifyChanged();
  }

  /// Renders an offscreen `128x128` close-up perspective snapshot of the
  /// dynamic world via `World3D.renderToImage` and stores it in
  /// [ShowcaseController.snapshotImage].
  ui.Image captureOffscreenSnapshot({ui.Size size = const ui.Size(128, 128)}) {
    final view = Matrix4.identity()
      ..setAsViewMatrix(
        Vector3(boardCells / 2 + 4.0, boardCells / 2 + 4.0, 3.2),
        Vector3(boardCells / 2, boardCells / 2, 1.0),
        Vector3(0, 0, 1),
      );
    final proj = Matrix4.identity()
      ..setAsPerspective(48, size.width / size.height, 0.2, 60);
    final img = dynamicLayer.world.renderToImage(
      size,
      view: view,
      projection: proj,
      clearValue: const ui.Color(0xFF162033),
    );
    controller.snapshotImage?.dispose();
    controller
      ..snapshotImage = img
      ..notifyChanged();
    return img;
  }

  /// Performs a triangle-accurate BVH raycast at [localPoint] (in layer local
  /// coordinates), highlighting any hit instance and placing a 3D hit decal +
  /// normal indicator.
  RayHit3D? pickAtLocalPoint(Vector2 localPoint) {
    final dynHit = dynamicLayer.raycastLocal(localPoint);
    final statHit = staticLayer.raycastLocal(localPoint);
    final RayHit3D? hit;
    if (dynHit != null && statHit != null) {
      hit = dynHit.distance <= statHit.distance ? dynHit : statHit;
    } else {
      hit = dynHit ?? statHit;
    }

    if (_highlightedInstance case final prev?
        when prev < tileInstances.length) {
      final paletteIdx = prev % ShowcaseAssets.accentPalette.length;
      tileInstances.setInstance(
        prev,
        instanceData: Vector4(
          0,
          0,
          0,
          StylizedMaterial.packAccentAndFade(paletteIdx),
        ),
      );
      _highlightedInstance = null;
    }

    if (hit == null) {
      _lastHitPoint = null;
      _lastHitNormal = null;
      controller.lastHitSummary = 'Miss (sky / background)';
    } else {
      _lastHitPoint = hit.worldPoint.clone();
      _lastHitNormal = hit.worldNormal.clone();
      final compName = hit.object.runtimeType.toString();
      final isTileInst = identical(hit.object, tileInstances);
      final instSuffix = isTileInst ? ' #${hit.surfaceIndex}' : '';
      controller.lastHitSummary =
          'Hit $compName$instSuffix (tri=${hit.triangleIndex}, '
          'd=${hit.distance.toStringAsFixed(1)})';

      if (isTileInst && hit.surfaceIndex < tileInstances.length) {
        final idx = hit.surfaceIndex;
        _highlightedInstance = idx;
        final paletteIdx = idx % ShowcaseAssets.accentPalette.length;
        tileInstances.setInstance(
          idx,
          instanceData: Vector4(
            0.85,
            0.38,
            0,
            StylizedMaterial.packAccentAndFade(paletteIdx),
          ),
        );
      }
    }

    if (controller.ribbonsAndDecals) {
      _populateBaseDecals();
      _rebuildEnergyStrokes(_time);
    }
    controller.notifyChanged();
    return hit;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (dt <= 0) {
      return;
    }
    _time += dt;

    final dtMs = dt * 1000.0;
    _frameDurationsMs[_frameRingCursor] = dtMs;
    _frameRingCursor = (_frameRingCursor + 1) % _frameDurationsMs.length;
    if (_frameSamples < _frameDurationsMs.length) {
      _frameSamples++;
    }

    if (controller.wind) {
      windTreeMaterial.windTime = _time;
      staticLayer.markDirty();
    }

    if (controller.autoOrbitCamera) {
      final center = staticLayer.scenePointToLocal(
        Vector3(boardCells / 2, boardCells / 2, 0.5),
      );
      camera.viewfinder
        ..position =
            center +
            Vector2(math.sin(_time * 0.65) * 55, math.cos(_time * 0.5) * 32)
        ..zoom = 1.0 + 0.14 * math.sin(_time * 0.45);
    }

    final orbAngle = _time * 1.45;
    final sx = boardCells / 2 + math.cos(orbAngle) * 2.75;
    final sy = boardCells / 2 + math.sin(orbAngle) * 2.75;
    final sz = 1.25 + 0.35 * math.sin(_time * 2.6);
    orbitingSentinel.position.setValues(sx, sy, sz);
    orbitingSentinelOutline.position.setValues(sx, sy, sz);

    final tip = armTipSocket.worldTransformMatrix.storage;
    socketPointLight.position.setValues(tip[12], tip[13], tip[14]);

    if (controller.particles) {
      _burstTimer += dt;
      if (_burstTimer >= 2.2) {
        _burstTimer = 0;
        coinMeshParticles.burst(12);
      }
    }

    if (controller.ribbonsAndDecals) {
      _rebuildEnergyStrokes(_time);
    }

    _hudRefreshTimer += dt;
    if (_hudRefreshTimer >= 0.25) {
      _hudRefreshTimer = 0;
      _publishTelemetry();
    }
  }

  void _publishTelemetry() {
    if (_frameSamples == 0) {
      return;
    }
    final sorted = _frameDurationsMs.sublist(0, _frameSamples)..sort();
    final p50 = sorted[(sorted.length * 0.50).floor()];
    final p95Index = math.min(
      sorted.length - 1,
      (sorted.length * 0.95).floor(),
    );
    final p95 = sorted[p95Index];
    final mean = sorted.fold<double>(0, (a, b) => a + b) / sorted.length;
    controller
      ..fps = mean > 0 ? 1000.0 / mean : 60.0
      ..frameMsP50 = p50
      ..frameMsP95 = p95
      ..notifyChanged();
  }

  @override
  void onTapUp(TapUpEvent event) {
    final local = staticLayer.absoluteToLocal(
      camera.globalToLocal(event.canvasPosition),
    );
    pickAtLocalPoint(local);
  }

  @override
  void onDragUpdate(DragUpdateEvent event) {
    super.onDragUpdate(event);
    if (controller.autoOrbitCamera || isScaling) {
      return;
    }
    camera.viewfinder.position -= event.localDelta / camera.viewfinder.zoom;
  }

  @override
  void onScroll(ScrollEvent event) {
    final factor = math.exp(-event.scrollDelta.y * 0.002);
    camera.viewfinder.zoom = (camera.viewfinder.zoom * factor).clamp(
      minZoom,
      maxZoom,
    );
  }

  @override
  void onScaleStart(ScaleStartEvent event) {
    super.onScaleStart(event);
    _startZoom = camera.viewfinder.zoom;
  }

  @override
  void onScaleUpdate(ScaleUpdateEvent event) {
    camera.viewfinder.zoom = (_startZoom * event.scale).clamp(minZoom, maxZoom);
  }
}
