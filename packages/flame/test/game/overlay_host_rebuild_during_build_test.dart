import 'package:flame/game.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(FlameGame game) => Directionality(
  textDirection: TextDirection.ltr,
  child: GameWidget(game: game),
);

/// An overlay that closes another overlay as soon as it is shown.
class const _ClosesOther({
  required final FlameGame game,
}) extends StatefulWidget {
  @override
  State<_ClosesOther> createState() => _ClosesOtherState();
}

class _ClosesOtherState() extends State<_ClosesOther> {
  @override
  void initState() {
    super.initState();
    widget.game.overlays.remove('hud');
  }

  @override
  Widget build(BuildContext context) => const Text('MENU');
}

void main() {
  group('OverlayHost changes that happen while the frame is being built', () {
    testWidgets(
      'an animated overlay can be removed before its enter transition has '
      'advanced',
      (tester) async {
        final game = FlameGame();
        game.overlays.addAnimatedEntry(
          'banner',
          (context, game) => const Text('BANNER'),
          reverseDuration: const Duration(milliseconds: 180),
        );
        await tester.pumpWidget(_host(game));
        await tester.pump();

        game.overlays.add('banner');
        await tester.pump();
        expect(find.text('BANNER'), findsOneWidget);

        // The controller is still at 0, so the exit transition completes the
        // moment it starts, while the host is updating its children.
        game.overlays.remove('banner');
        await tester.pump();
        expect(tester.takeException(), isNull);

        await tester.pump();
        expect(find.text('BANNER'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'an animated overlay without an exit transition leaves in the same '
      'frame',
      (tester) async {
        final game = FlameGame();
        game.overlays.addAnimatedEntry(
          'banner',
          (context, game) => const Text('BANNER'),
          reverseDuration: Duration.zero,
        );
        await tester.pumpWidget(_host(game));
        await tester.pump();

        game.overlays.add('banner');
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('BANNER'), findsOneWidget);

        game.overlays.remove('banner');
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('BANNER'), findsNothing);
      },
    );

    testWidgets(
      'an overlay with only a transition builder leaves in the same frame',
      (tester) async {
        final game = FlameGame();
        game.overlays.addEntry(
          'badge',
          (context, game) => const Text('BADGE'),
          transitionBuilder: (context, animation, child) =>
              ScaleTransition(scale: animation, child: child),
        );
        await tester.pumpWidget(_host(game));
        await tester.pump();

        game.overlays.add('badge');
        await tester.pump();
        expect(find.text('BADGE'), findsOneWidget);

        game.overlays.remove('badge');
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.text('BADGE'), findsNothing);
      },
    );

    testWidgets('an exit transition still plays to its end', (tester) async {
      final game = FlameGame();
      game.overlays.addAnimatedEntry(
        'banner',
        (context, game) => const Text('BANNER'),
        reverseDuration: const Duration(milliseconds: 180),
      );
      await tester.pumpWidget(_host(game));
      await tester.pump();

      game.overlays.add('banner');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      game.overlays.remove('banner');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 90));
      expect(find.text('BANNER'), findsOneWidget, reason: 'still fading out');

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(find.text('BANNER'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'an overlay widget can change the overlays while it is being mounted',
      (tester) async {
        final game = FlameGame();
        game.overlays
          ..addEntry('hud', (context, game) => const Text('HUD'))
          ..addEntry(
            'menu',
            (context, game) => _ClosesOther(game: game as FlameGame),
          )
          ..add('hud');
        await tester.pumpWidget(_host(game));
        await tester.pump();
        expect(find.text('HUD'), findsOneWidget);

        game.overlays.add('menu');
        await tester.pump();
        expect(tester.takeException(), isNull);

        await tester.pump();
        expect(find.text('MENU'), findsOneWidget);
        expect(find.text('HUD'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the builder of an animated overlay can change the overlays',
      (tester) async {
        final game = FlameGame();
        game.overlays
          ..addEntry('hint', (context, game) => const Text('HINT'))
          ..addAnimatedEntry('banner', (context, game) {
            game.overlays.add('hint');
            return const Text('BANNER');
          });
        await tester.pumpWidget(_host(game));
        await tester.pump();

        game.overlays.add('banner');
        await tester.pump();
        expect(tester.takeException(), isNull);

        await tester.pump();
        expect(find.text('BANNER'), findsOneWidget);
        expect(find.text('HINT'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
