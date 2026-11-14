import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OverlayHost isolated rebuilds & animated transitions', () {
    testWidgets(
      'toggling overlays never rebuilds GameWidgetState while updating UI',
      (tester) async {
        final game = FlameGame();
        const hudKey = ValueKey('isolated-hud');

        await tester.pumpWidget(
          GameWidget(
            game: game,
            overlayBuilderMap: {
              'hud': (_, _) => Positioned(
                top: 12,
                left: 12,
                child: Container(key: hudKey, width: 80, height: 32),
              ),
            },
          ),
        );
        await game.toBeLoaded();
        await tester.pump();

        final state = tester.state<GameWidgetState<FlameGame>>(
          find.byType(GameWidget<FlameGame>),
        );
        final baselineBuilds = state.debugBuildCount;
        expect(find.byKey(hudKey), findsNothing);

        for (var i = 0; i < 6; i++) {
          game.overlays.add('hud');
          await tester.pump();
          expect(find.byKey(hudKey), findsOneWidget);

          game.overlays.remove('hud');
          await tester.pump();
          expect(find.byKey(hudKey), findsNothing);
        }

        // GameWidgetState was NOT rebuilt a single time across 12 toggles!
        expect(state.debugBuildCount, baselineBuilds);
      },
    );

    testWidgets(
      'addAnimatedEntry plays enter and reverse exit transitions before '
      'unmounting',
      (tester) async {
        final game = FlameGame();
        const bannerKey = ValueKey('animated-banner');
        game.overlays.addAnimatedEntry(
          'banner',
          (_, _) => Positioned(
            top: 24,
            right: 24,
            child: Container(key: bannerKey, width: 120, height: 40),
          ),
          duration: const Duration(milliseconds: 200),
        );

        await tester.pumpWidget(GameWidget(game: game));
        await game.toBeLoaded();
        await tester.pump();

        expect(find.byKey(bannerKey), findsNothing);

        game.overlays.add('banner');
        await tester.pump();
        expect(find.byKey(bannerKey), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 220));

        // Removing keeps widget mounted mid-reverse, then unmounts cleanly.
        game.overlays.remove('banner');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(game.overlays.isActive('banner'), isFalse);
        expect(find.byKey(bannerKey), findsOneWidget);

        await tester.pump(const Duration(milliseconds: 150));
        expect(find.byKey(bannerKey), findsNothing);
      },
    );
  });
}
