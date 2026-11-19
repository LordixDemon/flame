import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame_3d/audio.dart';
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/cinematics.dart';
import 'package:flame_3d/collisions.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/debug.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/input.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/navigation.dart';
import 'package:flame_3d/parser.dart';
import 'package:flame_3d/physics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d/scene.dart';
import 'package:flame_3d/ui3d.dart';
import 'package:flame_3d/world_scale.dart';
import 'package:flame_3d_example/showcase/showcase_game.dart';
import 'package:flame_3d_example/showcase/showcase_variations.dart';
import 'package:flutter/painting.dart' show HSVColor;

class _ShowcaseVoiceBackend3D() implements AudioVoiceBackend3D {
  int _nextHandle = 1;
  int startedCount = 0;
  int updatedCount = 0;
  int stoppedCount = 0;
  final Map<int, AudioVoiceParams3D> activeVoices = {};

  @override
  int startVoice(SpatialAudioEmitter3D emitter, AudioVoiceParams3D params) {
    final id = _nextHandle++;
    startedCount++;
    activeVoices[id] = params;
    return id;
  }

  @override
  void updateVoice(
    int voiceHandle,
    SpatialAudioEmitter3D emitter,
    AudioVoiceParams3D params,
  ) {
    updatedCount++;
    activeVoices[voiceHandle] = params;
  }

  @override
  void stopVoice(int voiceHandle, SpatialAudioEmitter3D emitter) {
    stoppedCount++;
    activeVoices.remove(voiceHandle);
  }
}

/// Builders, per-frame simulation drivers, and automated GPU/subsystem checks
/// (`49..64`) for Feature Labs `17..20` of the `package:flame_3d` showcase.
class ShowcaseV4Builders() {
  // Lab 17 live state (`HDR, IBL, 4-CSM & OIT`):
  ReflectionProbeVolume3D? localReflectionProbe;
  LightProbeGrid3D? sh9LightProbeGrid;
  SpatialMaterial? clearcoatSphereMat;
  Surface? clearcoatTangentSurface;
  SpatialMaterial? glassRefractMat;
  SpatialMaterial? anisoSphereMat;
  Texture? ktx2PedestalTexture;
  LightComponent? multiShadowSpotLight;
  LightComponent? multiShadowPointLight;
  UnlitMaterial? stencilMaskMat;
  UnlitMaterial? stencilInnerMat;
  MeshComponent? stencilInnerGem;
  final List<MeshComponent> wboitGlassPanes = [];
  RenderGraph3D? labRenderGraph;
  CompiledRenderGraph3D? compiledLabRenderGraph;

  // Lab 18 live state (`Clustered 128+, Occlusion & CDLOD`):
  LightClusterGrid3D? clusterGrid;
  final Matrix4 clusterViewMatrix = Matrix4.identity();
  final Matrix4 clusterProjMatrix = Matrix4.identity();
  final Matrix4 occluderViewProj = Matrix4.identity();
  OcclusionCuller3D? occlusionCuller;
  MeshComponent? frontCrateMesh;
  MeshComponent? occludedRearCrateMesh;
  PortalOcclusionGraph3D? portalGraph;
  OcclusionPortal3D? vaultDoorPortal;
  StaticMeshBatcher3D? staticBatcher;
  FloatingOriginController3D? floatingOrigin;
  FloatingOriginTransform3D? satelliteOriginTransform;
  MeshComponent? satelliteBeaconMesh;
  ChunkedTerrain3D? cdlodTerrain;
  FoliageSystem3D? foliageSystem;
  FoliageInteractor3D? foliageInteractor;
  MeshComponent? foliageTramplerOrb;
  VolumeDecalBatch3D? volumeDecalBatch;

  // Lab 19 live state (`CCD, Compound, Cloth, Recast & Rollback`):
  CollisionSystem3D? ccdCollisionSystem;
  PhysicsWorld3D? ccdPhysicsWorld;
  RigidBody3D? ccdProjectileBody;
  RigidBody3D? thinWallBody;
  double _ccdFireTimer = 0.0;
  CompoundShape3D? compoundArchShape;
  RigidBody3D? compoundArchBody;

  PhysicsWorld3D? yUpSubPhysicsWorld;
  HeightfieldShape3D? heightfieldShape;
  RigidBody3D? heightfieldBallBody;
  MeshComponent? heightfieldBallMesh;
  FixedJoint3D? fixedJoint;
  SliderJoint3D? sliderJoint;
  ConeTwistJoint3D? coneTwistJoint;
  Generic6DofJoint3D? generic6DofJoint;
  BuoyancyVolume3D? buoyancyVolume;
  RigidBody3D? buoyancyCrateBody;
  MeshComponent? buoyancyCrateMesh;
  RaycastVehicle3D? raycastVehicle;
  MeshComponent? vehicleChassisMesh;
  XpbdCloth3D? xpbdCloth;
  XpbdRope3D? xpbdRope;
  XpbdSphereCollider3D? clothObstacleSphere;

  NavMesh3D? recastNavMesh;
  NavMeshObstacle3D? gateNavObstacle;
  OffMeshLink3D? jumpOffMeshLink;
  PhysicsSnapshotRingBuffer3D? snapshotRingBuffer;

  // Lab 20 live state (`AnimGraph, Retarget, Ragdoll, 3D UI & Gizmo`):
  ModelComponent? animGraphActor;
  AnimationStateMachine3D? animStateMachine;
  HumanoidProfile3D? sourceHumanoidProfile;
  HumanoidProfile3D? shortHumanoidProfile;
  HumanoidProfile3D? tallHumanoidProfile;
  ModelAnimation? sourceWalkClip;
  ModelAnimation? shortRetargetedClip;
  ModelAnimation? tallRetargetedClip;
  ModelComponent? shortHumanoidActor;
  ModelComponent? tallHumanoidActor;

  ModelComponent? fabrikTentacleActor;
  FabrikIkConstraint3D? fabrikConstraint;
  MeshComponent? fabrikTargetOrb;
  ModelComponent? footIkActor;
  FootPlacementIk3D? footPlacementIk;
  PhysicsWorld3D? ragdollPhysicsWorld;
  ModelComponent? ragdollActor;
  RagdollController3D? ragdollController;
  double _ragdollCycleTimer = 0.0;

  Group3D? toggleSubtreeGroup;
  Component3D? clonedCrystalGroup;
  PrefabRegistry3D? prefabRegistry;
  SceneSerializer3D? sceneSerializer;
  Uint8List? cachedBinarySceneBytes;
  GpuResourceManager3D? gpuResourceManager;
  GpuDeviceLossRecovery3D? deviceLossRecovery;
  MsdfTextBatch3D? msdfTextBatch;
  WidgetSurface3D? diegeticControlSurface;
  SurfaceButton2D? surfaceToggleButton;
  SurfaceSlider2D? surfaceSpeedSlider;
  int panelButtonClicks = 0;

  LoadedScene3D? meshoptLoadedScene;
  WorldChunkStreamer3D? chunkStreamer;
  _ShowcaseVoiceBackend3D? _audioBackend;
  SpatialAudioMixer3D? spatialAudioMixer;
  final List<SpatialAudioEmitter3D> pooledEmitters = [];
  AudioZone3D? cathedralAudioZone;
  TransformGizmo3D? transformGizmo;
  SceneInspector3D? sceneInspector;
  MeshComponent? gizmoTargetCube;
  DebugRenderer3D? gizmoDebugRenderer;

  void reset() {
    localReflectionProbe = null;
    sh9LightProbeGrid = null;
    clearcoatSphereMat = null;
    clearcoatTangentSurface = null;
    glassRefractMat = null;
    anisoSphereMat = null;
    ktx2PedestalTexture?.dispose();
    ktx2PedestalTexture = null;
    multiShadowSpotLight = null;
    multiShadowPointLight = null;
    stencilMaskMat = null;
    stencilInnerMat = null;
    stencilInnerGem = null;
    wboitGlassPanes.clear();
    labRenderGraph = null;
    compiledLabRenderGraph = null;

    clusterGrid = null;
    occlusionCuller = null;
    frontCrateMesh = null;
    occludedRearCrateMesh = null;
    portalGraph = null;
    vaultDoorPortal = null;
    staticBatcher = null;
    floatingOrigin?.removeFromParent();
    floatingOrigin = null;
    satelliteOriginTransform = null;
    satelliteBeaconMesh = null;
    cdlodTerrain = null;
    foliageSystem = null;
    foliageInteractor = null;
    foliageTramplerOrb = null;
    volumeDecalBatch?.clear();
    volumeDecalBatch = null;

    ccdCollisionSystem?.removeFromParent();
    ccdCollisionSystem = null;
    ccdPhysicsWorld?.removeFromParent();
    ccdPhysicsWorld = null;
    ccdProjectileBody = null;
    thinWallBody = null;
    _ccdFireTimer = 0.0;
    compoundArchShape = null;
    compoundArchBody = null;

    yUpSubPhysicsWorld = null;
    heightfieldShape = null;
    heightfieldBallBody = null;
    heightfieldBallMesh = null;
    fixedJoint = null;
    sliderJoint = null;
    coneTwistJoint = null;
    generic6DofJoint = null;
    buoyancyVolume = null;
    buoyancyCrateBody = null;
    buoyancyCrateMesh = null;
    raycastVehicle = null;
    vehicleChassisMesh = null;
    xpbdCloth = null;
    xpbdRope = null;
    clothObstacleSphere = null;

    recastNavMesh = null;
    gateNavObstacle = null;
    jumpOffMeshLink = null;
    snapshotRingBuffer?.clear();
    snapshotRingBuffer = null;

    animGraphActor = null;
    animStateMachine = null;
    sourceHumanoidProfile = null;
    shortHumanoidProfile = null;
    tallHumanoidProfile = null;
    sourceWalkClip = null;
    shortRetargetedClip = null;
    tallRetargetedClip = null;
    shortHumanoidActor = null;
    tallHumanoidActor = null;

    fabrikTentacleActor = null;
    fabrikConstraint = null;
    fabrikTargetOrb = null;
    footIkActor = null;
    footPlacementIk = null;
    ragdollController?.dispose();
    ragdollController = null;
    ragdollPhysicsWorld?.removeFromParent();
    ragdollPhysicsWorld = null;
    ragdollActor = null;
    _ragdollCycleTimer = 0.0;

    toggleSubtreeGroup = null;
    clonedCrystalGroup = null;
    prefabRegistry = null;
    sceneSerializer = null;
    cachedBinarySceneBytes = null;
    gpuResourceManager = null;
    deviceLossRecovery = null;
    msdfTextBatch?.clear();
    msdfTextBatch = null;
    diegeticControlSurface = null;
    surfaceToggleButton = null;
    surfaceSpeedSlider = null;
    panelButtonClicks = 0;

    chunkStreamer?.removeFromParent();
    chunkStreamer = null;
    spatialAudioMixer?.removeFromParent();
    spatialAudioMixer = null;
    _audioBackend = null;
    pooledEmitters.clear();
    cathedralAudioZone = null;
    transformGizmo = null;
    sceneInspector = null;
    gizmoTargetCube = null;
    gizmoDebugRenderer = null;
  }

  Future<void> preloadAssets() async {
    if (meshoptLoadedScene == null) {
      final bytes = buildMeshoptCompressedGlbBytes();
      meshoptLoadedScene = await SceneLoader3D.loadGlbBytes(bytes);
    }
  }

  // ===========================================================================
  // Lab 17 — HDR, IBL, 4-CSM & OIT
  // ===========================================================================

  void buildHdrIblShadowAtlasAndOitLab({
    required ShowcaseVariationRig rig,
    required World3D dynamicWorld,
    required PostProcessSettings postProcess,
    required ShadowSettings dynamicShadows,
    required ShowcaseController controller,
  }) {
    final upright = Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2);

    // 1. Float16 HDR + Warm Cinematic 3D LUT + WBOIT + Scene Color Grab-Pass.
    final warmLut = ColorLut3D.warmCinematic();
    controller
      ..hdr = true
      ..wboit = true
      ..csm4Cascades = true
      ..activeColorLut = warmLut;
    dynamicWorld
      ..hdrEnabled = true
      ..oitMode = OitMode3D.weightedBlended
      ..grabSceneColorEnabled = true;
    postProcess.colorLut = warmLut;
    dynamicShadows.cascades = 4;

    // 2. Box-projected local ReflectionProbeVolume3D + 3D SH9 LightProbeGrid3D.
    localReflectionProbe = ReflectionProbeVolume3D(
      probe: rig.v3.skyDomeProbe,
      extents: Vector3(5.6, 5.6, 3.2),
      blendDistance: 1.5,
      position: Vector3(7.0, 7.0, 1.5),
    );
    rig.dynamicExtras.add(localReflectionProbe!);

    // Simultaneous multi-light shadows: 4-CSM Sun + SpotLight + PointLight!
    multiShadowSpotLight = LightComponent.spot(
      position: Vector3(3.4, 9.8, 3.6),
      direction: Vector3(0.65, -0.55, -0.82),
      color: const ui.Color(0xFF38BDF8),
      intensity: 18.0,
      range: 11.5,
      innerConeAngle: 0.24,
      outerConeAngle: 0.56,
      shadows: ShadowSettings(
        resolution: 512,
        depthBias: 0.0025,
      ),
    );
    multiShadowPointLight = LightComponent(
      source: PointLight(
        color: const ui.Color(0xFFFFB703),
        intensity: 14.0,
        range: 9.5,
        shadows: ShadowSettings(
          resolution: 512,
          depthBias: 0.004,
        ),
      ),
      position: Vector3(10.2, 8.8, 2.35),
    );
    rig.dynamicExtras.addAll([multiShadowSpotLight!, multiShadowPointLight!]);

    sh9LightProbeGrid = LightProbeGrid3D.bakeFromLights(
      bounds: Aabb3.minMax(Vector3(0.5, 0.5, -0.2), Vector3(13.5, 13.5, 4.5)),
      resolutionY: 4,
      ambientColor: const ui.Color(0xFF1E3A8A),
      ambientIntensity: 0.22,
      lights: [
        multiShadowSpotLight!.light,
        multiShadowPointLight!.light,
      ],
    );
    dynamicWorld.lightProbeGrid = sh9LightProbeGrid;

    // 3. Ktx2TextureLoader BC1-encoded textured pedestal (`encodeBc1`->`load`).
    final rgba = Uint8List(16 * 16 * 4);
    for (var y = 0; y < 16; y++) {
      for (var x = 0; x < 16; x++) {
        final o = (y * 16 + x) * 4;
        final checker = ((x >> 2) + (y >> 2)).isEven;
        rgba[o] = checker ? 218 : 74;
        rgba[o + 1] = checker ? 196 : 92;
        rgba[o + 2] = checker ? 158 : 118;
        rgba[o + 3] = 255;
      }
    }
    final ktx2Bytes = Ktx2TextureLoader.encodeBc1(rgba, width: 16, height: 16);
    ktx2PedestalTexture = Ktx2TextureLoader.load(
      ktx2Bytes,
      sampler: TextureSampler.anisotropic16x,
    );
    final pedestalMat = SpatialMaterial(
      albedoTexture: ktx2PedestalTexture,
      roughness: 0.36,
      metallic: 0.18,
      environmentProbe: rig.v3.skyDomeProbe,
    )..renderState = const RenderState(cullMode: CullMode.backFace);
    final pedestalMesh = CuboidMesh(
      size: Vector3(3.6, 2.2, 0.42),
      material: pedestalMat,
    );
    for (final s in pedestalMesh.surfaces) {
      s.computeTangents();
    }
    rig.dynamicExtras.add(
      MeshComponent(
        mesh: pedestalMesh,
        position: Vector3(7.0, 7.2, 0.21),
      ),
    );

