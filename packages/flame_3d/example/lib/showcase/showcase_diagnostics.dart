import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d_example/showcase/showcase_game.dart';

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

/// Automated 12-point functional & rendering health suite for
/// `package:flame_3d`.
///
/// Can be executed interactively on desktop/mobile or headlessly under
/// `flutter test --enable-impeller --enable-flutter-gpu`.
class ShowcaseDiagnostics() {
  static Future<ShowcaseDiagnosticReport> runAllChecks(
    ShowcaseGame game, {
    required Future<void> Function() pumpFrame,
    Future<ByteData?> Function(ui.Image image)? readImageBytes,
  }) async {
    final sw = Stopwatch()..start();
    final results = <DiagnosticCheckResult>[];

    final ctrl = game.controller;
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

    try {
      // 1. GPU backend & shader library readiness.
      final gpuReady = GpuBackend.isAvailable && game.isLoaded;
      record(
        'gpu_backend',
        'Flutter GPU Backend & Shaders',
        ok: gpuReady,
        detail:
            'isAvailable=${GpuBackend.isAvailable}, isLoaded=${game.isLoaded}',
      );

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
        ..stressInstances = false;
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

      // 5. Flat `Surface.bvh` (`O(log T)`) & `Scene3DComponent.raycastLocal`.
      final tileLocal = game.staticLayer.scenePointToLocal(
        Vector3(2.5, 3.5, 0.2),
      );
      final hit = game.pickAtLocalPoint(tileLocal);
      final rayOk =
          hit != null &&
          hit.distance.isFinite &&
          (hit.worldNormal.length - 1.0).abs() < 1e-2;
      record(
        'bvh_raycasting',
        'SurfaceBvh Narrowphase & Scene Raycast',
        ok: rayOk,
        detail: hit == null
            ? 'missed at $tileLocal'
            : '${hit.object.runtimeType} idx=${hit.surfaceIndex} '
                  'tri=${hit.triangleIndex} '
                  'd=${hit.distance.toStringAsFixed(2)}',
      );

      // 6. `LodMeshComponent` tier switching across camera zoom.
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

      // 7. Zero-alloc skeletal `AnimationState` crossfade & `BoneSocket3D`.
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
      record(
        'animation_crossfade_and_socket',
        'ModelComponent Crossfade & BoneSocket3D Tracking',
        ok: crossFadingStarted && tipMoved,
        detail:
            'clip=${ctrl.activeClip}, crossFading=$crossFadingStarted, '
            'socketDelta=${tipAfter.distanceTo(tipBefore).toStringAsFixed(3)}',
      );

      // 8. Static & Skinned `OutlineMaterial` inverted-hull silhouettes.
      final dynStats = game.dynamicLayer.renderStats;
      final outlinesOk =
          ctrl.outlines &&
          game.automatonOutline.scale.x > 0.9 &&
          game.orbitingSentinelOutline.scale.x > 0.9 &&
          dynStats.drawCalls >= 4;
      record(
        'outlines_static_and_skinned',
        'OutlineMaterial (Static + 4-Joint Skinned)',
        ok: outlinesOk,
        detail:
            'dynamicDraws=${dynStats.drawCalls}, '
            'dynamicTris=${dynStats.triangles}',
      );

      // 9. `DecalBatch3D` (procedural rings + UV atlas) & `StrokeBatch3D`.
      final decalsAndStrokesOk =
          game.ringDecals.length >= 1 &&
          game.atlasDecals.length == 4 &&
          game.energyStrokes.segmentCount >= 10;
      record(
        'decals_and_strokes',
        'DecalBatch3D & StrokeBatch3D Instanced Batches',
        ok: decalsAndStrokesOk,
        detail:
            'rings=${game.ringDecals.length}, '
            'atlas=${game.atlasDecals.length}, '
            'strokeSegs=${game.energyStrokes.segmentCount}',
      );

      // 10. `RibbonTrail3D` motion history & `ParticleSystem3D` simulation.
      final trailsAndParticlesOk =
          game.sentinelRibbon.pointCount >= 3 &&
          game.sparkParticles.particleCount > 0 &&
          game.coinMeshParticles.particleCount > 0;
      record(
        'ribbon_trails_and_particles',
        'RibbonTrail3D & ParticleSystem3D (Billboard + Mesh)',
        ok: trailsAndParticlesOk,
        detail:
            'ribbonPts=${game.sentinelRibbon.pointCount}, '
            'sparks=${game.sparkParticles.particleCount}, '
            'coins=${game.coinMeshParticles.particleCount}',
      );

      // 11. `FogSettings` & `BloomSettings` multi-pass post-processing.
      final fogAndBloomOk =
          game.dynamicLayer.world.fog != null &&
          game.dynamicLayer.bloom != null &&
          dynStats.renderPasses >= 4;
      record(
        'fog_and_bloom',
        'FogSettings + Kawase BloomPass Pipeline',
        ok: fogAndBloomOk,
        detail:
            'dynamicPasses=${dynStats.renderPasses}, '
            'bloomIntensity=${game.dynamicLayer.bloom?.intensity}',
      );

      // 12. Offscreen `World3D.renderToImage` snapshot verification.
      final snapshot = game.captureOffscreenSnapshot(
        size: const ui.Size(64, 64),
      );
      var nonBgPixels = -1;
      final reader = readImageBytes ?? (img) => img.toByteData();
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
          snapshot.width == 64 && snapshot.height == 64 && nonBgPixels > 20;
      record(
        'offscreen_render_to_image',
        'World3D.renderToImage Offscreen Snapshot',
        ok: snapshotOk,
        detail:
            'size=${snapshot.width}x${snapshot.height}, litPixels=$nonBgPixels',
      );
    } finally {
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
        ..stressInstances = savedStress;
      game.camera.viewfinder
        ..zoom = savedZoom
        ..position = savedPos;
      game.syncControllerState();
    }

    sw.stop();
    return ShowcaseDiagnosticReport(results: results, elapsed: sw.elapsed);
  }
}
