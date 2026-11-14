import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:meta/meta.dart';

/// Lifecycle-safe mixin binding a [Component] to `FlameGame.graphics` quality
/// and dynamic resolution updates.
///
/// Subscribes automatically in [onMount], invokes [onGraphicsProfileChanged]
/// immediately with the active profile, and detaches cleanly in [onRemove].
mixin HasGraphicsAdaptation on Component {
  GraphicsSettingsController? _boundGraphics;

  /// Active [GraphicsProfile] from the enclosing [FlameGame], or
  /// [GraphicsProfile.high] if detached.
  GraphicsProfile get activeGraphicsProfile =>
      _boundGraphics?.profile ?? GraphicsProfile.high;

  /// Active [GraphicsQualityTier] from the enclosing [FlameGame], or
  /// [GraphicsQualityTier.high] if detached.
  GraphicsQualityTier get activeGraphicsTier =>
      _boundGraphics?.tier ?? GraphicsQualityTier.high;

  void _handleGraphicsNotification() {
    final ctrl = _boundGraphics;
    if (ctrl != null && isMounted) {
      onGraphicsProfileChanged(ctrl.profile, ctrl.tier);
    }
  }

  /// Invoked on mount and whenever `FlameGame.graphics` changes tier, custom
  /// profile, or dynamic governor multipliers.
  void onGraphicsProfileChanged(
    GraphicsProfile profile,
    GraphicsQualityTier tier,
  ) {}

  @mustCallSuper
  @override
  void onMount() {
    super.onMount();
    final game = findGame();
    if (game is FlameGame) {
      _boundGraphics = game.graphics..addListener(_handleGraphicsNotification);
      onGraphicsProfileChanged(game.graphics.profile, game.graphics.tier);
    }
  }

  @mustCallSuper
  @override
  void onRemove() {
    _boundGraphics?.removeListener(_handleGraphicsNotification);
    _boundGraphics = null;
    super.onRemove();
  }
}
