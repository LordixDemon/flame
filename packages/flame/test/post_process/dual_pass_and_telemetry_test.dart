import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/post_process.dart';
import 'package:flame_test/flame_test.dart';
import 'package:flutter_test/flutter_test.dart';

class _DualPassInspectorPostProcess() extends PostProcess {
  this : super(pixelRatio: 1.0);

  int? primaryW;
  int? primaryH;
  int? auxW;
  int? auxH;
  final List<Object?> observedTags = [];

  @override
  void postProcess(Vector2 size, ui.Canvas canvas) {
    final primary = rasterizePass(passTag: 'scene');
    final aux = rasterizePass(
      resolutionScale: 0.25,
      passTag: 'bloomAux',
      cameraRenderPass: RenderPass.emissiveMask,
    );
    primaryW = primary.width;
    primaryH = primary.height;
    auxW = aux.width;
    auxH = aux.height;
    canvas.drawImage(primary, ui.Offset.zero, ui.Paint());
    primary.dispose();
    aux.dispose();
  }
}

class _OpaqueWorldProp() extends Component {
  int renders = 0;

  @override
  void render(ui.Canvas canvas) {
    renders++;
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 20, 20),
      ui.Paint()..color = const ui.Color(0xFF336699),
    );
  }
}

class _GlowingCrystalProp(
  final List<Object?> observedTags,
) extends Component with MultiPassComponent {
  final List<String> executedPasses = [];

  @override
  Set<RenderPass> get activeRenderPasses => const {
    RenderPass.opaque,
    RenderPass.emissiveMask,
  };

  @override
  void renderPass(ui.Canvas canvas, RenderPass pass) {
    executedPasses.add(pass.name);
    observedTags.add(findPostProcessFromContext()?.currentPassTag);
    canvas.drawCircle(
      const ui.Offset(10, 10),
      8,
      ui.Paint()..color = const ui.Color(0xFFFFCC44),
    );
  }
}

class _TelemetryDemoGame() extends FlameGame with HasFrameTelemetry;

class _VerticesAndLayerComponent(final ui.Image atlas) extends Component {
  @override
  void render(ui.Canvas canvas) {
    canvas.saveLayer(const ui.Rect.fromLTWH(0, 0, 64, 64), ui.Paint());
    final verts = ui.Vertices.raw(
      ui.VertexMode.triangles,
      Float32List.fromList([0, 0, 32, 0, 16, 32]),
    );
    canvas.drawVertices(verts, ui.BlendMode.srcOver, ui.Paint());
    verts.dispose();
    canvas.drawAtlas(
      atlas,
      [ui.RSTransform(1, 0, 0, 0)],
      [const ui.Rect.fromLTWH(0, 0, 8, 8)],
      null,
      ui.BlendMode.srcOver,
      null,
      ui.Paint(),
    );
    canvas.restore();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Multi-Texture PostProcess.rasterizePass', () {
    testWithFlameGame(
      'rasterizes 0.25x downscaled emissiveMask auxiliary pass and isolates '
      'MultiPassComponent draws',
      (game) async {
        game.onGameResize(Vector2(400, 200));
        final inspector = _DualPassInspectorPostProcess();
        final opaqueProp = _OpaqueWorldProp();
        final crystal = _GlowingCrystalProp(inspector.observedTags);

        await game.world.ensureAddAll([opaqueProp, crystal]);
        game.camera.postProcess = inspector;
        await game.ready();

        final recorder = ui.PictureRecorder();
        game.render(ui.Canvas(recorder));
        recorder.endRecording().dispose();

        expect(inspector.primaryW, equals(400));
        expect(inspector.primaryH, equals(200));
        expect(inspector.auxW, equals(100));
        expect(inspector.auxH, equals(50));
        expect(inspector.currentPassTag, isNull);

        expect(opaqueProp.renders, equals(1));
        expect(crystal.executedPasses, ['opaque', 'emissiveMask']);
        expect(inspector.observedTags, ['scene', 'bloomAux']);
      },
    );
  });

  group('UniformSlotBuffer & GPU Render Telemetry', () {
    test(
      'UniformSlotBuffer skips redundant FFI setFloat calls and re-uploads '
      'only mutated slots or rebound shaders',
      () {
        final shaderIdentityA = Object();
        final shaderIdentityB = Object();
        final uploads = <(int, double)>[];
        final buffer = UniformSlotBuffer(initialCapacity: 8);

        for (var frame = 0; frame < 10; frame++) {
          for (var slot = 0; slot < 16; slot++) {
            final val = slot == 2 ? frame * 0.016 : slot * 1.25;
            buffer.setFloatCustom(
              shaderIdentityA,
              slot,
              val,
              (idx, v) => uploads.add((idx, v)),
            );
          }
        }

        expect(buffer.uploadedCount, equals(16 + 9));
        expect(buffer.skippedCount, equals(15 * 9));
        expect(uploads.length, equals(25));

        final uploadsB = <(int, double)>[];
        buffer.setFloatCustom(
          shaderIdentityB,
          0,
          0.0,
          (idx, v) => uploadsB.add((idx, v)),
        );
        expect(uploadsB, [(0, 0.0)]);
      },
    );

    test(
      'HasFrameTelemetry & TelemetryCanvas count drawCalls, atlasCalls, '
      'verticesCalls, saveLayerCalls, offscreenRasterizations, and timings',
      () async {
        final atlas = await generateImage(16, 16);
        final game = _TelemetryDemoGame()..onGameResize(Vector2(320, 240));
        final inspector = _DualPassInspectorPostProcess();
        game.world.add(_VerticesAndLayerComponent(atlas));
        game.camera.postProcess = inspector;
        await game.start();

        game.update(1 / 120);
        final recorder = ui.PictureRecorder();
        game.render(ui.Canvas(recorder));
        recorder.endRecording().dispose();

        expect(game.collectRenderTelemetry, isTrue);
        expect(game.lastOffscreenRasterizations, equals(2));
        expect(game.lastVerticesCalls, equals(1));
        expect(game.lastAtlasCalls, equals(1));
        expect(game.lastSaveLayerCalls, equals(1));
        expect(game.lastDrawCalls, equals(3));
        expect(game.lastUpdateMicros, greaterThanOrEqualTo(0));
        expect(game.lastRenderMicros, greaterThanOrEqualTo(0));
      },
    );
  });
}
