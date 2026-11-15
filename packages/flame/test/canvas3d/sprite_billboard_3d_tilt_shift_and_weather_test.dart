import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/canvas3d.dart';
import 'package:flame/components.dart';
import 'package:flame/post_process.dart';
import 'package:flame/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Future<ui.Image> _createQuadrantAtlas() async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  // 64x64 2x2 grid:
  // Frame 0 (top-left): Green, Frame 1 (top-right): Yellow,
  // Frame 2 (bottom-left): Cyan, Frame 3 (bottom-right): Magenta.
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 0, 32, 32),
    ui.Paint()..color = const ui.Color(0xFF00E640),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(32, 0, 32, 32),
    ui.Paint()..color = const ui.Color(0xFFFFE600),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(0, 32, 32, 32),
    ui.Paint()..color = const ui.Color(0xFF00E5FF),
  );
  canvas.drawRect(
    const ui.Rect.fromLTWH(32, 32, 32, 32),
    ui.Paint()..color = const ui.Color(0xFFFF00D4),
  );
  final pic = recorder.endRecording();
  final img = await pic.toImage(64, 64);
  pic.dispose();
  return img;
}

Future<ui.Image> _createCheckerboardImage(int width, int height) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  final white = ui.Paint()..color = const ui.Color(0xFFFFFFFF);
  final black = ui.Paint()..color = const ui.Color(0xFF000000);
  const cell = 4;
  for (var y = 0; y < height; y += cell) {
    for (var x = 0; x < width; x += cell) {
      final isWhite = ((x ~/ cell) + (y ~/ cell)).isEven;
      canvas.drawRect(
        ui.Rect.fromLTWH(
          x.toDouble(),
          y.toDouble(),
          cell.toDouble(),
          cell.toDouble(),
        ),
        isWhite ? white : black,
      );
    }
  }
  final pic = recorder.endRecording();
  final img = await pic.toImage(width, height);
  pic.dispose();
  return img;
}

ui.Color _pixelAt(ByteData rgba, int width, int x, int y) {
  final idx = (y * width + x) * 4;
  return ui.Color.fromARGB(
    rgba.getUint8(idx + 3),
    rgba.getUint8(idx),
    rgba.getUint8(idx + 1),
    rgba.getUint8(idx + 2),
  );
}

