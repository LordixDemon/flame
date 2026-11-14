import 'dart:ui' as ui;

import 'package:flame/audio.dart';
import 'package:flame/collisions.dart';
import 'package:flame/components.dart';
import 'package:flame/debug.dart';
import 'package:flame/game.dart';
import 'package:flame/grid.dart';
import 'package:flame/input.dart';
import 'package:flame/layout.dart';
import 'package:flame/math.dart';
import 'package:flame/navigation.dart';
import 'package:flame/text.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _ToggleChild({required super.size})
    extends PositionComponent
    with HasVisibility;

class const _GoalReachedEvent(final int bonus);

enum _AgentPhase() {
  seeking,
  celebrating,
}

enum _AgentSignal() {
  reachedGoal,
}

class _ExplorerActor({
  required super.position,
  required super.size,
  super.velocity,
}) extends KinematicBodyComponent with HasTags {
  this {
    addTags(const <String>['hero', 'active']);
  }
}

ui.Image _badgeImageSync() {
  final rec = ui.PictureRecorder();
  ui.Canvas(rec).drawCircle(
    const Offset(8, 8),
    7,
    Paint()..color = const Color(0xFF26C6DA),
  );
  final pic = rec.endRecording();
  try {
    return pic.toImageSync(16, 16);
  } finally {
    pic.dispose();
  }
}

