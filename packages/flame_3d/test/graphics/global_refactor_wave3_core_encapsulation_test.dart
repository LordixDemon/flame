import 'dart:ui' show Color;

import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart'
    show makeOrthographicMatrix, makePerspectiveMatrix, makeViewMatrix;

import '../_fakes/fake_gpu_backend.dart';

class _TestProbeSource({
  @override required final EnvironmentProbe3D probe,
  required Vector3 center,
  required Vector3 halfExtents,
  @override final int priority = 0,
  final double? fixedWeight,
}) implements ReflectionProbeSource3D {
  @override
  final double blendDistance = 1.0;

  @override
  final bool boxProjection = true;

  final Vector3 _worldCenter = center.clone();
  final Aabb3 _worldBounds = Aabb3.minMax(
    center - halfExtents,
    center + halfExtents,
  );

  @override
  Vector3 get worldCenter => _worldCenter;

  @override
  Aabb3 get worldBounds => _worldBounds;

  @override
  double weightAt(Vector3 worldPoint) {
    if (fixedWeight case final w?) {
      return w;
    }
    final min = _worldBounds.min;
    final max = _worldBounds.max;
    final inside =
        worldPoint.x >= min.x &&
        worldPoint.x <= max.x &&
        worldPoint.y >= min.y &&
        worldPoint.y <= max.y &&
        worldPoint.z >= min.z &&
        worldPoint.z <= max.z;
    return inside ? 1.0 : 0.0;
  }
}

class _RecordingShaderBindTarget() implements ShaderBindTarget {
  final List<UniformBlock> boundBlocks = [];
  final List<(GpuUniformSlot, Texture)> boundTextures = [];

  @override
  void bindUniformBlock(UniformBlock block) {
    boundBlocks.add(block);
  }

  @override
  void bindTexture(GpuUniformSlot slot, Texture texture) {
    boundTextures.add((slot, texture));
  }
}