void main() {
  group('SpriteBillboard3D depth sorting, clipping, flipbook & shadows', () {
    test(
      'interleaves cleanly between rear and front 3D walls with pixel proof',
      () async {
        const w = 240;
        const h = 240;
        const origin = ui.Offset(-w / 2, -h * 0.68);

        final camera = CameraRig3D(
          cellHalfW: 38.0,
          cellHalfH: 19.0,
          groundOriginY: 0.0,
          baseAzimuthRad: 0.0,
          baseElevationRad: 0.38,
        );
        final light = DirectionalLight3D(
          ambientIntensity: 1.0,
          diffuseIntensity: 0.0,
          rimIntensity: 0.0,
        );
        final renderer = BatchMeshRenderer3D(light: light);

        // camera.viewDepth(wx, wy, wz): larger = closer to camera!
        final depthPos = camera.viewDepth(
          camera.viewX * 2.5,
          camera.viewY * 2.5,
          0,
        );
        final depthNeg = camera.viewDepth(
          -camera.viewX * 2.5,
          -camera.viewY * 2.5,
          0,
        );
        final nearSign = depthPos > depthNeg ? 1.0 : -1.0;
        final farSign = -nearSign;

        final rearWall = Mesh3D.box(sizeX: 3.6, sizeY: 3.6, sizeZ: 3.2);
        final frontLowWall = Mesh3D.box(sizeX: 3.6, sizeY: 3.6, sizeZ: 0.9);

        final billboard = SpriteBillboard3D(
          worldX: 0.0,
          worldY: 0.0,
          width: 1.8,
          height: 2.2,
          tint: const ui.Color(0xFF00FF00),
          emissive: 1.0,
          material: const Material3D.unshaded(),
        );

        renderer.beginBatch();
        renderer.enqueueMesh(
          rearWall,
          camera: camera,
          worldX: camera.viewX * 3.8 * farSign,
          worldY: camera.viewY * 3.8 * farSign,
          worldZ: 1.6,
          canvasOrigin: origin,
          tint: const ui.Color(0xFF1144FF),
          emissive: 1.0,
          material: const Material3D.unshaded(),
        );
        billboard.enqueue(
          renderer,
          camera: camera,
          canvasOrigin: origin,
        );
        renderer.enqueueMesh(
          frontLowWall,
          camera: camera,
          worldX: camera.viewX * 2.6 * nearSign,
          worldY: camera.viewY * 2.6 * nearSign,
          worldZ: 0.45,
          canvasOrigin: origin,
          tint: const ui.Color(0xFFFF0000),
          emissive: 1.0,
          material: const Material3D.unshaded(),
        );

        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawColor(const ui.Color(0xFF000000), ui.BlendMode.src);
        renderer.flushShadows(canvas);
        renderer.flushGeometry(canvas);
        expect(renderer.lastFlushShadowTriangles, greaterThan(0));

        final pic = recorder.endRecording();
        final img = await pic.toImage(w, h);
        pic.dispose();
        final rgba = (await img.toByteData())!;
        img.dispose();

        // Sample upper torso of billboard (z = 1.75 -> above front low wall, in
        // front of rear blue wall):
        final upperScreen = camera.projectWorldPoint(0.0, 0.0, 1.75) - origin;
        final upperPx = _pixelAt(
          rgba,
          w,
          upperScreen.dx.round().clamp(0, w - 1),
          upperScreen.dy.round().clamp(0, h - 1),
        );
        expect(upperPx.g, greaterThan(0.75));
        expect(upperPx.r, lessThan(0.25));
        expect(upperPx.b, lessThan(0.35));

        // Sample front low red wall occluding the lower half:
        final frontScreen =
            camera.projectWorldPoint(
              camera.viewX * 2.6 * nearSign,
              camera.viewY * 2.6 * nearSign,
              0.45,
            ) -
            origin;
        final lowerPx = _pixelAt(
          rgba,
          w,
          frontScreen.dx.round().clamp(0, w - 1),
          frontScreen.dy.round().clamp(0, h - 1),
        );
        expect(lowerPx.r, greaterThan(0.75));
        expect(lowerPx.g, lessThan(0.25));
      },
    );

    test(
      'supports flipbook UV frames, orientation modes, and perspective '
      'near-plane clipping',
      () async {
        final atlas = await _createQuadrantAtlas();
        addTearDown(atlas.dispose);
        final shader = ui.ImageShader(
          atlas,
          ui.TileMode.clamp,
          ui.TileMode.clamp,
          Float64List.fromList(const <double>[
            1, 0, 0, 0, //
            0, 1, 0, 0, //
            0, 0, 1, 0, //
            0, 0, 0, 1,
          ]),
        );
        addTearDown(shader.dispose);

        const perspOrigin = ui.Offset(-100, -100);
        final mat = Material3D.texture(shader, width: 64, height: 64);
        final camera = CameraRig3D(
          projectionMode: CameraProjectionMode3D.perspective,
          fovYRad: 0.95,
          cameraDistance: 6.0,
          nearClip: 2.5,
          groundOriginY: 0.0,
          cellHalfW: 42.0,
          cellHalfH: 21.0,
        );
        final renderer = BatchMeshRenderer3D();

        final billboard =
            SpriteBillboard3D(
              worldX: 0.0,
              worldY: 0.0,
              width: 1.5,
              height: 1.5,
              orientation: BillboardOrientationMode3D.tiltedStandee,
              standeeTiltFactor: 0.5,
              emissive: 1.0,
              material: mat,
            )..setFlipbookFrame(
              frameIndex: 3, // bottom-right magenta cell (32, 32, 32, 32)
              columns: 2,
              frameWidthPx: 32,
              frameHeightPx: 32,
            );
        expect(billboard.uvRectPx, const ui.Rect.fromLTWH(32, 32, 32, 32));

        renderer.beginBatch();
        billboard.enqueue(
          renderer,
          camera: camera,
          canvasOrigin: perspOrigin,
        );

        // Also place a spherical billboard straddling the perspective nearClip
        // plane:
        final nearStraddler =
            SpriteBillboard3D(
              worldX: camera.viewX * 4.2,
              worldY: camera.viewY * 4.2,
              worldZ: camera.viewZ * 4.2,
              width: 5.0,
              height: 5.0,
              anchorY: 0.5,
              orientation: BillboardOrientationMode3D.sphericalCameraPlane,
              rollRad: 0.35,
              flipH: true,
              material: const Material3D.unshaded(),
            )..enqueue(
              renderer,
              camera: camera,
              canvasOrigin: perspOrigin,
            );
        expect(nearStraddler.flipH, isTrue);

        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        renderer.flushGeometry(canvas);
        expect(renderer.lastFlushTriangles, greaterThanOrEqualTo(2));

        final pic = recorder.endRecording();
        final img = await pic.toImage(200, 200);
        pic.dispose();
        final rgba = (await img.toByteData())!;
        img.dispose();

        final centerScreen =
            camera.projectWorldPoint(0.0, 0.0, 0.75) - perspOrigin;
        final px = _pixelAt(
          rgba,
          200,
          centerScreen.dx.round().clamp(0, 199),
          centerScreen.dy.round().clamp(0, 199),
        );
        // Frame 3 is magenta (high R, low G, high B):
        expect(px.r, greaterThan(0.7));
        expect(px.b, greaterThan(0.6));
        expect(px.g, lessThan(0.25));
      },
    );
  });

  group('TiltShiftPostProcess, DayNightWeatherController & Weather', () {
    test(
      'TiltShiftPostProcess preserves crisp focus band while blurring horizon '
      'and foreground',
      () async {
        final checker = await _createCheckerboardImage(128, 160);
        addTearDown(checker.dispose);

        final fx = TiltShiftPostProcess(
          focusCenterY: 0.5,
          focusBandHalfHeight: 0.15,
          featherFalloff: 0.12,
          farSigma: 6.0,
          nearSigma: 6.0,
        );
        expect(fx.supportsImageInput, isTrue);
        expect(fx.isEffectivelyNoOp, isFalse);

        fx.enabled = false;
        expect(fx.isEffectivelyNoOp, isTrue);
        fx.enabled = true;
        fx.strength = 0.0;
        expect(fx.isEffectivelyNoOp, isTrue);
        fx.strength = 1.0;

        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        final ok = fx.renderFromImage(
          checker,
          Vector2(128, 160),
          canvas,
        );
        expect(ok, isTrue);

        final pic = recorder.endRecording();
        final out = await pic.toImage(128, 160);
        pic.dispose();
        final rgba = (await out.toByteData())!;
        out.dispose();
        fx.onRemove();

        double rowContrast(int y) {
          var minL = 1.0;
          var maxL = 0.0;
          for (var x = 24; x < 104; x++) {
            final c = _pixelAt(rgba, 128, x, y);
            final lum = (c.r + c.g + c.b) / 3.0;
            if (lum < minL) {
              minL = lum;
            }
            if (lum > maxL) {
              maxL = lum;
            }
          }
          return maxL - minL;
        }

        final focusContrast = rowContrast(80); // y = 0.5 * 160 (in focus)
        final topBlurContrast = rowContrast(10); // far horizon blurred
        final bottomBlurContrast = rowContrast(150); // near foreground blurred

        expect(focusContrast, greaterThan(0.85));
        expect(topBlurContrast, lessThan(0.35));
        expect(bottomBlurContrast, lessThan(0.35));
      },
    );

    test(
      'DayNightWeatherController wraps smoothly across midnight and drives 3D '
      '+ 2D lights',
      () {
        final cycle = DayNightWeatherController(
          initialHour: 23.5,
          hoursPerRealSecond: 1.0,
        );
        final light3D = DirectionalLight3D();
        final light2D = Light2DLayer();

        cycle.setHour(-0.5);
        expect(cycle.hour, closeTo(23.5, 1e-6));
        expect(cycle.areNightLampsLit, isTrue);
        expect(cycle.nightLampFactor, greaterThan(0.8));

        final preMidnightSunZ = cycle.sunDirZ;
        final preMidnightSky = cycle.skyColor;

        // Advance 1.0 second -> crosses 24.0 cleanly to 00:30 (0.5h):
        cycle.update(1.0, light3D: light3D, light2D: light2D);
        expect(cycle.hour, closeTo(0.5, 1e-6));
        expect((cycle.sunDirZ - preMidnightSunZ).abs(), lessThan(0.25));
        expect((cycle.skyColor.b - preMidnightSky.b).abs(), lessThan(0.15));
        expect(light2D.ambientColor, cycle.ambient2DColor);
        expect(light3D.ambientIntensity, closeTo(cycle.ambientIntensity, 1e-6));

        // Noon disables night streetlamps:
        cycle.setHour(12.0);
        expect(cycle.areNightLampsLit, isFalse);
        expect(cycle.nightLampFactor, closeTo(0.0, 1e-6));
      },
    );

    test(
      'WeatherPrecipitationLayer wraps 100% of particles inside teleported '
      'camera bounds',
      () {
        const remoteBounds = ui.Rect.fromLTWH(50000, -80000, 640, 360);
        final weather = WeatherPrecipitationLayer(
          fallbackBounds: remoteBounds,
        );

        weather.update(14.75);
        for (final kind in <WeatherKind>[
          WeatherKind.rain,
          WeatherKind.snow,
          WeatherKind.embers,
        ]) {
          weather.kind = kind;
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder);
          weather.render(canvas);
          recorder.endRecording().dispose();
          expect(weather.lastActiveDropCount, 128);

          for (var i = 0; i < 128; i++) {
            final p = weather.sampleDropPosition(i, remoteBounds);
            expect(
              p.dx,
              inInclusiveRange(remoteBounds.left, remoteBounds.right),
            );
            expect(
              p.dy,
              inInclusiveRange(remoteBounds.top, remoteBounds.bottom),
            );
          }
        }
      },
    );
  });

  group('NormalMappedSpriteBatch & WaterSurface2DComponent', () {
    test(
      'computes directional dot(N, L) bevel asymmetry and flushes in 1 '
      'drawVertices call',
      () async {
        final atlas = await _createQuadrantAtlas();
        addTearDown(atlas.dispose);

        final flat = SurfaceNormal2D.fromRgbBytes(128, 128, 255);
        expect(flat.nx.abs(), lessThan(0.02));
        expect(flat.ny.abs(), lessThan(0.02));
        expect(flat.nz, greaterThan(0.99));

        final batch = NormalMappedSpriteBatch(
          diffuseAtlas: atlas,
          ambientColor: const ui.Color(0xFF181820),
          defaultLightHeightZ: 24.0,
        );
        addTearDown(batch.dispose);

        // Torch placed strictly to the RIGHT of the stone pillar at (140, 50):
        final torch = PointLight2D(
          position: Vector2(140, 50),
          radius: 220,
          color: const ui.Color(0xFFFFAA44),
          intensity: 1.5,
        );

        final rightLit = batch.evaluateLitColor(
          wx: 50,
          wy: 50,
          normal: const SurfaceNormal2D(0.85, 0.0, 0.52),
          lights: <PointLight2D>[torch],
        );
        final leftLit = batch.evaluateLitColor(
          wx: 50,
          wy: 50,
          normal: const SurfaceNormal2D(-0.85, 0.0, 0.52),
          lights: <PointLight2D>[torch],
        );
        expect(rightLit.r, greaterThan(leftLit.r + 0.35));

        batch.clear();
        for (var i = 0; i < 6; i++) {
          batch.addLitSprite(
            srcRect: const ui.Rect.fromLTWH(0, 0, 32, 32),
            dstRect: ui.Rect.fromLTWH(i * 32.0, 16, 32, 32),
            lights: <PointLight2D>[torch],
          );
        }
        expect(batch.spriteCount, 6);

        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        batch.flush(canvas);
        recorder.endRecording().dispose();
        expect(batch.lastDrawCalls, 1);
      },
    );

    test(
      'WaterSurface2DComponent renders foam, wave-rippled reflection, and '
      'specular glints',
      () async {
        final reflection = await _createQuadrantAtlas();
        addTearDown(reflection.dispose);

        final water = WaterSurface2DComponent(
          size: Vector2(128, 96),
          reflectionTexture: reflection,
          reflectionOpacity: 0.55,
          reflectionBands: 10,
        )..update(0.75);
        expect(water.elapsed, closeTo(0.75, 1e-6));

        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        water.render(canvas);
        final pic = recorder.endRecording();
        final img = await pic.toImage(128, 96);
        pic.dispose();
        final rgba = (await img.toByteData())!;
        img.dispose();

        // Top shoreline foam row is bright light-blue/white:
        final foamPx = _pixelAt(rgba, 128, 64, 1);
        expect(foamPx.b, greaterThan(0.75));
        expect(foamPx.g, greaterThan(0.65));

        // Mid-water body has non-zero blue+reflection color:
        final bodyPx = _pixelAt(rgba, 128, 20, 60);
        expect(bodyPx.a, closeTo(1.0, 0.02));
        expect(bodyPx.b, greaterThan(0.25));
      },
    );
  });
}