void main() {
  group('Flex/Grid Layout & Multiline RichBatchedTextComponent edge cases', () {
    test(
      'all FlexMainAxisAlignment modes, HasVisibility skip & Anchor.center',
      () {
        for (final align in FlexMainAxisAlignment.values) {
          final single = PositionComponent(size: Vector2(20, 12));
          final row = RowLayoutComponent(
            shrinkWrap: false,
            size: Vector2(100, 30),
            mainAxisAlignment: align,
            children: <Component>[single],
          )..performLayout();
          expect(single.position.x.isNaN, isFalse);
          expect(row.size, Vector2(100, 30));
        }

        // spaceBetween with 3 items across 100px width -> 0, 40, 80!
        final a = PositionComponent(size: Vector2(20, 10));
        final b = _ToggleChild(size: Vector2(20, 10));
        final c = PositionComponent(size: Vector2(20, 10));
        final row = RowLayoutComponent(
          shrinkWrap: false,
          size: Vector2(100, 20),
          mainAxisAlignment: FlexMainAxisAlignment.spaceBetween,
          children: <Component>[a, b, c],
        )..performLayout();
        expect(a.position.x, closeTo(0.0, 1e-5));
        expect(b.position.x, closeTo(40.0, 1e-5));
        expect(c.position.x, closeTo(80.0, 1e-5));

        // Hiding middle child skips it cleanly during relayout!
        b.isVisible = false;
        row.performLayout();
        expect(a.position.x, closeTo(0.0, 1e-5));
        expect(c.position.x, closeTo(80.0, 1e-5));

        // Anchor.center children align visually inside padded ColumnLayout!
        final centeredChild = PositionComponent(
          size: Vector2(40, 20),
          anchor: Anchor.center,
        );
        final col = ColumnLayoutComponent(
          padding: const EdgePadding.all(10),
          children: <Component>[centeredChild],
        )..performLayout();
        expect(col.size, Vector2(60, 40));
        expect(centeredChild.position, Vector2(30, 20));
      },
    );

    test(
      r'RichBatchedTextComponent multiline \n, malformed tags & typewriter',
      () {
        final font = RasterFontAtlas.bake(
          style: const TextStyle(fontSize: 14, color: Color(0xFFFFFFFF)),
        );
        final iconImg = _badgeImageSync();
        try {
          final multiline = RichBatchedTextComponent(
            atlas: font,
            markup:
                'Line 1 <color=#FFCA28>Gold</color>\n'
                'Line 2 [icon:gem] <wave>Longer second line!</wave>\r\n'
                'Line 3 <unclosed_tag>still renders safely',
            icons: <String, RichTextIconSpan>{
              'gem': RichTextIconSpan(
                image: iconImg,
                srcRect: const Rect.fromLTWH(0, 0, 16, 16),
                logicalWidth: 14,
                logicalHeight: 14,
              ),
            },
          );

          expect(multiline.lineCount, 3);
          expect(multiline.size.y, closeTo(font.lineHeight * 3, 1e-4));
          expect(multiline.size.x, greaterThan(80));

          // Fractional typewriter reveal (7.5 tokens/sec * 0.4s = 3 tokens).
          multiline
            ..startTypewriter(tokensPerSecond: 7.5)
            ..update(0.4);
          expect(multiline.visibleTokenLimit, 3);

          final rec = ui.PictureRecorder();
          multiline.render(ui.Canvas(rec));
          rec.endRecording().dispose();

          // Changing markup dynamically recomputes lineCount and bounds.
          multiline.markup = 'Single line';
          expect(multiline.lineCount, 1);
          expect(multiline.size.y, closeTo(font.lineHeight, 1e-4));
        } finally {
          font.dispose();
          iconImg.dispose();
        }
      },
    );
  });

  group('End-to-End Cross-Subsystem Headless FlameGame Verification', () {
    test(
      'Input + Pathfinding + Kinematic + TriggerZone + FSM + EventBus + '
      'WorldQuery + SpatialAudio + RichHUD + BenchmarkRunner work together',
      () async {
        final font = RasterFontAtlas.bake(
          style: const TextStyle(fontSize: 13, color: Color(0xFFFFFFFF)),
        );
        try {
          final world = World(spatialIndexEnabled: true);
          final game = FlameGame(world: world)..onGameResize(Vector2(640, 360));

          // 1. Input & modal context stack.
          final inputMap = InputMap()
            ..bind('advance', ActionBinding.key(LogicalKeyboardKey.space));
          final contextStack = InputContextStack()
            ..push(
              InputContext(
                name: 'gameplay',
                allowedActions: const <String>['advance'],
              ),
            );
          inputMap.handleKeyEvent(
            const KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.space,
              logicalKey: LogicalKeyboardKey.space,
              timeStamp: Duration.zero,
            ),
          );
          expect(
            inputMap.isPressed('advance') &&
                contextStack.isActionAllowed('advance'),
            isTrue,
          );

          // 2. Grid pathfinding around obstacle -> compute direction to goal!
          final pathfinder = AStarGridPathfinder(width: 8, height: 8)
            ..setBlocked(1, 0, blocked: true);
          final gridPath = <GridCell>[];
          expect(
            pathfinder.findPath(
              const GridCell(0, 0),
              const GridCell(2, 0),
              gridPath,
            ),
            isTrue,
          );
          expect(gridPath.length, greaterThan(3)); // detoured around (1, 0)!

          // 3. Audio mixer + spatial 2D cue.
          final audioBackend = InMemoryAudioBackend();
          final mixer = AudioMixer(backend: audioBackend);
          final listener = SpatialAudioListener2D(maxDistance: 600);
          final chimeCue = SoundCue(
            id: 'goal_chime',
            cooldownSeconds: 0.0,
            clips: <SoundClipEntry>[SoundClipEntry(assetId: 'chime.wav')],
          );

          // 4. FSM + WorldEventBus + WorldQuery + Rich HUD banner.
          var totalScore = 0;
          final fsm =
              StateMachine<_AgentPhase, _AgentSignal>(
                  initialState: _AgentPhase.seeking,
                )
                ..registerState(
                  StateNode<_AgentPhase>(id: _AgentPhase.seeking),
                )
                ..registerState(
                  StateNode<_AgentPhase>(id: _AgentPhase.celebrating),
                )
                ..addTransition(
                  from: _AgentPhase.seeking,
                  onEvent: _AgentSignal.reachedGoal,
                  to: _AgentPhase.celebrating,
                );

          final hudBanner = RichBatchedTextComponent(
            atlas: font,
            markup: 'Score: 0',
          );
          final debugHud = EngineDebugOverlay();
          game.camera.viewport.addAll(<Component>[hudBanner, debugHud]);

          final activeHeroes = world.registerQuery<_ExplorerActor>(
            WorldQuery<_ExplorerActor>(
              withTags: const <String>['hero', 'active'],
            ),
          );

          final hero = _ExplorerActor(
            position: Vector2(20, 60),
            size: Vector2(20, 20),
            velocity: Vector2(360, 0),
          );
          final goalSensor = TriggerZoneComponent(
            position: Vector2(90, 50),
            size: Vector2(40, 40),
            entityFilter: (c) => c is _ExplorerActor,
            onEntityEntered: (entity) {
              fsm.dispatch(_AgentSignal.reachedGoal);
              world.eventBus.enqueue(const _GoalReachedEvent(250));
              listener.playCueAt(
                mixer,
                chimeCue,
                worldX: entity.position.x,
                worldY: entity.position.y,
                rng: SeededRng(42),
              );
              (entity as _ExplorerActor).removeTag('active');
            },
          );

          world.eventBus.on<_GoalReachedEvent>((e) {
            totalScore += e.bonus;
            hudBanner.markup =
                'Score: <color=#69F0AE>$totalScore</color>\nCOMPLETE!';
          });

          // Drive kinematic movement inside a tick driver component.
          final simDriver = TimerComponent(
            period: 0.01,
            repeat: true,
            onTick: () {
              hero.moveAndSlide(1 / 60);
              mixer.update(1 / 60);
            },
          );

          world.addAll(<Component>[
            StateMachineComponent<_AgentPhase, _AgentSignal>(machine: fsm),
            hero,
            goalSensor,
            simDriver,
          ]);

          final report = await SceneBenchmarkRunner.run(
            game,
            warmupFrames: 3,
            measuredFrames: 20,
            viewportSize: Vector2(640, 360),
          );

          expect(fsm.currentState, _AgentPhase.celebrating);
          expect(totalScore, 250);
          expect(hudBanner.lineCount, 2);
          // live removeTag('active') updated query!
          expect(activeHeroes.length, 0);
          expect(audioBackend.startedCount, 1);
          expect(
            report.evaluateBudget(
              const SceneBenchmarkBudget(
                maxPeakDrawCalls: 500,
                maxPeakSaveLayerCalls: 25,
              ),
            ),
            isEmpty,
          );
        } finally {
          font.dispose();
        }
      },
    );
  });
}