    // 4. PBR Clearcoat, Refractive Transmission/IOR & Anisotropic 16x spheres.
    clearcoatSphereMat = SpatialMaterial(
      albedoColor: const ui.Color(0xFFDC2626),
      metallic: 0.72,
      roughness: 0.32,
      clearcoat: 1.0,
      clearcoatRoughness: 0.08,
      environmentProbe: rig.v3.skyDomeProbe,
    )..renderState = const RenderState(cullMode: CullMode.backFace);
    final clearcoatMesh = SphereMesh(
      radius: 0.56,
      segments: 24,
      material: clearcoatSphereMat,
    );
    for (final s in clearcoatMesh.surfaces) {
      s.computeTangents();
      clearcoatTangentSurface ??= s;
    }

    glassRefractMat = SpatialMaterial(
      albedoColor: const ui.Color(0xFFE0F2FE),
      roughness: 0.06,
      clearcoat: 0.55,
      clearcoatRoughness: 0.05,
      transmission: 0.82,
      ior: 1.52,
      environmentProbe: rig.v3.skyDomeProbe,
    )..renderState = const RenderState(cullMode: CullMode.backFace);
    final refractMesh = SphereMesh(
      radius: 0.58,
      segments: 24,
      material: glassRefractMat,
    );
    for (final s in refractMesh.surfaces) {
      s.computeTangents();
    }

    anisoSphereMat = SpatialMaterial(
      albedoTexture: ktx2PedestalTexture,
      albedoColor: const ui.Color(0xFFFDE68A),
      metallic: 0.85,
      roughness: 0.24,
      clearcoat: 0.65,
      clearcoatRoughness: 0.12,
      environmentProbe: rig.v3.skyDomeProbe,
    )..renderState = const RenderState(cullMode: CullMode.backFace);
    final anisoMesh = SphereMesh(
      radius: 0.54,
      segments: 22,
      material: anisoSphereMat,
    );
    for (final s in anisoMesh.surfaces) {
      s.computeTangents();
    }

    rig.dynamicExtras.addAll([
      MeshComponent(mesh: clearcoatMesh, position: Vector3(5.75, 7.2, 1.02)),
      MeshComponent(mesh: refractMesh, position: Vector3(7.0, 7.2, 1.06)),
      MeshComponent(mesh: anisoMesh, position: Vector3(8.25, 7.2, 1.0)),
    ]);

    // 5. Stencil-masked portal frame (`writeReference(1)` + `testEqual(1)`).
    stencilMaskMat =
        UnlitMaterial(
            albedoColor: const ui.Color(0xFF0F172A),
          )
          ..renderState = const RenderState(
            depthWrite: false,
            stencil: StencilState.writeReference(1),
          );
    stencilInnerMat =
        UnlitMaterial(
            albedoColor: const ui.Color(0xFF22D3EE),
          )
          ..renderState = const RenderState(
            cullMode: CullMode.backFace,
            stencil: StencilState.testEqual(1),
          );
    final portalWindow = MeshComponent(
      mesh: PlaneMesh(size: Vector2(1.75, 2.15), material: stencilMaskMat),
      position: Vector3(10.6, 4.8, 1.25),
      rotation:
          Quaternion.axisAngle(Vector3(0, 0, 1), -math.pi * 0.2) * upright,
      castsShadows: false,
    );
    stencilInnerGem = MeshComponent(
      mesh: TorusMesh(
        majorRadius: 0.48,
        minorRadius: 0.15,
        material: stencilInnerMat,
      ),
      position: Vector3(10.9, 5.1, 1.25),
      castsShadows: false,
    );
    rig.dynamicExtras.addAll([portalWindow, stencilInnerGem!]);

    // 6. Intersecting translucent glass panes rendered order-independently via
    //    `OitMode3D.weightedBlended`!
    const paneColors = [
      ui.Color(0x8806B6D4),
      ui.Color(0x88EC4899),
      ui.Color(0x88F59E0B),
    ];
    for (var i = 0; i < paneColors.length; i++) {
      final paneMat = SpatialMaterial(
        albedoColor: paneColors[i],
        roughness: 0.14,
        metallic: 0.08,
        doubleSided: true,
      )..renderState = RenderState.alphaBlend;
      final pane = MeshComponent(
        mesh: CuboidMesh(
          size: Vector3(1.95, 0.06, 1.65),
          material: paneMat,
        ),
        position: Vector3(3.8, 4.9, 1.05),
        rotation: Quaternion.axisAngle(
          Vector3(0, 0, 1),
          i * (math.pi / 3.0) + 0.25,
        ),
        castsShadows: false,
      );
      wboitGlassPanes.add(pane);
      rig.dynamicExtras.add(pane);
    }

