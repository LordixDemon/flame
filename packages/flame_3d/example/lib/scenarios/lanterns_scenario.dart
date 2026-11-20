import 'package:flame/game.dart';
import 'package:flame_3d_example/lanterns/lanterns_game.dart';
import 'package:flame_3d_example/scenarios/standalone_scenario.dart';

/// The pool at dusk lit by 200 small lights through a light grid, see
/// [LanternsGame].
class LanternsScenario() extends StandaloneScenario {
  @override
  Game createGame() => LanternsGame(lights: 200);
}
