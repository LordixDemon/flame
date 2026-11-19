import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flame_3d/components.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

/// A material whose shaders are faked and receive shadows.
class _Receiver() extends Material {
  this
    : super(
        vertexShader: VertexShader.fromAsset(
          'test',
          slots: [RenderContext3D.cameraMatricesBlock],
        ),
        fragmentShader: FragmentShader.fromAsset(
          'test',
          slots: [
            'Material',
            RenderContext3D.shadowsBlock,
            RenderContext3D.shadowMapSampler,
          ],
        ),
      );
}

void main() {
  late FakeGpuBackend backend;
  late GraphicsDevice device;
  late RenderContext3D context;
  late DirectionalShadowProjection projection;

  final bounds = Aabb3.minMax(Vector3(-2, -2, -12), Vector3(2, 2, -8));

  Surface triangle(Material material) {
    return Surface(
      vertices: [
        Vertex(position: Vector3.zero(), texCoord: Vector2.zero()),
        Vertex(position: Vector3(1, 0, 0), texCoord: Vector2.zero()),
        Vertex(position: Vector3(0, 1, 0), texCoord: Vector2.zero()),
      ],
      indices: [0, 1, 2],
      material: material,
    );
  }

  Light sun({ShadowSettings? shadows}) {
    return Light(
      position: Vector3.zero(),
      source: DirectionalLight(
        direction: Vector3(0.3, -1, -0.2),
        shadows: shadows,
      ),
    );
  }

  /// Renders a frame looking down -z, with a shadow pass first when one of
  /// [lights] casts shadows; [draw] records the draws of both passes.
  /// Returns whether there was a shadow pass.
  bool frame(List<Light> lights, void Function() draw) {
    device.begin();
    context
      ..lights = lights
      ..setCamera(
        Matrix4.identity(),
        Matrix4.identity()..setAsPerspective(60, 1, 0.1, 100),
      );
    final shadows = context.beginShadowPass(
      projection: projection,
      sceneBounds: bounds,
    );
    if (shadows) {
      expect(context.isShadowPass, isTrue);
      draw();
      while (context.advanceShadowAtlasTile()) {
        draw();
      }
      context.endShadowPass();
    }
    expect(context.isShadowPass, isFalse);
    device.beginPass(const Size(16, 16), frontFace: context.frontFace);
    draw();
    context.flush();
    device
      ..endPass()
      ..end();
    return shadows;
  }

  /// The floats of [member] of the Shadows block bound last.
  Float32List shadowsMember(Material material, String member, int floats) {
    final slot = material.fragmentShader.slot(RenderContext3D.shadowsBlock);
    final offset = slot.getMemberOffsetInBytes(member)! ~/ 4;
    return Float32List.sublistView(
      backend.uniforms[RenderContext3D.shadowsBlock]!,
      offset,
      offset + floats,
    );
  }

  setUp(() {
    backend = FakeGpuBackend(textureTargets: true);
    device = GraphicsDevice(backend: backend);
    context = RenderContext3D(device);
    projection = DirectionalShadowProjection();
  });

  group('Shadow pass', () {
    test('none without a light that casts shadows', () {
      final material = _Receiver();
      final surface = triangle(material);
      final shadows = frame([sun()], () {
        context.drawSurface(
          surface,
          transform: Matrix4.translationValues(0, 0, -10),
        );
      });

      expect(shadows, isFalse);
      expect(backend.countCommands('beginRenderPass'), 1);
      expect(backend.countCommands('commit'), 0);
      expect(device.lastFrameStats.shadowPasses, 0);
      // The receivers are told there are no shadows, and get a texture.
      expect(shadowsMember(material, 'toLight', 4)[3], -1);
      expect(
        backend.textureBindings,
        contains(RenderContext3D.shadowMapSampler),
      );
    });

    test('none, once, when the backend has no shadow caster shaders', () {
      // The WebGPU backend has no build of the caster shaders: shadows are
      // off there rather than failing the frame.
      final noCasters = FakeGpuBackend(
        textureTargets: true,
        missingShaderLibraries: {
          'packages/flame_3d/assets/shaders/shadow_caster.shaderbundle',
        },
      );
      final webDevice = GraphicsDevice(backend: noCasters);
      final webContext = RenderContext3D(webDevice);
      final logs = <String?>[];
      final debugPrintBefore = debugPrint;
      debugPrint = (message, {wrapWidth}) => logs.add(message);
      addTearDown(() => debugPrint = debugPrintBefore);
      for (var i = 0; i < 2; i++) {
        webDevice.begin();
        webContext
          ..lights = [sun(shadows: ShadowSettings())]
          ..setCamera(
            Matrix4.identity(),
            Matrix4.identity()..setAsPerspective(60, 1, 0.1, 100),
          );
        expect(
          webContext.beginShadowPass(
            projection: projection,
            sceneBounds: bounds,
          ),
          isFalse,
        );
        expect(webContext.hasActiveShadows, isFalse);
        webDevice.end();
      }
      expect(logs, hasLength(1));
      expect(logs.single, contains('shadow'));
    });

    test('none when the backend cannot render into textures', () {
      backend = FakeGpuBackend();
      device = GraphicsDevice(backend: backend);
      context = RenderContext3D(device);
      final surface = triangle(_Receiver());

      final shadows = frame([sun(shadows: ShadowSettings())], () {
        context.drawSurface(
          surface,
          transform: Matrix4.translationValues(0, 0, -10),
        );
      });

      expect(shadows, isFalse);
      expect(device.lastFrameStats.renderPasses, 1);
    });

    test('renders the casters into the shadow map before the main pass', () {
      final material = _Receiver();
      final surface = triangle(material);
      final shadows = frame(
        [sun(shadows: ShadowSettings(resolution: 512))],
        () {
          for (var i = 0; i < 3; i++) {
            context.drawSurface(
              surface,
              transform: Matrix4.translationValues(i * 0.5, 0, -10),
            );
          }
        },
      );

      expect(shadows, isTrue);
      final commands = backend.commands;
      final shadowPass = commands.indexOf('beginRenderPass 512x512');
      final commit = commands.indexOf('commit');
      final mainPass = commands.indexOf('beginRenderPass 16x16');
      expect(shadowPass, 0);
      expect(commit, greaterThan(shadowPass));
      expect(mainPass, greaterThan(commit));
      // One instanced draw of the three casters, then of the three receivers.
      expect(
        commands.where((c) => c.startsWith('drawIndexed')),
        ['drawIndexed 3 x3', 'drawIndexed 3 x3'],
      );
      final stats = device.lastFrameStats;
      expect(stats.renderPasses, 2);
      expect(stats.shadowPasses, 1);
      expect(stats.drawCalls, 2);
      expect(stats.shadowDrawCalls, 1);
      expect(backend.textureTargetsCreated, [
        (512, 512, GpuPixelFormat.r32Float),
      ]);
      // The main pass samples the map.
      final map = backend.textureBindings[RenderContext3D.shadowMapSampler]!;
      expect(identical(map.$1, backend.textures.last), isTrue);
    });

    test('skips what casts no shadows and batches across materials', () {
      final receiver = _Receiver();
      final other = _Receiver();
      final glass = _Receiver()
        ..renderState = RenderState.premultipliedAlphaBlend;
      final glow = _Receiver()..castsShadows = false;
      final surface = triangle(receiver);
      frame([sun(shadows: ShadowSettings())], () {
        for (final material in [receiver, other, glass, glow]) {
          context.drawSurface(
            surface,
            material: material,
            transform: Matrix4.translationValues(0, 0, -10),
          );
        }
      });

      final draws = backend.commands
          .where((c) => c.startsWith('drawIndexed') || c == 'commit')
          .toList();
      // The shadow pass draws the two opaque materials at once.
      expect(draws.first, 'drawIndexed 3 x2');
      expect(draws[1], 'commit');
      // The main pass draws each material.
      expect(draws.length - 2, 4);
      expect(device.lastFrameStats.shadowDrawCalls, 1);
    });

    test('records no draws of what casts no shadows', () {
      final receiver = _Receiver();
      final glass = _Receiver()
        ..renderState = RenderState.premultipliedAlphaBlend;
      final glow = _Receiver()..castsShadows = false;
      final surface = triangle(receiver);
      final instances = Float32List(VertexLayout.instanceStrideInFloats * 2);
      void draw() {
        for (final material in [receiver, glass, glow]) {
          context.drawSurface(
            surface,
            material: material,
            transform: Matrix4.translationValues(0, 0, -10),
          );
        }
        context.drawInstances(
          surface,
          material: glow,
          instances: instances,
          count: 2,
        );
      }

      device.begin();
      context
        ..lights = [sun(shadows: ShadowSettings())]
        ..setCamera(
          Matrix4.identity(),
          Matrix4.identity()..setAsPerspective(60, 1, 0.1, 100),
        );
      expect(
        context.beginShadowPass(projection: projection, sceneBounds: bounds),
        isTrue,
      );
      draw();
      context.endShadowPass();
      // Only the opaque material was recorded.
      expect(context.drawCount, 1);

      device.beginPass(const Size(16, 16), frontFace: context.frontFace);
      draw();
      context.flush();
      device
        ..endPass()
        ..end();
      expect(context.drawCount, 4);
    });

    test('tells the receivers about the light and its map', () {
      backend = FakeGpuBackend(
        textureTargets: true,
        floatTextureTargets: false,
      );
      device = GraphicsDevice(backend: backend);
      context = RenderContext3D(device);
      final material = _Receiver();
      final surface = triangle(material);
      final settings = ShadowSettings(
        resolution: 256,
        color: const Color(0xFF336699),
        strength: 0.75,
        softness: 2,
        depthBias: 1.25,
      );

      frame([sun(), sun(shadows: settings)], () {
        context.drawSurface(
          surface,
          transform: Matrix4.translationValues(0, 0, -10),
        );
      });

      final toLight = shadowsMember(material, 'toLight', 4);
      final direction = Vector3(0.3, -1, -0.2).normalized();
      expect(toLight[0], closeTo(-direction.x, 1e-6));
      expect(toLight[1], closeTo(-direction.y, 1e-6));
      expect(toLight[2], closeTo(-direction.z, 1e-6));
      // The second directional light casts the shadows.
      expect(toLight[3], 1);
      final color = shadowsMember(material, 'color', 4);
      expect(color[0], closeTo(0x33 / 255, 1e-6));
      expect(color[2], closeTo(0x99 / 255, 1e-6));
      expect(color[3], 0.75);
      expect(shadowsMember(material, 'map', 4), [256, 256, 1 / 256, 1 / 256]);
      final bias = shadowsMember(material, 'bias', 4);
      // The larger side of a texel.
      expect(
        bias[0],
        closeTo(math.max(projection.texelWidth, projection.texelHeight), 1e-6),
      );
      expect(bias.sublist(1), [1.25, 0.5, 2]);
      // Without float targets, the depth is packed into RGBA8.
      expect(backend.textureTargetsCreated.single.$3, GpuPixelFormat.rgba8888);
      expect(shadowsMember(material, 'decode', 4), [
        closeTo(65536 * 255 / 16777215, 1e-9),
        closeTo(256 * 255 / 16777215, 1e-9),
        closeTo(255 / 16777215, 1e-9),
        0,
      ]);
      final lightViewProjection = shadowsMember(
        material,
        'lightViewProjection',
        16,
      );
      expect(
        lightViewProjection,
        orderedEquals(projection.viewProjection.storage),
      );
    });

    test('creates the shadow map once', () {
      final surface = triangle(_Receiver());
      final settings = ShadowSettings(resolution: 128);
      for (var i = 0; i < 3; i++) {
        frame([sun(shadows: settings)], () {
          context.drawSurface(
            surface,
            transform: Matrix4.translationValues(0, 0, -10),
          );
        });
      }
      expect(backend.textureTargetsCreated, hasLength(1));

      settings.resolution = 64;
      frame([sun(shadows: settings)], () {
        context.drawSurface(
          surface,
          transform: Matrix4.translationValues(0, 0, -10),
        );
      });
      expect(backend.textureTargetsCreated, hasLength(2));
    });

    test('a pass after one with shadows has none until told', () {
      final material = _Receiver();
      final surface = triangle(material);
      frame([sun(shadows: ShadowSettings())], () {
        context.drawSurface(
          surface,
          transform: Matrix4.translationValues(0, 0, -10),
        );
      });
      expect(shadowsMember(material, 'toLight', 4)[3], 0);

      // A host that sets its camera without a shadow pass.
      device.begin();
      context.setCamera(Matrix4.identity(), Matrix4.identity());
      device.beginPass(const Size(16, 16));
      context
        ..drawSurface(surface, transform: Matrix4.translationValues(0, 0, -0.5))
        ..flush();
      device
        ..endPass()
        ..end();
      expect(shadowsMember(material, 'toLight', 4)[3], -1);
    });
  });

  group('reuseShadowMap', () {
    /// A main pass whose camera is set without a shadow pass, reusing the
    /// map of [version] when given; returns what reuseShadowMap returned.
    bool mainPass(Surface surface, {int? version}) {
      device.begin();
      context.setCamera(Matrix4.identity(), Matrix4.identity());
      final reused = version != null && context.reuseShadowMap(version);
      device.beginPass(const Size(16, 16));
      context
        ..drawSurface(surface, transform: Matrix4.translationValues(0, 0, -0.5))
        ..flush();
      device
        ..endPass()
        ..end();
      return reused;
    }

    test('fails before any shadow map was rendered', () {
      final material = _Receiver();
      expect(
        mainPass(triangle(material), version: context.shadowMapVersion),
        isFalse,
      );
      expect(shadowsMember(material, 'toLight', 4)[3], -1);
    });

    test('binds the last shadow map to a later pass without rendering', () {
      final material = _Receiver();
      final surface = triangle(material);
      final before = context.shadowMapVersion;
      frame([sun(shadows: ShadowSettings(resolution: 128))], () {
        context.drawSurface(
          surface,
          transform: Matrix4.translationValues(0, 0, -10),
        );
      });
      final version = context.shadowMapVersion;
      expect(version, isNot(before));
      final lightViewProjection = shadowsMember(
        material,
        'lightViewProjection',
        16,
      ).toList();
      final commandsBefore = backend.commands.length;

      expect(mainPass(surface, version: version), isTrue);
      // No shadow pass: one main pass, no commit.
      final commands = backend.commands.sublist(commandsBefore);
      expect(commands.where((c) => c.startsWith('beginRenderPass')), [
        'beginRenderPass 16x16',
      ]);
      expect(commands, isNot(contains('commit')));
      expect(device.lastFrameStats.shadowPasses, 0);
      // The same map and the same light as the pass that rendered it.
      expect(shadowsMember(material, 'toLight', 4)[3], 0);
      expect(
        shadowsMember(material, 'lightViewProjection', 16),
        orderedEquals(lightViewProjection),
      );
      final map = backend.textureBindings[RenderContext3D.shadowMapSampler]!;
      expect(identical(map.$1, backend.textures.last), isTrue);
      expect(context.shadowMapVersion, version);
    });

    test('binds the atlas again to a later pass', () {
      final material = _Receiver();
      final surface = triangle(material);
      final settings = ShadowSettings(
        resolution: 128,
        cascades: 2,
        cascadeSplits: [0.8, 1],
      );
      frame([sun(shadows: settings)], () {
        context.drawSurface(
          surface,
          transform: Matrix4.translationValues(0, 0, -10),
        );
      });
      expect(shadowsMember(material, 'atlas', 4).toList(), [1, 2, 0, -1]);
      final version = context.shadowMapVersion;

      expect(mainPass(surface, version: version), isTrue);
      expect(context.hasShadowAtlas, isTrue);
      expect(shadowsMember(material, 'atlas', 4).toList(), [1, 2, 0, -1]);
      expect(shadowsMember(material, 'toLight', 4)[3], 0);
    });

    test('fails once another shadow map was rendered', () {
      final material = _Receiver();
      final surface = triangle(material);
      void shadowFrame() {
        frame([sun(shadows: ShadowSettings(resolution: 128))], () {
          context.drawSurface(
            surface,
            transform: Matrix4.translationValues(0, 0, -10),
          );
        });
      }

      shadowFrame();
      final version = context.shadowMapVersion;
      shadowFrame();
      expect(context.shadowMapVersion, isNot(version));
      expect(mainPass(surface, version: version), isFalse);
      expect(shadowsMember(material, 'toLight', 4)[3], -1);
    });

    test('is refused while a shadow pass is recorded', () {
      device.begin();
      context
        ..lights = [sun(shadows: ShadowSettings())]
        ..setCamera(
          Matrix4.identity(),
          Matrix4.identity()..setAsPerspective(60, 1, 0.1, 100),
        );
      expect(
        context.beginShadowPass(projection: projection, sceneBounds: bounds),
        isTrue,
      );
      expect(
        () => context.reuseShadowMap(context.shadowMapVersion),
        throwsStateError,
      );
      context.endShadowPass();
      device.end();
    });
  });

  group('Material.castsShadows', () {
    test('defaults to whether the material is opaque', () {
      final material = _Receiver();
      expect(material.castsShadows, isTrue);
      material.renderState = RenderState.additive;
      expect(material.castsShadows, isFalse);
      material.castsShadows = true;
      expect(material.castsShadows, isTrue);
      material
        ..renderState = RenderState.opaque
        ..castsShadows = false;
      expect(material.castsShadows, isFalse);
      material.castsShadows = null;
      expect(material.castsShadows, isTrue);
    });
  });

  group('Cascades', () {
    /// The floats of element [index] of the array [member] of the Shadows
    /// block bound last.
    Float32List element(Material material, String member, int index, int n) {
      final all = shadowsMember(material, member, (index + 1) * n);
      return Float32List.sublistView(all, index * n);
    }

    List<double> cascade0(ShadowSettings settings) {
      final material = _Receiver();
      final surface = triangle(material);
      frame([sun(shadows: settings)], () {
        context.drawSurface(
          surface,
          transform: Matrix4.translationValues(0, 0, -10),
        );
      });
      expect(shadowsMember(material, 'atlas', 4)[1], 2);
      expect(
        element(material, 'atlasCascadeParams', 0, 4)[1],
        closeTo(settings.cascadeBlendRange, 1e-6),
      );
      return element(material, 'atlasCascadeViewProjections', 0, 16).toList();
    }

    test('two cascades read cascadeSplits and cascadeBlendRange', () {
      final near = cascade0(
        ShadowSettings(
          cascades: 2,
          cascadeSplits: [0.75, 1],
          cascadeBlendRange: 0.25,
        ),
      );
      final far = cascade0(
        ShadowSettings(
          cascades: 2,
          cascadeSplits: [0.9, 1],
          cascadeBlendRange: 0.05,
        ),
      );
      expect(near, isNot(orderedEquals(far)));
    });

    test('cascadeSplits must have one increasing split per cascade', () {
      expect(
        () => ShadowSettings(cascades: 2, cascadeSplits: [0.2, 0.5, 1]),
        throwsArgumentError,
      );
      // The split of the last cascade, which covers it all, may be left out.
      expect(ShadowSettings(cascades: 3, cascadeSplits: [0.2, 0.5]), isNotNull);
      expect(
        () => ShadowSettings(cascades: 2, cascadeSplits: [0.6, 0.5]),
        throwsArgumentError,
      );
      expect(
        () => ShadowSettings(cascades: 2, cascadeSplits: [0, 1]),
        throwsArgumentError,
      );
      expect(
        ShadowSettings(cascades: 3, cascadeSplits: [0.2, 0.5, 1]),
        isNotNull,
      );
      // A list changed afterwards is checked when the pass reads it.
      final settings = ShadowSettings(cascades: 2)..cascades = 4;
      settings.cascadeSplits = [0.5, 1];
      device.begin();
      context
        ..lights = [sun(shadows: settings)]
        ..setCamera(
          Matrix4.identity(),
          Matrix4.identity()..setAsPerspective(60, 1, 0.1, 100),
        );
      expect(
        () => context.beginShadowPass(
          projection: projection,
          sceneBounds: bounds,
        ),
        throwsStateError,
      );
    });
  });

  group('The atlas', () {
    /// Renders a frame of a sun with [settings], and [others], and returns
    /// the size of the atlas (from the `map` member) and of its tiles.
    (List<double>, List<int>) atlasOf(
      ShadowSettings settings, [
      List<Light> others = const [],
    ]) {
      final material = _Receiver();
      final surface = triangle(material);
      frame([sun(shadows: settings), ...others], () {
        context.drawSurface(
          surface,
          transform: Matrix4.translationValues(0, 0, -10),
        );
      });
      expect(context.hasShadowAtlas, isTrue);
      return (
        shadowsMember(material, 'map', 2).toList(),
        [for (final tile in context.shadowAtlas.tiles) tile.width],
      );
    }

    void expectAtlas(
      (List<double>, List<int>) atlas,
      List<double> size,
      List<int> tiles,
    ) {
      expect(atlas.$1, size);
      expect(atlas.$2, tiles);
    }

    test('keeps the resolution asked for', () {
      // Two cascades of 2048 are side by side in 4096 by 2048 texels.
      expectAtlas(
        atlasOf(
          ShadowSettings(
            resolution: 2048,
            cascades: 2,
            cascadeSplits: [0.8, 1],
          ),
        ),
        [4096, 2048],
        [2048, 2048],
      );
      // A resolution that is not a power of two is kept.
      expectAtlas(
        atlasOf(
          ShadowSettings(
            resolution: 768,
            cascades: 2,
            cascadeSplits: [0.8, 1],
          ),
        ),
        [1536, 768],
        [768, 768],
      );
    });

    test('is as large as its tiles', () {
      final spot = Light(
        position: Vector3(0, 4, -10),
        source: SpotLight(
          direction: Vector3(0, -1, 0),
          range: 10,
          shadows: ShadowSettings(),
        ),
      );
      // A sun and a spot light: two tiles, not a square of four.
      expectAtlas(
        atlasOf(ShadowSettings(), [spot]),
        [2048, 1024],
        [1024, 1024],
      );
    });

    test('reuses its tiles from frame to frame', () {
      final settings = ShadowSettings(cascades: 2, cascadeSplits: [0.8, 1]);
      atlasOf(settings);
      final first = context.shadowAtlas.tiles.toList();
      final rects = [for (final tile in first) tile.uvRect];
      final matrix = first[0].viewProjection!.clone();
      atlasOf(settings);
      final second = context.shadowAtlas.tiles;
      expect(second, hasLength(first.length));
      for (var i = 0; i < first.length; i++) {
        expect(identical(second[i], first[i]), isTrue);
        expect(identical(second[i].uvRect, rects[i]), isTrue);
      }
      expect(second[0].viewProjection, matrix);
    });

    test('copies what its tiles are given', () {
      final atlas = ShadowAtlas3D()..reset(width: 512, height: 256);
      final view = Matrix4.translationValues(1, 2, 3);
      final position = Vector3(4, 5, 6);
      final tile = atlas.allocateTile(
        kind: ShadowAtlasTileKind3D.spotLight,
        lightIndex: 1,
        tileSize: 256,
        view: view,
        projection: Matrix4.identity(),
        viewProjection: view,
        lightPosition: position,
      )!;
      view.setIdentity();
      position.setZero();
      expect(tile.view, Matrix4.translationValues(1, 2, 3));
      expect(tile.lightPosition, Vector3(4, 5, 6));
      expect(tile.uvRect, Vector4(0, 0, 0.5, 1));
      final point = atlas.allocateTile(
        kind: ShadowAtlasTileKind3D.pointParaboloidFront,
        lightIndex: 0,
        tileSize: 256,
      )!;
      expect(point.view, isNull);
      expect(point.lightPosition, isNull);
      expect(point.uvRect, Vector4(0.5, 0, 0.5, 1));
      expect(
        atlas.allocateTile(
          kind: ShadowAtlasTileKind3D.pointParaboloidBack,
          lightIndex: 0,
          tileSize: 256,
        ),
        isNull,
      );
    });

    test('shrinks its tiles to fit within its largest size', () {
      final atlas = ShadowAtlas3D();
      expect(atlas.recommendedTileSize(2, preferred: 8192), 2048);
      expect(atlas.recommendedTileSize(8, preferred: 2048), 1365);
      expect(atlas.recommendedTileSize(1, preferred: 700), 700);
    });
  });

  group('Point light tiles', () {
    // The main camera sees x and y in [-1, 1]; the point light at
    // (2.5, 0, -3) reaches 10 units around it.
    final pointLight = Light(
      position: Vector3(2.5, 0, -3),
      source: PointLight(
        color: const Color(0xFFFFFFFF),
        intensity: 1,
        range: 10,
        shadows: ShadowSettings(resolution: 256),
      ),
    );
    final spotAway = Light(
      position: Vector3(-0.5, 0, -2),
      source: SpotLight(
        direction: Vector3(-1, 0, 0),
        range: 3,
        outerConeAngle: 0.3,
        shadows: ShadowSettings(resolution: 256),
      ),
    );
    // Out of the main camera's view, and of the spot light's.
    final outOfView = Aabb3.minMax(
      Vector3(1.05, -0.2, -4.2),
      Vector3(1.45, 0.2, -3.8),
    );
    // Out of the light's reach.
    final outOfReach = Aabb3.minMax(Vector3(20, 0, -4), Vector3(21, 1, -3));

    for (final (name, lights) in [
      ('alone', [pointLight]),
      ('after a spot light', [spotAway, pointLight]),
    ]) {
      test('cull with the bounds of the light, $name', () {
        device.begin();
        context
          ..lights = lights
          ..setCamera(
            Matrix4.identity(),
            Matrix4.identity()..setEntry(2, 2, -0.1),
          );
        expect(
          context.beginShadowPass(
            projection: projection,
            sceneBounds: Aabb3.minMax(Vector3(-1, -1, -5), Vector3(1.5, 1, -3)),
          ),
          isTrue,
        );
        var index = 0;
        var pointTiles = 0;
        var seen = 0;
        do {
          final tile = context.shadowAtlas.tiles[index++];
          if (tile.kind == ShadowAtlasTileKind3D.pointParaboloidFront ||
              tile.kind == ShadowAtlasTileKind3D.pointParaboloidBack) {
            pointTiles++;
            // The cube is below the light: in the tile of its -z half.
            if (context.frustum.intersectsWithAabb3(outOfView)) {
              seen++;
              expect(tile.kind, ShadowAtlasTileKind3D.pointParaboloidBack);
            }
            expect(context.frustum.intersectsWithAabb3(outOfReach), isFalse);
          }
          // Components pick what they draw (levels of detail, chunks) as the
          // main camera sees them.
          expect(context.viewerPosition, Vector3.zero());
        } while (context.advanceShadowAtlasTile());
        expect(pointTiles, 2);
        expect(seen, 1);
        context.endShadowPass();
        device.end();
      });
    }
  });

  group('ShadowSettings', () {
    test('checks its resolution and softness', () {
      final settings = ShadowSettings();
      expect(settings.resolution, 1024);
      expect(settings.softness, 1);
      expect(() => settings.resolution = 8, throwsArgumentError);
      expect(() => settings.resolution = 16384, throwsArgumentError);
      expect(() => settings.softness = -1, throwsArgumentError);
      expect(
        () => settings.softness = ShadowSettings.maxSoftness + 1,
        throwsArgumentError,
      );
      expect(() => ShadowSettings(resolution: 4), throwsArgumentError);
    });

    test('are given to directional lights', () {
      final settings = ShadowSettings();
      final light = LightComponent.directional(shadows: settings);
      expect((light.source as DirectionalLight).shadows, same(settings));
      expect(DirectionalLight().shadows, isNull);
    });
  });

  group('RenderStats', () {
    test('count shadow passes and draw calls', () {
      final stats = RenderStats()
        ..shadowPasses = 2
        ..shadowDrawCalls = 5;
      final copy = RenderStats()..setFrom(stats);
      expect(copy.shadowPasses, 2);
      expect(copy.shadowDrawCalls, 5);
      expect(copy.toString(), contains('shadowDrawCalls: 5'));
      stats.reset();
      expect(stats.shadowPasses, 0);
      expect(stats.shadowDrawCalls, 0);
    });
  });
}
