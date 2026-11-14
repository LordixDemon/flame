/// {@canonicalFor text.TextPaint}
/// {@canonicalFor text.TextRenderer}
library;

export 'src/collisions/has_collision_detection.dart';
export 'src/components/mixins/has_fixed_update.dart';
export 'src/components/mixins/passive_component.dart';
export 'src/components/router/overlay_route.dart' show OverlayRoute;
export 'src/components/router/route.dart' show Route;
export 'src/components/router/router_component.dart' show RouterComponent;
export 'src/components/router/value_route.dart' show ValueRoute;
export 'src/components/router/world_route.dart' show WorldRoute;
export 'src/extensions/vector2.dart';
export 'src/game/flame_game.dart';
export 'src/game/game.dart';
export 'src/game/game_widget/game_widget.dart';
export 'src/game/mixins/defer_hit_test_to_components.dart';
export 'src/game/mixins/has_frame_telemetry.dart';
export 'src/game/mixins/has_performance_tracker.dart';
export 'src/game/mixins/single_game_instance.dart';
export 'src/game/notifying_vector2.dart';
export 'src/game/overlay_manager.dart'
    show OverlayBuilderFunction, OverlayManager, OverlayTransitionBuilder;
export 'src/game/telemetry_canvas.dart';
export 'src/game/transform2d.dart';
export 'src/text/renderers/text_paint.dart';