EnvironmentProbe3D _dummyProbe() => EnvironmentProbe3D(
  shCoefficients: List<Vector3>.generate(9, (_) => Vector3.zero()),
  reflectionTexture: ColorTexture(const Color(0xFFFFFFFF)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Wave 3.1 core encapsulation & cycle break', () {
    test('ReflectionProbeSource3D works independently of Component3D', () {
      final backend = FakeGpuBackend(textureTargets: true);
      final device = GraphicsDevice(backend: backend);
      final context = RenderContext3D(device);

      final lowPrio = _TestProbeSource(
        probe: _dummyProbe(),
        center: Vector3.zero(),
        halfExtents: Vector3.all(5),
        priority: 1,
        fixedWeight: 1.0,
      );
      final highPrioLowerWeight = _TestProbeSource(
        probe: _dummyProbe(),
        center: Vector3.zero(),
        halfExtents: Vector3.all(5),
        priority: 5,
        fixedWeight: 0.4,
      );
      final samePrioHigherWeight = _TestProbeSource(
        probe: _dummyProbe(),
        center: Vector3.zero(),
        halfExtents: Vector3.all(5),
        priority: 5,
        fixedWeight: 0.8,
      );

      final probes = <ReflectionProbeSource3D>[
        lowPrio,
        highPrioLowerWeight,
        samePrioHigherWeight,
      ];
      context.reflectionProbes = probes;

      final selected = context.selectReflectionProbe(Vector3.zero());
      expect(selected, isNotNull);
      expect(selected!.$1, same(samePrioHigherWeight));
      expect(selected.$2, closeTo(0.8, 1e-6));

      expect(
        context.needsSyncOptions(
          lights: const [],
          lightsVersion: 1,
          fog: null,
          waterVolume: null,
          renderDebugMode: RenderDebugMode3D.none,
          lightProbeGrid: null,
          reflectionProbes: probes,
          prioritizeNearestLights: false,
          lightGrid: null,
          lightGridBounds: null,
          hdrEnabled: false,
        ),
        isTrue,
      );
      expect(
        context.needsSyncOptions(
          lights: const [],
          lightsVersion: 1,
          fog: null,
          waterVolume: null,
          renderDebugMode: RenderDebugMode3D.none,
          lightProbeGrid: null,
          reflectionProbes: probes,
          prioritizeNearestLights: false,
          lightGrid: null,
          lightGridBounds: null,
          hdrEnabled: false,
        ),
        isFalse,
      );
      expect(
        context.needsSyncOptions(
          lights: const [],
          lightsVersion: 1,
          fog: null,
          waterVolume: null,
          renderDebugMode: RenderDebugMode3D.none,
          lightProbeGrid: null,
          reflectionProbes: [lowPrio],
          prioritizeNearestLights: false,
          lightGrid: null,
          lightGridBounds: null,
          hdrEnabled: false,
        ),
        isTrue,
      );
    });

    test(
      'Shader.bind targets ShaderBindTarget without concrete GraphicsDevice',
      () {
        final backend = FakeGpuBackend();
        final device = GraphicsDevice(backend: backend);
        expect(device, isA<ShaderBindTarget>());

        final shader = FragmentShader.fromAsset(
          'test_wave3_bind.shaderbundle',
          entryPoint: 'fragment_main',
          slots: const ['Material', 'albedoTexture'],
        );
        shader.setFloat('Material.roughness', 0.5);
        shader.setTexture('albedoTexture', Texture.standard);

        final customTarget = _RecordingShaderBindTarget();
        shader.bind(customTarget);

        expect(customTarget.boundBlocks.length, 1);
        expect(customTarget.boundBlocks.first.slot.name, 'Material');
        expect(customTarget.boundTextures.length, 1);
        expect(customTarget.boundTextures.first.$1.name, 'albedoTexture');
        expect(customTarget.boundTextures.first.$2, same(Texture.standard));
      },
    );

    test(
      'RenderContext3D camera, viewer, lights, and registry sub-objects',
      () {
        final backend = FakeGpuBackend();
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);

        final view = makeViewMatrix(
          Vector3(0, 2, 10),
          Vector3.zero(),
          Vector3(0, 1, 0),
        );
        final proj = makePerspectiveMatrix(1.0, 16 / 9, 0.1, 100.0);
        context.setCamera(view, proj);

        expect(context.viewerEpoch, 1);
        expect(context.isMirrored, isFalse);
        expect(context.frontFace, WindingOrder.counterClockwise);
        expect(context.cameraPosition.z, closeTo(10.0, 1e-4));

        // Mirroring flips frontFace.
        final mirroredProj = proj.clone()..scaleByVector3(Vector3(-1, 1, 1));
        context.setCamera(view, mirroredProj);
        expect(context.isMirrored, isTrue);
        expect(context.frontFace, WindingOrder.clockwise);

        // Viewer caching per camera pass writes perspective center (w = 1).
        final viewerSlot = FakeUniformSlot('ViewerTest', 32);
        final viewerBlock = UniformBlock(viewerSlot);
        context.writeViewerTo(viewerBlock, 0);
        expect(viewerBlock.data[3], closeTo(1.0, 1e-6));
        expect(viewerBlock.data[2], closeTo(10.0, 1e-3));

        // Lights state + worldLightsVersion tracking.
        final lights = <Light>[
          Light(
            position: Vector3(1, 2, 3),
            source: PointLight(
              color: const Color(0xFFFFFFFF),
              intensity: 1.0,
            ),
          ),
        ];
        context.setWorldLights(lights, 7);
        expect(context.worldLightsVersion, 7);
        expect(context.lights, same(lights));
        context.lights = lights;
        expect(context.worldLightsVersion, isNull);

        // Pass uniform registry registration + removal.
        void customWriter(RenderContext3D ctx, UniformBlock b) {}
        context.registerPassUniform('CustomBlock', customWriter);
        expect(context.passUniforms['CustomBlock'], same(customWriter));
        context.registerPassUniform('CustomBlock', null);
        expect(context.passUniforms.containsKey('CustomBlock'), isFalse);
      },
    );

    test(
      'GraphicsDevice pools texture targets and evicts expired entries',
      () {
        final backend = FakeGpuBackend(textureTargets: true);
        final device = GraphicsDevice(backend: backend);

        device.begin();
        final t1 = device.textureTarget(
          64,
          64,
          GpuPixelFormat.rgba8888,
          role: #a,
        );
        final t1Same = device.textureTarget(
          64,
          64,
          GpuPixelFormat.rgba8888,
          role: #a,
        );
        final t2 = device.textureTarget(
          64,
          64,
          GpuPixelFormat.rgba8888,
          role: #b,
        );
        expect(t1Same, same(t1));
        expect(t2, isNot(same(t1)));
        expect(device.estimatedTargetVramBytes, greaterThan(0));
        device.end();

        // Advance past targetRetainFrames while touching #a each frame.
        for (var i = 0; i < GraphicsDevice.targetRetainFrames + 1; i++) {
          device.begin();
          device.touchTextureTarget(t1);
          device.end();
        }

        device.begin();
        expect(
          device.textureTarget(64, 64, GpuPixelFormat.rgba8888, role: #a),
          same(t1),
        );
        final t2Recreated = device.textureTarget(
          64,
          64,
          GpuPixelFormat.rgba8888,
          role: #b,
        );
        expect(t2Recreated, isNot(same(t2)));
        device.end();
      },
    );

    test(
      'RenderGraph3D compiles DAG, culls dead passes, aliases slots, '
      'detects cycles',
      () {
        final graph = RenderGraph3D();
        const desc = RenderGraphTextureDesc3D(width: 64, height: 64);
        final a = graph.createTexture('a', desc);
        final b = graph.createTexture('b', desc);
        final deadTex = graph.createTexture('dead', desc);
        final out = graph.createTexture('out', desc);
        graph.markOutput(out);

        graph
          ..addRenderPass(
            name: 'produce_a',
            writes: [a],
            execute: (_) {},
          )
          ..addRenderPass(
            name: 'dead_pass',
            writes: [deadTex],
            execute: (_) {},
          )
          ..addRenderPass(
            name: 'produce_b_from_a',
            reads: [a],
            writes: [b],
            execute: (_) {},
          )
          ..addRenderPass(
            name: 'produce_out_from_b',
            reads: [b],
            writes: [out],
            execute: (_) {},
          );

        final plan = graph.compile();
        expect(graph.compileCount, 1);
        expect(graph.compile(), same(plan));
        expect(graph.compileCount, 1);

        expect(plan.culledPasses.map((p) => p.name), ['dead_pass']);
        expect(
          plan.executionOrder.map((p) => p.name),
          ['produce_a', 'produce_b_from_a', 'produce_out_from_b'],
        );
        expect(plan.physicalTargetCount, 2);

        final cyclic = RenderGraph3D();
        final x = cyclic.createTexture('x', desc);
        final y = cyclic.createTexture('y', desc);
        cyclic
          ..addRenderPass(name: 'p1', reads: [y], writes: [x], execute: (_) {})
          ..addRenderPass(name: 'p2', reads: [x], writes: [y], execute: (_) {});
        expect(cyclic.compile, throwsStateError);
      },
    );

    test(
      'LightGrid3D bins, enforces maxLights and per-cell caps, tests cones',
      () {
        final grid = LightGrid3D();
        final lights = <Light>[
          for (var i = 0; i < 6; i++)
            Light(
              position: Vector3.zero(),
              source: PointLight(
                color: const Color(0xFFFFFFFF),
                intensity: (i + 1).toDouble(),
                range: 5.0,
              ),
            ),
        ];
        final vp = makeOrthographicMatrix(-10, 10, -10, 10, -10, 10)
          ..multiply(
            makeViewMatrix(Vector3(0, 0, 5), Vector3.zero(), Vector3(0, 1, 0)),
          );

        final changed = grid.build(
          lights: lights,
          cameraMask: 0xFFFFFFFF,
          settings: const LightGridSettings(
            cellSize: 4.0,
            maxLights: 4,
            maxPointLightsPerCell: 2,
            beyondLimitsOnly: false,
          ),
          points: true,
          spots: false,
          bounds: Aabb3.minMax(Vector3(-2, -2, -2), Vector3(2, 2, 2)),
          viewProjection: vp,
        );
        expect(changed, isTrue);
        expect(grid.hasLights, isTrue);
        expect(grid.stats.droppedLights, 2);
        expect(grid.stats.maxPointLightsInCell, lessThanOrEqualTo(2));
        expect(grid.stats.droppedEntries, greaterThan(0));

        expect(
          LightGrid3D.coneReachesForTest(0, 0, 0, 0, 0, -1, 0.5, 0, 0, -5, 1.0),
          isTrue,
        );
        expect(
          LightGrid3D.coneReachesForTest(0, 0, 0, 0, 0, -1, 0.3, 0, 0, 5, 1.0),
          isFalse,
        );
      },
    );
  });
}
