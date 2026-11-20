import 'package:flame/game.dart';
import 'package:flame_3d_example/pool/pool_game.dart';
import 'package:flame_3d_example/scenarios/standalone_scenario.dart';

/// A 2D game whose 3D layer is a clear pool with slabs that rise out of the
/// water, see [PoolGame].
class PoolScenario() extends StandaloneScenario {
  @override
  Game createGame() => PoolGame();
}
