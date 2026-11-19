import 'dart:typed_data';
import 'dart:ui';

import 'package:flame/game.dart' show GameWidget;
import 'package:flame_3d/camera.dart';
import 'package:flame_3d/components.dart';
import 'package:flame_3d/game.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/resources.dart';
import 'package:flutter/widgets.dart' show ObjectKey;
import 'package:flutter_test/flutter_test.dart';

import 'gpu_test_helpers.dart';

Matrix4 _persp(double fovDeg, double aspect, double near, double far) =>
    Matrix4.identity()..setAsPerspective(fovDeg, aspect, near, far);

Matrix4 _lookAt(Vector3 eye, Vector3 target, Vector3 up) =>
    Matrix4.identity()..setAsViewMatrix(eye, target, up);

Future<Pixels> _snapshotWorld(
  WidgetTester tester,
  World3D world, {
  required Matrix4 view,
  required Matrix4 projection,
  int width = 128,
  int height = 128,
  Color clearValue = const Color(0xFF000000),
  GraphicsDevice? device,
  RenderContext3D? context,
}) async {
  if (!world.isMounted) {
    final game = FlameGame3D(world: world);
    await tester.pumpWidget(GameWidget(key: ObjectKey(game), game: game));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
  } else {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return (await tester.runAsync(() async {
    final dev = device ?? GraphicsDevice();
    final ctx = context ?? RenderContext3D(dev);
    dev.begin();
    final img = world.renderToImage(
      Size(width.toDouble(), height.toDouble()),
      view: view,
      projection: projection,
      clearValue: clearValue,
      device: dev,
      context: ctx,
    );
    dev.end();
    final px = await readImage(img);
    img.dispose();
    return px;
  }))!;
}

EnvironmentProbe3D _makeContrastProbe() {
  const w = 64;
  const h = 32;
  final bytes = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final isTopBand = y < 8;
    for (var x = 0; x < w; x++) {
      final isHotspot = isTopBand && x >= 24 && x < 40;
      final idx = (y * w + x) * 4;
      bytes[idx] = isHotspot ? 255 : (y < 16 ? 70 : 18);
      bytes[idx + 1] = isHotspot ? 245 : (y < 16 ? 110 : 22);
      bytes[idx + 2] = isHotspot ? 210 : (y < 16 ? 190 : 35);
      bytes[idx + 3] = 255;
    }
  }
  return EnvironmentProbe3D.fromEquirectangular(
    ByteData.sublistView(bytes),
    width: w,
    height: h,
    intensity: 1.4,
  );
}

Texture _makeCheckerTexture({
  int size = 32,
  TextureSampler sampler = TextureSampler.anisotropic16x,
}) {
  final bytes = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final even = ((x ~/ 4) + (y ~/ 4)).isEven;
      final o = (y * size + x) * 4;
      bytes[o] = even ? 245 : 25;
      bytes[o + 1] = even ? 235 : 35;
      bytes[o + 2] = even ? 220 : 55;
      bytes[o + 3] = 255;
    }
  }
  return Texture(
    ByteData.sublistView(bytes),
    width: size,
    height: size,
    mipmaps: true,
    sampler: sampler,
  );
}

