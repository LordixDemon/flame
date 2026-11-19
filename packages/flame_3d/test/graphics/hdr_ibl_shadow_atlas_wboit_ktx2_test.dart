import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' show makePerspectiveMatrix;

import '../_fakes/fake_gpu_backend.dart';

Surface _makeUnitQuadSurface() {
  return Surface(
    vertices: [
      Vertex(
        position: Vector3(-1, 0, -1),
        texCoord: Vector2(0, 0),
        normal: Vector3(0, 1, 0),
      ),
      Vertex(
        position: Vector3(1, 0, -1),
        texCoord: Vector2(1, 0),
        normal: Vector3(0, 1, 0),
      ),
      Vertex(
        position: Vector3(1, 0, 1),
        texCoord: Vector2(1, 1),
        normal: Vector3(0, 1, 0),
      ),
      Vertex(
        position: Vector3(-1, 0, 1),
        texCoord: Vector2(0, 1),
        normal: Vector3(0, 1, 0),
      ),
    ],
    indices: [0, 2, 1, 0, 3, 2],
  );
}

void main() {
  group('GpuBackend HAL, PixelFormats, Anisotropy & StencilState', () {
    test(
      'GpuPixelFormat reports block dimensions and compression metadata',
      () {
        expect(GpuPixelFormat.rgba8888.isCompressed, isFalse);
        expect(GpuPixelFormat.rgba8888.bytesPerBlock, 4);
        expect(GpuPixelFormat.rgba8888Srgb.isCompressed, isFalse);
        expect(GpuPixelFormat.rgba8888Srgb.bytesPerBlock, 4);
        expect(GpuPixelFormat.bgra8888Srgb.bytesPerBlock, 4);
        expect(GpuPixelFormat.rgbaFloat16.isCompressed, isFalse);
        expect(GpuPixelFormat.rgbaFloat16.bytesPerBlock, 8);

        expect(GpuPixelFormat.bc1Rgba.isCompressed, isTrue);
        expect(GpuPixelFormat.bc1Rgba.blockWidth, 4);
        expect(GpuPixelFormat.bc1Rgba.blockHeight, 4);
        expect(GpuPixelFormat.bc1Rgba.bytesPerBlock, 8);

        expect(GpuPixelFormat.bc3Rgba.bytesPerBlock, 16);
        expect(GpuPixelFormat.bc7Rgba.bytesPerBlock, 16);
        expect(GpuPixelFormat.etc2Rgb8.bytesPerBlock, 8);
        expect(GpuPixelFormat.etc2Rgba8.bytesPerBlock, 16);

        expect(GpuPixelFormat.astc4x4.blockWidth, 4);
        expect(GpuPixelFormat.astc4x4.blockHeight, 4);
        expect(GpuPixelFormat.astc4x4.bytesPerBlock, 16);
        expect(GpuPixelFormat.astc8x8.blockWidth, 8);
        expect(GpuPixelFormat.astc8x8.blockHeight, 8);
        expect(GpuPixelFormat.astc8x8.bytesPerBlock, 16);
      },
    );

    test('TextureSampler anisotropy presets produce unique cache keys', () {
      expect(TextureSampler.linear.maxAnisotropy, 1);
      expect(TextureSampler.anisotropic4x.maxAnisotropy, 4);
      expect(TextureSampler.anisotropic8x.maxAnisotropy, 8);
      expect(TextureSampler.anisotropic16x.maxAnisotropy, 16);

      final keys = {
        TextureSampler.nearest.key,
        TextureSampler.linear.key,
        TextureSampler.anisotropic4x.key,
        TextureSampler.anisotropic8x.key,
        TextureSampler.anisotropic16x.key,
      };
      expect(keys.length, 5);
      for (final k in keys) {
        expect(k, inInclusiveRange(0, TextureSampler.keyCount - 1));
      }
      expect(
        TextureSampler.anisotropic8x.copyWith(maxAnisotropy: 6).maxAnisotropy,
        6,
      );
    });

    test('StencilState and RenderState copyWith preserve equality', () {
      const writeRef = StencilState.writeReference(3);
      const testEq = StencilState.testEqual(3);
      const testNeq = StencilState.testNotEqual(3);

      expect(writeRef.compare, CompareFunction.always);
      expect(writeRef.pass, StencilOp.replace);
      expect(writeRef.referenceValue, 3);
      expect(testEq.compare, CompareFunction.equal);
      expect(testEq.writeMask, 0);
      expect(testNeq.compare, CompareFunction.notEqual);

      const state = RenderState(
        stencil: writeRef,
        polygonMode: PolygonFillMode.wireframe,
      );
      expect(state.stencil, writeRef);
      expect(state.polygonMode, PolygonFillMode.wireframe);
      expect(
        state.copyWith(stencil: testEq).stencil,
        equals(testEq),
      );
      expect(
        state.copyWith(clearStencil: true).stencil,
        isNull,
      );
    });

    test('GraphicsDevice records viewport, scissor, stencil, wireframe, '
        'and topology commands', () {
      final backend = FakeGpuBackend();
      final device = GraphicsDevice(backend: backend);

      final lineSurface = Surface(
        vertices: [
          Vertex(position: Vector3(0, 0, 0), texCoord: Vector2(0, 0)),
          Vertex(position: Vector3(1, 1, 0), texCoord: Vector2(1, 1)),
        ],
        indices: [0, 1],
        topology: PrimitiveTopology.lines,
      );
      final material = SpatialMaterial();
      final pipeline = device.pipelineFor(
        material.vertexShader,
        material.fragmentShader,
        lineSurface.layout,
      );

      device
        ..begin()
        ..beginPass(const Size(128, 128))
        ..setViewport(16, 24, 64, 48)
        ..setScissor(16, 24, 64, 48)
        ..bindPipeline(pipeline)
        ..setStencil(const StencilState.writeReference(7))
        ..setPolygonMode(PolygonFillMode.wireframe)
        ..drawSurface(lineSurface)
        ..endPass()
        ..end();

      expect(backend.commands, contains('setViewport 16 24 64x48 0.0..1.0'));
      expect(backend.commands, contains('setScissor 16 24 64x48'));
      expect(backend.commands, contains('setStencil always replace ref=7'));
      expect(backend.commands, contains('setPolygonMode wireframe'));
      expect(backend.commands, contains('setPrimitiveTopology lines'));
    });
  });

  group('Ktx2TextureLoader', () {
    test('rejects invalid magic header and supercompressed containers', () {
      expect(
        () => Ktx2TextureLoader.parse(Uint8List(16)),
        throwsFormatException,
      );
      final base = Uint8List(4 * 4 * 4);
      final valid = Ktx2TextureLoader.encodeUncompressedRgba8(
        base,
        width: 4,
        height: 4,
      );
      // Corrupt supercompressionScheme (bytes 44..47) to BasisLZ (1).
      ByteData.sublistView(valid).setUint32(44, 1, Endian.little);
      expect(
        () => Ktx2TextureLoader.parse(valid),
        throwsUnsupportedError,
      );
    });

    test('encodes and parses multi-mip RGBA8 sRGB KTX2 container', () {
      final mip0 = Uint8List.fromList(List.filled(4 * 4 * 4, 200));
      final mip1 = Uint8List.fromList(List.filled(2 * 2 * 4, 100));
      final ktx2Bytes = Ktx2TextureLoader.encodeUncompressedRgba8(
        mip0,
        width: 4,
        height: 4,
        mipLevels: [mip0, mip1],
        srgb: true,
      );

      final parsed = Ktx2TextureLoader.parse(ktx2Bytes);
      expect(parsed.width, 4);
      expect(parsed.height, 4);
      expect(parsed.levelCount, 2);
      expect(parsed.gpuFormat, GpuPixelFormat.rgba8888Srgb);
      expect(parsed.isSrgb, isTrue);
      expect(parsed.levels[0].width, 4);
      expect(parsed.levels[1].width, 2);
    });

    test('BC1 encode/decode round-trip and hardware vs fallback upload', () {
      final rgba = Uint8List(4 * 4 * 4);
      for (var i = 0; i < 16; i++) {
        final isRed = i < 8;
        rgba[i * 4] = isRed ? 248 : 16;
        rgba[i * 4 + 1] = isRed ? 20 : 236;
        rgba[i * 4 + 2] = 24;
        rgba[i * 4 + 3] = 255;
      }

      final ktx2Bc1 = Ktx2TextureLoader.encodeBc1(
        rgba,
        width: 4,
        height: 4,
      );
      final container = Ktx2TextureLoader.parse(ktx2Bc1);
      expect(container.gpuFormat, GpuPixelFormat.bc1Rgba);
      expect(container.levels.single.byteLength, 8);

      // 1. Hardware supports BC1 -> uploads compressed blocks directly.
      final hwBackend = FakeGpuBackend(
        supportedFormats: {GpuPixelFormat.bc1Rgba, GpuPixelFormat.rgba8888},
      );
      final hwTex = Ktx2TextureLoader.load(ktx2Bc1, backend: hwBackend);
      final hwGpu = hwTex.resource as FakeTexture;
      expect(hwGpu.format, GpuPixelFormat.bc1Rgba);
      expect(hwGpu.writes.single.$2.length, 8);

      // 2. Hardware does not support BC1 -> software decode to RGBA8888.
      final swBackend = FakeGpuBackend(
        supportedFormats: {GpuPixelFormat.rgba8888},
      );
      final swTex = Ktx2TextureLoader.load(ktx2Bc1, backend: swBackend);
      final swGpu = swTex.resource as FakeTexture;
      expect(swGpu.format, GpuPixelFormat.rgba8888);
      final decoded = swGpu.writes.single.$2;
      expect(decoded.length, 64);

      // Top half stays strongly red; bottom half stays strongly green.
      expect(decoded[0], greaterThan(220));
      expect(decoded[1], lessThan(40));
      expect(decoded[8 * 4 + 1], greaterThan(210));
      expect(decoded[8 * 4], lessThan(40));
    });
  });

  group(
    'ColorLut3D, BrdfLut3D, EnvironmentProbe3D & ReflectionProbeVolume3D',
    () {
      test('ColorLut3D identity, film presets, and trilinear sampling', () {
        final identity = ColorLut3D.identity();
        expect(identity.stripWidth, 256);
        expect(identity.stripHeight, 16);

        final s = identity.sample(0.25, 0.5, 0.75);
        expect(s.x, closeTo(0.25, 0.015));
        expect(s.y, closeTo(0.5, 0.015));
        expect(s.z, closeTo(0.75, 0.015));

        final warm = ColorLut3D.warmCinematic().sample(0.7, 0.5, 0.5);
        final cool = ColorLut3D.coolNight().sample(0.5, 0.5, 0.5);
        final sepia = ColorLut3D.sepia().sample(0.5, 0.5, 0.5);

        expect(warm.x, greaterThan(warm.z));
        expect(cool.z, greaterThan(cool.x));
        expect(sepia.x, greaterThan(sepia.y));
        expect(sepia.y, greaterThan(sepia.z));
      });

      test('BrdfLut3D split-sum integral conserves energy in (0, 1]', () {
        final (scaleNormal, biasNormal) = BrdfLut3D.integrateBrdf(0.9, 0.2);
        final (scaleGrazing, biasGrazing) = BrdfLut3D.integrateBrdf(0.05, 0.2);

        expect(scaleNormal + biasNormal, inInclusiveRange(0.7, 1.02));
        expect(scaleGrazing + biasGrazing, inInclusiveRange(0.5, 1.02));
        // Fresnel bias increases sharply toward grazing angles.
        expect(biasGrazing, greaterThan(biasNormal));

        final backend = FakeGpuBackend();
        final lut = BrdfLut3D.sharedTexture(backend);
        expect(lut.width, 64);
        expect(lut.height, 64);
        expect(identical(lut, BrdfLut3D.sharedTexture(backend)), isTrue);
      });

      test('EnvironmentProbe3D builds prefiltered roughness mip chain and '
          'ReflectionProbeVolume3D computes box-projected parallax', () {
        FakeGpuBackend();

        final pixels = Uint8List(32 * 16 * 4);
        for (var i = 0; i < 32 * 16; i++) {
          pixels[i * 4] = 180;
          pixels[i * 4 + 1] = 200;
          pixels[i * 4 + 2] = 255;
          pixels[i * 4 + 3] = 255;
        }
        final probe = EnvironmentProbe3D.fromEquirectangular(
          ByteData.sublistView(pixels),
          width: 32,
          height: 16,
        );
        final gpuTex = probe.reflectionTexture.resource as FakeTexture;
        expect(gpuTex.mipLevelCount, greaterThan(1));
        expect(gpuTex.writes.length, gpuTex.mipLevelCount);

        final volume = ReflectionProbeVolume3D(
          probe: probe,
          position: Vector3(0, 2, 0),
          extents: Vector3(5, 3, 5),
          blendDistance: 2,
        );
        expect(volume.weightAt(Vector3(0, 2, 0)), closeTo(1, 1e-5));
        expect(volume.weightAt(Vector3(6, 2, 0)), inExclusiveRange(0, 1));
        expect(volume.weightAt(Vector3(9, 2, 0)), 0);

        // Off-center point at x = 3 reflecting straight +Y hits ceiling at
        // (3, 5, 0); vector from probe center (0, 2, 0) is normalize(3, 3, 0).
        final corrected = volume.parallaxCorrectRay(
          Vector3(3, 2, 0),
          Vector3(0, 1, 0),
        );
        final invSqrt2 = 1 / math.sqrt(2);
        expect(corrected.x, closeTo(invSqrt2, 1e-4));
        expect(corrected.y, closeTo(invSqrt2, 1e-4));
        expect(corrected.z, closeTo(0, 1e-4));
      });
    },
  );

  group('MikkTSpace Tangents & LightProbeGrid3D', () {
    test('Surface.computeTangents builds orthogonal vec4 tangents and '
        'upgrades layout to pbrStandard', () {
      FakeGpuBackend();

      final surface = _makeUnitQuadSurface();
      final uv1 = Float32List.fromList([
        0, 0, //
        0.5, 0, //
        0.5, 0.5, //
        0, 0.5,
      ]);
      final tangents = surface.computeTangents(texCoord1: uv1);

      expect(tangents.length, 4 * 4);
      expect(surface.layout, VertexLayout.pbrStandard);
      expect(VertexLayout.pbrStandard.strideInFloats, 26);

      for (var i = 0; i < 4; i++) {
        final tx = tangents[i * 4];
        final ty = tangents[i * 4 + 1];
        final tz = tangents[i * 4 + 2];
        final tw = tangents[i * 4 + 3];
        final len = math.sqrt(tx * tx + ty * ty + tz * tz);
        expect(len, closeTo(1, 1e-4));
        // Orthogonal to normal (0, 1, 0) -> ty == 0.
        expect(ty.abs(), lessThan(1e-4));
        expect(tw.abs(), closeTo(1, 1e-4));
      }

      final mat = SpatialMaterial();
      expect(
        mat.vertexShaderFor(surface.layout).resource.toString(),
        isNotEmpty,
      );
      expect(
        identical(
          mat.vertexShaderFor(surface.layout),
          mat.vertexShaderFor(VertexLayout.standard),
        ),
        isFalse,
      );
    });

    test('LightProbeGrid3D bakes spatially varying SH9 irradiance', () {
      final backend = FakeGpuBackend();

      final lights = [
        Light(
          position: Vector3(-4, 1, 0),
          source: PointLight(
            color: const Color(0xFFFF4422),
            intensity: 18,
            range: 8,
          ),
        ),
        Light(
          position: Vector3(4, 1, 0),
          source: PointLight(
            color: const Color(0xFF2288FF),
            intensity: 18,
            range: 8,
          ),
        ),
      ];

      final grid = LightProbeGrid3D.bakeFromLights(
        bounds: Aabb3.minMax(Vector3(-5, 0, -5), Vector3(5, 4, 5)),
        lights: lights,
      );

      final leftIrr = grid.sampleIrradiance(
        Vector3(-3.5, 1, 0),
        Vector3(-1, 0, 0),
      );
      final rightIrr = grid.sampleIrradiance(
        Vector3(3.5, 1, 0),
        Vector3(1, 0, 0),
      );

      // Near left warm point light: red dominates blue.
      expect(leftIrr.x, greaterThan(leftIrr.z * 2));
      // Near right cool point light: blue dominates red.
      expect(rightIrr.z, greaterThan(rightIrr.x * 2));

      final gpuTex = grid.volumeTextureFor(backend);
      expect(gpuTex.width, grid.resolutionX * grid.resolutionZ);
      expect(gpuTex.height, grid.resolutionY);
    });
  });

  group('ShadowAtlas3D & Unified Multi-Light Shadow Pass', () {
    test('packs 4 CSM + 2 Spot + Dual-Paraboloid Point tiles disjointly', () {
      final atlas = ShadowAtlas3D()..reset();
      for (var c = 0; c < 4; c++) {
        expect(
          atlas.allocateTile(
            kind: ShadowAtlasTileKind3D.directionalCascade,
            lightIndex: 0,
            subIndex: c,
            tileSize: 512,
          ),
          isNotNull,
        );
      }
      for (var s = 0; s < 2; s++) {
        expect(
          atlas.allocateTile(
            kind: ShadowAtlasTileKind3D.spotLight,
            lightIndex: s + 1,
            tileSize: 512,
          ),
          isNotNull,
        );
      }
      expect(
        atlas.allocateTile(
          kind: ShadowAtlasTileKind3D.pointParaboloidFront,
          lightIndex: 3,
          tileSize: 512,
        ),
        isNotNull,
      );
      expect(
        atlas.allocateTile(
          kind: ShadowAtlasTileKind3D.pointParaboloidBack,
          lightIndex: 3,
          subIndex: 1,
          tileSize: 512,
        ),
        isNotNull,
      );
      expect(atlas.tiles.length, 8);

      // Verify pairwise disjoint pixel rectangles inside 2048x2048.
      for (var i = 0; i < atlas.tiles.length; i++) {
        final a = atlas.tiles[i];
        expect(a.x + a.width, lessThanOrEqualTo(atlas.atlasSize));
        expect(a.y + a.height, lessThanOrEqualTo(atlas.atlasSize));
        for (var j = i + 1; j < atlas.tiles.length; j++) {
          final b = atlas.tiles[j];
          final separated =
              a.x + a.width <= b.x ||
              b.x + b.width <= a.x ||
              a.y + a.height <= b.y ||
              b.y + b.height <= a.y;
          expect(separated, isTrue);
        }
      }
    });

    test('renders 4-CSM + Spot + Dual-Paraboloid Point in 1 atlas pass', () {
      final backend = FakeGpuBackend(textureTargets: true);
      final device = GraphicsDevice(backend: backend);
      final ctx = RenderContext3D(device);

      final view = Matrix4.identity()..setTranslationRaw(0, -2, -8);
      final proj = makePerspectiveMatrix(math.pi / 3, 1, 0.2, 60);
      ctx
        ..setCamera(view, proj)
        ..lights = [
          Light(
            position: Vector3.zero(),
            source: DirectionalLight(
              direction: Vector3(-0.4, -1, -0.3)..normalize(),
              shadows: ShadowSettings(cascades: 4, resolution: 512),
            ),
          ),
          Light(
            position: Vector3(0, 6, 0),
            source: SpotLight(
              direction: Vector3(0, -1, 0),
              range: 20,
              shadows: ShadowSettings(resolution: 512),
            ),
          ),
          Light(
            position: Vector3(2, 3, 1),
            source: PointLight(
              color: const Color(0xFFFFFFFF),
              intensity: 10,
              range: 15,
              shadows: ShadowSettings(resolution: 512),
            ),
          ),
        ];

      final world = World3D();
      final mesh = CuboidMesh(
        size: Vector3.all(1),
        material: SpatialMaterial(),
      );

      device.begin();
      final started = ctx.beginShadowPass(
        projection: world.shadowProjection,
        sceneBounds: Aabb3.minMax(Vector3(-8, -1, -8), Vector3(8, 5, 8)),
      );
      expect(started, isTrue);
      var tileLoops = 1;
      ctx.drawMesh(mesh);
      while (ctx.advanceShadowAtlasTile()) {
        tileLoops++;
        ctx.drawMesh(mesh);
      }
      ctx.endShadowPass();
      device.end();

      // 4 directional cascades + 1 spot + 2 paraboloid hemispheres = 7 tiles
      // inside a single GPU shadow pass!
      expect(tileLoops, 7);
      expect(device.stats.shadowPasses, 1);
      final viewports = backend.commands
          .where((c) => c.startsWith('setViewport '))
          .toList();
      expect(viewports.length, 7);
    });
  });

  group('RenderGraph3D & CustomRenderPass3D', () {
    test('topologically sorts passes, culls dead branches, and aliases '
        'transient textures', () {
      final backend = FakeGpuBackend(textureTargets: true);
      final device = GraphicsDevice(backend: backend);
      final ctx = RenderContext3D(device);

      final graph = RenderGraph3D();
      const desc = RenderGraphTextureDesc3D(width: 128, height: 128);
      final texA = graph.createTexture('gbufferA', desc);
      final texB = graph.createTexture('lightingB', desc);
      final texC = graph.createTexture('postC', desc);
      final texDead = graph.createTexture('unusedDead', desc);
      graph.markOutput(texC);

      final executed = <String>[];

      // Declared deliberately in reverse order (final -> middle -> dead ->
      // first).
      graph
        ..addRenderPass(
          name: 'tonemapC',
          reads: [texB],
          writes: [texC],
          execute: (_) => executed.add('tonemapC'),
        )
        ..addRenderPass(
          name: 'shadeB',
          reads: [texA],
          writes: [texB],
          execute: (_) => executed.add('shadeB'),
        )
        ..addRenderPass(
          name: 'deadBranch',
          reads: [texA],
          writes: [texDead],
          execute: (_) => executed.add('deadBranch'),
        )
        ..addRenderPass(
          name: 'renderA',
          writes: [texA],
          execute: (_) => executed.add('renderA'),
        );

      device.begin();
      final plan = graph.execute(device, ctx);
      device.end();

      expect(executed, ['renderA', 'shadeB', 'tonemapC']);
      expect(plan.culledPasses.map((p) => p.name), ['deadBranch']);
      // `texA` (live 0..1) and `texC` (live 2..3) have non-overlapping
      // lifetimes and identical descriptors, so 3 virtual textures alias into 2
      // slots!
      expect(plan.virtualTextureCount, 3);
      expect(plan.physicalTargetCount, 2);
    });

    test('detects dependency cycles with StateError', () {
      final graph = RenderGraph3D();
      const desc = RenderGraphTextureDesc3D(width: 64, height: 64);
      final a = graph.createTexture('a', desc);
      final b = graph.createTexture('b', desc);
      graph
        ..markOutput(b)
        ..addRenderPass(
          name: 'p1',
          reads: [b],
          writes: [a],
          execute: (_) {},
        )
        ..addRenderPass(
          name: 'p2',
          reads: [a],
          writes: [b],
          execute: (_) {},
        );

      expect(graph.compile, throwsStateError);
    });

    test('World3D.customPasses run beforeScene and afterScene hooks', () {
      final log = <String>[];
      final world = World3D(
        customPasses: [
          CustomRenderPass3D(
            name: 'pre',
            stage: CustomRenderPassStage3D.beforeScene,
            execute: (_) => log.add('before'),
          ),
          CustomRenderPass3D(
            name: 'post',
            execute: (c) {
              expect(c.sceneTarget, isNotNull);
              log.add('after');
            },
          ),
        ],
      );

      final backend = FakeGpuBackend(textureTargets: true);
      final device = GraphicsDevice(backend: backend);
      final ctx = RenderContext3D(device);

      device.begin();
      final img = world.executeWorldRenderPipeline(
        device: device,
        renderContext: ctx,
        width: 64,
        height: 64,
        msaaSampleCount: 1,
        clearValue: const Color(0x00000000),
        recordDraws: () => log.add('draws'),
      );
      img.dispose();
      device.end();

      expect(log, ['before', 'draws', 'after']);
    });
  });
}
