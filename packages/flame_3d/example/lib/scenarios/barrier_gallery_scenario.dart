import 'package:flame/game.dart';
import 'package:flame_3d_example/barrier/barrier_gallery.dart';
import 'package:flame_3d_example/scenarios/standalone_scenario.dart';

/// A row of podiums walled by barriers: one per preset look, then strips
/// that sweep the height, the profile, the density and the reaction one at a
/// time, see [BarrierGalleryGame].
class BarrierGalleryScenario() extends StandaloneScenario {
  @override
  Game createGame() => BarrierGalleryGame();
}
