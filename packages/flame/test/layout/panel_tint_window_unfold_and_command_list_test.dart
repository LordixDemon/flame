import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/layout.dart';
import 'package:flutter_test/flutter_test.dart';

/// Renders [draw] into a `width` x `height` image and returns its RGBA bytes.
Future<ByteData> _rasterize(
  int width,
  int height,
  void Function(ui.Canvas canvas) draw,
) async {
  final recorder = ui.PictureRecorder();
  draw(ui.Canvas(recorder));
  final picture = recorder.endRecording();
  final image = await picture.toImage(width, height);
  picture.dispose();
  final data = (await image.toByteData())!;
  image.dispose();
  return data;
}

int _alphaAt(ByteData rgba, int width, int x, int y) =>
    rgba.getUint8((y * width + x) * 4 + 3);

Future<ui.Image> _opaqueWhiteImage(int size) async {
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawRect(
    ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..color = const ui.Color(0xFFFFFFFF),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(size, size);
  picture.dispose();
  return image;
}

void main() {
  group('NineSlicePanelComponent tint', () {
    testWidgets('a translucent tint is applied once', (tester) async {
      final alpha = await tester.runAsync(() async {
        final skin = await _opaqueWhiteImage(16);
        final panel = NineSlicePanelComponent(
          image: skin,
          tint: const ui.Color(0x80FFFFFF),
          size: Vector2(32, 32),
        );
        final rgba = await _rasterize(32, 32, panel.render);
        skin.dispose();
        return _alphaAt(rgba, 32, 16, 16);
      });
      // 0x80 of an opaque skin, not 0x80 * 0x80.
      expect(alpha, closeTo(128, 3));
    });

    testWidgets('an opaque tint colors the skin without fading it', (
      tester,
    ) async {
      final pixel = await tester.runAsync(() async {
        final skin = await _opaqueWhiteImage(16);
        final panel = NineSlicePanelComponent(
          image: skin,
          tint: const ui.Color(0xFF4080C0),
          size: Vector2(32, 32),
        );
        final rgba = await _rasterize(32, 32, panel.render);
        skin.dispose();
        const at = (16 * 32 + 16) * 4;
        return [
          rgba.getUint8(at),
          rgba.getUint8(at + 1),
          rgba.getUint8(at + 2),
          rgba.getUint8(at + 3),
        ];
      });
      expect(pixel![0], closeTo(0x40, 3));
      expect(pixel[1], closeTo(0x80, 3));
      expect(pixel[2], closeTo(0xC0, 3));
      expect(pixel[3], 255);
    });
  });

  group('WindowSkinComponent unfold', () {
    /// The rows of column 50 that a half open 100 x 40 window paints.
    Future<List<int>> paintedRows(
      WidgetTester tester,
      WindowSkinComponent window,
    ) async {
      final rows = await tester.runAsync(() async {
        final rgba = await _rasterize(100, 100, window.renderTree);
        return [
          for (var y = 0; y < 100; y++)
            if (_alphaAt(rgba, 100, 50, y) > 0) y,
        ];
      });
      return rows!;
    }

    testWidgets('a top-left anchored window unfolds from its middle line', (
      tester,
    ) async {
      final rows = await paintedRows(
        tester,
        WindowSkinComponent(
          initialOpenness: 0.5,
          position: Vector2(0, 30),
          size: Vector2(100, 40),
        ),
      );
      // The window covers y 30..70; half open it covers 40..60.
      expect(rows.first, inInclusiveRange(39, 41));
      expect(rows.last, inInclusiveRange(59, 61));
    });

    testWidgets('a center anchored window unfolds from its middle line too', (
      tester,
    ) async {
      final rows = await paintedRows(
        tester,
        WindowSkinComponent(
          initialOpenness: 0.5,
          position: Vector2(50, 50),
          size: Vector2(100, 40),
          anchor: Anchor.center,
        ),
      );
      expect(rows.first, inInclusiveRange(39, 41));
      expect(rows.last, inInclusiveRange(59, 61));
    });

    testWidgets('a scaled, bottom anchored window as well', (tester) async {
      final rows = await paintedRows(
        tester,
        WindowSkinComponent(
          initialOpenness: 0.5,
          position: Vector2(50, 90),
          size: Vector2(50, 20),
          scale: Vector2.all(2),
          anchor: Anchor.bottomCenter,
        ),
      );
      // Scaled to 100 x 40 with its bottom at y = 90: 50..90, half 60..80.
      expect(rows.first, inInclusiveRange(59, 61));
      expect(rows.last, inInclusiveRange(79, 81));
    });
  });

  group('CommandListWindow.moveSelection', () {
    const enabled = WindowCommandItem(id: 'e', label: 'Enabled');
    const disabled = WindowCommandItem(
      id: 'd',
      label: 'Disabled',
      enabled: false,
    );

    CommandListWindow list(List<WindowCommandItem> items) =>
        CommandListWindow(items: items, size: Vector2(200, 200));

    test('skips disabled rows', () {
      final window = list(const [enabled, disabled, disabled, enabled]);
      window.moveSelection(1, skipDisabled: true);
      expect(window.selectedIndex, 3);
      window.moveSelection(-1, skipDisabled: true);
      expect(window.selectedIndex, 0);
    });

    test('does not land on a disabled row at the end of a list that does '
        'not wrap', () {
      final window = list(const [enabled, enabled, disabled]);
      window.moveSelection(1, wrap: false, skipDisabled: true);
      expect(window.selectedIndex, 1);
      window.moveSelection(1, wrap: false, skipDisabled: true);
      expect(window.selectedIndex, 1);
      window.moveSelection(5, wrap: false, skipDisabled: true);
      expect(window.selectedIndex, 1);
    });

    test('wraps past disabled rows and stays put when all are disabled', () {
      final wrapping = list(const [enabled, disabled, enabled, disabled]);
      wrapping.moveSelection(2, skipDisabled: true);
      expect(wrapping.selectedIndex, 0);

      final nothingToSelect = list(const [disabled, disabled, disabled]);
      nothingToSelect.moveSelection(1, skipDisabled: true);
      expect(nothingToSelect.selectedIndex, 0);
    });

    test('without skipping it moves row by row and stops at the ends', () {
      final window = list(const [enabled, disabled, enabled]);
      window.moveSelection(1, wrap: false);
      expect(window.selectedIndex, 1);
      window.moveSelection(5, wrap: false);
      expect(window.selectedIndex, 2);
      window.moveSelection(1);
      expect(window.selectedIndex, 0);
    });
  });

  group('PagedGridWindow', () {
    test('emptying a scrolled grid hides the scroll indicators', () {
      final items = [
        for (var i = 0; i < 40; i++) WindowCommandItem(id: '$i', label: '$i'),
      ];
      final grid = PagedGridWindow(items: items, size: Vector2(200, 100));
      grid.setItems(items, selectIndex: 20);
      expect(grid.showScrollUpIndicator, isTrue);
      expect(grid.showScrollDownIndicator, isTrue);

      grid.setItems(const []);
      expect(grid.showScrollUpIndicator, isFalse);
      expect(grid.showScrollDownIndicator, isFalse);
      expect(grid.selectedIndex, -1);
    });
  });
}
