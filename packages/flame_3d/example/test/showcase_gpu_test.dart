import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame_3d/graphics.dart';
import 'package:flame_3d_example/showcase/showcase_diagnostics.dart';
import 'package:flame_3d_example/showcase/showcase_game.dart';
import 'package:flame_3d_example/showcase/showcase_view.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final gpuAvailable = GpuBackend.isAvailable;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    if (gpuAvailable) {
      await GpuBackend.initialize();
    }
  });

  testWidgets(
    'ShowcaseGame boots, renders all subsystems, and passes 12/12 self-tests',
    (tester) async {
      tester.view
        ..physicalSize = const ui.Size(640, 400)
        ..devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final game = ShowcaseGame();
      addTearDown(game.controller.dispose);
      final boundaryKey = GlobalKey();

      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: RepaintBoundary(
            key: boundaryKey,
            child: ShowcaseView(game: game),
          ),
        ),
      );

      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(game.isLoaded, isTrue);

      final report = await ShowcaseDiagnostics.runAllChecks(
        game,
        pumpFrame: () => tester.pump(const Duration(milliseconds: 16)),
        readImageBytes: (img) =>
            tester.runAsync<ByteData?>(() => img.toByteData()),
      );

      final failedDetails = report.results
          .where((r) => !r.passed)
          .map((r) => '${r.id}: ${r.detail}')
          .join('\n');
      expect(
        report.allPassed,
        isTrue,
        reason: 'Failed showcase checks:\n$failedDetails',
      );
      expect(report.totalCount, 12);

      // Verify 1,024-instance stress mode renders in a single instanced draw
      // for the tile mesh and paints visible pixels into the frame!
      game.controller
        ..stressInstances = true
        ..retainedStaticLayer = false;
      game.syncControllerState();
      await tester.pump(const Duration(milliseconds: 16));
      expect(game.tileInstances.length, 1024);
      expect(
        game.staticLayer.renderStats.instances,
        greaterThanOrEqualTo(1024),
      );

      final boundary =
          boundaryKey.currentContext!.findRenderObject()!
              as RenderRepaintBoundary;
      final nonDarkPixels = await tester.runAsync(() async {
        final image = await boundary.toImage();
        final data = await image.toByteData();
        image.dispose();
        final bytes = data!.buffer.asUint8List();
        var count = 0;
        for (var i = 0; i + 3 < bytes.length; i += 4) {
          if (bytes[i] > 60 || bytes[i + 1] > 60 || bytes[i + 2] > 80) {
            count++;
          }
        }
        return count;
      });
      expect(nonDarkPixels, greaterThan(5000));
    },
    skip: !gpuAvailable,
  );
}
