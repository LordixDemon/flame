import 'package:flame/game.dart';
import 'package:flame_3d_example/barrier/barrier_game.dart';
import 'package:flame_3d_example/scenarios/standalone_scenario.dart';

/// A barrier around a stone platform in a pool, hit in several colors, and
/// water splashes, in a 3D layer over 2D water, see [BarrierGame].
class BarrierScenario() extends StandaloneScenario {
  @override
  Game createGame() => BarrierGame();
}
