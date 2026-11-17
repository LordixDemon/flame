import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flame/src/game/game_render_box.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _HideableButton({required String label})
    extends PositionComponent
    with SemanticsComponent, HasVisibility {
  this {
    position = Vector2(20, 20);
    size = Vector2.all(48);
    semanticsLabel = label;
    isSemanticsButton = true;
  }
}

Widget _host(FlameGame game) => Directionality(
  textDirection: TextDirection.ltr,
  child: GameWidget(game: game),
);

Future<void> _pumpFrames(WidgetTester tester, [int frames = 3]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

void main() {
  group('GameRenderBox keeps the semantics tree up to date', () {
    testWidgets('when a SemanticsComponent is hidden and shown again', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final game = FlameGame();
      final button = _HideableButton(label: 'Buy plot');
      game.camera.viewport.add(button);

      await tester.pumpWidget(_host(game));
      await tester.pump();
      await _pumpFrames(tester);
      expect(find.semantics.byLabel('Buy plot'), findsOne);

      // Nothing moves: only the visibility changes.
      button.isVisible = false;
      await _pumpFrames(tester);
      expect(find.semantics.byLabel('Buy plot'), findsNothing);

      button.isVisible = true;
      await _pumpFrames(tester);
      expect(find.semantics.byLabel('Buy plot'), findsOne);
      handle.dispose();
    });

    testWidgets('when a camera mask excludes a world component', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final game = FlameGame();
      final tile = _HideableButton(label: 'Harbor');
      game.world.add(tile);

      await tester.pumpWidget(_host(game));
      await tester.pump();
      await _pumpFrames(tester);
      expect(find.semantics.byLabel('Harbor'), findsOne);

      tile.cameraMask = 0x2;
      game.camera.cameraMask = 0x1;
      await _pumpFrames(tester);
      expect(find.semantics.byLabel('Harbor'), findsNothing);
      handle.dispose();
    });

    testWidgets('when the render box is given another game', (tester) async {
      final handle = tester.ensureSemantics();

      Future<FlameGame> startedGame() async {
        final game = FlameGame()..onGameResize(Vector2(800, 600));
        await game.start();
        return game;
      }

      Widget renderWidget(FlameGame game) => Directionality(
        textDirection: TextDirection.ltr,
        child: RenderGameWidget(
          game: game,
          addRepaintBoundary: true,
          behavior: HitTestBehavior.opaque,
        ),
      );

      final first = await startedGame();
      first.camera.viewport.add(_HideableButton(label: 'Old game button'));
      await first.ready();
      await tester.pumpWidget(renderWidget(first));
      await _pumpFrames(tester);
      expect(find.semantics.byLabel('Old game button'), findsOne);

      // The same render box now shows a game with nothing accessible in it,
      // and nothing moves in either game.
      final second = await startedGame();
      await tester.pumpWidget(renderWidget(second));
      await _pumpFrames(tester);
      expect(find.semantics.byLabel('Old game button'), findsNothing);

      // Leave no ticker behind.
      await tester.pumpWidget(const SizedBox());
      handle.dispose();
    });
  });
}
