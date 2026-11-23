import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flame/game.dart' show FlameGame;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart'
    show makeOrthographicMatrix, makePerspectiveMatrix, makeViewMatrix;

import '../_fakes/fake_gpu_backend.dart';

bool _referenceConeReaches(
  double x,
  double y,
  double z,
  double ax,
  double ay,
  double az,
  double outer,
  double cx,
  double cy,
  double cz,
  double radius,
) {
  final vx = cx - x;
  final vy = cy - y;
  final vz = cz - z;
  final distance = math.sqrt(vx * vx + vy * vy + vz * vz);
  if (distance <= radius) {
    return true;
  }
  final spread = outer + math.asin(radius / distance) + 1e-3;
  if (spread >= math.pi) {
    return true;
  }
  return (vx * ax + vy * ay + vz * az) >= distance * math.cos(spread);
}

void main() {
  group('Stage 2 Wave 1 optimizations', () {
    test(
      'World3D HDR + shadows keeps synced lights and single pass epoch',
      () async {
        final backend = FakeGpuBackend(
          textureTargets: true,
          blockSize: 64 * 1024,
        );
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);
        final world = World3D(
          hdrEnabled: true,
          children: [
            LightComponent.directional(
              direction: Vector3(0, -1, 0),
              shadows: ShadowSettings(resolution: 64),
            ),
            MeshComponent(
              mesh: CuboidMesh(
                size: Vector3.all(1),
                material: SpatialMaterial(metallic: 0.2, roughness: 0.7),
              ),
            ),
          ],
        );
        final camera = CameraComponent3D(
          world: world,
          position: Vector3(0, 2, 5),
          target: Vector3.zero(),
        );
        final game = FlameGame(world: world, camera: camera);
        await game.onLoad();
        world.add(camera);
        game.onGameResize(Vector2(64, 64));
        await game.ready();

        final view = camera.viewMatrix;
        final proj = camera.projectionMatrix;

        // First render syncs context once with effective HDR enabled.
        device.begin();
        context
          ..cameraMask = 0xFFFFFFFF
          ..setCamera(view, proj);
        world.syncContextOptions(
          context,
          hdrEnabled: world.effectiveHdrEnabled(device),
        );
        final img1 = world.renderToImage(
          const Size(64, 64),
          view: view,
          projection: proj,
          device: device,
          context: context,
        );
        device.end();
        img1.dispose();

        expect(context.hdrEnabled, isTrue);
        expect(context.worldLightsVersion, world.lightsVersion);

        // Steady-state frame does not trigger needsSyncOptions again.
        expect(context.syncedOwner, same(world));
        expect(
          context.needsSyncOptions(
            lights: context.lights,
            lightsVersion: world.lightsVersion,
            fog: world.fog,
            waterVolume: world.waterVolume,
            renderDebugMode: world.renderDebugMode3D,
            lightProbeGrid: world.lightProbeGrid,
            reflectionProbes: context.reflectionProbes,
            prioritizeNearestLights: world.prioritizeNearestLights,
            lightGrid: world.lightGrid,
            lightGridBounds:
                world.lightGrid == null || world.hasUnboundedComponents
                ? null
                : world.sceneBounds,
            hdrEnabled: world.effectiveHdrEnabled(device),
            owner: world,
          ),
          isFalse,
        );
      },
    );

    test(
      'per-kind pass epochs skip unrelated block uploads on SceneColor toggle',
      () {
        final backend = FakeGpuBackend(
          textureTargets: true,
          blockSize: 64 * 1024,
        );
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);
        final spatialMat = SpatialMaterial();
        final stylizedMat = StylizedMaterial();
        final tri = Surface(
          vertices: [
            Vertex(position: Vector3.zero(), texCoord: Vector2.zero()),
            Vertex(position: Vector3(1, 0, 0), texCoord: Vector2.zero()),
            Vertex(position: Vector3(0, 1, 0), texCoord: Vector2.zero()),
          ],
          indices: [0, 1, 2],
          material: spatialMat,
        );
        final stylizedTri = Surface(
          vertices: [
            Vertex(position: Vector3.zero(), texCoord: Vector2.zero()),
            Vertex(position: Vector3(1, 0, 0), texCoord: Vector2.zero()),
            Vertex(position: Vector3(0, 1, 0), texCoord: Vector2.zero()),
          ],
          indices: [0, 1, 2],
          material: stylizedMat,
        );
        final target = device.textureTarget(
          16,
          16,
          GpuPixelFormat.rgba8888,
          role: 'grab_test',
        );

        device.begin();
        context.setCamera(Matrix4.identity(), Matrix4.identity());
        device.beginPass(const Size(16, 16));
        context
          ..drawSurface(tri)
          ..drawSurface(stylizedTri)
          ..flush();
        final uploadsBefore = device.stats.uniformUploads;

        // Switching SceneColor bumps SceneColor/PassOptions/SpatialPass,
        // without re-uploading StylizedPass.
        context.setActiveSceneColorTarget(target);
        context
          ..drawSurface(stylizedTri)
          ..flush();
        final uploadsAfterStylized = device.stats.uniformUploads;
        expect(uploadsAfterStylized, uploadsBefore);

        context
          ..drawSurface(tri)
          ..flush();
        final uploadsAfterSpatial = device.stats.uniformUploads;
        expect(uploadsAfterSpatial, greaterThan(uploadsAfterStylized));
        device
          ..endPass()
          ..end();
      },
    );

    test(
      'VertexLayout.hashCode, GraphicsDevice caching, and ByteData bindUniform',
      () {
        final layoutA = VertexLayout(const [
          VertexAttribute(VertexLayout.positionAttribute, 3),
          VertexAttribute('vertexNormal', 3),
        ]);
        final layoutB = VertexLayout(const [
          VertexAttribute(VertexLayout.positionAttribute, 3),
          VertexAttribute('vertexNormal', 3),
        ]);
        expect(layoutA.hashCode, layoutB.hashCode);
        expect(layoutA, layoutB);
        expect(layoutA.attribute('vertexNormal')?.components, 3);
        expect(layoutA.attribute('missing'), isNull);

        final backend = FakeGpuBackend(textureTargets: true);
        final device = GraphicsDevice(backend: backend);
        final vert = VertexShader.fromAsset(
          'packages/flame_3d/assets/shaders/unlit_material.shaderbundle',
        );
        final frag = FragmentShader.fromAsset(
          'packages/flame_3d/assets/shaders/unlit_material.shaderbundle',
          slots: const ['albedoTexture', 'Material'],
        );

        final p1 = device.pipelineFor(vert, frag, layoutA);
        final p2 = device.pipelineFor(vert, frag, layoutB);
        expect(identical(p1, p2), isTrue);
        expect(device.cachedPipelineCount, 1);

        device.begin();
        final t1 = device.textureTarget(
          16,
          16,
          GpuPixelFormat.rgba8888,
          role: 'roleA',
        );
        final t2 = device.textureTarget(
          16,
          16,
          GpuPixelFormat.rgba8888,
          role: 'roleA',
        );
        final t3 = device.textureTarget(
          16,
          16,
          GpuPixelFormat.rgba8888,
          role: 'roleB',
        );
        expect(identical(t1, t2), isTrue);
        expect(identical(t1, t3), isFalse);

        // Verify ByteData upload copies exact unaligned tail bytes without
        // allocating a Uint8List view.
        final bytes = Uint8List.fromList(List<int>.generate(19, (i) => i + 7));
        final subData = ByteData.sublistView(bytes);
        final customSlot = frag.resource.getUniformSlot('CustomBytes');
        device.beginPass(const Size(8, 8));
        device.bindUniform(customSlot, subData);
        device
          ..endPass()
          ..end();

        final (buf, off, len) = backend.uniformBindings['CustomBytes']!;
        expect(len, 19);
        expect(buf.contents.sublist(off, off + 19), bytes);
      },
    );

    test(
      'joint hash cache handles >64 poses, in-place mutation, and zero tail',
      () {
        final backend = FakeGpuBackend(blockSize: 64 * 1024);
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);
        final mat = SpatialMaterial();
        final skinnedSurface = Surface(
          vertices: [
            Vertex(position: Vector3.zero(), texCoord: Vector2.zero()),
            Vertex(position: Vector3(1, 0, 0), texCoord: Vector2.zero()),
            Vertex(position: Vector3(0, 1, 0), texCoord: Vector2.zero()),
          ],
          indices: [0, 1, 2],
          material: mat,
        );

        // >64 distinct poses drawn twice each: cache hits all 80 poses!
        final poses = [
          for (var i = 0; i < 80; i++)
            [Matrix4.translationValues(i.toDouble() + 1.0, 0.5, -0.25)],
        ];

        device.begin();
        context.setCamera(Matrix4.identity(), Matrix4.identity());
        device.beginPass(const Size(8, 8));
        for (final pose in poses) {
          context.drawSurface(skinnedSurface, jointTransforms: pose);
        }
        context.flush();
        final uploadsFirstPass = device.stats.uniformUploads;

        // Re-submit all 80 poses in another draw batch in the same frame.
        for (final pose in poses) {
          context.drawSurface(skinnedSurface, jointTransforms: pose);
        }
        context.flush();
        final uploadsSecondPass = device.stats.uniformUploads;
        expect(uploadsSecondPass, uploadsFirstPass);
        device
          ..endPass()
          ..end();

        // In-place Matrix4 mutation triggers fresh upload, and trailing tail is
        // cleanly zeroed when a shorter joint list follows a longer one.
        final longPose = [
          Matrix4.translationValues(1, 2, 3),
          Matrix4.translationValues(4, 5, 6),
          Matrix4.translationValues(7, 8, 9),
        ];
        final shortPose = [Matrix4.translationValues(10, 11, 12)];

        device.begin();
        context.setCamera(Matrix4.identity(), Matrix4.identity());
        device.beginPass(const Size(8, 8));
        context.drawSurface(skinnedSurface, jointTransforms: longPose);
        context.flush();
        final afterLong = device.stats.uniformUploads;

        // Draw shortPose after longPose so trailing tail must be zeroed.
        context.drawSurface(skinnedSurface, jointTransforms: shortPose);
        context.flush();
        final beforeMutation = device.stats.uniformUploads;
        expect(beforeMutation, greaterThan(afterLong));
        device
          ..endPass()
          ..end();

        final (buf1, off1, len1) =
            backend.uniformBindings[RenderContext3D.jointMatricesBlock]!;
        final floats1 = buf1.contents.buffer.asFloat32List(off1, len1 ~/ 4);
        expect(floats1[3], closeTo(10.0, 1e-5));
        // Previously written joint 1..2 region must be zeroed.
        for (var k = 12; k < 36; k++) {
          expect(floats1[k], 0.0);
        }

        // Mutate shortPose[0] in place in the next frame and verify fresh
        // upload.
        shortPose[0].setTranslationRaw(99.0, 11.0, 12.0);
        device.begin();
        context.setCamera(Matrix4.identity(), Matrix4.identity());
        device.beginPass(const Size(8, 8));
        final startUploadsFrame2 = device.stats.uniformUploads;
        context.drawSurface(skinnedSurface, jointTransforms: shortPose);
        context.flush();
        expect(device.stats.uniformUploads, greaterThan(startUploadsFrame2));
        device
          ..endPass()
          ..end();

        final (buf2, off2, len2) =
            backend.uniformBindings[RenderContext3D.jointMatricesBlock]!;
        final floats2 = buf2.contents.buffer.asFloat32List(off2, len2 ~/ 4);
        expect(floats2[3], closeTo(99.0, 1e-5));
      },
    );

    test(
      'probe weights quantize to 1/64 bins and allow instanced batching',
      () {
        final backend = FakeGpuBackend(blockSize: 64 * 1024);
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);
        final probeTex = Texture(
          ByteData.sublistView(Uint8List.fromList([255, 0, 0, 255])),
          width: 1,
          height: 1,
        );
        final volume = ReflectionProbeVolume3D(
          probe: EnvironmentProbe3D(
            reflectionTexture: probeTex,
            shCoefficients: List<Vector3>.filled(9, Vector3(0.5, 0.2, 0.1)),
            intensity: 1.5,
          ),
          position: Vector3.zero(),
          extents: Vector3(2, 2, 2),
          blendDistance: 2.0,
        );
        final mat = SpatialMaterial();
        final surface = Surface(
          vertices: [
            Vertex(position: Vector3.zero(), texCoord: Vector2.zero()),
            Vertex(position: Vector3(1, 0, 0), texCoord: Vector2.zero()),
            Vertex(position: Vector3(0, 1, 0), texCoord: Vector2.zero()),
          ],
          indices: [0, 1, 2],
          material: mat,
        );

        // Two adjacent draws with slightly different weights in the same 1/64
        // quantization bin coalesce into 1 instanced draw call.
        device.begin();
        context
          ..reflectionProbes = [volume]
          ..setCamera(Matrix4.identity(), Matrix4.identity());
        device.beginPass(const Size(16, 16));
        context
          ..drawSurface(
            surface,
            transform: Matrix4.translationValues(3.0, 0, 0),
          )
          ..drawSurface(
            surface,
            transform: Matrix4.translationValues(3.001, 0, 0),
          )
          ..flush();
        final statsBinSame = RenderStats()..setFrom(device.stats);
        expect(statsBinSame.drawCalls, 1);
        expect(statsBinSame.instances, 2);
        expect(
          context.activeProbeWeight * 64.0,
          closeTo(
            (context.activeProbeWeight * 64.0).roundToDouble(),
            1e-9,
          ),
        );

        // Drawing at another bin triggers SpatialMaterial's partial weight
        // update.
        context
          ..drawSurface(
            surface,
            transform: Matrix4.translationValues(2.0, 0, 0),
          )
          ..flush();
        device
          ..endPass()
          ..end();

        expect(context.activeProbeWeight, greaterThan(0.5));
        expect(device.lastFrameStats.drawCalls, 2);
        final spatialSlot = mat
            .fragmentShaderFor(context, surface.layout)
            .slot('Material');
        final flagsOff =
            spatialSlot.getMemberOffsetInBytes('flags')! ~/
            Float32List.bytesPerElement;
        final shOff =
            spatialSlot.getMemberOffsetInBytes('shCoeffs')! ~/
            Float32List.bytesPerElement;
        final matUniforms = backend.uniforms['Material']!;
        expect(
          matUniforms[flagsOff + 3],
          closeTo(mat.environmentIntensity * context.activeProbeWeight, 1e-5),
        );
        expect(
          matUniforms[shOff + 3],
          closeTo(1.5 * context.activeProbeWeight / math.pi, 1e-5),
        );
      },
    );

    test('LightGrid3D algebraic cone test matches reference formula', () {
      final rng = math.Random(42);
      var checked = 0;
      for (var caseIdx = 0; caseIdx < 2000; caseIdx++) {
        // Sample acute, right-angle boundary, and wide obtuse cones.
        final outer = switch (caseIdx % 5) {
          0 => math.pi * 0.5 - 1e-3,
          1 => math.pi * 0.5,
          2 => math.pi * 0.5 + 1e-3,
          3 => math.pi - 5e-4,
          _ => 0.05 + rng.nextDouble() * (math.pi - 0.1),
        };
        var ax = rng.nextDouble() * 2 - 1;
        var ay = rng.nextDouble() * 2 - 1;
        var az = rng.nextDouble() * 2 - 1;
        final len = math.sqrt(ax * ax + ay * ay + az * az);
        if (len < 1e-6) {
          continue;
        }
        ax /= len;
        ay /= len;
        az /= len;

        final x = (rng.nextDouble() - 0.5) * 20;
        final y = (rng.nextDouble() - 0.5) * 20;
        final z = (rng.nextDouble() - 0.5) * 20;
        final cx = x + (rng.nextDouble() - 0.5) * 30;
        final cy = y + (rng.nextDouble() - 0.5) * 30;
        final cz = z + (rng.nextDouble() - 0.5) * 30;
        final radius = 0.2 + rng.nextDouble() * 8.0;

        // Avoid razor-thin float boundary ties within 1e-12.
        final vx = cx - x;
        final vy = cy - y;
        final vz = cz - z;
        final d = math.sqrt(vx * vx + vy * vy + vz * vz);
        if (d > radius) {
          final spread = outer + math.asin(radius / d) + 1e-3;
          if ((spread - math.pi).abs() < 1e-11) {
            continue;
          }
          final diff = (vx * ax + vy * ay + vz * az) - d * math.cos(spread);
          if (diff.abs() < 1e-11 * d) {
            continue;
          }
        }

        final fast = LightGrid3D.coneReachesForTest(
          x,
          y,
          z,
          ax,
          ay,
          az,
          outer,
          cx,
          cy,
          cz,
          radius,
        );
        final ref = _referenceConeReaches(
          x,
          y,
          z,
          ax,
          ay,
          az,
          outer,
          cx,
          cy,
          cz,
          radius,
        );
        expect(fast, ref, reason: 'Mismatch at case $caseIdx (outer=$outer)');
        checked++;
      }
      expect(checked, greaterThan(1800));
    });

    test('writeViewerTo and BarrierMaterial reaction caching', () {
      final backend = FakeGpuBackend(blockSize: 64 * 1024);
      final device = GraphicsDevice(backend: backend);
      final context = RenderContext3D(device);
      final slot = FakeUniformSlot('BarrierLook', 256);
      final block = UniformBlock(slot);

      final view = makeViewMatrix(
        Vector3(2, 3, 7),
        Vector3(0, 0, 0),
        Vector3(0, 1, 0),
      );
      final persp = makePerspectiveMatrix(1.0, 1.5, 0.2, 50.0);
      final ortho = makeOrthographicMatrix(-5, 5, -5, 5, 0.1, 40.0);

      // Perspective camera center of projection at (2, 3, 7), w = 1.
      context.setCamera(view, persp);
      context.writeViewerTo(block, 0);
      expect(block.data[0], closeTo(2.0, 1e-4));
      expect(block.data[1], closeTo(3.0, 1e-4));
      expect(block.data[2], closeTo(7.0, 1e-4));
      expect(block.data[3], closeTo(1.0, 1e-5));

      // Orthographic camera: directional viewer (w = 0).
      context.setCamera(view, ortho);
      context.writeViewerTo(block, 0);
      expect(block.data[3], 0.0);
      final dirLen = math.sqrt(
        block.data[0] * block.data[0] +
            block.data[1] * block.data[1] +
            block.data[2] * block.data[2],
      );
      expect(dirLen, closeTo(1.0, 1e-5));

      // BarrierMaterial reaction material caches per cameraPass/version.
      final barrier = BarrierMaterial(reactionInFront: 0.6);
      final ring = BarrierMesh.ring(
        radius: 2,
        height: 2,
        material: barrier,
      );
      device.begin();
      context.setCamera(view, persp);
      device.beginPass(const Size(16, 16));
      context
        ..drawMesh(ring)
        ..flush();
      final afterFirst = device.stats.uniformUploads;

      context
        ..drawMesh(ring)
        ..flush();
      expect(device.stats.uniformUploads, afterFirst);
      device
        ..endPass()
        ..end();
    });
  });
}