    // 7. Live compiled `RenderGraph3D` DAG instance with transient aliasing!
    final graph = RenderGraph3D();
    final hdrColor = graph.createTexture(
      'hdr_color',
      const RenderGraphTextureDesc3D(
        width: 256,
        height: 256,
        format: GpuPixelFormat.rgbaFloat16,
      ),
    );
    final depthPre = graph.createTexture(
      'depth_normal',
      const RenderGraphTextureDesc3D(width: 128, height: 128),
    );
    final litTemp = graph.createTexture(
      'lit_temp',
      const RenderGraphTextureDesc3D(
        width: 256,
        height: 256,
        format: GpuPixelFormat.rgbaFloat16,
      ),
    );
    final ldrOut = graph.createTexture(
      'ldr_out',
      const RenderGraphTextureDesc3D(width: 256, height: 256),
    );
    graph
      ..addRenderPass(
        name: 'opaque',
        writes: [hdrColor, depthPre],
        execute: (_) {},
      )
      ..addRenderPass(
        name: 'lighting',
        reads: [hdrColor, depthPre],
        writes: [litTemp],
        execute: (_) {},
      )
      ..addRenderPass(
        name: 'post',
        reads: [litTemp],
        writes: [ldrOut],
        hasSideEffects: true,
        execute: (_) {},
      );
    compiledLabRenderGraph = graph.compile();
    labRenderGraph = graph;
  }

  // ===========================================================================
  // Lab 18 — Clustered 128+, Occlusion, Batcher, FloatingOrigin, CDLOD & 10k
  // ===========================================================================

  void buildClusteredOcclusionCdlodAndFoliageLab(ShowcaseVariationRig rig) {
    final upright = Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2);

    // 1. `LightClusterGrid3D` binning 128 active Point & Spot lights.
    clusterGrid = LightClusterGrid3D();
    clusterViewMatrix.setAsViewMatrix(
      Vector3(7.0, -3.5, 9.5),
      Vector3(7.0, 7.0, 0.8),
      Vector3(0, 0, 1),
    );
    clusterProjMatrix.setAsPerspective(55.0, 16.0 / 9.0, 0.5, 48.0);

    final lanternGroup = InstancedGroup3D(
      mesh: SphereMesh(
        radius: 0.08,
        segments: 8,
        material: UnlitMaterial()..renderState = RenderState.opaque,
      ),
      initialCapacity: 128,
      castsShadows: false,
    );
    final lanternTf = Matrix4.identity();
    for (var i = 0; i < 128; i++) {
      final col = i % 16;
      final row = i ~/ 16;
      final lx = 1.4 + col * 0.75;
      final ly = 1.6 + row * 1.48;
      final lz = 0.55 + 0.35 * math.sin(i * 0.45);
      final hueColor = HSVColor.fromAHSV(
        1.0,
        (i * 19.0) % 360.0,
        0.75,
        1.0,
      ).toColor();
      if (i < 96) {
        clusterGrid!.addLight(
          ClusterLightEntry3D.point(
            position: Vector3(lx, ly, lz),
            range: 3.4,
            color: hueColor,
            intensity: 2.2,
          ),
        );
      } else {
        clusterGrid!.addLight(
          ClusterLightEntry3D.spot(
            position: Vector3(lx, ly, lz + 1.2),
            direction: Vector3(0, 0, -1),
            range: 4.8,
            innerConeAngle: 0.28,
            outerConeAngle: 0.62,
            color: hueColor,
            intensity: 3.1,
          ),
        );
      }
      lanternTf
        ..setIdentity()
        ..setTranslationRaw(lx, ly, lz);
      lanternGroup.addInstance(transform: lanternTf, color: hueColor);
    }
    clusterGrid!.assignLights(
      clusterViewMatrix,
      clusterProjMatrix,
      near: 0.5,
      far: 48.0,
    );
    rig.dynamicExtras.add(lanternGroup);

    // 2. Software Hi-Z `OcclusionCuller3D` + Indoor `PortalOcclusionGraph3D`.
    occlusionCuller = OcclusionCuller3D()
      ..addBox(
        OccluderBox3D(
          center: Vector3(7.0, 9.2, 1.25),
          halfExtents: Vector3(2.4, 0.32, 1.35),
        ),
      );
    final wallView = Matrix4.identity()
      ..setAsViewMatrix(
        Vector3(7.0, 4.2, 1.2),
        Vector3(7.0, 11.5, 1.2),
        Vector3(0, 0, 1),
      );
    final wallProj = Matrix4.identity()..setAsPerspective(55.0, 1.5, 0.3, 30.0);
    occluderViewProj
      ..setFrom(wallProj)
      ..multiply(wallView);
    occlusionCuller!.rasterizeOccluders(occluderViewProj);

    final castleWallMesh = MeshComponent(
      mesh: CuboidMesh(
        size: Vector3(4.8, 0.64, 2.7),
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFF475569),
          roughness: 0.82,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      position: Vector3(7.0, 9.2, 1.35),
    );
    frontCrateMesh = MeshComponent(
      mesh: CuboidMesh(
        size: Vector3.all(0.62),
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFF22C55E),
          roughness: 0.55,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      position: Vector3(7.0, 7.8, 0.45),
    );
    occludedRearCrateMesh = MeshComponent(
      mesh: CuboidMesh(
        size: Vector3.all(0.55),
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFFEF4444),
          roughness: 0.55,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      position: Vector3(7.0, 11.2, 0.55),
    );
    occludedRearCrateMesh!.visible = occlusionCuller!.isAabbVisible(
      Aabb3.minMax(Vector3(6.72, 10.92, 0.27), Vector3(7.28, 11.48, 0.83)),
      occluderViewProj,
    );
    rig.dynamicExtras.addAll([
      castleWallMesh,
      frontCrateMesh!,
      occludedRearCrateMesh!,
    ]);

    portalGraph = PortalOcclusionGraph3D()
      ..addRoom(
        OcclusionRoom3D(
          id: 0,
          name: 'courtyard',
          bounds: Aabb3.minMax(Vector3(4.0, 3.0, 0.0), Vector3(10.0, 9.2, 3.0)),
        ),
      )
      ..addRoom(
        OcclusionRoom3D(
          id: 1,
          name: 'vault',
          bounds: Aabb3.minMax(
            Vector3(4.0, 9.2, 0.0),
            Vector3(10.0, 13.5, 3.0),
          ),
        ),
      );
    vaultDoorPortal = OcclusionPortal3D(
      roomA: 0,
      roomB: 1,
      vertices: [
        Vector3(6.3, 9.2, 0.1),
        Vector3(7.7, 9.2, 0.1),
        Vector3(7.7, 9.2, 2.2),
        Vector3(6.3, 9.2, 2.2),
      ],
    );
    portalGraph!.addPortal(vaultDoorPortal!);
    portalGraph!.evaluateVisibility(
      cameraPosition: Vector3(7.0, 4.2, 1.2),
      viewProjection: occluderViewProj,
      cameraRoomId: 0,
    );

    // 3. `StaticMeshBatcher3D` merging 96 heterogeneous static props/pillars.
    final sharedStoneMat = SpatialMaterial(
      albedoColor: const ui.Color(0xFFCBD5E1),
      roughness: 0.74,
      metallic: 0.12,
    )..renderState = const RenderState(cullMode: CullMode.backFace);
    final protoMeshes = <Mesh>[
      CuboidMesh(size: Vector3(0.24, 0.24, 0.68), material: sharedStoneMat),
      CylinderMesh(
        radius: 0.12,
        height: 0.72,
        segments: 10,
        material: sharedStoneMat,
      ),
      ConeMesh(
        radius: 0.16,
        height: 0.52,
        segments: 10,
        material: sharedStoneMat,
      ),
    ];
    staticBatcher = StaticMeshBatcher3D(chunkSize: 16.0);
    final propTf = Matrix4.identity();
    for (var i = 0; i < 96; i++) {
      final ring = i ~/ 24;
      final step = i % 24;
      final ang = (step / 24.0) * math.pi * 2.0;
      final rad = 4.6 + ring * 0.52;
      final px = 7.0 + math.cos(ang) * rad;
      final py = 7.0 + math.sin(ang) * rad;
      final mesh = protoMeshes[i % protoMeshes.length];
      if (i % 3 == 0) {
        propTf.setFromTranslationRotation(
          Vector3(px, py, 0.34),
          Quaternion.axisAngle(Vector3(0, 0, 1), ang),
        );
      } else {
        propTf.setFromTranslationRotation(Vector3(px, py, 0.36), upright);
      }
      staticBatcher!.addStaticInstance(
        mesh: mesh,
        transform: propTf,
        color: i.isEven
            ? const ui.Color(0xFFE2E8F0)
            : const ui.Color(0xFF94A3B8),
      );
    }
    rig.dynamicExtras.add(staticBatcher!);

    // 4. `FloatingOriginController3D` at `WorldPosition64(250000, 250000, 0)`.
    floatingOrigin = FloatingOriginController3D(
      initialOrigin: WorldPosition64(250000.0, 250000.0),
      rebaseThreshold: 512.0,
    );
    satelliteBeaconMesh = MeshComponent(
      mesh: SphereMesh(
        radius: 0.26,
        segments: 14,
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFF38BDF8),
          emissiveColor: const ui.Color(0xFF0284C7),
          roughness: 0.2,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      castsShadows: false,
    );
    satelliteOriginTransform = FloatingOriginTransform3D(
      worldPosition: WorldPosition64(250007.0, 250007.0, 2.35),
      target: satelliteBeaconMesh,
    );
    floatingOrigin!.register(satelliteOriginTransform!);
    rig.dynamicExtras.add(satelliteBeaconMesh!);

    // 5. Quadtree `ChunkedTerrain3D` (CDLOD + skirts + 4-biome splatting).
    cdlodTerrain =
        ChunkedTerrain3D.procedural(
            gridColumns: 33,
            gridRows: 33,
            worldWidth: 4.8,
            worldDepth: 4.8,
            maxHeight: 1.15,
            frequency: 0.65,
            lodLevels: 3,
            lodSplitFactor: 0.9,
            skirtDepth: 0.24,
          )
          ..position.setValues(3.6, 4.2, 0.06)
          ..rotation.setFrom(upright);
    rig.dynamicExtras.add(cdlodTerrain!);

    // 6. `FoliageSystem3D` scattering 10,000+ wind-swaying grass blades +
    //    orbiting `FoliageInteractor3D` trampling a visible path!
    final meadowTerrain = ChunkedTerrain3D.procedural(
      gridColumns: 33,
      gridRows: 33,
      worldWidth: 4.8,
      worldDepth: 4.8,
      maxHeight: 0.25,
      frequency: 0.35,
      lodLevels: 2,
    );
    foliageInteractor = FoliageInteractor3D(
      position: Vector3(10.2, 4.2, 0.35),
      radius: 0.95,
    );
    foliageSystem =
        FoliageSystem3D(
          capacity: 12000,
          cellSize: 1.6,
          maxDrawDistance: 900.0,
          windStrength: 0.16,
          interactors: [foliageInteractor!],
          position: Vector3(10.2, 4.2, 0.08),
          rotation: upright,
        )..scatterOnTerrain(
          meadowTerrain,
          count: 10240,
          minSlopeCos: 0.2,
          minScale: 0.28,
          maxScale: 0.52,
        );
    foliageTramplerOrb = MeshComponent(
      mesh: SphereMesh(
        radius: 0.24,
        segments: 14,
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFFFACC15),
          metallic: 0.65,
          roughness: 0.22,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      position: Vector3(10.2, 4.2, 0.35),
    );
    rig.dynamicExtras.addAll([foliageSystem!, foliageTramplerOrb!]);

    // 7. `VolumeDecalBatch3D` projecting an oriented 3D box decal across a 90°
    //    stepped wall!
    final stepBase = MeshComponent(
      mesh: CuboidMesh(
        size: Vector3(1.8, 1.4, 0.28),
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFF64748B),
          roughness: 0.78,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      position: Vector3(7.0, 4.2, 0.14),
    );
    final stepRiser = MeshComponent(
      mesh: CuboidMesh(
        size: Vector3(1.8, 0.36, 1.15),
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFF475569),
          roughness: 0.78,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      position: Vector3(7.0, 4.72, 0.58),
    );
    volumeDecalBatch = VolumeDecalBatch3D(
      material: UnlitMaterial(
        albedoColor: const ui.Color(0xFF38BDF8),
      )..renderState = RenderState.alphaBlend,
      normalOffset: 0.008,
    );
    final decalBox = ProjectedDecalBox3D.lookAlong(
      center: Vector3(7.0, 4.35, 0.55),
      direction: Vector3(0, 0.72, -0.69),
      up: Vector3(0, 0, 1),
      halfExtents: Vector3(0.65, 0.65, 0.95),
      color: const ui.Color(0xD922D3EE),
    );
    volumeDecalBatch!.projectOntoSurfaces(
      [decalBox],
      [
        ...VolumeDecalTarget3D.fromMeshComponent(stepBase),
        ...VolumeDecalTarget3D.fromMeshComponent(stepRiser),
      ],
    );
    rig.dynamicExtras.addAll([stepBase, stepRiser, volumeDecalBatch!]);
  }

  // ===========================================================================
  // Lab 19 — CCD, Compound, Heightfield, 6DOF, Buoyancy, Vehicle, Cloth, Recast
  // ===========================================================================

  void buildCcdCompoundClothRecastAndRollbackLab({
    required ShowcaseVariationRig rig,
    required World3D dynamicWorld,
  }) {
    final upright = Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2);

    // 1. `CollisionSystem3D` (`DynamicAabbTree3D`) + `PhysicsWorld3D` firing a
    //    `120 m/s` `ccdEnabled` projectile at a `0.03 m` thin wall!
    ccdCollisionSystem = CollisionSystem3D();
    ccdPhysicsWorld = PhysicsWorld3D(gravity: Vector3(0, 0, -9.81));
    dynamicWorld.addAll([ccdCollisionSystem!, ccdPhysicsWorld!]);

    final floorBody = RigidBody3D(
      shape: BoxShape3D(halfExtents: Vector3(7.0, 7.0, 0.25)),
      bodyType: BodyType3D.static,
      material: const PhysicsMaterial3D(
        friction: 0.65,
        restitution: 0.25,
        surfaceTag: 'stone',
      ),
      syncParent: false,
      position: Vector3(7.0, 7.0, -0.25),
    );
    thinWallBody = RigidBody3D(
      shape: BoxShape3D(halfExtents: Vector3(0.015, 1.15, 0.95)),
      bodyType: BodyType3D.static,
      material: const PhysicsMaterial3D(
        friction: 0.4,
        restitution: 0.45,
        surfaceTag: 'armor_plate',
      ),
      syncParent: false,
      position: Vector3(8.6, 10.4, 0.95),
    );
    final thinWallMesh = MeshComponent(
      mesh: CuboidMesh(
        size: Vector3(0.03, 2.3, 1.9),
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFF94A3B8),
          metallic: 0.78,
          roughness: 0.26,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      position: Vector3(8.6, 10.4, 0.95),
      children: [
        Collider3D(
          shape: BoxShape3D(halfExtents: Vector3(0.015, 1.15, 0.95)),
          isStatic: true,
        ),
      ],
    );

    ccdProjectileBody = RigidBody3D(
      shape: SphereShape3D(radius: 0.18),
      mass: 1.2,
      ccdEnabled: true,
      canSleep: false,
      material: const PhysicsMaterial3D(
        friction: 0.35,
        restitution: 0.55,
        surfaceTag: 'steel_shot',
      ),
      linearVelocity: Vector3(120.0, 0, 0.6),
    );
    final ccdProjectileMesh = MeshComponent(
      mesh: SphereMesh(
        radius: 0.18,
        segments: 14,
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFFF97316),
          emissiveColor: const ui.Color(0xFFEA580C),
          metallic: 0.6,
          roughness: 0.22,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      position: Vector3(3.4, 10.4, 0.85),
      children: [
        ccdProjectileBody!,
        Collider3D(shape: SphereShape3D(radius: 0.18)),
      ],
    );

    // 2. Concave `CompoundShape3D` arch/table (Huygens–Steiner parallel-axis).
    compoundArchShape = CompoundShape3D([
      CompoundChildShape3D(
        shape: BoxShape3D(halfExtents: Vector3(0.75, 0.38, 0.1)),
        position: Vector3(0, 0, 0.42),
        massWeight: 2.0,
      ),
      CompoundChildShape3D(
        shape: BoxShape3D(halfExtents: Vector3(0.12, 0.34, 0.32)),
        position: Vector3(-0.58, 0, 0.0),
      ),
      CompoundChildShape3D(
        shape: BoxShape3D(halfExtents: Vector3(0.12, 0.34, 0.32)),
        position: Vector3(0.58, 0, 0.0),
      ),
    ]);
    compoundArchBody = RigidBody3D(
      shape: compoundArchShape!,
      mass: 4.5,
      material: const PhysicsMaterial3D(friction: 0.6, restitution: 0.18),
    );
    final archMat = SpatialMaterial(
      albedoColor: const ui.Color(0xFFA855F7),
      roughness: 0.42,
      metallic: 0.25,
    )..renderState = const RenderState(cullMode: CullMode.backFace);
    final archGroup = Group3D(
      position: Vector3(11.2, 10.4, 0.65),
      children: [
        compoundArchBody!,
        MeshComponent(
          mesh: CuboidMesh(size: Vector3(1.5, 0.76, 0.2), material: archMat),
          position: Vector3(0, 0, 0.42),
        ),
        MeshComponent(
          mesh: CuboidMesh(size: Vector3(0.24, 0.68, 0.64), material: archMat),
          position: Vector3(-0.58, 0, 0.0),
        ),
        MeshComponent(
          mesh: CuboidMesh(size: Vector3(0.24, 0.68, 0.64), material: archMat),
          position: Vector3(0.58, 0, 0.0),
        ),
      ],
    );

    rig.dynamicExtras.addAll([
      floorBody,
      thinWallBody!,
      thinWallMesh,
      ccdProjectileMesh,
      archGroup,
    ]);

    // 3. `+Y`-up Physics Contraption Sub-World (Heightfield, 4 Joint types,
    //    BuoyancyVolume3D, 4-Wheel RaycastVehicle3D, XpbdCloth3D & XpbdRope3D)
    //    mounted inside an `upright`-rotated Group3D!
    yUpSubPhysicsWorld = PhysicsWorld3D();
    final subStage = Group3D(
      position: Vector3(7.0, 5.2, 0.12),
      rotation: upright,
    );

    final hfSamples = Float32List(9 * 9);
    for (var r = 0; r < 9; r++) {
      for (var c = 0; c < 9; c++) {
        final nx = (c - 4) * 0.35;
        final nz = (r - 4) * 0.35;
        hfSamples[r * 9 + c] = 0.08 * math.cos(nx * 1.4) * math.cos(nz * 1.4);
      }
    }
    heightfieldShape = HeightfieldShape3D(
      heights: hfSamples,
      columns: 9,
      rows: 9,
      width: 9.0,
      depth: 4.4,
    );
    final hfBody = RigidBody3D(
      shape: heightfieldShape!,
      bodyType: BodyType3D.static,
      syncParent: false,
      position: Vector3.zero(),
    );
    yUpSubPhysicsWorld!.addBody(hfBody);

    heightfieldBallBody = RigidBody3D(
      shape: SphereShape3D(radius: 0.22),
      syncParent: false,
      position: Vector3(-3.2, 1.1, 0.0),
    );
    yUpSubPhysicsWorld!.addBody(heightfieldBallBody!);
    heightfieldBallMesh = MeshComponent(
      mesh: SphereMesh(
        radius: 0.22,
        segments: 12,
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFF34D399),
          roughness: 0.3,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      position: Vector3(-3.2, 1.1, 0.0),
    );
    subStage.add(heightfieldBallMesh!);

    final jointFrameAnchor = RigidBody3D(
      shape: SphereShape3D(radius: 0.1),
      bodyType: BodyType3D.static,
      syncParent: false,
      position: Vector3(-1.8, 1.85, 0.0),
    );
    final fixedBob = RigidBody3D(
      shape: BoxShape3D(halfExtents: Vector3.all(0.14)),
      mass: 0.8,
      syncParent: false,
      position: Vector3(-2.15, 1.55, 0.0),
    );
    final sliderBob = RigidBody3D(
      shape: BoxShape3D(halfExtents: Vector3.all(0.14)),
      mass: 0.8,
      syncParent: false,
      position: Vector3(-1.8, 1.45, 0.0),
    );
    final coneBob = RigidBody3D(
      shape: SphereShape3D(radius: 0.15),
      mass: 0.8,
      syncParent: false,
      position: Vector3(-1.45, 1.35, 0.05),
    );
    final sixDofBob = RigidBody3D(
      shape: BoxShape3D(halfExtents: Vector3.all(0.15)),
      mass: 0.9,
      syncParent: false,
      position: Vector3(-1.1, 1.4, 0.0),
    );
    for (final b in [
      jointFrameAnchor,
      fixedBob,
      sliderBob,
      coneBob,
      sixDofBob,
    ]) {
      yUpSubPhysicsWorld!.addBody(b);
    }

    fixedJoint = FixedJoint3D(bodyA: jointFrameAnchor, bodyB: fixedBob);
    sliderJoint = SliderJoint3D(
      bodyA: jointFrameAnchor,
      bodyB: sliderBob,
      worldAxis: Vector3(0, 1, 0),
      minDistance: -0.65,
      maxDistance: 0.15,
      motorSpeed: 0.35,
      maxMotorForce: 14.0,
    );
    coneTwistJoint = ConeTwistJoint3D(
      bodyA: jointFrameAnchor,
      bodyB: coneBob,
      localAnchorA: Vector3(0.35, -0.1, 0.0),
      localAnchorB: Vector3(0.0, 0.4, 0.0),
      swingLimitRad: 0.65,
      minTwistRad: -0.45,
      maxTwistRad: 0.45,
    );
    generic6DofJoint = Generic6DofJoint3D(
      bodyA: jointFrameAnchor,
      bodyB: sixDofBob,
      localAnchorA: Vector3(0.7, -0.1, 0.0),
      localAnchorB: Vector3(0.0, 0.35, 0.0),
      linearLowerLimit: Vector3(-0.08, -0.35, -0.08),
      linearUpperLimit: Vector3(0.08, 0.15, 0.08),
      linearSpringStiffness: Vector3(25.0, 38.0, 25.0),
      linearSpringDamping: Vector3.all(4.5),
      angularLowerLimit: Vector3.all(-0.35),
      angularUpperLimit: Vector3.all(0.35),
    );
    for (final j in [
      fixedJoint!,
      sliderJoint!,
      coneTwistJoint!,
      generic6DofJoint!,
    ]) {
      yUpSubPhysicsWorld!.addJoint(j);
    }

    // Archimedes `BuoyancyVolume3D` floating crate:
    buoyancyVolume = BuoyancyVolume3D(
      baseWaterLevel: 0.62,
      fluidDensity: 28.0,
      bounds: Aabb3.minMax(Vector3(-0.6, -0.5, -1.2), Vector3(1.2, 1.4, 1.2)),
      waterSurfaceHeight: (x, z, t) =>
          0.62 + 0.05 * math.sin(x * 2.2 + t * 2.4),
    );
    yUpSubPhysicsWorld!.addBuoyancyVolume(buoyancyVolume!);
    buoyancyCrateBody = RigidBody3D(
      shape: BoxShape3D(halfExtents: Vector3.all(0.24)),
      mass: 1.1,
      canSleep: false,
      syncParent: false,
      position: Vector3(0.25, 0.48, 0.0),
    );
    yUpSubPhysicsWorld!.addBody(buoyancyCrateBody!);
    buoyancyCrateMesh = MeshComponent(
      mesh: CuboidMesh(
        size: Vector3.all(0.48),
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFFF59E0B),
          roughness: 0.48,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      position: Vector3(0.25, 0.48, 0.0),
    );
    final waterTankVisual = MeshComponent(
      mesh: CuboidMesh(
        size: Vector3(1.5, 0.62, 1.5),
        material:
            SpatialMaterial(
                albedoColor: const ui.Color(0x660EA5E9),
                roughness: 0.12,
              )
              ..renderState = const RenderState(
                blend: BlendState.alpha,
                depthWrite: false,
                cullMode: CullMode.backFace,
              ),
      ),
      position: Vector3(0.25, 0.31, 0.0),
      castsShadows: false,
    );
    subStage.addAll([buoyancyCrateMesh!, waterTankVisual]);

    // 4-Wheel `RaycastVehicle3D`:
    final roadSlab = RigidBody3D(
      shape: BoxShape3D(halfExtents: Vector3(1.8, 0.15, 2.2)),
      bodyType: BodyType3D.static,
      syncParent: false,
      position: Vector3(2.4, -0.15, 0.0),
    );
    final vehicleChassisBody = RigidBody3D(
      shape: BoxShape3D(halfExtents: Vector3(0.38, 0.16, 0.58)),
      mass: 3.5,
      canSleep: false,
      syncParent: false,
      position: Vector3(2.4, 0.48, -0.5),
    );
    yUpSubPhysicsWorld!
      ..addBody(roadSlab)
      ..addBody(vehicleChassisBody);
    raycastVehicle = RaycastVehicle3D.fourWheel(
      chassis: vehicleChassisBody,
      halfTrackWidth: 0.36,
      halfWheelbase: 0.46,
      restLength: 0.28,
      wheelRadius: 0.18,
      springStiffness: 42.0,
      engineForce: 16.0,
    )..throttle = 0.65;
    yUpSubPhysicsWorld!.addVehicle(raycastVehicle!);
    vehicleChassisMesh = MeshComponent(
      mesh: CuboidMesh(
        size: Vector3(0.76, 0.32, 1.16),
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFFEF4444),
          metallic: 0.55,
          roughness: 0.28,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      position: Vector3(2.4, 0.48, -0.5),
    );
    subStage.add(vehicleChassisMesh!);

    // Aerodynamic `XpbdCloth3D` banner + `XpbdRope3D` colliding with sphere!
    clothObstacleSphere = XpbdSphereCollider3D(
      center: Vector3(4.15, 5.05, 1.05),
      radius: 0.34,
    );
    final clothMat = SpatialMaterial(
      albedoColor: const ui.Color(0xFFEC4899),
      roughness: 0.68,
      doubleSided: true,
    )..renderState = RenderState.opaque;
    xpbdCloth = XpbdCloth3D(
      columns: 10,
      rows: 10,
      width: 1.35,
      height: 1.35,
      pinTopEdge: true,
      material: clothMat,
      gravity: Vector3(0, 0, -9.81),
      windVelocity: Vector3(0.8, 1.9, 0.2),
      sphereColliders: [clothObstacleSphere!],
      position: Vector3(-2.85, 1.35, 0.15),
      autoStep: false,
    );
    xpbdRope = XpbdRope3D(
      startPoint: Vector3(0.0, 0.65, 0.0),
      endPoint: Vector3(0.45, -0.55, 0.25),
      segmentCount: 12,
      radius: 0.035,
      material: SpatialMaterial(
        albedoColor: const ui.Color(0xFFFACC15),
        roughness: 0.55,
      )..renderState = const RenderState(cullMode: CullMode.backFace),
      gravity: Vector3(0, 0, -9.81),
      sphereColliders: [clothObstacleSphere!],
      position: Vector3(-2.35, 1.35, 0.15),
      autoStep: false,
    );
    final obstacleOrb = MeshComponent(
      mesh: SphereMesh(
        radius: 0.32,
        segments: 14,
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFF38BDF8),
          metallic: 0.45,
          roughness: 0.28,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      position: Vector3(4.15, 5.05, 1.05),
    );
    subStage.addAll([xpbdCloth!, xpbdRope!]);
    rig.dynamicExtras.addAll([subStage, obstacleOrb]);

    // 4. Voxel `NavMeshBuilder3D.fromGeometry` + `NavMeshObstacle3D` gate +
    //    jump `OffMeshLink3D`!
    final westDeck = CuboidMesh(
      size: Vector3(4.2, 0.3, 2.4),
      material: UnlitMaterial(),
    );
    final eastDeck = CuboidMesh(
      size: Vector3(3.2, 0.3, 2.4),
      material: UnlitMaterial(),
    );
    recastNavMesh = NavMeshBuilder3D.fromGeometry(
      [
        ...NavMeshGeometrySource3D.fromMesh(
          westDeck,
          transform: Matrix4.translationValues(0.0, 0.0, 0.0),
        ),
        ...NavMeshGeometrySource3D.fromMesh(
          eastDeck,
          transform: Matrix4.translationValues(5.2, 0.35, 0.0),
        ),
      ],
      config: const NavMeshBuildConfig3D(
        cellHeight: 0.12,
        agentRadius: 0.2,
        agentHeight: 1.4,
      ),
    );
    gateNavObstacle = NavMeshObstacle3D(
      center: Vector3(0.0, 0.25, 0.0),
      halfExtents: Vector3(0.32, 0.6, 1.4),
      enabled: false,
    );
    recastNavMesh!.addObstacle(gateNavObstacle!);
    jumpOffMeshLink = OffMeshLink3D(
      start: Vector3(1.65, 0.15, 0.0),
      end: Vector3(3.95, 0.5, 0.0),
    );
    recastNavMesh!.addOffMeshLink(jumpOffMeshLink!);

    // 5. `PhysicsSnapshotRingBuffer3D` initial deterministic capture.
    snapshotRingBuffer = PhysicsSnapshotRingBuffer3D(capacity: 32)
      ..capture(yUpSubPhysicsWorld!);
  }

  // ===========================================================================
  // Lab 20 — AnimGraph HFSM, Retargeting, FABRIK/FootIK/Ragdoll, 3D UI & Gizmo
  // ===========================================================================

  void buildAnimGraphRetargetRagdollUiAndGizmoLab({
    required ShowcaseVariationRig rig,
    required World3D dynamicWorld,
    required Scene3DComponent dynamicLayer,
    required World world2D,
  }) {
    final upright = Quaternion.axisAngle(Vector3(1, 0, 0), math.pi / 2);

    // 1. `AnimationStateMachine3D` (HFSM with float speed, trigger & phase
    //    sync) + `HumanoidProfile3D` & `AnimationRetargeter3D` (`0.7x`/`1.35x`).
    final baseHumanoidMat = SpatialMaterial(
      albedoColor: const ui.Color(0xFF38BDF8),
      metallic: 0.28,
      roughness: 0.38,
    )..renderState = const RenderState(cullMode: CullMode.backFace);
    final sourceModel = _buildHumanoidRigModel(
      scaleFactor: 1.0,
      material: baseHumanoidMat,
    );
    final idleClip = sourceModel.animations[0];
    final walkClip = sourceModel.animations[1];
    final runClip = sourceModel.animations[2];
    final jumpClip = sourceModel.animations[3];
    sourceWalkClip = walkClip;

    animGraphActor = ModelComponent(
      model: sourceModel,
      position: Vector3(3.0, 9.6, 0.08),
      rotation: upright,
    );
    final locoSubSm = SubStateMachine3D(
      name: 'locomotion',
      initialState: 'idle',
      states: [
        ClipAnimState3D(name: 'idle', animation: idleClip),
        ClipAnimState3D(
          name: 'walk',
          animation: walkClip,
          syncGroup: 'gait',
        ),
        ClipAnimState3D(
          name: 'run',
          animation: runClip,
          syncGroup: 'gait',
        ),
      ],
      transitions: [
        AnimTransition3D(
          fromState: 'idle',
          toState: 'walk',
          conditions: const [AnimCondition3D.greater('speed', 0.3)],
          crossFadeDuration: 0.15,
        ),
        AnimTransition3D(
          fromState: 'walk',
          toState: 'run',
          conditions: const [AnimCondition3D.greater('speed', 2.2)],
          crossFadeDuration: 0.18,
          syncNormalizedPhase: true,
        ),
        AnimTransition3D(
          fromState: 'run',
          toState: 'walk',
          conditions: const [AnimCondition3D.less('speed', 2.0)],
          crossFadeDuration: 0.18,
          syncNormalizedPhase: true,
        ),
        AnimTransition3D(
          fromState: 'walk',
          toState: 'idle',
          conditions: const [AnimCondition3D.less('speed', 0.2)],
          crossFadeDuration: 0.15,
        ),
      ],
    );
    animStateMachine = AnimationStateMachine3D(
      initialState: 'locomotion',
      animationState: animGraphActor!.animationState,
      states: [
        locoSubSm,
        ClipAnimState3D(
          name: 'jump',
          animation: jumpClip,
          playMode: AnimationPlayMode.once,
        ),
      ],
      transitions: [
        AnimTransition3D(
          fromState: AnimTransition3D.anyState,
          toState: 'jump',
          conditions: const [AnimCondition3D.onTrigger('jump')],
          crossFadeDuration: 0.1,
        ),
        AnimTransition3D(
          fromState: 'jump',
          toState: 'locomotion',
          exitTime: 0.9,
          crossFadeDuration: 0.15,
        ),
      ],
    )..setFloat('speed', 1.2);
    rig.dynamicExtras.add(animGraphActor!);

    // Humanoid Retargeting (`0.7x` short & `1.35x` tall rigs):
    sourceHumanoidProfile = HumanoidProfile3D.autoDetect(sourceModel);
    final shortModel = _buildHumanoidRigModel(
      scaleFactor: 0.7,
      material: SpatialMaterial(
        albedoColor: const ui.Color(0xFF34D399),
        roughness: 0.4,
      )..renderState = const RenderState(cullMode: CullMode.backFace),
    );
    final tallModel = _buildHumanoidRigModel(
      scaleFactor: 1.35,
      material: SpatialMaterial(
        albedoColor: const ui.Color(0xFFF59E0B),
        roughness: 0.4,
      )..renderState = const RenderState(cullMode: CullMode.backFace),
    );
    shortHumanoidProfile = HumanoidProfile3D.autoDetect(shortModel);
    tallHumanoidProfile = HumanoidProfile3D.autoDetect(tallModel);
    shortRetargetedClip = AnimationRetargeter3D.retargetClip(
      walkClip,
      sourceProfile: sourceHumanoidProfile!,
      targetProfile: shortHumanoidProfile!,
      newName: 'Walk_Short',
    );
    tallRetargetedClip = AnimationRetargeter3D.retargetClip(
      walkClip,
      sourceProfile: sourceHumanoidProfile!,
      targetProfile: tallHumanoidProfile!,
      newName: 'Walk_Tall',
    );
    shortHumanoidActor = ModelComponent(
      model: shortModel,
      position: Vector3(4.35, 9.6, 0.08),
      rotation: upright,
    )..animationState.startAnimation(shortRetargetedClip);
    tallHumanoidActor = ModelComponent(
      model: tallModel,
      position: Vector3(5.65, 9.6, 0.08),
      rotation: upright,
    )..animationState.startAnimation(tallRetargetedClip);
    rig.dynamicExtras.addAll([shortHumanoidActor!, tallHumanoidActor!]);

    // 2. 6-Joint `FabrikIkConstraint3D` tentacle + `FootPlacementIk3D` +
    //    articulated `RagdollController3D` (`activateRagdoll` -> `recover`).
    final tentacleModel = _buildSixJointTentacleModel();
    fabrikTentacleActor = ModelComponent(
      model: tentacleModel,
      position: Vector3(7.4, 9.8, 0.1),
      rotation: upright,
    );
    fabrikConstraint = FabrikIkConstraint3D(
      chainNodeIndices: const [0, 1, 2, 3, 4, 5],
      targetPosition: Vector3(7.85, 9.45, 1.32),
      maxIterations: 16,
      maxConeAngleRad: 1.25,
    );
    fabrikTentacleActor!.boneModifiers.add(fabrikConstraint!);
    fabrikTargetOrb = MeshComponent(
      mesh: SphereMesh(
        radius: 0.15,
        segments: 12,
        material: UnlitMaterial(albedoColor: const ui.Color(0xFF00F5D4))
          ..renderState = RenderState.opaque,
      ),
      position: Vector3(8.0, 9.4, 1.35),
      castsShadows: false,
    );
    rig.dynamicExtras.addAll([fabrikTentacleActor!, fabrikTargetOrb!]);

    final footIkStage = Group3D(
      position: Vector3(9.2, 9.6, 0.08),
      rotation: upright,
    );
    final footIkModel = _buildHumanoidRigModel(
      scaleFactor: 1.0,
      material: SpatialMaterial(
        albedoColor: const ui.Color(0xFFA855F7),
        roughness: 0.42,
      )..renderState = const RenderState(cullMode: CullMode.backFace),
    );
    final footProfile = HumanoidProfile3D.autoDetect(footIkModel);
    footIkActor = ModelComponent(model: footIkModel)
      ..animationState.startAnimation(footIkModel.animations[0]);
    footPlacementIk = FootPlacementIk3D.fromHumanoid(
      footProfile,
      pelvisSmoothing: 40.0,
      groundQuery: (origin, maxDist) {
        final stepY = origin.x < 9.2 ? 0.24 : 0.04;
        return GroundHit3D(
          point: Vector3(origin.x, stepY, origin.z),
          normal: Vector3(0, 1, 0),
        );
      },
    );
    footIkActor!.boneModifiers.add(footPlacementIk!);
    footIkStage.add(footIkActor!);
    rig.dynamicExtras.add(footIkStage);

    // Articulated `RagdollController3D` on a `+Z`-up physics floor:
    ragdollPhysicsWorld = PhysicsWorld3D(gravity: Vector3(0, 0, -9.81));
    dynamicWorld.add(ragdollPhysicsWorld!);
    ragdollPhysicsWorld!.addBody(
      RigidBody3D(
        shape: BoxShape3D(halfExtents: Vector3(7.0, 7.0, 0.25)),
        bodyType: BodyType3D.static,
        syncParent: false,
        position: Vector3(7.0, 7.0, -0.25),
      ),
    );
    final ragdollModel = _buildHumanoidRigModel(
      scaleFactor: 1.0,
      material: SpatialMaterial(
        albedoColor: const ui.Color(0xFFFB7185),
        roughness: 0.38,
      )..renderState = const RenderState(cullMode: CullMode.backFace),
    );
    ragdollActor = ModelComponent(
      model: ragdollModel,
      position: Vector3(11.1, 9.6, 0.12),
      rotation: upright,
    )..animationState.startAnimation(ragdollModel.animations[1]);
    ragdollController = RagdollController3D(
      modelComponent: ragdollActor!,
      physicsWorld: ragdollPhysicsWorld!,
      defaultRadius: 0.07,
    );
    rig.dynamicExtras.add(ragdollActor!);

    // 3. `Component3D.visible` subtree toggling + `clone()`, `PrefabRegistry3D`
    //    & `'F3DS'` binary CRC32 `SceneSerializer3D` + `GpuResourceManager3D`.
    final prototypeCrystal = MeshComponent(
      mesh: ConeMesh(
        radius: 0.24,
        height: 0.72,
        segments: 6,
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFF22D3EE),
          metallic: 0.45,
          roughness: 0.2,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      rotation: upright,
    )..addTag3D('beacon');
    final beaconPrefab = Prefab3D.fromPrototype(
      'crystal_beacon',
      prototypeCrystal,
    );
    prefabRegistry = PrefabRegistry3D()..register(beaconPrefab);
    toggleSubtreeGroup = Group3D(
      position: Vector3(3.2, 5.8, 0.36),
      children: [
        beaconPrefab.instantiate(
          PrefabOverrides3D(
            position: Vector3(-0.35, 0, 0),
            color: const ui.Color(0xFF38BDF8),
          ),
        ),
        beaconPrefab.instantiate(
          PrefabOverrides3D(
            position: Vector3(0.35, 0, 0),
            color: const ui.Color(0xFFF472B6),
          ),
        ),
      ],
    );
    clonedCrystalGroup = toggleSubtreeGroup!.clone()
      ..position.setValues(4.6, 5.8, 0.36);
    rig.dynamicExtras.addAll([toggleSubtreeGroup!, clonedCrystalGroup!]);

    sceneSerializer = SceneSerializer3D(prefabRegistry: prefabRegistry);
    final miniSnapshotWorld = World3D()
      ..add(
        beaconPrefab.instantiate(
          PrefabOverrides3D(position: Vector3(1.0, 2.0, 0.5)),
        ),
      );
    cachedBinarySceneBytes = sceneSerializer!.encodeBinary(miniSnapshotWorld);

    deviceLossRecovery = GpuDeviceLossRecovery3D();
    gpuResourceManager = GpuResourceManager3D(
      maxVramBytes: 64 * 1024,
      deviceLossRecovery: deviceLossRecovery,
    );
    final managedLease = gpuResourceManager!.acquire<Texture>(
      'lab20_checker_tex',
      () {
        final px = Uint8List(8 * 8 * 4)..fillRange(0, 8 * 8 * 4, 220);
        return Texture(ByteData.sublistView(px), width: 8, height: 8);
      },
      estimatedBytes: 256,
    );
    deviceLossRecovery!.registerResource(
      'lab20_checker_tex',
      managedLease.resource,
    );

    // 4. 1-Draw `MsdfTextBatch3D` crisp 3D labels + Interactive diegetic
    //    `WidgetSurface3D` (`SurfaceButton2D` + `SurfaceSlider2D`)!
    msdfTextBatch = MsdfTextBatch3D()
      ..addText(
        'ANIM HFSM',
        position: Vector3(3.0, 9.6, 1.85),
        fontSize: 0.24,
        align: TextAlign3D.center,
        color: const ui.Color(0xFF7DD3FC),
      )
      ..addText(
        'RETARGET',
        position: Vector3(5.0, 9.6, 2.15),
        fontSize: 0.24,
        align: TextAlign3D.center,
        color: const ui.Color(0xFF6EE7B7),
      )
      ..addText(
        'IK + RAGDOLL',
        position: Vector3(9.4, 9.6, 1.95),
        fontSize: 0.24,
        align: TextAlign3D.center,
        color: const ui.Color(0xFFFDA4AF),
      )
      ..addText(
        'MSDF + 3D UI',
        position: Vector3(7.0, 4.4, 2.05),
        fontSize: 0.26,
        align: TextAlign3D.center,
        color: const ui.Color(0xFFFDE047),
      );
    rig.dynamicExtras.add(msdfTextBatch!);

    surfaceToggleButton = SurfaceButton2D(
      bounds: const ui.Rect.fromLTWH(28, 86, 210, 62),
      label: 'Toggle Beacons',
      onPressed: () {
        panelButtonClicks++;
        if (toggleSubtreeGroup case final grp?) {
          grp.visible = !grp.visible;
        }
      },
    );
    surfaceSpeedSlider = SurfaceSlider2D(
      bounds: const ui.Rect.fromLTWH(28, 186, 320, 42),
      value: 1.2,
      max: 4.0,
      onChanged: (v) {
        animStateMachine?.setFloat('speed', v);
      },
    );
    diegeticControlSurface = WidgetSurface3D(
      width: 2.3,
      height: 1.35,
      pixelWidth: 384,
      pixelHeight: 256,
      controls: [surfaceToggleButton!, surfaceSpeedSlider!],
      paintSurface: (canvas, size) {
        canvas.drawRect(
          ui.Rect.fromLTWH(0, 0, size.width, 54),
          ui.Paint()..color = const ui.Color(0xFF1E293B),
        );
      },
      position: Vector3(7.0, 4.4, 1.05),
      rotation: upright,
    );
    rig.dynamicExtras.add(diegeticControlSurface!);

    rig.pointerRouter3D = PointerRouter3D.forScene(dynamicLayer);
    rig.world2DExtras.add(rig.pointerRouter3D!);
    world2D.add(rig.pointerRouter3D!);

    // 5. `MeshoptDecoder3D` (`EXT_meshopt_compression` GLB) +
    //    `WorldChunkStreamer3D`!
    if (meshoptLoadedScene case final loaded?
        when loaded.staticMeshes.isNotEmpty) {
      final clonedMesh = loaded.staticMeshes.first.clone()
        ..position.setValues(9.8, 5.8, 0.35);
      rig.dynamicExtras.add(clonedMesh);
    }
    chunkStreamer = WorldChunkStreamer3D(
      chunkSize: 6.0,
      loadRadius: 7.5,
      focusPosition: Vector3(7.0, 0.0, 7.0),
      chunkLoader: (coord) async {
        final marker = MeshComponent(
          mesh: SphereMesh(
            radius: 0.14,
            segments: 10,
            material: UnlitMaterial(albedoColor: const ui.Color(0xFF34D399))
              ..renderState = RenderState.opaque,
          ),
          position: Vector3(
            5.5 + coord.x * 0.85,
            3.2 + coord.z * 0.85,
            0.22,
          ),
          castsShadows: false,
        );
        return [marker];
      },
    );
    dynamicWorld.add(chunkStreamer!);
    chunkStreamer!.refreshStreaming();

    // 6. Voice-pooled `SpatialAudioMixer3D` (`maxRealVoices: 2` across 4
    //    emitters, wall occlusion query & `AudioZone3D` cathedral reverb).
    _audioBackend = _ShowcaseVoiceBackend3D();
    final listener = SpatialAudioListener3D(
      position: Vector3(7.0, 6.2, 1.2),
    );
    cathedralAudioZone = AudioZone3D(
      preset: ReverbPreset3D.cathedral,
      radius: 4.5,
      fadeDistance: 1.5,
      position: Vector3(7.0, 6.2, 1.2),
    );
    final emitterPositions = <Vector3>[
      Vector3(7.4, 6.6, 1.2), // Near #1 -> real
      Vector3(6.4, 7.1, 1.2), // Near #2 (behind wall) -> real + occluded
      Vector3(2.2, 2.2, 1.2), // Far #3 -> virtual
      Vector3(12.2, 12.2, 1.2), // Far #4 -> virtual
    ];
    for (var i = 0; i < emitterPositions.length; i++) {
      final em = SpatialAudioEmitter3D(
        clipId: 'ambience_$i',
        clipDuration: 8.0,
        maxDistance: 18.0,
        position: emitterPositions[i],
      );
      pooledEmitters.add(em);
      rig.dynamicExtras.add(em);
    }
    rig.dynamicExtras.addAll([listener, cathedralAudioZone!]);
    spatialAudioMixer = SpatialAudioMixer3D(
      backend: _audioBackend!,
      listener: listener,
      maxRealVoices: 2,
      occlusionQuery: (ear, src) => src.x < 6.6 && src.y > 6.8 ? 0.85 : 0.0,
    );
    dynamicWorld.add(spatialAudioMixer!);

    // 7. Interactive `TransformGizmo3D` + `SceneInspector3D` with Undo/Redo!
    gizmoTargetCube = MeshComponent(
      mesh: CuboidMesh(
        size: Vector3.all(0.56),
        material: SpatialMaterial(
          albedoColor: const ui.Color(0xFFF97316),
          metallic: 0.35,
          roughness: 0.32,
        )..renderState = const RenderState(cullMode: CullMode.backFace),
      ),
      position: Vector3(11.0, 5.2, 0.45),
    );
    transformGizmo = TransformGizmo3D(fixedWorldSize: 0.95);
    sceneInspector = SceneInspector3D(gizmo: transformGizmo)
      ..select(gizmoTargetCube);
    gizmoDebugRenderer = DebugRenderer3D(
      lineThickness: 0.024,
    );
    sceneInspector!.render(
      gizmoDebugRenderer!,
      cameraPosition: Vector3(7.0, -2.0, 9.0),
    );
    rig.dynamicExtras.addAll([gizmoTargetCube!, gizmoDebugRenderer!]);
  }

  // ===========================================================================
  // Per-Frame Simulation Update
  // ===========================================================================

  void update(double time, double dt) {
    if (stencilInnerGem case final gem?) {
      gem.rotation.setAxisAngle(
        Vector3(0.3, 0.5, 0.8)..normalize(),
        time * 1.6,
      );
    }
    for (var i = 0; i < wboitGlassPanes.length; i++) {
      wboitGlassPanes[i].rotation.setAxisAngle(
        Vector3(0, 0, 1),
        i * (math.pi / 3.0) + time * 0.35,
      );
    }

    // Lab 18: Orbit foliage trampler & 64-bit satellite.
    if (foliageInteractor case final inter?) {
      final ox = 10.2 + math.cos(time * 1.35) * 1.45;
      final oy = 4.2 + math.sin(time * 1.35) * 1.45;
      inter.position.setValues(ox, oy, 0.28);
      foliageTramplerOrb?.position.setValues(ox, oy, 0.32);
    }
    if (satelliteOriginTransform case final sat?) {
      sat.setWorldValues(
        250007.0 + math.cos(time * 1.1) * 1.8,
        250007.0 + math.sin(time * 1.1) * 1.8,
        2.35 + 0.2 * math.sin(time * 2.2),
      );
    }

    // Lab 19: Re-fire 120 m/s CCD shot periodically & step `+Y`-up sub-world.
    if (ccdProjectileBody case final shot?) {
      _ccdFireTimer += dt;
      if (_ccdFireTimer >= 2.6) {
        _ccdFireTimer = 0.0;
        shot
          ..bodyPosition.setValues(3.4, 10.4, 0.85)
          ..linearVelocity.setValues(120.0, 0, 0.6)
          ..angularVelocity.setZero()
          ..wakeUp();
      }
    }
    if (yUpSubPhysicsWorld case final subW?) {
      final clampedDt = math.min(dt, 1.0 / 30.0);
      if (raycastVehicle case final car?) {
        car.throttle = math.sin(time * 0.9) >= 0 ? 0.65 : -0.55;
        car.steering = 0.25 * math.sin(time * 1.3);
      }
      subW.step(clampedDt);
      if (heightfieldBallBody case final hb?) {
        heightfieldBallMesh?.position.setFrom(hb.bodyPosition);
      }
      if (buoyancyCrateBody case final bc?) {
        buoyancyCrateMesh
          ?..position.setFrom(bc.bodyPosition)
          ..rotation.setFrom(bc.bodyRotation);
      }
      if (raycastVehicle case final car?) {
        vehicleChassisMesh
          ?..position.setFrom(car.chassis.bodyPosition)
          ..rotation.setFrom(car.chassis.bodyRotation);
      }
      xpbdCloth?.step(clampedDt);
      xpbdRope?.step(clampedDt);
    }

    // Lab 20: Step AnimGraph HFSM, FABRIK target, and Ragdoll cycle.
    if (animStateMachine case final sm?) {
      final targetSpeed =
          surfaceSpeedSlider?.value ?? (1.6 + 1.4 * math.sin(time * 0.85));
      sm
        ..setFloat('speed', targetSpeed)
        ..update(dt);
      animGraphActor?.markPoseDirty();
    }
    if (fabrikConstraint case final ik?) {
      final tx = 7.75 + 0.55 * math.cos(time * 1.7);
      final ty = 9.55 + 0.55 * math.sin(time * 1.4);
      final tz = 1.25 + 0.32 * math.sin(time * 2.3);
      ik.targetPosition.setValues(tx, ty, tz);
      fabrikTargetOrb?.position.setValues(tx, ty, tz);
      fabrikTentacleActor?.markPoseDirty();
    }
    if (ragdollController case final rag?) {
      _ragdollCycleTimer += dt;
      if (_ragdollCycleTimer >= 3.2 &&
          rag.mode == RagdollMode3D.kinematicFollow) {
        rag.activateRagdoll(impulse: Vector3(1.2, -0.8, 2.5));
      } else if (_ragdollCycleTimer >= 5.0 &&
          rag.mode == RagdollMode3D.ragdoll) {
        rag.recoverToAnimation();
        _ragdollCycleTimer = 0.0;
      }
      ragdollActor?.markPoseDirty();
    }
    if (gizmoDebugRenderer case final dbg?) {
      dbg.clearCustomSegments();
      sceneInspector?.render(dbg, cameraPosition: Vector3(7.0, -2.0, 9.0));
    }
  }

  // ===========================================================================
  // Procedural Helpers (Humanoid Rig, 6-Joint Tentacle & Meshopt GLB)
  // ===========================================================================

  Model _buildHumanoidRigModel({
    required double scaleFactor,
    required Material material,
  }) {
    final s = scaleFactor;
    final hipMesh = CuboidMesh(
      size: Vector3(0.32 * s, 0.18 * s, 0.22 * s),
      material: material,
    );
    final torsoMesh = CuboidMesh(
      size: Vector3(0.34 * s, 0.36 * s, 0.2 * s),
      material: material,
    );
    final headMesh = SphereMesh(
      radius: 0.13 * s,
      segments: 10,
      material: material,
    );
    final limbMesh = CuboidMesh(
      size: Vector3(0.11 * s, 0.28 * s, 0.11 * s),
      material: material,
    );
    final footMesh = CuboidMesh(
      size: Vector3(0.12 * s, 0.08 * s, 0.2 * s),
      material: material,
    );

    final hipsY = 0.68 * s;
    final thighLen = 0.32 * s;
    final calfLen = 0.32 * s;

    final nodes = <int, ModelNode>{
      0: ModelNode(
        name: 'Hips',
        nodeIndex: 0,
        parentNodeIndex: null,
        transform: Matrix4.translationValues(0, hipsY, 0),
        mesh: hipMesh,
        joints: const {},
      ),
      1: ModelNode(
        name: 'Spine',
        nodeIndex: 1,
        parentNodeIndex: 0,
        transform: Matrix4.translationValues(0, 0.24 * s, 0),
        mesh: torsoMesh,
        joints: const {},
      ),
      2: ModelNode(
        name: 'Head',
        nodeIndex: 2,
        parentNodeIndex: 1,
        transform: Matrix4.translationValues(0, 0.28 * s, 0),
        mesh: headMesh,
        joints: const {},
      ),
      3: ModelNode(
        name: 'LeftUpperLeg',
        nodeIndex: 3,
        parentNodeIndex: 0,
        transform: Matrix4.translationValues(-0.11 * s, -0.04 * s, 0),
        mesh: limbMesh,
        joints: const {},
      ),
      4: ModelNode(
        name: 'LeftLowerLeg',
        nodeIndex: 4,
        parentNodeIndex: 3,
        transform: Matrix4.translationValues(0, -thighLen, 0),
        mesh: limbMesh,
        joints: const {},
      ),
      5: ModelNode(
        name: 'LeftFoot',
        nodeIndex: 5,
        parentNodeIndex: 4,
        transform: Matrix4.translationValues(0, -calfLen, 0.04 * s),
        mesh: footMesh,
        joints: const {},
      ),
      6: ModelNode(
        name: 'RightUpperLeg',
        nodeIndex: 6,
        parentNodeIndex: 0,
        transform: Matrix4.translationValues(0.11 * s, -0.04 * s, 0),
        mesh: limbMesh,
        joints: const {},
      ),
      7: ModelNode(
        name: 'RightLowerLeg',
        nodeIndex: 7,
        parentNodeIndex: 6,
        transform: Matrix4.translationValues(0, -thighLen, 0),
        mesh: limbMesh,
        joints: const {},
      ),
      8: ModelNode(
        name: 'RightFoot',
        nodeIndex: 8,
        parentNodeIndex: 7,
        transform: Matrix4.translationValues(0, -calfLen, 0.04 * s),
        mesh: footMesh,
        joints: const {},
      ),
    };

    Quaternion rotX(double a) => Quaternion.axisAngle(Vector3(1, 0, 0), a);

    ModelAnimation buildClip({
      required String name,
      required double duration,
      required double swing,
      required double strideZ,
      required double bounceY,
    }) {
      final times = [
        0.0,
        duration * 0.25,
        duration * 0.5,
        duration * 0.75,
        duration,
      ];
      final hipsPos = TranslationAnimationSpline.from(
        interpolation: AnimationInterpolation.linear,
        times: [0.0, duration * 0.5, duration],
        values: [
          Vector3(0, hipsY, 0),
          Vector3(0, hipsY + bounceY * s, strideZ * 0.5 * s),
          Vector3(0, hipsY, strideZ * s),
        ],
      );
      final leftThigh = RotationAnimationSpline.from(
        interpolation: AnimationInterpolation.linear,
        times: times,
        values: [rotX(0), rotX(swing), rotX(0), rotX(-swing), rotX(0)],
      );
      final rightThigh = RotationAnimationSpline.from(
        interpolation: AnimationInterpolation.linear,
        times: times,
        values: [rotX(0), rotX(-swing), rotX(0), rotX(swing), rotX(0)],
      );
      return ModelAnimation(
        name: name,
        nodes: {
          0: NodeAnimation(channels: [AnimationController(animation: hipsPos)]),
          3: NodeAnimation(
            channels: [AnimationController(animation: leftThigh)],
          ),
          6: NodeAnimation(
            channels: [AnimationController(animation: rightThigh)],
          ),
        },
      );
    }

    return Model(
      nodes: nodes,
      animations: [
        buildClip(
          name: 'Idle',
          duration: 1.0,
          swing: 0.04,
          strideZ: 0.0,
          bounceY: 0.02,
        ),
        buildClip(
          name: 'Walk',
          duration: 0.8,
          swing: 0.48,
          strideZ: 0.85,
          bounceY: 0.06,
        ),
        buildClip(
          name: 'Run',
          duration: 0.5,
          swing: 0.82,
          strideZ: 1.65,
          bounceY: 0.12,
        ),
        buildClip(
          name: 'Jump',
          duration: 0.6,
          swing: 0.35,
          strideZ: 0.4,
          bounceY: 0.42,
        ),
      ],
    );
  }

  Model _buildSixJointTentacleModel() {
    final segMat = SpatialMaterial(
      albedoColor: const ui.Color(0xFF2DD4BF),
      metallic: 0.35,
      roughness: 0.28,
    )..renderState = const RenderState(cullMode: CullMode.backFace);
    final segMesh = CylinderMesh(
      radius: 0.075,
      height: 0.28,
      segments: 10,
      material: segMat,
    );
    final tipMesh = SphereMesh(
      radius: 0.1,
      segments: 10,
      material: segMat,
    );
    final nodes = <int, ModelNode>{};
    for (var i = 0; i < 6; i++) {
      nodes[i] = ModelNode(
        name: 'Tentacle_$i',
        nodeIndex: i,
        parentNodeIndex: i == 0 ? null : i - 1,
        transform: Matrix4.translationValues(0, i == 0 ? 0.05 : 0.28, 0),
        mesh: i == 5 ? tipMesh : segMesh,
        joints: const {},
      );
    }
    return Model(nodes: nodes, animations: const []);
  }

  /// Encodes a binary `.glb` asset whose `POSITION` (`ATTRIBUTES` +
  /// `EXPONENTIAL` filter) and triangle `indices` (`TRIANGLES`) buffer views
  /// are compressed with `EXT_meshopt_compression`.
  Uint8List buildMeshoptCompressedGlbBytes() {
    final positions = Float32List.fromList([
      0.0, 0.0, 0.72, // apex
      -0.38, -0.38, 0.0,
      0.38, -0.38, 0.0,
      0.38, 0.38, 0.0,
      -0.38, 0.38, 0.0,
    ]);
    final expFilteredPos = MeshoptDecoder3D.encodeFilterExp(
      positions,
      count: 5,
      byteStride: 12,
    );
    final compressedPos = MeshoptDecoder3D.encodeVertexStream(
      expFilteredPos,
      count: 5,
      byteStride: 12,
    );

    final rawIndices = Uint16List.fromList([
      0,
      1,
      2,
      0,
      2,
      3,
      0,
      3,
      4,
      0,
      4,
      1,
      1,
      3,
      2,
      1,
      4,
      3,
    ]);
    final compressedIdx = MeshoptDecoder3D.encodeIndexStream(
      Uint8List.sublistView(rawIndices),
      count: rawIndices.length,
      byteStride: 2,
    );

    final bin = BytesBuilder(copy: false);
    final posOffset = bin.length;
    bin.add(compressedPos);
    while (bin.length % 4 != 0) {
      bin.addByte(0);
    }
    final idxOffset = bin.length;
    bin.add(compressedIdx);
    while (bin.length % 4 != 0) {
      bin.addByte(0);
    }
    final binBytes = bin.takeBytes();

    final gltfJson = <String, Object?>{
      'asset': {'version': '2.0'},
      'extensionsUsed': ['EXT_meshopt_compression'],
      'buffers': [
        {'byteLength': binBytes.length},
      ],
      'bufferViews': [
        {
          'buffer': 0,
          'byteOffset': 0,
          'byteLength': 5 * 12,
          'byteStride': 12,
          'extensions': {
            'EXT_meshopt_compression': {
              'buffer': 0,
              'byteOffset': posOffset,
              'byteLength': compressedPos.length,
              'byteStride': 12,
              'count': 5,
              'mode': 'ATTRIBUTES',
              'filter': 'EXPONENTIAL',
            },
          },
        },
        {
          'buffer': 0,
          'byteOffset': 0,
          'byteLength': rawIndices.length * 2,
          'extensions': {
            'EXT_meshopt_compression': {
              'buffer': 0,
              'byteOffset': idxOffset,
              'byteLength': compressedIdx.length,
              'byteStride': 2,
              'count': rawIndices.length,
              'mode': 'TRIANGLES',
            },
          },
        },
      ],
      'accessors': [
        {
          'bufferView': 0,
          'componentType': 5126, // FLOAT
          'count': 5,
          'type': 'VEC3',
        },
        {
          'bufferView': 1,
          'componentType': 5123, // UNSIGNED_SHORT
          'count': rawIndices.length,
          'type': 'SCALAR',
        },
      ],
      'materials': [
        {
          'name': 'MeshoptCrystalMat',
          'pbrMetallicRoughness': {
            'baseColorFactor': [0.35, 0.92, 0.78, 1.0],
            'metallicFactor': 0.5,
            'roughnessFactor': 0.25,
          },
        },
      ],
      'meshes': [
        {
          'name': 'MeshoptPyramid',
          'primitives': [
            {
              'attributes': {'POSITION': 0},
              'indices': 1,
              'material': 0,
            },
          ],
        },
      ],
      'nodes': [
        {'name': 'MeshoptNode', 'mesh': 0},
      ],
      'scenes': [
        {
          'nodes': [0],
        },
      ],
      'scene': 0,
    };

    final jsonRaw = utf8.encode(jsonEncode(gltfJson));
    final jsonPad = (4 - (jsonRaw.length % 4)) % 4;
    final jsonChunkLen = jsonRaw.length + jsonPad;
    final totalLen = 12 + 8 + jsonChunkLen + 8 + binBytes.length;

    final out = Uint8List(totalLen);
    final header = ByteData.sublistView(out);
    header
      ..setUint32(0, 0x46546C67, Endian.little) // 'glTF'
      ..setUint32(4, 2, Endian.little)
      ..setUint32(8, totalLen, Endian.little)
      ..setUint32(12, jsonChunkLen, Endian.little)
      ..setUint32(16, 0x4E4F534A, Endian.little); // 'JSON'
    out.setRange(20, 20 + jsonRaw.length, jsonRaw);
    for (var i = 0; i < jsonPad; i++) {
      out[20 + jsonRaw.length + i] = 0x20;
    }
    final binChunkHeaderOff = 20 + jsonChunkLen;
    header
      ..setUint32(binChunkHeaderOff, binBytes.length, Endian.little)
      ..setUint32(binChunkHeaderOff + 4, 0x004E4942, Endian.little); // 'BIN\0'
    out.setRange(binChunkHeaderOff + 8, totalLen, binBytes);
    return out;
  }

  // ===========================================================================
  // Automated GPU & Subsystem Self-Tests (Checks 49..64)
  // ===========================================================================

  Future<void> runChecks49To64({
    required ShowcaseGame game,
    required Future<void> Function(int frames) pumpFrames,
    required void Function(
      String id, {
      required bool passed,
      required String detail,
    })
    record,
  }) async {
    // 49. Float16 HDR pipeline + 3D ColorLut3D + RenderDebugMode3D views!
    game.applyPreset(ShowcasePreset.hdrIblShadowAtlasAndOit);
    await pumpFrames(3);
    final hdrWorld = game.dynamicLayer.world;
    final fp16Supported = GpuBackend.instance.supportsPixelFormat(
      GpuPixelFormat.rgbaFloat16,
    );
    final activeLut = hdrWorld.postProcess?.colorLut;
    final idLutSample = ColorLut3D.identity(size: 8).sample(0.25, 0.5, 0.75);
    final lutAccurate =
        activeLut != null &&
        activeLut.size == 16 &&
        (idLutSample.x - 0.25).abs() < 0.02 &&
        (idLutSample.y - 0.5).abs() < 0.02 &&
        (idLutSample.z - 0.75).abs() < 0.02;

    const wireframeState = RenderState(polygonMode: PolygonFillMode.wireframe);
    var debugModesRendered =
        RenderDebugMode3D.values.length >= 9 &&
        wireframeState.polygonMode == PolygonFillMode.wireframe;
    // Exercise shader & additive-blend diagnostic views on the GPU (skipping
    // `VK_POLYGON_MODE_LINE` rasterization here so headless `flutter_tester`'s
    // bundled SwiftShader does not hit its `setupWireframeTriangles` bug).
    for (final dbgMode in const [
      RenderDebugMode3D.normals,
      RenderDebugMode3D.cascadeSplits,
      RenderDebugMode3D.roughnessMetallic,
      RenderDebugMode3D.overdraw,
    ]) {
      game.controller.renderDebugMode = dbgMode;
      game.syncControllerState();
      await pumpFrames(2);
      if (game.dynamicLayer.renderStats.drawCalls <= 0) {
        debugModesRendered = false;
      }
    }
    game.controller.renderDebugMode = RenderDebugMode3D.none;
    game.syncControllerState();
    await pumpFrames(2);
    record(
      'hdr_float16_color_lut_and_debug_modes',
      passed:
          hdrWorld.hdrEnabled &&
          fp16Supported &&
          lutAccurate &&
          debugModesRendered,
      detail:
          'hdr=${hdrWorld.hdrEnabled}, fp16=$fp16Supported, '
          'lut=${activeLut?.size}³, debugModes=$debugModesRendered',
    );

    // 50. Split-sum BrdfLut3D + Box-Parallax ReflectionProbeVolume3D + SH9
    //     LightProbeGrid3D + Clearcoat/Transmission + Tangents + Aniso16x +
    //     Ktx2TextureLoader BC1!
    final brdfTex = BrdfLut3D.sharedTexture(GpuBackend.instance);
    final dfg = BrdfLut3D.integrateBrdf(0.7, 0.25);
    final probeVol = localReflectionProbe;
    final parallaxRay = probeVol?.parallaxCorrectRay(
      Vector3(7.5, 7.0, 1.5),
      Vector3(1.0, 0.0, 0.0),
    );
    final sh9Irr = sh9LightProbeGrid?.sampleIrradiance(
      Vector3(7.0, 7.0, 1.0),
      Vector3(0.0, 0.0, 1.0),
    );
    final pbrExtOk =
        clearcoatSphereMat != null &&
        clearcoatSphereMat!.clearcoat == 1.0 &&
        glassRefractMat != null &&
        glassRefractMat!.transmission > 0.8 &&
        glassRefractMat!.ior > 1.5 &&
        clearcoatTangentSurface != null &&
        clearcoatTangentSurface!.vertexCount > 0 &&
        TextureSampler.anisotropic16x.maxAnisotropy == 16 &&
        ktx2PedestalTexture != null &&
        ktx2PedestalTexture!.width == 16;
    final ktxW = ktx2PedestalTexture?.width;
    record(
      'split_sum_brdf_lut_reflection_probe_and_pbr_ext',
      passed:
          brdfTex.width == 64 &&
          dfg.$1 > 0 &&
          probeVol != null &&
          hdrWorld.reflectionProbes.contains(probeVol) &&
          parallaxRay != null &&
          (parallaxRay.length - 1.0).abs() < 1e-3 &&
          sh9Irr != null &&
          sh9Irr.length > 0 &&
          pbrExtOk,
      detail:
          'brdf=${brdfTex.width}x${brdfTex.height}, '
          'probes=${hdrWorld.reflectionProbes.length}, '
          'sh9=${sh9Irr?.length.toStringAsFixed(2)}, ktx2=${ktxW}px',
    );

    // 51. Unified ShadowAtlas3D: 4-CSM + SpotLight + Dual-Paraboloid Point!
    final shStats = game.dynamicLayer.renderStats;
    final testAtlas = ShadowAtlas3D();
    for (var c = 0; c < 4; c++) {
      testAtlas.allocateTile(
        kind: ShadowAtlasTileKind3D.directionalCascade,
        lightIndex: 0,
        subIndex: c,
        tileSize: 512,
      );
    }
    final spotTile = testAtlas.allocateTile(
      kind: ShadowAtlasTileKind3D.spotLight,
      lightIndex: 1,
      tileSize: 512,
    );
    final ptFront = testAtlas.allocateTile(
      kind: ShadowAtlasTileKind3D.pointParaboloidFront,
      lightIndex: 2,
      tileSize: 512,
    );
    final ptBack = testAtlas.allocateTile(
      kind: ShadowAtlasTileKind3D.pointParaboloidBack,
      lightIndex: 2,
      subIndex: 1,
      tileSize: 512,
    );
    final tileCount = testAtlas.tiles.length;
    record(
      'shadow_atlas_4csm_multi_spot_and_point_paraboloid',
      passed:
          shStats.shadowPasses >= 1 &&
          shStats.shadowDrawCalls >= 7 &&
          tileCount == 7 &&
          spotTile != null &&
          ptFront != null &&
          ptBack != null,
      detail:
          'shadowPasses=${shStats.shadowPasses}, '
          'shadowDraws=${shStats.shadowDrawCalls}, atlasTiles=$tileCount',
    );

    // 52. Weighted Blended OIT + SceneColor Grab-Pass + Stencil + RenderGraph!
    final aliasGraph = RenderGraph3D();
    final tA = aliasGraph.createTexture(
      'a',
      const RenderGraphTextureDesc3D(width: 128, height: 128),
    );
    final tB = aliasGraph.createTexture(
      'b',
      const RenderGraphTextureDesc3D(width: 128, height: 128),
    );
    final tC = aliasGraph.createTexture(
      'c',
      const RenderGraphTextureDesc3D(width: 128, height: 128),
    );
    aliasGraph
      ..addRenderPass(name: 'p0', writes: [tA], execute: (_) {})
      ..addRenderPass(name: 'p1', reads: [tA], writes: [tB], execute: (_) {})
      ..addRenderPass(
        name: 'p2',
        reads: [tB],
        writes: [tC],
        hasSideEffects: true,
        execute: (_) {},
      );
    final plan = aliasGraph.compile();
    final stencilOk =
        stencilMaskMat?.renderState.stencil ==
            const StencilState.writeReference(1) &&
        stencilInnerMat?.renderState.stencil == const StencilState.testEqual(1);
    final poolSlots = plan.physicalTargetCount;
    final virtCount = plan.virtualTextureCount;
    final grabOk = hdrWorld.grabSceneColorEnabled;
    record(
      'wboit_grab_pass_refraction_stencil_and_render_graph',
      passed:
          hdrWorld.oitMode == OitMode3D.weightedBlended &&
          grabOk &&
          shStats.drawCalls >= 6 &&
          stencilOk &&
          plan.executionOrder.length == 3 &&
          poolSlots < virtCount,
      detail:
          'oit=${hdrWorld.oitMode.name}, grab=$grabOk, '
          'draws=${shStats.drawCalls}, pool=$poolSlots/$virtCount',
    );

    // 53. Clustered Forward+ 128 Point & Spot lights!
    game.applyPreset(ShowcasePreset.clusteredOcclusionCdlodAndFoliage);
    await pumpFrames(3);
    final grid = clusterGrid;
    final topLights = grid?.gatherTopLightsForAabb(
      Aabb3.minMax(Vector3(4.5, 4.5, 0.0), Vector3(9.5, 9.5, 2.5)),
      clusterViewMatrix,
    );
    record(
      'clustered_forward_128_lights',
      passed:
          grid != null &&
          grid.lightCount == 128 &&
          grid.totalAssignedLightRefs > 0 &&
          topLights != null &&
          topLights.pointLightIndices.isNotEmpty &&
          topLights.spotLightIndices.isNotEmpty,
      detail:
          'lights=${grid?.lightCount}, refs=${grid?.totalAssignedLightRefs}, '
          'topPt=${topLights?.pointLightIndices.length}, '
          'topSpot=${topLights?.spotLightIndices.length}',
    );

    // 54. Software Hi-Z OcclusionCuller3D + PortalOcclusionGraph3D doors!
    final culler = occlusionCuller;
    final frontVis =
        culler?.isAabbVisible(
          Aabb3.minMax(Vector3(6.6, 7.4, 0.2), Vector3(7.4, 8.1, 0.9)),
          occluderViewProj,
        ) ??
        false;
    final rearVis =
        culler?.isAabbVisible(
          Aabb3.minMax(Vector3(6.72, 10.92, 0.27), Vector3(7.28, 11.48, 0.83)),
          occluderViewProj,
        ) ??
        true;
    final pGraph = portalGraph;
    final door = vaultDoorPortal;
    var openRooms = 0;
    var closedRooms = 0;
    if (pGraph != null && door != null) {
      door.isOpen = true;
      pGraph.evaluateVisibility(
        cameraPosition: Vector3(7.0, 4.2, 1.2),
        viewProjection: occluderViewProj,
        cameraRoomId: 0,
      );
      openRooms = pGraph.visibleRoomIds.length;
      door.isOpen = false;
      pGraph.evaluateVisibility(
        cameraPosition: Vector3(7.0, 4.2, 1.2),
        viewProjection: occluderViewProj,
        cameraRoomId: 0,
      );
      closedRooms = pGraph.visibleRoomIds.length;
      door.isOpen = true;
    }
    record(
      'hi_z_occlusion_culler_and_portal_rooms',
      passed: frontVis && !rearVis && openRooms == 2 && closedRooms == 1,
      detail:
          'frontVis=$frontVis, rearVis=$rearVis, '
          'portalRooms(open=$openRooms, closed=$closedRooms)',
    );

    // 55. 96-Mesh StaticMeshBatcher3D + 64-Bit FloatingOriginController3D!
    final batcher = staticBatcher;
    var surgicalBefore = 0;
    var surgicalAfter = 0;
    if (batcher != null) {
      await pumpFrames(1);
      surgicalBefore = batcher.surgicalUpdateCount;
      batcher.setSlotVisible(0, visible: false);
      surgicalAfter = batcher.surgicalUpdateCount;
      batcher.setSlotVisible(0, visible: true);
    }
    final testOrigin = FloatingOriginController3D(
      initialOrigin: WorldPosition64(250000.0, 250000.0),
      rebaseThreshold: 100.0,
    );
    final relOffset = testOrigin.world64ToLocal(
      WorldPosition64(250003.25, 250001.5, 0.75),
    );
    final precisionError = (relOffset - Vector3(3.25, 1.5, 0.75)).length;
    final probeTarget = MeshComponent(
      mesh: SphereMesh(radius: 0.1, material: UnlitMaterial()),
      position: Vector3(160.0, 0.0, 0.0),
    );
    testOrigin
      ..trackedTarget = probeTarget
      ..update(0.016);
    final batchCnt = batcher?.surfaceBatchCount;
    record(
      'static_mesh_batcher_and_floating_origin_64',
      passed:
          batcher != null &&
          batcher.activeSlotCount == 96 &&
          batchCnt != null &&
          batchCnt <= 4 &&
          surgicalAfter > surgicalBefore &&
          precisionError < 1e-4 &&
          testOrigin.rebaseCount >= 1,
      detail:
          'slots=${batcher?.activeSlotCount}->batches=$batchCnt, '
          'err64=${precisionError.toStringAsExponential(2)}, '
          'rebases=${testOrigin.rebaseCount}',
    );

    // 56. Quadtree CDLOD Terrain + 10,000-Blade Foliage Trample + VolumeDecals!
    final terr = cdlodTerrain;
    final chunks =
        terr?.selectVisibleChunks(cameraPosition: Vector3(1.3, 1.9, 0.2)) ??
        const [];
    final lodSet = {for (final c in chunks) c.lodLevel};
    final hasSkirts = chunks.any((c) => c.skirtTriangleCount > 0);
    final biome = const TerrainBiomePalette3D().evaluateWeights(0.45, 0.9);
    final biomeSum = biome.sand + biome.grass + biome.rock + biome.snow;

    final fol = foliageSystem;
    if (fol != null && foliageInteractor != null) {
      foliageInteractor!.position.setValues(10.2, 4.2, 0.18);
      for (var i = 0; i < 6; i++) {
        fol.update(0.05);
      }
    }
    var maxCrush = 0.0;
    if (fol != null) {
      for (var i = 0; i < fol.bladeCount; i++) {
        final c = fol.bladeCrush(i);
        if (c > maxCrush) {
          maxCrush = c;
        }
      }
    }
    final decalTris = volumeDecalBatch?.generatedTriangleCount ?? 0;
    record(
      'cdlod_terrain_10k_foliage_trample_and_volume_decals',
      passed:
          chunks.isNotEmpty &&
          lodSet.length >= 2 &&
          hasSkirts &&
          (biomeSum - 1.0).abs() < 1e-4 &&
          fol != null &&
          fol.bladeCount >= 10000 &&
          maxCrush > 0.15 &&
          decalTris >= 4,
      detail:
          'chunks=${chunks.length}(lods=${lodSet.length}), '
          'blades=${fol?.bladeCount}, '
          'maxCrush=${maxCrush.toStringAsFixed(2)}, decalTris=$decalTris',
    );

    // 57. DynamicAabbTree3D Overlaps & 120 m/s CCD Zero-Tunneling vs 0.03m Wall!
    game.applyPreset(ShowcasePreset.ccdCompoundClothRecastAndRollback);
    await pumpFrames(3);
    final colSys = ccdCollisionSystem;
    final sphereHits = colSys?.overlapSphere(Vector3(8.6, 10.4, 0.95), 0.8);
    final boxHits = colSys?.overlapBox(
      Vector3(8.6, 10.4, 1.0),
      Vector3(0.6, 0.9, 0.8),
    );

    final ccdTestWorld = PhysicsWorld3D(gravity: Vector3.zero());
    final thinBarrier = RigidBody3D(
      shape: BoxShape3D(halfExtents: Vector3(0.015, 2.0, 2.0)),
      bodyType: BodyType3D.static,
      syncParent: false,
      position: Vector3(1.5, 0.0, 0.0),
    );
    final fastBullet = RigidBody3D(
      shape: SphereShape3D(radius: 0.14),
      ccdEnabled: true,
      canSleep: false,
      syncParent: false,
      position: Vector3.zero(),
      linearVelocity: Vector3(120.0, 0.0, 0.0),
    );
    ccdTestWorld
      ..addBody(thinBarrier)
      ..addBody(fastBullet);
    for (var i = 0; i < 4; i++) {
      ccdTestWorld.step(1.0 / 60.0);
    }
    final stoppedBeforeWall = fastBullet.bodyPosition.x < 1.5;
    record(
      'dynamic_bvh_overlaps_and_ccd_zero_tunneling',
      passed:
          sphereHits != null &&
          sphereHits.isNotEmpty &&
          boxHits != null &&
          boxHits.isNotEmpty &&
          stoppedBeforeWall,
      detail:
          'overlapSphere=${sphereHits?.length}, overlapBox=${boxHits?.length}, '
          'bulletX=${fastBullet.bodyPosition.x.toStringAsFixed(3)} (<1.5)',
    );

    // 58. CompoundShape3D Parallel-Axis Inertia + Heightfield O(1) + Materials!
    final comp = compoundArchShape;
    final compDiag = comp?.computeLocalInertiaDiagonal(4.5);
    final singleBoxDiag = BoxShape3D(
      halfExtents: Vector3(0.75, 0.38, 0.1),
    ).computeLocalInertiaDiagonal(4.5);

    final hfWorld = PhysicsWorld3D();
    final flatHf = HeightfieldShape3D(
      heights: Float32List(16)..fillRange(0, 16, 0.25),
      columns: 4,
      rows: 4,
      width: 4.0,
      depth: 4.0,
    );
    final hfDropBall = RigidBody3D(
      shape: SphereShape3D(radius: 0.2),
      syncParent: false,
      position: Vector3(0.0, 0.85, 0.0),
    );
    hfWorld
      ..addBody(
        RigidBody3D(
          shape: flatHf,
          bodyType: BodyType3D.static,
          syncParent: false,
        ),
      )
      ..addBody(hfDropBall);
    for (var i = 0; i < 45; i++) {
      hfWorld.step(1.0 / 60.0);
    }
    const matA = PhysicsMaterial3D(
      friction: 0.8,
      frictionCombine: PhysicsCombineMode3D.multiply,
    );
    const matB = PhysicsMaterial3D(
      restitution: 0.9,
    );
    final combFric = PhysicsMaterial3D.combineFriction(matA, matB);
    final combRest = PhysicsMaterial3D.combineRestitution(matA, matB);
    record(
      'compound_huygens_heightfield_and_physics_materials',
      passed:
          comp != null &&
          comp.children.length == 3 &&
          compDiag != null &&
          compDiag.y > singleBoxDiag.y &&
          hfDropBall.bodyPosition.y > 0.38 &&
          (combFric - 0.4).abs() < 1e-5 &&
          (combRest - 0.9).abs() < 1e-5,
      detail:
          'compoundChildren=${comp?.children.length}, '
          'hfBallY=${hfDropBall.bodyPosition.y.toStringAsFixed(2)}, '
          'fric=$combFric, rest=$combRest',
    );

    // 59. Fixed/Slider/ConeTwist/6DOF Joints + Buoyancy + Vehicle + XPBD Cloth!
    if (yUpSubPhysicsWorld case final subW?) {
      raycastVehicle?.throttle = 0.85;
      for (var i = 0; i < 20; i++) {
        subW.step(1.0 / 60.0);
        xpbdCloth?.step(1.0 / 60.0);
        xpbdRope?.step(1.0 / 60.0);
      }
    }
    final crateY = buoyancyCrateBody?.bodyPosition.y ?? -99.0;
    final carSpeed = raycastVehicle?.forwardSpeed ?? 0.0;
    final carGrounded = raycastVehicle?.groundedWheelCount ?? 0;
    final ropeTip = xpbdRope?.getParticlePosition(xpbdRope!.particleCount - 1);
    final jointsValid =
        fixedJoint != null &&
        sliderJoint != null &&
        sliderJoint!.currentDistance >= -0.7 &&
        sliderJoint!.currentDistance <= 0.2 &&
        coneTwistJoint != null &&
        coneTwistJoint!.swingAngle <= 0.75 &&
        generic6DofJoint != null;
    record(
      'joints_6dof_buoyancy_vehicle_and_xpbd_cloth',
      passed:
          jointsValid &&
          crateY > 0.35 &&
          carGrounded >= 2 &&
          carSpeed > 0.05 &&
          xpbdCloth != null &&
          xpbdCloth!.surface.vertexCount == 100 &&
          ropeTip != null &&
          ropeTip.x.isFinite,
      detail:
          'jointsOk=$jointsValid, buoyY=${crateY.toStringAsFixed(2)}, '
          'wheels=$carGrounded(v=${carSpeed.toStringAsFixed(2)}), '
          'clothV=${xpbdCloth?.surface.vertexCount}',
    );

    // 60. Recast NavMeshBuilder3D + Gate Carving + OffMeshLink3D + Rollback!
    final nav = recastNavMesh;
    final obs = gateNavObstacle;
    var pathOpenOk = false;
    var pathBlockedOk = false;
    var jumpLinkUsed = false;
    if (nav != null && obs != null) {
      obs.enabled = false;
      nav.updateObstacle(obs);
      final openPath = nav.findPath(
        Vector3(-1.4, 0.15, 0.0),
        Vector3(1.4, 0.15, 0.0),
      );
      pathOpenOk = openPath.length >= 2;

      obs.enabled = true;
      nav.updateObstacle(obs);
      final blockedPath = nav.findPath(
        Vector3(-1.4, 0.15, 0.0),
        Vector3(1.4, 0.15, 0.0),
      );
      pathBlockedOk = blockedPath.isEmpty;
      obs.enabled = false;
      nav.updateObstacle(obs);

      final segs = nav.findSegmentedPath(
        Vector3(-1.2, 0.15, 0.0),
        Vector3(5.8, 0.5, 0.0),
      );
      jumpLinkUsed = segs.any((s) => s.isOffMeshLink && s.linkTag == 'jump');
    }

    final rbWorld = PhysicsWorld3D();
    final rbBall = RigidBody3D(
      shape: SphereShape3D(radius: 0.25),
      canSleep: false,
      syncParent: false,
      position: Vector3(0.0, 3.0, 0.0),
      linearVelocity: Vector3(1.5, 0.0, -0.5),
    );
    rbWorld
      ..addBody(rbBall)
      ..step(1.0 / 60.0);
    final ring = PhysicsSnapshotRingBuffer3D(capacity: 8);
    final t0 = rbWorld.tick;
    final snapBytes = ring.capture(rbWorld);
    for (var i = 0; i < 10; i++) {
      rbWorld.step(1.0 / 60.0);
    }
    final posRun1 = rbBall.bodyPosition.clone();
    final velRun1 = rbBall.linearVelocity.clone();
    final rolledBack = ring.rollbackToTick(rbWorld, t0);
    for (var i = 0; i < 10; i++) {
      rbWorld.step(1.0 / 60.0);
    }
    final exactMatch =
        rolledBack &&
        PhysicsSnapshot3D.verifyChecksum(snapBytes) &&
        rbBall.bodyPosition.distanceTo(posRun1) == 0.0 &&
        rbBall.linearVelocity.distanceTo(velRun1) == 0.0;
    record(
      'recast_voxel_navmesh_carving_offmesh_and_rollback',
      passed:
          nav != null &&
          nav.polygons.isNotEmpty &&
          pathOpenOk &&
          pathBlockedOk &&
          jumpLinkUsed &&
          exactMatch,
      detail:
          'polys=${nav?.polygons.length}, open=$pathOpenOk, '
          'carvedBlock=$pathBlockedOk, jumpLink=$jumpLinkUsed, '
          'crcRollback=$exactMatch',
    );

    // 61. AnimationStateMachine3D HFSM + Humanoid Retargeting!
    game.applyPreset(ShowcasePreset.animGraphRetargetRagdollUiAndGizmo);
    await pumpFrames(3);
    final sm = animStateMachine;
    var hfsmOk = false;
    if (sm != null) {
      sm
        ..forceState('locomotion')
        ..setFloat('speed', 1.0)
        ..update(0.2);
      sm
        ..setFloat('speed', 3.0)
        ..update(0.01);
      final ranState = sm.currentStateName == 'run';
      sm
        ..setTrigger('jump')
        ..update(0.01);
      final jumpedAndConsumed =
          sm.currentStateName == 'jump' && !sm.isTriggerSet('jump');
      hfsmOk = ranState && jumpedAndConsumed;
    }

    var retargetScaleRatio = 0.0;
    final shortActor = shortHumanoidActor;
    final tallActor = tallHumanoidActor;
    final shortClip = shortRetargetedClip;
    final tallClip = tallRetargetedClip;
    if (shortActor != null &&
        tallActor != null &&
        shortClip != null &&
        tallClip != null) {
      final sState = AnimationState()
        ..startAnimation(shortClip)
        ..clock = 0.8;
      final tState = AnimationState()
        ..startAnimation(tallClip)
        ..clock = 0.8;
      final sWs = ModelPoseWorkspace.forModel(shortActor.model);
      final tWs = ModelPoseWorkspace.forModel(tallActor.model);
      shortActor.model.evaluateInto(sState, sWs);
      tallActor.model.evaluateInto(tState, tWs);
      final shortZ = sWs.nodesByIndex[0]!.combinedTransform.storage[14];
      final tallZ = tWs.nodesByIndex[0]!.combinedTransform.storage[14];
      if (shortZ.abs() > 1e-5) {
        retargetScaleRatio = tallZ / shortZ;
      }
    }
    const expectedRatio = 1.35 / 0.7;
    final ratioStr = retargetScaleRatio.toStringAsFixed(3);
    final expStr = expectedRatio.toStringAsFixed(3);
    record(
      'anim_state_machine_hfsm_and_humanoid_retargeting',
      passed: hfsmOk && (retargetScaleRatio - expectedRatio).abs() < 0.08,
      detail: 'hfsmOk=$hfsmOk, retargetRatio=$ratioStr (expected $expStr)',
    );

    // 62. 6-Bone FABRIK IK + Terrain FootPlacementIk3D + Ragdoll Recovery!
    var fabrikTipErr = 99.0;
    if (fabrikTentacleActor != null && fabrikConstraint != null) {
      final goal = Vector3(7.85, 9.45, 1.32);
      fabrikConstraint!.targetPosition.setFrom(goal);
      fabrikTentacleActor!.markPoseDirty();
      final ws = fabrikTentacleActor!.evaluatePose();
      final tipWorld = fabrikTentacleActor!.worldTransformMatrix.clone()
        ..multiply(ws.nodesByIndex[5]!.combinedTransform);
      fabrikTipErr = tipWorld.getTranslation().distanceTo(goal);
    }

    if (footIkActor != null) {
      for (var i = 0; i < 6; i++) {
        footIkActor!
          ..update(0.05)
          ..markPoseDirty()
          ..evaluatePose();
      }
    }
    final pelvisDrop = footPlacementIk?.hipsOffsetY ?? 0.0;

    var ragdollRecovered = false;
    if (ragdollController case final rag?) {
      rag.activateRagdoll(impulse: Vector3(0.5, 0.0, -1.5));
      final enteredRagdoll = rag.mode == RagdollMode3D.ragdoll;
      for (var i = 0; i < 8; i++) {
        ragdollPhysicsWorld?.step(1.0 / 60.0);
      }
      rag.syncFromPhysics();
      rag.recoverToAnimation(blendDuration: 0.25);
      final enteredRecovering = rag.mode == RagdollMode3D.recoveringToAnimation;
      ragdollActor!
        ..update(0.3)
        ..markPoseDirty()
        ..evaluatePose();
      ragdollRecovered =
          enteredRagdoll &&
          enteredRecovering &&
          rag.mode == RagdollMode3D.kinematicFollow;
    }
    record(
      'fabrik_ik_foot_placement_and_ragdoll_recovery',
      passed: fabrikTipErr < 0.08 && pelvisDrop < -0.01 && ragdollRecovered,
      detail:
          'fabrikErr=${fabrikTipErr.toStringAsFixed(4)}, '
          'pelvisDrop=${pelvisDrop.toStringAsFixed(3)}, '
          'ragdollRecovered=$ragdollRecovered',
    );

    // 63. Component3D.visible + PrefabRegistry3D + F3DS Binary Serializer +
    //     GpuResourceManager3D LRU + CameraStack3D & VirtualCameraBrain3D!
    final grp = toggleSubtreeGroup;
    var visSubtreeOk = false;
    if (grp != null && grp.children.isNotEmpty) {
      final child = grp.children.first as Component3D;
      grp.visible = false;
      final hidden = !child.isEffectivelyVisible;
      grp.visible = true;
      visSubtreeOk = hidden && child.isEffectivelyVisible;
    }

    final f3dsBytes = cachedBinarySceneBytes;
    final restoredWorld = World3D();
    var binaryCorruptCaught = false;
    if (f3dsBytes != null) {
      sceneSerializer!.decodeBinaryInto(f3dsBytes, restoredWorld);
      final corrupted = Uint8List.fromList(f3dsBytes);
      corrupted[corrupted.length - 1] ^= 0xFF;
      try {
        sceneSerializer!.decodeBinaryInto(corrupted, World3D());
      } on FormatException {
        binaryCorruptCaught = true;
      }
    }

    final vramMgr = GpuResourceManager3D(maxVramBytes: 512);
    final l1 = vramMgr.acquire<Texture>(
      't1',
      () => Texture(ByteData(64), width: 4, height: 4),
      estimatedBytes: 300,
    );
    l1.release();
    final l2 = vramMgr.acquire<Texture>(
      't2',
      () => Texture(ByteData(64), width: 4, height: 4),
      estimatedBytes: 300,
    );
    final lruEvicted = vramMgr.evictionCount >= 1 && !vramMgr.containsKey('t1');
    l2.release();
    final recoveredHooks = deviceLossRecovery?.recoverAll() ?? 0;

    final camL = CameraComponent3D(position: Vector3(-4, 3, 6));
    final camR = CameraComponent3D(position: Vector3(4, 3, 6));
    final camOverlay = CameraComponent3D(position: Vector3(0, 1, 3));
    final stack = CameraStack3D.splitHorizontal(camL, camR)
      ..addSlot(
        CameraViewportSlot3D(
          camera: camOverlay,
          clearMode: CameraClearMode3D.depthOnly,
          priority: 10,
        ),
      );
    final vcamA = VirtualCamera3D(position: Vector3(0, 2, 8), fovY: 50.0);
    final vcamB = VirtualCamera3D(position: Vector3(6, 4, 6), fovY: 68.0);
    final outCam = CameraComponent3D();
    final brain = VirtualCameraBrain3D(
      camera: outCam,
      cameras: [vcamA, vcamB],
      blendDuration: 0.4,
    );
    final actorDummy = Group3D();
    final timeline = Timeline3D(
      tracks: [
        CameraShotTrack3D(
          shots: [
            CameraShot3D(camera: vcamA, startTime: 0.0, endTime: 1.0),
            CameraShot3D(camera: vcamB, startTime: 1.0, endTime: 2.0),
          ],
        ),
        TransformTrack3D(
          target: actorDummy,
          positionKeys: [
            TransformKeyframe3D(time: 0.0, value: Vector3.zero()),
            TransformKeyframe3D(time: 2.0, value: Vector3(4.0, 0.0, 0.0)),
          ],
        ),
      ],
      autoPlay: true,
    )..seek(0.2);
    brain.evaluate(0.016);
    final shotAOk = identical(brain.activeCamera, vcamA);
    timeline.seek(1.5);
    brain.evaluate(0.5);
    final shotBOk =
        identical(brain.activeCamera, vcamB) && actorDummy.position.x > 2.5;
    record(
      'visibility_prefab_binary_serializer_vram_and_multicam',
      passed:
          visSubtreeOk &&
          restoredWorld.children.isNotEmpty &&
          binaryCorruptCaught &&
          lruEvicted &&
          recoveredHooks >= 1 &&
          stack.slots.length == 3 &&
          shotAOk &&
          shotBOk,
      detail:
          'vis=$visSubtreeOk, f3ds=${f3dsBytes?.length}B, '
          'evictions=${vramMgr.evictionCount}, slots=${stack.slots.length}, '
          'brain=${shotAOk && shotBOk}',
    );

    // 64. 1-Draw MsdfTextBatch3D + WidgetSurface3D UV Tap + Meshopt GLB &
    //     WorldChunkStreamer3D + SpatialAudioMixer3D + TransformGizmo3D Undo!
    final msdfOk =
        msdfTextBatch != null &&
        msdfTextBatch!.textCount >= 4 &&
        msdfTextBatch!.glyphCount >= 20;

    final panel = diegeticControlSurface;
    final clicksBefore = panelButtonClicks;
    if (panel != null) {
      final u = 133.0 / panel.pixelWidth;
      final v = 117.0 / panel.pixelHeight;
      final localX = (u - 0.5) * panel.width;
      final localY = (0.5 - v) * panel.height;
      final worldHitPt = panel.worldTransformMatrix.transformed3(
        Vector3(localX, localY, 0.0),
      );
      final fakeRay = Ray.originDirection(
        worldHitPt + Vector3(0, -1.0, 0),
        Vector3(0, 1.0, 0),
      );
      final hit = panel.raycast(fakeRay);
      panel
        ..onTapDown3D(
          TapDownEvent3D(
            pointerId: 1,
            localPosition: Vector2.zero(),
            worldRay: fakeRay,
            target: panel,
            hit: hit,
          ),
        )
        ..onTapUp3D(
          TapUpEvent3D(
            pointerId: 1,
            localPosition: Vector2.zero(),
            worldRay: fakeRay,
            target: panel,
            hit: hit,
          ),
        );
    }
    final uiClicked = panelButtonClicks > clicksBefore;

    await chunkStreamer?.flushPending();
    final streamerOk =
        meshoptLoadedScene != null &&
        chunkStreamer != null &&
        chunkStreamer!.activeChunks.isNotEmpty;

    spatialAudioMixer?.update(0.25);
    final mixer = spatialAudioMixer;
    final occParams = pooledEmitters.length >= 2
        ? mixer?.voiceParamsFor(pooledEmitters[1])
        : null;
    final audioOk =
        mixer != null &&
        mixer.realVoiceCount == 2 &&
        mixer.virtualVoiceCount >= 2 &&
        occParams != null &&
        occParams.occlusion > 0.5 &&
        mixer.currentReverb.wetMix > 0.1;

    var gizmoUndoRedoOk = false;
    final gizmo = transformGizmo;
    final cube = gizmoTargetCube;
    if (gizmo != null && cube != null) {
      final startX = cube.position.x;
      final r0 = Ray.originDirection(
        Vector3(startX + 0.5, 2.0, 0.45),
        Vector3(0.0, 1.0, 0.0),
      );
      final r1 = Ray.originDirection(
        Vector3(startX + 1.35, 2.0, 0.45),
        Vector3(0.0, 1.0, 0.0),
      );
      gizmo
        ..beginDrag(r0, axis: GizmoAxis3D.x)
        ..updateDrag(r1)
        ..endDrag();
      final draggedX = cube.position.x;
      final undone = gizmo.history.undo();
      final undoneX = cube.position.x;
      final redone = gizmo.history.redo();
      final redoneX = cube.position.x;
      gizmoUndoRedoOk =
          (draggedX - startX).abs() > 0.4 &&
          undone &&
          (undoneX - startX).abs() < 1e-4 &&
          redone &&
          (redoneX - draggedX).abs() < 1e-4;
    }
    record(
      'msdf_text_widget_surface_meshopt_audio_mixer_and_gizmo',
      passed: msdfOk && uiClicked && streamerOk && audioOk && gizmoUndoRedoOk,
      detail:
          'msdfGlyphs=${msdfTextBatch?.glyphCount}, uiTap=$uiClicked, '
          'chunks=${chunkStreamer?.activeChunks.length}, '
          'voices=${mixer?.realVoiceCount}R/${mixer?.virtualVoiceCount}V, '
          'gizmoUndoRedo=$gizmoUndoRedoOk',
    );
  }
}
