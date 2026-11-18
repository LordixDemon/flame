import 'package:flame/game.dart';
import 'package:flame_3d_example/scenarios/standalone_scenario.dart';
import 'package:flame_3d_example/showcase/showcase_game.dart';

/// All-in-one maximum-feature `flame_3d` testbed scenario, see [ShowcaseGame].
class ShowcaseScenario() extends StandaloneScenario {
  @override
  Game createGame() => ShowcaseGame();
}
