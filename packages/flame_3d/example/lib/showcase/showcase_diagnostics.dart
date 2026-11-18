import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/model.dart';
import 'package:flame_3d/particles.dart';
import 'package:flame_3d/resources.dart';
import 'package:flame_3d_example/showcase/pure_camera_lab_game.dart';
import 'package:flame_3d_example/showcase/showcase_game.dart';
import 'package:flame_3d_example/showcase/showcase_variations.dart';

/// Result of a single subsystem check executed by [ShowcaseDiagnostics].
class DiagnosticCheckResult({
  required final String id,
  required final String title,
  required final bool passed,
  required final String detail,
}) {
  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'passed': passed,
    'detail': detail,
  };
}

/// Complete report returned by [ShowcaseDiagnostics.runAllChecks].
class ShowcaseDiagnosticReport({
  required final List<DiagnosticCheckResult> results,
  required final Duration elapsed,
}) {
  int get passedCount => results.where((r) => r.passed).length;
  int get totalCount => results.length;
  bool get allPassed => passedCount == totalCount;

  Map<String, Object?> toJson() => {
    'all_passed': allPassed,
    'passed_count': passedCount,
    'total_count': totalCount,
    'elapsed_ms': elapsed.inMicroseconds / 1000.0,
    'checks': [for (final r in results) r.toJson()],
  };
}

