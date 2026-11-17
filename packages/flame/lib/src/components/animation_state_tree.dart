import 'package:flame/src/sprite_animation.dart';
import 'package:flame/src/sprite_animation_ticker.dart';

/// Declarative animation state controller mapping typed state keys [S] to
/// [SpriteAnimationTicker] instances with automatic one-shot return transitions
/// and named frame-event dispatch.
class AnimationStateTree<S>({required S initialState, this.onAnimationEvent}) {
  final Map<S, SpriteAnimationTicker> _tickers = <S, SpriteAnimationTicker>{};
  S _currentState = initialState;
  S? _returnToAfterOneShot;

  /// Optional listener invoked with `(state, frameIndex, eventName)` whenever
  /// the active state's [SpriteAnimationTicker] emits a frame event.
  void Function(S state, int frameIndex, String eventName)? onAnimationEvent;

  /// Currently active animation state.
  S get currentState => _currentState;

  /// Active [SpriteAnimationTicker] for [currentState] (`null` if not
  /// registered yet).
  SpriteAnimationTicker? get currentTicker => _tickers[_currentState];

  /// Current [Sprite] of the active state.
  Sprite? get currentSprite => _tickers[_currentState]?.getSprite();

  /// Registers [animation] under [state] and returns its ticker so callers can
  /// attach frame events via [SpriteAnimationTicker.registerFrameEvent].
  SpriteAnimationTicker registerState(S state, SpriteAnimation animation) {
    final ticker = animation.createTicker();
    ticker.onEvent = (frameIndex, eventName) {
      if (_currentState == state) {
        onAnimationEvent?.call(state, frameIndex, eventName);
      }
    };
    _tickers[state] = ticker;
    return ticker;
  }

  /// Switches to [nextState], resetting its ticker if [restartIfSame] or if
  /// entering a different state.
  void transitionTo(S nextState, {bool restartIfSame = false}) {
    if (_currentState == nextState && !restartIfSame) {
      return;
    }
    _returnToAfterOneShot = null;
    _currentState = nextState;
    _tickers[nextState]?.reset();
  }

  /// Plays non-looping [oneShotState] immediately and automatically returns to
  /// [returnTo] upon completion.
  ///
  /// [returnTo] defaults to the state that was current before the call. When
  /// that state is itself a one-shot that is still playing, its own return
  /// state is used instead, so that a one-shot which interrupts another one
  /// ends in the state the first one was going to return to, not on the last
  /// frame of the interrupted one-shot.
  void playOneShot(S oneShotState, {S? returnTo}) {
    final fallback = returnTo ?? _returnToAfterOneShot ?? _currentState;
    _currentState = oneShotState;
    _returnToAfterOneShot = fallback;
    _tickers[oneShotState]?.reset();
  }

  /// Advances the active ticker by [dt] and handles one-shot auto-returns.
  void update(double dt) {
    final ticker = _tickers[_currentState];
    if (ticker == null) {
      return;
    }
    ticker.update(dt);
    final next = _returnToAfterOneShot;
    if (next != null && ticker.done()) {
      _returnToAfterOneShot = null;
      _currentState = next;
      _tickers[next]?.reset();
    }
  }
}
