import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flame_3d/camera.dart';
import 'package:flame_3d/core.dart';
import 'package:flame_3d/graphics.dart';
import 'package:flame_3d/input.dart';
import 'package:flame_3d/ui3d.dart';
import 'package:flutter_test/flutter_test.dart';

import '../_fakes/fake_gpu_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MsdfFontAtlas3D & single-draw MsdfTextBatch3D', () {
    test('batches without an atlas share one', () {
      expect(MsdfTextBatch3D().atlas, same(MsdfTextBatch3D().atlas));
    });

    test('keeps every glyph of a long fixed string', () {
      final batch = MsdfTextBatch3D()
        ..addText(
          'A' * 17000,
          position: Vector3.zero(),
          mode: TextBillboardMode3D.fixed,
        );
      expect(batch.glyphCount, 17000);
    });

    test('setText changes the letter spacing and line height', () {
      final batch = MsdfTextBatch3D();
      final slot = batch.addText('ABC\nDEF', position: Vector3.zero());
      final width = batch.aabb.max.x - batch.aabb.min.x;
      final height = batch.aabb.max.y - batch.aabb.min.y;
      batch.setText(slot, 'ABC\nDEF', letterSpacing: 1, lineHeight: 3);
      expect(batch.aabb.max.x - batch.aabb.min.x, greaterThan(width + 0.9));
      expect(batch.aabb.max.y - batch.aabb.min.y, greaterThan(height + 0.9));
    });

    test(
      'MsdfFontAtlas3D packs printable ASCII + symbols with valid UV rects, '
      'kerning, and signed-distance stroke contours',
      () {
        final atlas = MsdfFontAtlas3D.generateDefault();
        expect(atlas.glyphs.length, 95);
        expect(atlas.atlasWidth, 16 * 32);
        expect(atlas.atlasHeight, 6 * 32);

        for (var code = 0x20; code <= 0x7E; code++) {
          final m = atlas.metricsFor(code);
          expect(m.uvRect.left, greaterThanOrEqualTo(0.0));
          expect(m.uvRect.top, greaterThanOrEqualTo(0.0));
          expect(m.uvRect.right, lessThanOrEqualTo(1.0));
          expect(m.uvRect.bottom, lessThanOrEqualTo(1.0));
          expect(m.advance, greaterThan(0.2));
        }

        // Kerning tightens 'AV' compared to unkerned sum of advances.
        final kernAV = atlas.kerning('A'.codeUnitAt(0), 'V'.codeUnitAt(0));
        expect(kernAV, lessThan(0.0));
        final avWidth = atlas.measureLineWidth('AV', fontSize: 2.0);
        final sumWidth =
            (atlas.metricsFor('A'.codeUnitAt(0)).advance +
                atlas.metricsFor('V'.codeUnitAt(0)).advance) *
            2.0;
        expect(avWidth, lessThan(sumWidth));

        // Center of '+' (`0x2B`) lies right on the intersection of its
        // horizontal and vertical strokes (`median > 0.5`), whereas `' '` is 0.
        final plusUv = atlas.metricsFor('+'.codeUnitAt(0)).uvRect.center;
        final spaceUv = atlas.metricsFor(' '.codeUnitAt(0)).uvRect.center;
        expect(
          atlas.sampleMedianDistance(plusUv.dx, plusUv.dy),
          greaterThan(0.55),
        );
        expect(
          atlas.sampleMedianDistance(spaceUv.dx, spaceUv.dy),
          closeTo(0.0, 1e-5),
        );
      },
    );

    test(
      'MsdfTextBatch3D records 150 world-space strings as 1 instanced draw '
      'call (on a recording fake backend), plus fixed 3D plaques',
      () {
        final backend = FakeGpuBackend();
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);

        final atlas = MsdfFontAtlas3D.generateDefault(cellSize: 24);
        final batch = MsdfTextBatch3D(atlas: atlas, alphaCutoff: 0.48);

        for (var i = 0; i < 150; i++) {
          batch.addText(
            'HP ${100 + i}\nCRIT!',
            position: Vector3((i % 15) * 1.5, (i ~/ 15).toDouble(), -4.0),
            fontSize: 0.45,
            color: const ui.Color(0xFFFFD54F),
            mode: i.isEven
                ? TextBillboardMode3D.spherical
                : TextBillboardMode3D.cylindrical,
            align: TextAlign3D.values[i % 3],
          );
        }

        expect(batch.textCount, 150);
        final totalGlyphs = batch.glyphCount;
        expect(totalGlyphs, greaterThan(1200));
        expect(batch.billboardMaterial.renderState, RenderState.opaque);

        device.begin();
        context.setCamera(
          Matrix4.identity(),
          Matrix4.identity()..setAsPerspective(60.0, 1.0, 0.1, 200.0),
        );
        device.beginPass(
          const ui.Size(64, 64),
          frontFace: context.frontFace,
        );
        batch.draw(context);
        context.flush();
        device
          ..endPass()
          ..end();

        // All 150 multi-line strings (`> 1200` glyph quads!) coalesce into
        // EXACTLY ONE instanced `drawIndexed` submission!
        expect(backend.countCommands('drawIndexed'), 1);
        expect(context.drawCount, 1);
        expect(device.lastFrameStats.instances, totalGlyphs);

        // Also verify `TextBillboardMode3D.fixed` with explicit 3D Quaternion
        // rotation and `setText` / `clear()`.
        batch.clear();
        expect(batch.textCount, 0);
        final slot = batch.addText(
          'GATE 07',
          position: Vector3(0.0, 2.0, -5.0),
          mode: TextBillboardMode3D.fixed,
          rotation: Quaternion.axisAngle(Vector3(0.0, 1.0, 0.0), 0.35),
          align: TextAlign3D.center,
        );
        batch.setText(slot, 'GATE 08');
        expect(batch.glyphCount, 6); // 'G','A','T','E','0','8' (space skipped).

        backend.commands.clear();
        device.begin();
        context.setCamera(
          Matrix4.identity(),
          Matrix4.identity()..setAsPerspective(60.0, 1.0, 0.1, 200.0),
        );
        device.beginPass(
          const ui.Size(64, 64),
          frontFace: context.frontFace,
        );
        batch.draw(context);
        context.flush();
        device
          ..endPass()
          ..end();
        expect(backend.countCommands('drawIndexed'), 1);
      },
    );
  });

  group('WidgetSurface3D diegetic 2D-in-3D panel & PointerRouter3D', () {
    test(
      'throttles static panel uploads to 0 and routes 3D raycast taps, hovers, '
      'and drags to SurfaceButton2D & SurfaceSlider2D',
      () {
        var customPaintCalls = 0;
        var buttonClicks = 0;
        final sliderValues = <double>[];
        final tappedOffsets = <ui.Offset>[];
        final hoveredOffsets = <ui.Offset>[];
        final draggedDeltas = <ui.Offset>[];

        final button = SurfaceButton2D(
          bounds: const ui.Rect.fromLTWH(40.0, 40.0, 160.0, 60.0),
          label: 'ENGAGE',
          onPressed: () => buttonClicks++,
        );
        final slider = SurfaceSlider2D(
          bounds: const ui.Rect.fromLTWH(50.0, 180.0, 300.0, 40.0),
          value: 0.2,
          onChanged: sliderValues.add,
        );

        final panel = WidgetSurface3D(
          width: 4.0,
          height: 3.0,
          pixelWidth: 400,
          position: Vector3(0.0, 1.5, -2.0),
          rotation: Quaternion.axisAngle(Vector3(0.0, 1.0, 0.0), 0.2),
          controls: [button, slider],
          paintSurface: (canvas, size) {
            customPaintCalls++;
            canvas.drawRect(
              ui.Rect.fromLTWH(8.0, 8.0, size.width - 16.0, size.height - 16.0),
              ui.Paint()
                ..color = const ui.Color(0xFF38BDF8)
                ..style = ui.PaintingStyle.stroke,
            );
          },
          onSurfaceTap: tappedOffsets.add,
          onSurfaceHover: hoveredOffsets.add,
          onSurfaceDrag: (pos, delta) => draggedDeltas.add(delta),
        );

        // 1. Initial rasterization ran once (`uploadCount == 1`); 10 clean
        // ticks + GPU draws perform 0 re-uploads!
        expect(panel.uploadCount, 1);
        expect(customPaintCalls, 1);

        final backend = FakeGpuBackend();
        final device = GraphicsDevice(backend: backend);
        final context = RenderContext3D(device);
        for (var f = 0; f < 10; f++) {
          panel.update(0.016);
          device.begin();
          context.setCamera(
            Matrix4.identity(),
            Matrix4.identity()..setAsPerspective(60.0, 1.0, 0.1, 100.0),
          );
          device.beginPass(
            const ui.Size(32, 32),
            frontFace: context.frontFace,
          );
          panel.draw(context);
          context.flush();
          device
            ..endPass()
            ..end();
        }
        expect(panel.uploadCount, 1);
        expect(customPaintCalls, 1);

        // Explicit `markDirty()` + `minUploadInterval` throttling check:
        // First dirty update after 0.16s of clean frames flushes immediately
        // (`uploadCount == 2`, resetting `_sinceLastUpload = 0`); a rapid
        // follow-up `markDirty()` 0.04s later is throttled until 0.1s elapses!
        panel
          ..minUploadInterval = 0.1
          ..markDirty()
          ..update(0.01);
        expect(panel.uploadCount, 2);
        panel
          ..markDirty()
          ..update(0.04);
        expect(panel.uploadCount, 2); // Throttled until 0.1s elapsed!
        panel.update(0.07);
        expect(panel.uploadCount, 3);
        panel.minUploadInterval = 0.0;

        // 2. Mount in World3D + CameraComponent3D + PointerRouter3D and test
        // exact 3D -> 2D panel coordinate projection!
        final world = World3D(children: [panel]);
        final camera = CameraComponent3D(
          position: Vector3(0.0, 1.5, 5.0),
          target: Vector3(0.0, 1.5, -2.0),
          viewport: FixedSizeViewport(800, 600),
        );
        final router = PointerRouter3D.forCamera(
          world: world,
          camera: camera,
          cullMode: CullMode.none,
        );

        // Helper mapping 2D panel pixel `(px, py)` into its exact 3D world
        // point on the rotated panel and then into viewport screen pixels!
        Vector2 panelPixelToScreen(double px, double py) {
          final u = px / panel.pixelWidth;
          final v = py / panel.pixelHeight;
          final localPt = Vector3(
            (u - 0.5) * panel.width,
            (0.5 - v) * panel.height,
            0.0,
          );
          final worldPt = panel.worldTransformMatrix.transformed3(localPt);
          return camera.worldToViewportPoint(worldPt);
        }

        // Hover over button center `(120, 70)` -> `button.hovered == true`!
        final btnScreen = panelPixelToScreen(120.0, 70.0);
        router.dispatchHover(btnScreen);
        expect(button.hovered, isTrue);
        expect(hoveredOffsets, hasLength(1));
        expect(hoveredOffsets.single.dx, closeTo(120.0, 0.5));
        expect(hoveredOffsets.single.dy, closeTo(70.0, 0.5));

        // Tap button -> fires `onPressed` and `onSurfaceTap`!
        expect(router.dispatchTapDown(btnScreen), isTrue);
        expect(button.pressed, isTrue);
        expect(router.dispatchTapUp(btnScreen), isTrue);
        expect(button.pressed, isFalse);
        expect(buttonClicks, 1);
        expect(tappedOffsets.single.dx, closeTo(120.0, 0.5));
        expect(tappedOffsets.single.dy, closeTo(70.0, 0.5));

        // Drag across `SurfaceSlider2D` (`x: 50..350`, `y: 200`) from 10%
        // (`80`) to 85% (`305`) -> scrubs `slider.value` cleanly!
        final sliderStart = panelPixelToScreen(80.0, 200.0);
        final sliderEnd = panelPixelToScreen(305.0, 200.0);
        expect(router.dispatchDragStart(sliderStart), isTrue);
        expect(slider.value, closeTo(0.1, 1e-2));

        expect(router.dispatchDragUpdate(sliderEnd), isTrue);
        expect(router.dispatchDragEnd(point: sliderEnd), isTrue);
        expect(slider.value, closeTo(0.85, 1e-2));
        expect(sliderValues.last, closeTo(0.85, 1e-2));
        expect(draggedDeltas.single.dx, closeTo(225.0, math.max(1.0, 1.5)));

        // Hover exit clears `button.hovered`.
        router.dispatchHoverExit();
        expect(button.hovered, isFalse);
      },
    );
  });
}