/// Automated 24-point functional & rendering health suite for
/// `package:flame_3d`.
///
/// Exercises all 8 [ShowcasePreset] feature labs plus [PureCameraLabGame], both
/// interactively on desktop/mobile and headlessly under
/// `flutter test --enable-impeller --enable-flutter-gpu`.
class ShowcaseDiagnostics() {
  static Future<ShowcaseDiagnosticReport> runAllChecks(
    ShowcaseGame game, {
    required Future<void> Function() pumpFrame,
    Future<ByteData?> Function(ui.Image image)? readImageBytes,
    Future<T?> Function<T>(Future<T> Function() task)? runAsyncHost,
  }) async {
    final sw = Stopwatch()..start();
    final results = <DiagnosticCheckResult>[];

    final ctrl = game.controller;
    final rig = game.variationRig;

    final savedPreset = ctrl.preset;
    final savedOrbit = ctrl.autoOrbitCamera;
    final savedWind = ctrl.wind;
    final savedRetained = ctrl.retainedStaticLayer;
    final savedShadowCache = ctrl.staticShadowCache;
    final savedSharedShadow = ctrl.sharedShadowGroup;
    final savedBloom = ctrl.bloom;
    final savedFog = ctrl.fog;
    final savedOutlines = ctrl.outlines;
    final savedParticles = ctrl.particles;
    final savedRibbons = ctrl.ribbonsAndDecals;
    final savedStress = ctrl.stressInstances;
    final savedEncoding = ctrl.shadowEncoding;
    final savedFit = ctrl.shadowFit;
    final savedSoftness = ctrl.shadowSoftness;
    final savedScale = ctrl.renderScale;
    final savedPlayMode = ctrl.playMode;
    final savedSpeed = ctrl.animSpeed;
    final savedZoom = game.camera.viewfinder.zoom;
    final savedPos = game.camera.viewfinder.position.clone();

    void record(
      String id,
      String title, {
      required bool ok,
      required String detail,
    }) {
      results.add(
        DiagnosticCheckResult(
          id: id,
          title: title,
          passed: ok,
          detail: detail,
        ),
      );
    }

    void renderPureLab(PureCameraLabGame lab) {
      final rec = ui.PictureRecorder();
      lab.render(ui.Canvas(rec));
      rec.endRecording().dispose();
    }

    try {
      if (runAsyncHost != null) {
        await runAsyncHost(game.preloadVariationAssets);
      } else {
        await game.preloadVariationAssets();
      }

      // 1. GPU backend & shader library readiness.
      final gpuReady = GpuBackend.isAvailable && game.isLoaded;
      record(
        'gpu_backend',
        'Flutter GPU Backend & Shaders',
        ok: gpuReady,
        detail:
            'isAvailable=${GpuBackend.isAvailable}, isLoaded=${game.isLoaded}',
      );

      // --- LAB 1: All-in-One ---
      game.applyPreset(ShowcasePreset.allInOne);
      ctrl
        ..autoOrbitCamera = false
        ..wind = false
        ..retainedStaticLayer = false
        ..staticShadowCache = true
        ..sharedShadowGroup = false
        ..bloom = true
        ..fog = true
        ..outlines = true
        ..particles = true
        ..ribbonsAndDecals = true
        ..stressInstances = false
        ..shadowEncoding = ShadowMapEncoding.auto
        ..shadowFit = ShadowFit.scene
        ..shadowSoftness = 1
        ..renderScale = 1.0
        ..animSpeed = 1.0;
      const halfBoard = ShowcaseGame.boardCells / 2;
      game.camera.viewfinder
        ..zoom = 1.0
        ..position = game.staticLayer.scenePointToLocal(
          Vector3(halfBoard, halfBoard, 0.5),
        );
      game.syncControllerState();
      await pumpFrame();
      await pumpFrame();

      // 2. InstancedGroup3D + 16-color accentPalette batching.
      final statStats = game.staticLayer.renderStats;
      final instCount = game.tileInstances.length;
      final batchedOk =
          instCount == 144 &&
          statStats.instances >= 144 &&
          statStats.drawCalls <= 16;
      record(
        'instanced_palette_batching',
        'InstancedGroup3D + 16-Accent Palette Batch',
        ok: batchedOk,
        detail:
            'tileInstances=$instCount, staticDraws=${statStats.drawCalls}, '
            'staticInstances=${statStats.instances}',
      );

      // 3. Static Shadow Map Caching (`ShadowSettings.cacheWhenStatic`).
      final shadowCachedOk =
          statStats.renderPasses == 1 &&
          statStats.shadowPasses == 0 &&
          game.staticLayer.context.hasActiveShadows;
      record(
        'static_shadow_cache',
        'ShadowSettings.cacheWhenStatic (0 Shadow Passes)',
        ok: shadowCachedOk,
        detail:
            'renderPasses=${statStats.renderPasses}, '
            'shadowPasses=${statStats.shadowPasses}, '
            'hasActiveShadows=${game.staticLayer.context.hasActiveShadows}',
      );

      // 4. Retained 3D Layer Caching (`Scene3DCacheMode.retained`).
      ctrl.retainedStaticLayer = true;
      game.syncControllerState();
      final hitsBefore = game.staticLayer.cacheHitCount;
      await pumpFrame();
      await pumpFrame();
      await pumpFrame();
      final hitsDelta = game.staticLayer.cacheHitCount - hitsBefore;
      final retainedPasses = game.staticLayer.renderStats.renderPasses;
      record(
        'retained_layer_cache',
        'Scene3DCacheMode.retained (0 GPU Passes on Clean Frame)',
        ok: hitsDelta >= 2 && retainedPasses == 0,
        detail: 'cacheHitsDelta=$hitsDelta, staticRenderPasses=$retainedPasses',
      );

      // 5. `LodMeshComponent` tier switching across camera zoom.
      final tower = game.lodTowers.first;
      game.camera.viewfinder
        ..position = game.staticLayer.scenePointToLocal(tower.position)
        ..zoom = 2.4;
      ctrl.retainedStaticLayer = false;
      game.syncControllerState();
      await pumpFrame();
      final nearLod = tower.lastSelectedLevel;

      game.camera.viewfinder.zoom = 0.35;
      await pumpFrame();
      final farLod = tower.lastSelectedLevel;
      game.camera.viewfinder
        ..zoom = 1.0
        ..position = game.staticLayer.scenePointToLocal(
          Vector3(halfBoard, halfBoard, 0.5),
        );
      record(
        'lod_switching',
        'LodMeshComponent Distance / Screen-Coverage Tiers',
        ok: farLod > nearLod,
        detail: 'nearZoomLod=$nearLod -> farZoomLod=$farLod',
      );

      // 6. Skeletal `AnimationPlayMode` (`once`/`pingPong`/`loop`), Crossfade &
      //    `BoneSocket3D`.
      final tipBefore = Vector3(
        game.armTipSocket.worldTransformMatrix.storage[12],
        game.armTipSocket.worldTransformMatrix.storage[13],
        game.armTipSocket.worldTransformMatrix.storage[14],
      );
      game.crossFadeNextClip(duration: 0.25);
      final crossFadingStarted = game.automaton.animationState.isCrossFading;
      for (var i = 0; i < 6; i++) {
        await pumpFrame();
      }
      final tipAfter = Vector3(
        game.armTipSocket.worldTransformMatrix.storage[12],
        game.armTipSocket.worldTransformMatrix.storage[13],
        game.armTipSocket.worldTransformMatrix.storage[14],
      );
      final tipMoved = tipAfter.distanceTo(tipBefore) > 1e-3;

      var onceCompleted = false;
      ctrl.animSpeed = 24.0;
      game.syncControllerState();
      game.automaton.playAnimationByName(
        'Spin',
        mode: AnimationPlayMode.once,
        onComplete: () => onceCompleted = true,
      );
      for (var i = 0; i < 6; i++) {
        await pumpFrame();
      }
      game.automaton.playAnimationByName(
        'Swing',
        mode: AnimationPlayMode.pingPong,
      );
      final pingPongOk =
          game.automaton.animationState.mode == AnimationPlayMode.pingPong;
      ctrl.animSpeed = 1.0;
      game.automaton.playAnimationByName('Idle');
      game.syncControllerState();
      record(
        'animation_modes_crossfade_socket',
        'AnimationPlayMode (once/pingPong/loop), Crossfade & BoneSocket3D',
        ok: crossFadingStarted && tipMoved && onceCompleted && pingPongOk,
        detail:
            'crossFade=$crossFadingStarted, tipMoved=$tipMoved, '
            'onceDone=$onceCompleted, pingPong=$pingPongOk',
      );

      // 7. Static & Skinned `OutlineMaterial` inverted-hull silhouettes.
      await pumpFrame();
      final dynStatsAllInOne = game.dynamicLayer.renderStats;
      final outlinesOk =
          ctrl.outlines &&
          game.automatonOutline.scale.x > 0.9 &&
          game.orbitingSentinelOutline.scale.x > 0.9 &&
          dynStatsAllInOne.drawCalls >= 4;
      record(
        'outlines_static_and_skinned',
        'OutlineMaterial (Static + 4-Joint Skinned)',
        ok: outlinesOk,
        detail:
            'dynamicDraws=${dynStatsAllInOne.drawCalls}, '
            'dynamicTris=${dynStatsAllInOne.triangles}',
      );

      // --- LAB 2: Materials, Grading, Depth-Prepass Ghost & Mirror Scale ---
      game.applyPreset(ShowcasePreset.materialsAndGrading);
      await pumpFrame();
      await pumpFrame();

      // 8. Flat `SurfaceBvh` raycasting + Negative Mirror Scale (`-1, 1, 1`).
      final normHit = rig.normalMonument?.raycast(
        Ray.originDirection(Vector3(3.45, 10.6, 2.5), Vector3(0, 0, -1)),
      );
      final mirrorHit = rig.mirroredMonument?.raycast(
        Ray.originDirection(Vector3(4.05, 10.6, 2.5), Vector3(0, 0, -1)),
      );
      final mirrorMiss = rig.mirroredMonument?.raycast(
        Ray.originDirection(Vector3(4.95, 10.6, 2.5), Vector3(0, 0, -1)),
      );
      final sceneHit = game.pickAtLocalPoint(
        game.staticLayer.scenePointToLocal(Vector3(3.3, 10.6, 1.0)),
      );
      final bvhMirrorOk =
          normHit != null &&
          mirrorHit != null &&
          mirrorMiss == null &&
          (mirrorHit.worldNormal.z - 1.0).abs() < 1e-2 &&
          sceneHit != null;
      record(
        'bvh_raycasting_and_mirror_scale',
        'SurfaceBvh Narrowphase & Negative Mirror Scale (-1, 1, 1)',
        ok: bvhMirrorOk,
        detail:
            'normHit=${normHit != null}, mirrorHit=${mirrorHit != null}, '
            'mirrorMiss=${mirrorMiss == null}, sceneHit=${sceneHit != null}',
      );

      // 9. Depth-Prepass single-piece translucent fade vs naive ghost.
      final ghostOk =
          rig.depthPrepassGhost != null &&
          rig.naiveGhost != null &&
          rig.depthPrepassGhost!.isMounted &&
          game.dynamicLayer.renderStats.drawCalls >= 4;
      record(
        'depth_prepass_translucent_fade',
        'RenderState.depthOnly Prepass + Seamless Translucent Fade',
        ok: ghostOk,
        detail:
            'ghostFade=${rig.depthPrepassGhost?.fade.toStringAsFixed(2)}, '
            'dynamicDraws=${game.dynamicLayer.renderStats.drawCalls}',
      );

      // 10. StylizedMaterial color grading (saturation 0 / 1.65 / overlay /
      //     metallic MatCap).
      final matStats = game.staticLayer.renderStats;
      final gradingOk = matStats.drawCalls >= 12 && matStats.triangles >= 1000;
      record(
        'stylized_color_grading_and_metallic',
        'StylizedMaterial Color Grading (Saturation/Overlay/Metallic)',
        ok: gradingOk,
        detail:
            'staticDraws=${matStats.drawCalls}, '
            'staticTris=${matStats.triangles}',
      );

      // 11. SpatialMaterial 3x3 PBR grid + TextureSampler wrap/filter modes.
      final samplersOk =
          rig.staticExtras.length >= 17 && matStats.renderPasses >= 1;
      record(
        'spatial_pbr_and_samplers',
        'SpatialMaterial 3x3 PBR & Samplers (repeat/mirror/clamp)',
        ok: samplersOk,
        detail:
            'staticExtras=${rig.staticExtras.length}, '
            'passes=${matStats.renderPasses}',
      );

      // 12. Zero-copy `ImageTexture.create` from `ui.PictureRecorder` Canvas.
      final bannerTex = rig.canvasBannerTexture;
      final imgTexOk =
          bannerTex != null && bannerTex.width == 128 && bannerTex.height == 64;
      record(
        'zero_copy_image_texture',
        'Canvas Picture -> Zero-Copy ImageTexture.create',
        ok: imgTexOk,
        detail:
            'width=${bannerTex?.width ?? 0}, height=${bannerTex?.height ?? 0}',
      );

      // --- LAB 3: Wind v2 Spaces ---
      game.applyPreset(ShowcasePreset.windSpaces);
      await pumpFrame();
      await pumpFrame();

      // 13. Wind v2 (`WindSpace.world` vs `model` vs `worldScaled` + gusts).
      final spaces = {for (final m in rig.animatedWindMaterials) m.windSpace};
      final windOk =
          spaces.containsAll(WindSpace.values) &&
          rig.animatedWindMaterials.every((m) => m.windTime > 0) &&
          game.dynamicLayer.renderStats.instances >= 12;
      record(
        'wind_spaces_v2',
        'WindSpace (world / model / worldScaled) + Gusts & Flutter',
        ok: windOk,
        detail:
            'spaces=${spaces.length}/3, '
            'dynInstances=${game.dynamicLayer.renderStats.instances}',
      );

      // --- LAB 4: Shadows, 3-Layer ShadowGroup & 4+8 Lights ---
      game.applyPreset(ShowcasePreset.shadowsAndLights);
      ctrl
        ..retainedStaticLayer = false
        ..staticShadowCache = false
        ..sharedShadowGroup = true;
      game.syncControllerState();
      await pumpFrame();
      await pumpFrame();

      // 14. Multi-light limits: 4 DirectionalLights + 8 PointLights.
      final lights = game.dynamicLayer.world.children
          .whereType<LightComponent>()
          .toList();
      final dirCount = lights.where((l) => l.source is DirectionalLight).length;
      final ptCount = lights.where((l) => l.source is PointLight).length;
      record(
        'multi_lights_4dir_8point',
        '4 DirectionalLights + 8 PointLights (Range & Zero-Skip)',
        ok:
            dirCount == 4 &&
            ptCount == 8 &&
            game.dynamicLayer.renderStats.renderPasses >= 1,
        detail: 'directional=$dirCount, point=$ptCount',
      );

      // 15. 3-Layer `ShadowGroup` + sandwiched 2D layer (1 shared shadow pass).
      final sky = rig.skyShadowLayer;
      final totalShPasses =
          game.staticLayer.renderStats.shadowPasses +
          game.dynamicLayer.renderStats.shadowPasses +
          (sky?.renderStats.shadowPasses ?? 99);
      final groupOk =
          sky != null &&
          sky.renderStats.renderPasses >= 1 &&
          totalShPasses == 1 &&
          game.staticLayer.context.hasActiveShadows &&
          game.dynamicLayer.context.hasActiveShadows &&
          sky.context.hasActiveShadows;
      record(
        'shadow_group_3_layers',
        '3-Layer ShadowGroup + 2D Sandwich (1 Shared Shadow Pass)',
        ok: groupOk,
        detail:
            'totalShadowPasses=$totalShPasses, '
            'skyPasses=${sky?.renderStats.renderPasses ?? 0}',
      );

      // 16. `ShadowMapEncoding.rgba8` + `ShadowFit.view` + PCF `softness: 2`.
      ctrl
        ..sharedShadowGroup = false
        ..shadowEncoding = ShadowMapEncoding.rgba8
        ..shadowFit = ShadowFit.view
        ..shadowSoftness = 2;
      game.syncControllerState();
      await pumpFrame();
      await pumpFrame();
      final rgba8Ok =
          game.staticLayer.renderStats.shadowPasses == 1 &&
          game.dynamicLayer.renderStats.shadowPasses == 1 &&
          game.dynamicLayer.context.hasActiveShadows;
      record(
        'shadow_rgba8_and_view_fit',
        'ShadowMapEncoding.rgba8 + ShadowFit.view + PCF Softness 2',
        ok: rgba8Ok,
        detail:
            'statSh=${game.staticLayer.renderStats.shadowPasses}, '
            'dynSh=${game.dynamicLayer.renderStats.shadowPasses}',
      );
      ctrl
        ..shadowEncoding = ShadowMapEncoding.auto
        ..shadowFit = ShadowFit.scene
        ..shadowSoftness = 1;

      // --- LAB 5: Flipbook, 4 Billboards, 5 Shapes, Attractor & Ribbons ---
      game.applyPreset(ShowcasePreset.particlesAndRibbons);
      for (var i = 0; i < 6; i++) {
        await pumpFrame();
      }

      // 17. `DecalBatch3D` (ring + 2x2 UV atlas) & textured `RibbonMaterial3D`.
      final ribbonBatches = rig.dynamicExtras.whereType<StrokeBatch3D>().length;
      final decalsAndStrokesOk =
          game.ringDecals.length >= 1 &&
          game.atlasDecals.length == 4 &&
          game.energyStrokes.segmentCount >= 10 &&
          ribbonBatches == 3;
      record(
        'decals_and_textured_strokes',
        'DecalBatch3D & Textured RibbonMaterial3D (3 Blend Modes)',
        ok: decalsAndStrokesOk,
        detail:
            'rings=${game.ringDecals.length}, atlas=${game.atlasDecals.length},'
            ' plasmaBatches=$ribbonBatches',
      );

      // 18. All 4 `ParticleBillboard` modes + 4x4 `ParticleFlipbook3D`.
      final pSystems = rig.dynamicExtras.whereType<ParticleSystem3D>().toList();
      final billboards = {
        for (final ps in pSystems) ?ps.material?.billboard,
      };
      final hasFlipbook = pSystems.any(
        (ps) => ps.flipbook != null && (ps.material?.frameBlending ?? false),
      );
      final ptclBillboardOk =
          billboards.containsAll(ParticleBillboard.values) &&
          hasFlipbook &&
          game.dynamicLayer.renderStats.particles >= 100;
      record(
        'particle_billboards_and_flipbook',
        '4 ParticleBillboards + 4x4 Flipbook FrameBlending',
        ok: ptclBillboardOk,
        detail:
            'billboards=${billboards.length}/4, flipbook=$hasFlipbook, '
            'particles=${game.dynamicLayer.renderStats.particles}',
      );

      // 19. 5 `EmitterShape3D`s + `ParticleAttractor3D` + `onGroundHit`.
      final forcesOk =
          rig.attractorArrivals > 0 &&
          rig.groundBounceHits > 0 &&
          game.sentinelRibbon.pointCount >= 3;
      record(
        'particle_shapes_attractor_ground',
        '5 EmitterShapes + Attractor Consumption + Ground Hit Decals',
        ok: forcesOk,
        detail:
            'arrivals=${rig.attractorArrivals}, '
            'groundHits=${rig.groundBounceHits}',
      );

      // --- LAB 6: Projections, PiP Insets & DRS 0.5x ---
      game.applyPreset(ShowcasePreset.projectionsAndInsets);
      ctrl.renderScale = 0.5;
      game.syncControllerState();
      await pumpFrame();
      await pumpFrame();

      // 20. `Scene3DProjection` (`.perspective`, `.camera`, `.matrix`) + DRS.
      final pipDraws = rig.perspectiveInsetLayer?.renderStats.drawCalls ?? 0;
      final camDraws = rig.cameraProjLayer?.renderStats.drawCalls ?? 0;
      final oblDraws = rig.obliqueMatrixLayer?.renderStats.drawCalls ?? 0;
      final projOk =
          pipDraws >= 1 &&
          camDraws >= 1 &&
          oblDraws >= 1 &&
          game.dynamicLayer.renderScale == 0.5;
      record(
        'projections_perspective_camera_matrix_drs',
        'Scene3DProjection (.perspective / .camera / .matrix) + DRS 0.5x',
        ok: projOk,
        detail:
            'pipDraws=$pipDraws, camDraws=$camDraws, oblDraws=$oblDraws, '
            'scale=${game.dynamicLayer.renderScale}',
      );
      ctrl.renderScale = 1.0;

      // 21. Pure 3D `FlameGame3D` (`PureCameraLabGame` 5 camera modes + pick).
      final lab = PureCameraLabGame()..onGameResize(Vector2(320, 200));
      await lab.start();
      lab.update(0.05);
      renderPureLab(lab);
      final perspDraws = lab.renderStats.drawCalls;
      final perspNotMirrored = !lab.context.isMirrored;

      // Test `worldToViewportPoint` -> `viewportPointToRay` -> `world.raycast`.
      final beaconScreen = lab.camera.worldToViewportPoint(
        lab.beaconA.position,
      );
      final pickRay = lab.camera.viewportPointToRay(beaconScreen);
      final beaconHit = lab.world.raycast(pickRay);
      final purePickOk = identical(beaconHit?.object, lab.beaconA);

      lab.setCameraMode(PureCameraMode.orthographic);
      renderPureLab(lab);
      final orthoDraws = lab.renderStats.drawCalls;

      lab
        ..setCameraMode(PureCameraMode.thirdPerson)
        ..update(0.05);
      renderPureLab(lab);
      final thirdOk = lab.camera.position.distanceTo(lab.rover.position) > 1.0;

      lab
        ..setCameraMode(PureCameraMode.firstPerson)
        ..update(0.05);
      renderPureLab(lab);
      final firstOk =
          (lab.camera.position.x - lab.rover.position.x).abs() < 0.05;

      lab.setCameraMode(PureCameraMode.customMirrored);
      renderPureLab(lab);
      final mirroredOk =
          lab.context.isMirrored && lab.renderStats.drawCalls >= 6;
      lab.onRemove();
      lab.hudTick.dispose();

      record(
        'pure_3d_cameras_and_line3d',
        'FlameGame3D (Perspective/Ortho/3rd/1st/Mirrored + Pick + Pins)',
        ok:
            perspDraws >= 6 &&
            perspNotMirrored &&
            purePickOk &&
            orthoDraws >= 6 &&
            thirdOk &&
            firstOk &&
            mirroredOk,
        detail:
            'perspDraws=$perspDraws, orthoDraws=$orthoDraws, '
            'pick=$purePickOk, mirrored=$mirroredOk',
      );

      // --- LAB 7: 26-Float Skinning, GLB/OBJ Parsers & 67,600v 32-Bit Mesh ---
      game.applyPreset(ShowcasePreset.modelsAnd32BitMesh);
      await pumpFrame();
      await pumpFrame();

      // 22. 26-Float `StylizedMaterial.skinnedVertexLayout` + `hideNodeByName`.
      final rig26 = rig.stylized26Rig;
      var skin26Stride = 0;
      var crownHideOk = false;
      if (rig26 != null) {
        final bodyNode = rig26.model.nodes[3];
        skin26Stride =
            bodyNode?.mesh?.surfaces.first.layout.strideInFloats ?? 0;
        rig26
          ..stopAnimation()
          ..hideNodeByName('Crown', hidden: false);
        final crownRay = Ray.originDirection(
          Vector3(4.2, 4.2, 3.0),
          Vector3(0, 0, -1),
        );
        final hitWithCrown = rig26.raycast(crownRay);
        rig26.hideNodeByName('Crown');
        final hitWithoutCrown = rig26.raycast(crownRay);
        crownHideOk =
            hitWithCrown != null &&
            hitWithCrown.worldPoint.z > 1.95 &&
            (hitWithoutCrown == null || hitWithoutCrown.worldPoint.z < 1.90);
        rig26
          ..hideNodeByName('Crown', hidden: false)
          ..playAnimationByName('Wave');
      }
      record(
        'stylized_26float_skinning_and_hide_node',
        'StylizedMaterial 26-Float Skinned Layout & hideNodeByName',
        ok: skin26Stride == 26 && crownHideOk,
        detail: 'strideFloats=$skin26Stride, crownToggleRaycast=$crownHideOk',
      );

      // 23. `67,600`-vertex (`> 65,535`) `Uint32List` surface + `OBJ` & `GLB`.
      final waveSurf = rig.wave32BitTerrain?.mesh.surfaces.first;
      final uint32Ok =
          waveSurf != null &&
          waveSurf.vertexCount == 67600 &&
          waveSurf.indexType == GpuIndexType.uint32 &&
          game.staticLayer.renderStats.triangles >= 134000;
      final objOk =
          rig.parsedObjModel != null && rig.parsedObjModel!.nodes.isNotEmpty;
      final glbOk =
          rig.parsedGlbModel != null &&
          rig.parsedGlbModel!.animations.isNotEmpty;
      record(
        'large_32bit_surface_and_parsers',
        '67,600v Uint32 Surface + ModelParser (OBJ/.mtl & GLB)',
        ok: uint32Ok && objOk && glbOk,
        detail:
            'verts=${waveSurf?.vertexCount ?? 0} '
            '(${waveSurf?.indexType.name}), obj=$objOk, glb=$glbOk',
      );

      // --- Restore All-in-One & Verify Fog + Bloom + Offscreen Snapshot ---
      game.applyPreset(ShowcasePreset.allInOne);
      await pumpFrame();
      await pumpFrame();

      // 24. `FogSettings` + `BloomSettings` + `World3D.renderToImage`.
      final dynPasses = game.dynamicLayer.renderStats.renderPasses;
      final fogAndBloomOk =
          game.dynamicLayer.world.fog != null &&
          game.dynamicLayer.bloom != null &&
          dynPasses >= 4;
      final snapshot = game.captureOffscreenSnapshot(
        size: const ui.Size(64, 64),
      );
      var nonBgPixels = -1;
      final reader =
          readImageBytes ??
          (runAsyncHost != null
              ? (ui.Image img) => runAsyncHost<ByteData?>(img.toByteData)
              : (ui.Image img) => img.toByteData());
      final bytes = await reader(snapshot);
      if (bytes != null) {
        nonBgPixels = 0;
        final raw = bytes.buffer.asUint8List(
          bytes.offsetInBytes,
          bytes.lengthInBytes,
        );
        for (var i = 0; i + 3 < raw.length; i += 4) {
          if ((raw[i] - 22).abs() > 6 ||
              (raw[i + 1] - 32).abs() > 6 ||
              (raw[i + 2] - 51).abs() > 6) {
            nonBgPixels++;
          }
        }
      }
      final snapshotOk =
          fogAndBloomOk &&
          snapshot.width == 64 &&
          snapshot.height == 64 &&
          nonBgPixels > 20;
      record(
        'fog_bloom_and_offscreen_snapshot',
        'FogSettings + Kawase Bloom + World3D.renderToImage',
        ok: snapshotOk,
        detail:
            'passes=$dynPasses, size=${snapshot.width}x${snapshot.height}, '
            'litPixels=$nonBgPixels',
      );
    } finally {
      game.applyPreset(savedPreset);
      ctrl
        ..autoOrbitCamera = savedOrbit
        ..wind = savedWind
        ..retainedStaticLayer = savedRetained
        ..staticShadowCache = savedShadowCache
        ..sharedShadowGroup = savedSharedShadow
        ..bloom = savedBloom
        ..fog = savedFog
        ..outlines = savedOutlines
        ..particles = savedParticles
        ..ribbonsAndDecals = savedRibbons
        ..stressInstances = savedStress
        ..shadowEncoding = savedEncoding
        ..shadowFit = savedFit
        ..shadowSoftness = savedSoftness
        ..renderScale = savedScale
        ..playMode = savedPlayMode
        ..animSpeed = savedSpeed;
      game.camera.viewfinder
        ..zoom = savedZoom
        ..position = savedPos;
      game.syncControllerState();
    }

    sw.stop();
    return ShowcaseDiagnosticReport(results: results, elapsed: sw.elapsed);
  }
}