void main() {
  setUpGpu();

  testGpu(
    'Linear HDR rgbaFloat16 preserves super-white bloom (> 1.0) and applies '
    'ACES / AgX tonemapping + ColorLut3D film presets',
    (tester) async {
      expect(
        GpuBackend.instance.supportsPixelFormat(GpuPixelFormat.rgbaFloat16),
        isTrue,
      );

      final view = _lookAt(
        Vector3(0, 0, 4),
        Vector3.zero(),
        Vector3(0, 1, 0),
      );
      final proj = _persp(60, 1, 0.2, 40);

      Future<Pixels> renderHdrScene({
        required bool hdr,
        ToneMapMode toneMap = ToneMapMode.acesFilmic,
        ColorLut3D? lut,
      }) {
        final world = World3D(
          hdrEnabled: hdr,
          bloom: BloomSettings(
            threshold: 1.35,
            softKnee: 0.05,
            intensity: 1.4,
            radius: 2.4,
            passes: 4,
          ),
          postProcess: PostProcessSettings(
            toneMap: toneMap,
            colorLut: lut,
          ),
          children: [
            LightComponent.directional(
              direction: Vector3(0, 0, -1),
              intensity: 2,
            ),
            MeshComponent(
              mesh: SphereMesh(
                radius: 0.45,
                material: SpatialMaterial(
                  emissiveColor: const Color(0xFFFFFFFF),
                  emissiveStrength: 3.5,
                  roughness: 0.35,
                ),
              ),
            ),
          ],
        );
        return _snapshotWorld(
          tester,
          world,
          view: view,
          projection: proj,
        );
      }

      // Measure bloom halo OUTSIDE the sphere's screen silhouette (sphere
      // projects to r = 12.5 px around (64, 64), so r > 15 px is pure black
      // background unless bloom spreads beyond the silhouette!): with
      // threshold = 1.35 (> 1.0), legacy SDR clamps scene radiance below 1.0 so
      // bloom extracts 0 halo, whereas float16 HDR preserves radiance > 1.35!
      final sdrPx = await renderHdrScene(hdr: false);
      final hdrPx = await renderHdrScene(hdr: true);

      int countOuterHalo(Pixels px) {
        var count = 0;
        for (var y = 0; y < px.height; y++) {
          for (var x = 0; x < px.width; x++) {
            final dx = x - 64;
            final dy = y - 64;
            if (dx * dx + dy * dy > 15 * 15) {
              final (r, g, b, _) = px.at(x, y);
              if (r > 6 || g > 6 || b > 6) {
                count++;
              }
            }
          }
        }
        return count;
      }

      final sdrHaloCount = countOuterHalo(sdrPx);
      final hdrHaloCount = countOuterHalo(hdrPx);
      expect(sdrHaloCount, 0);
      expect(hdrHaloCount, greaterThan(80));

      // Verify ColorLut3D film presets shift midtone halo color channels.
      final warmPx = await renderHdrScene(
        hdr: true,
        toneMap: ToneMapMode.agx,
        lut: ColorLut3D.warmCinematic(),
      );
      final coolPx = await renderHdrScene(
        hdr: true,
        toneMap: ToneMapMode.agx,
        lut: ColorLut3D.coolNight(),
      );
      final sepiaPx = await renderHdrScene(
        hdr: true,
        lut: ColorLut3D.sepia(),
      );

      final (wr, _, wb, _) = warmPx.at(50, 64);
      final (cr, _, cb, _) = coolPx.at(50, 64);
      final (sr, sg, sb, _) = sepiaPx.at(50, 64);

      expect(wr - wb, greaterThan(cr - cb));
      expect(sr, greaterThan(sg));
      expect(sg, greaterThan(sb));
    },
  );

  testGpu(
    'Anisotropic 16x sampler, Viewport/Scissor quadrants, Stencil portal mask, '
    'PolygonFillMode.wireframe, and Line/TriangleStrip topologies',
    (tester) async {
      expect(GpuBackend.instance.maxSamplerAnisotropy, greaterThanOrEqualTo(1));

      // 1. Grazing-angle floor with TextureSampler.anisotropic16x.
      final anisoWorld = World3D(
        children: [
          LightComponent.ambient(intensity: 1),
          MeshComponent(
            position: Vector3(0, -0.8, -3),
            mesh: PlaneMesh(
              size: Vector2(8, 12),
              material: SpatialMaterial(
                albedoTexture: _makeCheckerTexture(),
                roughness: 0.7,
              ),
            ),
          ),
        ],
      );
      final anisoPx = await _snapshotWorld(
        tester,
        anisoWorld,
        view: _lookAt(
          Vector3(0, 0.35, 2),
          Vector3(0, -0.8, -4),
          Vector3(0, 1, 0),
        ),
        projection: _persp(60, 1, 0.1, 30),
      );
      expect(anisoPx.count((r, g, b, _) => r > 20 || b > 20), greaterThan(900));

      // 2. Viewport + Scissor quadrant isolation & Stencil portal mask &
      //    Wireframe & Line/Strip topologies directly on GraphicsDevice.
      final (
        quadrantPx,
        stencilPx,
        wirePx,
        fillPx,
        linePx,
      ) = (await tester.runAsync(() async {
        final device = GraphicsDevice();
        final ctx = RenderContext3D(device);

        final redMat = opaqueUnlit(const Color(0xFFFF2020));
        final blueMat = opaqueUnlit(const Color(0xFF2060FF));
        final fullRed = quad(redMat, halfSize: 1);
        final fullBlue = quad(blueMat, halfSize: 1);

        // A) Viewport + Scissor quadrants (top-left red, bottom-right blue)
        device.begin();
        ctx.setCamera(defaultView, defaultProjection);
        device.beginPass(const Size(128, 128));
        device
          ..setViewport(0, 0, 64, 64)
          ..setScissor(0, 0, 64, 64);
        ctx
          ..drawSurface(fullRed)
          ..flush();
        device
          ..setViewport(64, 64, 64, 64)
          ..setScissor(64, 64, 64, 64);
        ctx
          ..drawSurface(fullBlue)
          ..flush();
        final qImg = device.endPass();
        device.end();
        final qPx = await readImage(qImg);
        qImg.dispose();

        // B) Stencil portal cutout: small central portal writes ref = 5,
        //    fullscreen green quad tests equal == 5.
        final maskMat = UnlitMaterial(albedoColor: const Color(0xFF2040FF))
          ..renderState = const RenderState(
            depthTest: false,
            depthWrite: false,
            stencil: StencilState.writeReference(5),
          );
        final portalGreenMat =
            UnlitMaterial(albedoColor: const Color(0xFF20FF50))
              ..renderState = const RenderState(
                depthTest: false,
                depthWrite: false,
                stencil: StencilState.testEqual(5),
              );
        final smallPortal = quad(maskMat, halfSize: 0.35);
        final fullGreen = quad(portalGreenMat, halfSize: 1);

        device.begin();
        ctx.setCamera(defaultView, defaultProjection);
        device.beginPass(const Size(128, 128));
        ctx
          ..drawSurface(smallPortal)
          ..flush()
          ..drawSurface(fullGreen)
          ..flush();
        final sImg = device.endPass();
        device.end();
        final sPx = await readImage(sImg);
        sImg.dispose();

        // C) PolygonFillMode.wireframe vs PolygonFillMode.fill
        final wireMat = UnlitMaterial(albedoColor: const Color(0xFFFFEE20))
          ..renderState = const RenderState(
            polygonMode: PolygonFillMode.wireframe,
          );
        final solidMat = opaqueUnlit(const Color(0xFFFFEE20));

        device.begin();
        ctx.setCamera(defaultView, defaultProjection);
        device.beginPass(const Size(128, 128));
        ctx
          ..drawSurface(quad(wireMat, halfSize: 0.7))
          ..flush();
        final wImg = device.endPass();
        device.end();
        final wPx = await readImage(wImg);
        wImg.dispose();

        device.begin();
        ctx.setCamera(defaultView, defaultProjection);
        device.beginPass(const Size(128, 128));
        ctx
          ..drawSurface(quad(solidMat, halfSize: 0.7))
          ..flush();
        final fImg = device.endPass();
        device.end();
        final fPx = await readImage(fImg);
        fImg.dispose();

        // D) PrimitiveTopology.lines + PrimitiveTopology.triangleStrip
        final cyanLineMat = opaqueUnlit(const Color(0xFF00F0FF));
        final crossLines = Surface(
          vertices: [
            Vertex(position: Vector3(-0.8, -0.8, 0), texCoord: Vector2.zero()),
            Vertex(position: Vector3(0.8, 0.8, 0), texCoord: Vector2(1, 1)),
            Vertex(position: Vector3(-0.8, 0.8, 0), texCoord: Vector2(0, 1)),
            Vertex(position: Vector3(0.8, -0.8, 0), texCoord: Vector2(1, 0)),
          ],
          indices: [0, 1, 2, 3],
          material: cyanLineMat,
          topology: PrimitiveTopology.lines,
        );
        final stripSurface = Surface(
          vertices: [
            Vertex(position: Vector3(-0.2, -0.2, 0), texCoord: Vector2.zero()),
            Vertex(position: Vector3(0.2, -0.2, 0), texCoord: Vector2(1, 0)),
            Vertex(position: Vector3(-0.2, 0.2, 0), texCoord: Vector2(0, 1)),
            Vertex(position: Vector3(0.2, 0.2, 0), texCoord: Vector2(1, 1)),
          ],
          indices: [0, 1, 2, 3],
          material: cyanLineMat,
          topology: PrimitiveTopology.triangleStrip,
        );

        device.begin();
        ctx.setCamera(defaultView, defaultProjection);
        device.beginPass(const Size(128, 128));
        ctx
          ..drawSurface(crossLines)
          ..drawSurface(stripSurface)
          ..flush();
        final lImg = device.endPass();
        device.end();
        final lPx = await readImage(lImg);
        lImg.dispose();

        return (qPx, sPx, wPx, fPx, lPx);
      }))!;

      // Quadrant checks: (32, 32) is red, (96, 96) is blue, off-diagonals
      // clear.
      expect(quadrantPx.at(32, 32).$1, greaterThan(220));
      expect(quadrantPx.at(32, 32).$3, lessThan(60));
      expect(quadrantPx.at(96, 96).$3, greaterThan(220));
      expect(quadrantPx.at(96, 96).$1, lessThan(60));
      expect(quadrantPx.isClear(96, 32), isTrue);
      expect(quadrantPx.isClear(32, 96), isTrue);

      // Stencil portal checks: center (64, 64) is bright green, outer (12, 12)
      // was masked out by stencil != 5!
      expect(stencilPx.at(64, 64).$2, greaterThan(220));
      expect(stencilPx.isClear(12, 12), isTrue);

      // Wireframe draws far fewer pixels than solid fill while still drawing
      // non-empty edges + diagonal!
      final wireLit = wirePx.count((r, g, _, a) => a > 0 && r > 150 && g > 150);
      final fillLit = fillPx.count((r, g, _, a) => a > 0 && r > 150 && g > 150);
      expect(wireLit, greaterThan(60));
      expect(wireLit, lessThan(fillLit ~/ 3));

      // Line + triangleStrip center and diagonal are cyan.
      expect(linePx.at(64, 64).$2, greaterThan(200));
      expect(linePx.at(64, 64).$3, greaterThan(200));
    },
  );

  testGpu(
    'Ktx2TextureLoader uploads RGBA8 sRGB and BC1 textures on real Flutter GPU',
    (tester) async {
      final raw = Uint8List(8 * 8 * 4);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          final leftHalf = x < 4;
          final o = (y * 8 + x) * 4;
          raw[o] = leftHalf ? 248 : 20;
          raw[o + 1] = leftHalf ? 24 : 236;
          raw[o + 2] = 28;
          raw[o + 3] = 255;
        }
      }

      final ktxSrgb = Ktx2TextureLoader.encodeUncompressedRgba8(
        raw,
        width: 8,
        height: 8,
        srgb: true,
      );
      final ktxBc1 = Ktx2TextureLoader.encodeBc1(raw, width: 8, height: 8);

      final texSrgb = Ktx2TextureLoader.load(
        ktxSrgb,
        sampler: TextureSampler.nearest,
      );
      final texBc1 = Ktx2TextureLoader.load(
        ktxBc1,
        sampler: TextureSampler.nearest,
      );

      final px = (await tester.runAsync(() async {
        final f = await renderFrame(
          width: 128,
          height: 128,
          draw: (ctx) {
            ctx
              ..drawSurface(
                quad(
                  UnlitMaterial(albedoTexture: texSrgb)
                    ..renderState = RenderState.opaque,
                  halfSize: 0.42,
                ),
                transform: Matrix4.translationValues(-0.5, 0, 0),
              )
              ..drawSurface(
                quad(
                  UnlitMaterial(albedoTexture: texBc1)
                    ..renderState = RenderState.opaque,
                  halfSize: 0.42,
                ),
                transform: Matrix4.translationValues(0.5, 0, 0),
              );
          },
        );
        return f.pixels;
      }))!;

      // Left quad (KTX2 sRGB): left half red, right half green.
      expect(px.at(22, 64).$1, greaterThan(180));
      expect(px.at(42, 64).$2, greaterThan(180));
      // Right quad (KTX2 BC1): left half red, right half green.
      expect(px.at(86, 64).$1, greaterThan(180));
      expect(px.at(106, 64).$2, greaterThan(180));
    },
  );

  testGpu(
    'Split-Sum BrdfLut3D, Roughness Mips, ReflectionProbeVolume3D, MikkTSpace '
    'Tangents, Clearcoat, Lightmap, and LightProbeGrid3D render on GPU',
    (tester) async {
      final envProbe = _makeContrastProbe();
      final view = _lookAt(
        Vector3(0, 0.4, 4.2),
        Vector3.zero(),
        Vector3(0, 1, 0),
      );
      final proj = _persp(60, 1, 0.2, 40);

      // 1. Mirror metal (roughness 0.04) vs rough metal (roughness 0.88) under
      //    Split-Sum + Kulla-Conty multi-scattering IBL + Clearcoat + Lightmap.
      final lightmapBytes = Uint8List.fromList([
        255, 220, 160, 255, //
        255, 220, 160, 255, //
        255, 220, 160, 255, //
        255, 220, 160, 255,
      ]);
      final lightmapTex = Texture(
        ByteData.sublistView(lightmapBytes),
        width: 2,
        height: 2,
      );

      final normalBytes = Uint8List(4 * 4 * 4);
      for (var i = 0; i < 16; i++) {
        normalBytes[i * 4] = i.isEven ? 180 : 80;
        normalBytes[i * 4 + 1] = 128;
        normalBytes[i * 4 + 2] = 245;
        normalBytes[i * 4 + 3] = 255;
      }
      final normalMap = Texture(
        ByteData.sublistView(normalBytes),
        width: 4,
        height: 4,
      );

      final sphereMirror = SphereMesh(
        radius: 0.72,
        material: SpatialMaterial(
          albedoColor: const Color(0xFFFFD88A),
          metallic: 1,
          roughness: 0.04,
          environmentProbe: envProbe,
          clearcoat: 1,
          clearcoatRoughness: 0.06,
        ),
      );
      final sphereRough = SphereMesh(
        radius: 0.72,
        material: SpatialMaterial(
          albedoColor: const Color(0xFFFFD88A),
          metallic: 1,
          roughness: 0.88,
          environmentProbe: envProbe,
          normalTexture: normalMap,
          lightmapTexture: lightmapTex,
          lightmapIntensity: 0.35,
        ),
      );
      for (final s in sphereRough.surfaces) {
        s.computeTangents();
      }

      final iblWorld = World3D(
        children: [
          ReflectionProbeVolume3D(
            probe: envProbe,
            extents: Vector3.all(6),
          ),
          MeshComponent(position: Vector3(-1, 0, 0), mesh: sphereMirror),
          MeshComponent(position: Vector3(1, 0, 0), mesh: sphereRough),
        ],
      );
      final iblPx = await _snapshotWorld(
        tester,
        iblWorld,
        view: view,
        projection: proj,
      );

      // Both mirror and rough gold spheres render visibly without rough-metal
      // energy collapse.
      final leftLit = iblPx.count((r, g, _, _) => r > 35 && g > 25);
      expect(leftLit, greaterThan(800));
      expect(iblPx.at(38, 64).$1, greaterThan(25));
      expect(iblPx.at(90, 64).$1, greaterThan(25));

      // 2. LightProbeGrid3D spatially varying SH9 diffuse indirect lighting:
      //    warm red light on -X, cool blue light on +X, zero direct lights in
      //    World3D itself!
      final bakedGrid = LightProbeGrid3D.bakeFromLights(
        bounds: Aabb3.minMax(Vector3(-4, -2, -4), Vector3(4, 3, 4)),
        ambientIntensity: 0,
        lights: [
          Light(
            position: Vector3(-2.5, 0.5, 1),
            source: PointLight(
              color: const Color(0xFFFF3010),
              intensity: 28,
              range: 6,
            ),
          ),
          Light(
            position: Vector3(2.5, 0.5, 1),
            source: PointLight(
              color: const Color(0xFF1070FF),
              intensity: 28,
              range: 6,
            ),
          ),
        ],
      );

      final gridWorld = World3D(
        lightProbeGrid: bakedGrid,
        children: [
          MeshComponent(
            position: Vector3(-1.1, 0, 0),
            mesh: SphereMesh(
              radius: 0.7,
              material: SpatialMaterial(roughness: 0.9),
            ),
          ),
          MeshComponent(
            position: Vector3(1.1, 0, 0),
            mesh: SphereMesh(
              radius: 0.7,
              material: SpatialMaterial(roughness: 0.9),
            ),
          ),
        ],
      );

      final gridPx = await _snapshotWorld(
        tester,
        gridWorld,
        view: view,
        projection: proj,
      );
      final (lr, _, lb, _) = gridPx.at(36, 64);
      final (rr, _, rb, _) = gridPx.at(92, 64);
      expect(lr, greaterThan(lb + 15));
      expect(rb, greaterThan(rr + 15));
    },
  );

  testGpu(
    'Unified ShadowAtlas3D renders 4-CSM + Spot + Dual-Paraboloid PointLight '
    'shadows in 1 pass, plus RenderDebugMode3D diagnostic views',
    (tester) async {
      final view = _lookAt(
        Vector3(0, 6.5, 7.5),
        Vector3(0, 0, 0),
        Vector3(0, 1, 0),
      );
      final proj = _persp(60, 1, 0.3, 60);

      World3D buildShadowScene({required bool withShadows}) {
        final shadowCfg = withShadows
            ? ShadowSettings(resolution: 512, strength: 0.9)
            : null;
        final csmCfg = withShadows
            ? ShadowSettings(cascades: 4, resolution: 512, strength: 0.9)
            : null;
        return World3D(
          depthPrepassEnabled: true,
          children: [
            // Weak directional + spot + strong central omnidirectional point
            // light at (0, 1.8, 0) with occluders on both +Z and -Z sides!
            LightComponent.directional(
              direction: Vector3(-0.3, -1, -0.2)..normalize(),
              intensity: 0.35,
              shadows: csmCfg,
            ),
            LightComponent.spot(
              position: Vector3(-3, 5, 0),
              direction: Vector3(0.4, -1, 0)..normalize(),
              intensity: 3,
              range: 16,
              shadows: shadowCfg,
            ),
            LightComponent(
              position: Vector3(0, 1.8, 0),
              source: PointLight(
                color: const Color(0xFFFFFFFF),
                intensity: 24,
                range: 14,
                shadows: shadowCfg,
              ),
            ),
            // Floor receiver
            MeshComponent(
              mesh: PlaneMesh(
                size: Vector2(14, 14),
                material: SpatialMaterial(
                  albedoColor: const Color(0xFFE8ECF4),
                  roughness: 0.85,
                ),
              ),
            ),
            // +Z hemisphere occluder casting shadow toward (0, 0, 3.2)
            MeshComponent(
              position: Vector3(0, 0.9, 1.4),
              mesh: CuboidMesh(
                size: Vector3(1.1, 1.4, 0.5),
                material: SpatialMaterial(albedoColor: const Color(0xFFCC5544)),
              ),
            ),
            // -Z hemisphere occluder casting shadow toward (0, 0, -3.2)
            MeshComponent(
              position: Vector3(0, 0.9, -1.4),
              mesh: CuboidMesh(
                size: Vector3(1.1, 1.4, 0.5),
                material: SpatialMaterial(albedoColor: const Color(0xFF4477CC)),
              ),
            ),
          ],
        );
      }

      final unshadowedWorld = buildShadowScene(withShadows: false);
      final shadowedWorld = buildShadowScene(withShadows: true);

      final dev = GraphicsDevice();
      final ctx = RenderContext3D(dev);

      final unshadowedPx = await _snapshotWorld(
        tester,
        unshadowedWorld,
        view: view,
        projection: proj,
        device: dev,
        context: ctx,
      );
      final shadowedPx = await _snapshotWorld(
        tester,
        shadowedWorld,
        view: view,
        projection: proj,
        device: dev,
        context: ctx,
      );

      // All 7 shadow tiles (4 CSM + 1 Spot + 2 Dual-Paraboloid hemispheres)
      // executed in ONE unified shadow atlas pass!
      expect(dev.lastFrameStats.shadowPasses, 1);

      // Total floor brightness decreases measurably where +Z, -Z, Spot, and CSM
      // shadows land!
      var darkenedPixels = 0;
      for (var y = 16; y < 112; y++) {
        for (var x = 16; x < 112; x++) {
          final u = unshadowedPx.at(x, y).$1;
          final s = shadowedPx.at(x, y).$1;
          if (u - s > 22) {
            darkenedPixels++;
          }
        }
      }
      expect(darkenedPixels, greaterThan(180));

      // Verify diagnostic RenderDebugMode3D views each render non-blank,
      // distinct diagnostic buffers.
      for (final mode in [
        RenderDebugMode3D.normals,
        RenderDebugMode3D.depth,
        RenderDebugMode3D.ssao,
        RenderDebugMode3D.cascadeSplits,
        RenderDebugMode3D.wireframe,
        RenderDebugMode3D.overdraw,
        RenderDebugMode3D.roughnessMetallic,
        RenderDebugMode3D.albedo,
      ]) {
        shadowedWorld.renderDebugMode3D = mode;
        final dbgPx = await _snapshotWorld(
          tester,
          shadowedWorld,
          view: view,
          projection: proj,
          device: dev,
          context: ctx,
        );
        expect(
          dbgPx.count((r, g, b, _) => r > 10 || g > 10 || b > 10),
          greaterThan(100),
          reason: 'Debug view $mode should produce visible diagnostic pixels',
        );
      }
    },
  );

  testGpu(
    'Scene Color Grab-Pass refracts background through glass & water, and '
    'OitMode3D.weightedBlended is strictly order-independent',
    (tester) async {
      final view = _lookAt(
        Vector3(0, 0, 4),
        Vector3.zero(),
        Vector3(0, 1, 0),
      );
      final proj = _persp(60, 1, 0.2, 30);

      // 1. Grab-Pass IOR refraction: background split sharply at x = 0 into
      //    bright red (left) and bright cyan (right). A refractive sphere with
      //    ior = 1.52 bends rays across the split compared to ior = 1.0!
      Future<Pixels> renderGlass({required double ior}) {
        final world = World3D(
          grabSceneColorEnabled: true,
          children: [
            LightComponent.directional(
              direction: Vector3(-0.3, -0.5, -1)..normalize(),
              intensity: 1.2,
            ),
            MeshComponent(
              position: Vector3(-1.1, 0, -2),
              mesh: CuboidMesh(
                size: Vector3(2.2, 4, 0.2),
                material: SpatialMaterial(
                  albedoColor: const Color(0xFFFF1818),
                  roughness: 0.9,
                ),
              ),
            ),
            MeshComponent(
              position: Vector3(1.1, 0, -2),
              mesh: CuboidMesh(
                size: Vector3(2.2, 4, 0.2),
                material: SpatialMaterial(
                  albedoColor: const Color(0xFF10E8FF),
                  roughness: 0.9,
                ),
              ),
            ),
            MeshComponent(
              position: Vector3(0.45, 0, 1.2),
              mesh: SphereMesh(
                radius: 0.95,
                material: SpatialMaterial(
                  roughness: 0.03,
                  transmission: 0.94,
                  ior: ior,
                ),
              ),
            ),
          ],
        );
        return _snapshotWorld(tester, world, view: view, projection: proj);
      }

      final unbentPx = await renderGlass(ior: 1);
      final bentPx = await renderGlass(ior: 1.55);

      var refractedDiff = 0;
      for (var y = 36; y < 92; y++) {
        for (var x = 36; x < 92; x++) {
          final a = unbentPx.at(x, y);
          final b = bentPx.at(x, y);
          if ((a.$1 - b.$1).abs() + (a.$3 - b.$3).abs() > 18) {
            refractedDiff++;
          }
        }
      }
      expect(refractedDiff, greaterThan(80));

      // Also verify WaterMaterial with grabSceneColorEnabled renders cleanly
      // over submerged tiles.
      final waterWorld = World3D(
        grabSceneColorEnabled: true,
        children: [
          LightComponent.directional(
            direction: Vector3(0, -1, -0.4)..normalize(),
            intensity: 1.5,
          ),
          MeshComponent(
            position: Vector3(0, -1.2, -2),
            mesh: PlaneMesh(
              size: Vector2(6, 6),
              material: SpatialMaterial(albedoColor: const Color(0xFFFFAA22)),
            ),
          ),
          MeshComponent(
            position: Vector3(0, -0.3, -2),
            mesh: PlaneMesh(
              size: Vector2(6, 6),
              material: WaterMaterial(opacity: 0.65, refractionStrength: 0.08),
            ),
          ),
        ],
      );
      final waterPx = await _snapshotWorld(
        tester,
        waterWorld,
        view: _lookAt(
          Vector3(0, 2.5, 2.5),
          Vector3(0, -0.5, -2),
          Vector3(0, 1, 0),
        ),
        projection: proj,
      );
      expect(waterPx.count((r, g, b, _) => r > 30 && b > 30), greaterThan(500));

      // 2. Weighted Blended OIT (`OitMode3D.weightedBlended`): two intersecting
      //    translucent planes (tilted +Y-axis red glass and -Y-axis blue glass)
      //    MUST render identically regardless of component insertion order!
      MeshComponent makePlaneA() => MeshComponent(
        rotation: Quaternion.axisAngle(Vector3(0, 1, 0), 0.45),
        mesh: CuboidMesh(
          size: Vector3(2.2, 2.2, 0.04),
          material: SpatialMaterial(
            albedoColor: const Color(0x99FF2838),
            roughness: 0.4,
          )..renderState = RenderState.alphaBlend,
        ),
      );
      MeshComponent makePlaneB() => MeshComponent(
        rotation: Quaternion.axisAngle(Vector3(0, 1, 0), -0.45),
        mesh: CuboidMesh(
          size: Vector3(2.2, 2.2, 0.04),
          material: SpatialMaterial(
            albedoColor: const Color(0x992078FF),
            roughness: 0.4,
          )..renderState = RenderState.alphaBlend,
        ),
      );

      final wboitAB = World3D(
        oitMode: OitMode3D.weightedBlended,
        children: [
          LightComponent.ambient(intensity: 1),
          makePlaneA(),
          makePlaneB(),
        ],
      );
      final wboitBA = World3D(
        oitMode: OitMode3D.weightedBlended,
        children: [
          LightComponent.ambient(intensity: 1),
          makePlaneB(),
          makePlaneA(),
        ],
      );

      final pxAB = await _snapshotWorld(
        tester,
        wboitAB,
        view: view,
        projection: proj,
      );
      final pxBA = await _snapshotWorld(
        tester,
        wboitBA,
        view: view,
        projection: proj,
      );

      // Center overlap has blended purple (both red & blue > 40) AND order
      // reversal produces 0 differing pixels!
      expect(pxAB.at(64, 64).$1, greaterThan(40));
      expect(pxAB.at(64, 64).$3, greaterThan(40));
      var orderMismatchPixels = 0;
      for (var i = 0; i < pxAB.rgba.length; i += 4) {
        final dr = (pxAB.rgba[i] - pxBA.rgba[i]).abs();
        final dg = (pxAB.rgba[i + 1] - pxBA.rgba[i + 1]).abs();
        final db = (pxAB.rgba[i + 2] - pxBA.rgba[i + 2]).abs();
        if (dr > 1 || dg > 1 || db > 1) {
          orderMismatchPixels++;
        }
      }
      expect(orderMismatchPixels, 0);
    },
  );

  testGpu(
    'RenderGraph3D transient texture aliasing and World3D.customPasses execute '
    'on real Flutter GPU',
    (tester) async {
      final (aliasedSlots, customPx) = (await tester.runAsync(() async {
        final dev = GraphicsDevice();
        final ctx = RenderContext3D(dev);

        final graph = RenderGraph3D();
        const desc = RenderGraphTextureDesc3D(width: 64, height: 64);
        final a = graph.createTexture('passA', desc);
        final b = graph.createTexture('passB', desc);
        final c = graph.createTexture('passC', desc);
        graph
          ..markOutput(c)
          ..addRenderPass(
            name: 'drawRedA',
            writes: [a],
            execute: (p) {
              final t = p.targetOf(a);
              p.device.beginTexturePass(t);
              p.renderContext
                ..setCamera(defaultView, defaultProjection)
                ..drawSurface(
                  quad(opaqueUnlit(const Color(0xFFFF2020)), halfSize: 1),
                )
                ..flush();
              p.device.endTexturePass();
            },
          )
          ..addRenderPass(
            name: 'copyToB',
            reads: [a],
            writes: [b],
            execute: (p) {
              final srcTex = p.textureOf(a);
              final t = p.targetOf(b);
              p.device.beginTexturePass(t);
              p.renderContext
                ..setCamera(defaultView, defaultProjection)
                ..drawSurface(
                  quad(
                    UnlitMaterial(albedoTexture: srcTex)
                      ..renderState = RenderState.opaque,
                    halfSize: 1,
                  ),
                )
                ..flush();
              p.device.endTexturePass();
            },
          )
          ..addRenderPass(
            name: 'tintToC',
            reads: [b],
            writes: [c],
            execute: (p) {
              final srcTex = p.textureOf(b);
              final t = p.targetOf(c);
              p.device.beginTexturePass(t);
              p.renderContext
                ..setCamera(defaultView, defaultProjection)
                ..drawSurface(
                  quad(
                    UnlitMaterial(
                      albedoTexture: srcTex,
                      albedoColor: const Color(0xFFFFAA00),
                    )..renderState = RenderState.opaque,
                    halfSize: 1,
                  ),
                )
                ..flush();
              p.device.endTexturePass();
            },
          );

        dev.begin();
        final plan = graph.execute(dev, ctx);
        dev.end();

        // Also execute a real afterScene CustomRenderPass3D stamping a green
        // corner badge into `sceneTarget`!
        final world = World3D(
          customPasses: [
            CustomRenderPass3D(
              name: 'greenCornerStamp',
              execute: (passCtx) {
                final target = passCtx.sceneTarget!;
                passCtx.device
                  ..beginTexturePass(target)
                  ..setViewport(0, 0, 32, 32)
                  ..setScissor(0, 0, 32, 32);
                passCtx.renderContext
                  ..setCamera(defaultView, defaultProjection)
                  ..drawSurface(
                    quad(opaqueUnlit(const Color(0xFF10FF40)), halfSize: 1),
                  )
                  ..flush();
                passCtx.device.endTexturePass();
              },
            ),
          ],
          children: [
            LightComponent.ambient(intensity: 1),
          ],
        );
        final game = FlameGame3D(world: world);
        await game.onLoad();
        game.onMount();
        game.update(0);

        dev.begin();
        final img = world.renderToImage(
          const Size(128, 128),
          view: defaultView,
          projection: defaultProjection,
          device: dev,
          context: ctx,
        );
        dev.end();
        final px = await readImage(img);
        img.dispose();

        return (plan.physicalTargetCount, px);
      }))!;

      expect(aliasedSlots, 2);
      expect(customPx.at(16, 16).$2, greaterThan(220));
      expect(customPx.at(96, 96).$2, lessThan(20));
    },
  );
}
