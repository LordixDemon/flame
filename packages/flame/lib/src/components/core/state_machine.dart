import 'package:flame/src/components/core/component.dart';

/// Definition of an individual state `S` inside a [StateMachine].
class StateNode<S>({
  required this.id,
  this.parent,
  this.onEnter,
  this.onUpdate,
  this.onExit,
}) {
  /// Unique state identifier.
  final S id;

  /// Optional parent state ID for hierarchical state inheritance.
  final S? parent;

  /// Invoked when entering this state (`previous` is `null` on initial boot).
  final void Function(S? previous)? onEnter;

  /// Invoked each tick with frame `dt` and accumulated `elapsed` seconds in
  /// this state.
  final void Function(double dt, double elapsed)? onUpdate;

  /// Invoked before exiting this state toward `next`.
  final void Function(S? next)? onExit;
}

/// Declarative event-triggered transition rule in a [StateMachine].
class const StateTransitionRule<S, E>({
  required this.from,
  required this.event,
  required this.to,
  this.guard,
}) {
  /// Source state (`null` acts as a wildcard any-state transition).
  final S? from;

  /// Triggering event key.
  final E event;

  /// Destination state.
  final S to;

  /// Optional guard predicate evaluated when [event] is dispatched.
  final bool Function()? guard;
}

/// Hierarchical & pushdown Finite State Machine (`HFSM`) supporting explicit
/// `onEnter` / `onUpdate` / `onExit` hooks, parent state chains, guarded event
/// transitions, and a push/pop state stack (e.g. `Moving -> Stunned -> Moving`).
///
/// Transitions run to completion. A transition that is requested from inside
/// an `onEnter` or `onExit` hook, or from the [onStateChanged] observer, does
/// not interrupt the one in progress: it is queued and carried out right
/// after it, before the outermost [transitionTo], [dispatch], [pushState],
/// [popState] or [start] call returns. Every state that is entered is
/// therefore exited before another branch is entered, and [onStateChanged]
/// reports the changes in the order in which they happen.
class StateMachine<S, E>({
  required S initialState,
  Iterable<StateNode<S>> states = const [],
  Iterable<StateTransitionRule<S, E>> transitions = const [],
  this.onStateChanged,
}) {
  final Map<S, StateNode<S>> _states = <S, StateNode<S>>{
    for (final node in states) node.id: node,
  };
  final List<StateTransitionRule<S, E>> _rules =
      List<StateTransitionRule<S, E>>.of(transitions);
  final List<S> _historyStack = <S>[];
  final List<S> _currAncestorsScratch = <S>[];
  final List<S> _nextAncestorsScratch = <S>[];
  final List<S> _startAncestorsScratch = <S>[];
  final List<S> _updateAncestorsScratch = <S>[];

  /// Optional observer invoked after every completed state change.
  final void Function(S previous, S current)? onStateChanged;

  S _current = initialState;
  double _stateElapsed = 0.0;
  bool _started = false;

  /// Whether the hooks of a transition (or of [start]) are running.
  bool _inTransition = false;

  /// Transitions requested while [_inTransition], oldest first.
  final List<(S, bool)> _pendingTransitions = <(S, bool)>[];

  /// Upper bound for the transitions that hooks may chain onto one request,
  /// so that two states which keep redirecting to each other fail loudly
  /// instead of spinning forever.
  static const int _maxChainedTransitions = 256;

  /// Active leaf state identifier.
  S get currentState => _current;

  /// Seconds spent in [currentState] since the last transition.
  double get stateElapsed => _stateElapsed;

  /// Depth of the pushdown state stack (`pushState` / `popState`).
  int get stackDepth => _historyStack.length;

  /// Registers or replaces a [StateNode] definition.
  void registerState(StateNode<S> node) {
    _states[node.id] = node;
  }

  /// Appends an event-triggered transition rule.
  void addTransition({
    required E onEvent,
    required S to,
    S? from,
    bool Function()? guard,
  }) {
    _rules.add(
      StateTransitionRule<S, E>(
        from: from,
        event: onEvent,
        to: to,
        guard: guard,
      ),
    );
  }

  /// Ensures `onEnter` has fired for the initial state chain.
  ///
  /// A transition that one of those hooks requests is carried out once the
  /// whole chain, from the root ancestor down to the initial state, has been
  /// entered.
  void start() {
    if (_started) {
      return;
    }
    _started = true;
    _stateElapsed = 0.0;
    _collectAncestors(_current, _startAncestorsScratch);
    _inTransition = true;
    try {
      for (var i = _startAncestorsScratch.length - 1; i >= 0; i--) {
        _states[_startAncestorsScratch[i]]?.onEnter?.call(null);
      }
      _drainPendingTransitions();
    } finally {
      _inTransition = false;
      _pendingTransitions.clear();
    }
  }

  /// Returns `true` if [state] equals [currentState] or is an active parent
  /// ancestor of [currentState].
  bool isInState(S state) {
    if (_current == state) {
      return true;
    }
    var cursor = _states[_current]?.parent;
    var guard = 0;
    while (cursor != null && guard < _maxDepth) {
      if (cursor == state) {
        return true;
      }
      cursor = _states[cursor]?.parent;
      guard++;
    }
    return false;
  }

  /// Transitions to [nextState], exiting only the non-shared branch and
  /// entering only the newly activated branch of a hierarchical state tree.
  ///
  /// Returns whether the state changed (or, with [allowSelfTransition], was
  /// re-entered). When called while another transition is in progress (from
  /// one of its hooks or from [onStateChanged]) the request is queued, runs
  /// right after that transition and `true` is returned.
  bool transitionTo(S nextState, {bool allowSelfTransition = false}) {
    if (!_started) {
      start();
    }
    if (_inTransition) {
      _pendingTransitions.add((nextState, allowSelfTransition));
      return true;
    }
    _inTransition = true;
    try {
      final changed = _performTransition(nextState, allowSelfTransition);
      _drainPendingTransitions();
      return changed;
    } finally {
      _inTransition = false;
      _pendingTransitions.clear();
    }
  }

  void _drainPendingTransitions() {
    var chained = 0;
    while (_pendingTransitions.isNotEmpty) {
      if (++chained > _maxChainedTransitions) {
        throw StateError(
          'More than $_maxChainedTransitions transitions were chained from '
          'state hooks: the hooks keep redirecting to each other',
        );
      }
      final (next, allowSelf) = _pendingTransitions.removeAt(0);
      _performTransition(next, allowSelf);
    }
  }

  bool _performTransition(S nextState, bool allowSelfTransition) {
    if (_current == nextState && !allowSelfTransition) {
      return false;
    }
    final prev = _current;
    if (prev == nextState) {
      _states[prev]?.onExit?.call(nextState);
      _stateElapsed = 0.0;
      _states[nextState]?.onEnter?.call(prev);
      onStateChanged?.call(prev, nextState);
      return true;
    }

    _collectAncestors(prev, _currAncestorsScratch);
    _collectAncestors(nextState, _nextAncestorsScratch);

    // Exit from current leaf up until the Lowest Common Ancestor (LCA).
    for (var i = 0; i < _currAncestorsScratch.length; i++) {
      final candidate = _currAncestorsScratch[i];
      if (_nextAncestorsScratch.contains(candidate)) {
        break;
      }
      _states[candidate]?.onExit?.call(nextState);
    }

    _current = nextState;
    _stateElapsed = 0.0;

    // Find LCA index in next chain and enter downward to leaf.
    var enterStart = _nextAncestorsScratch.length - 1;
    for (var i = 0; i < _nextAncestorsScratch.length; i++) {
      if (_currAncestorsScratch.contains(_nextAncestorsScratch[i])) {
        enterStart = i - 1;
        break;
      }
    }
    for (var i = enterStart; i >= 0; i--) {
      _states[_nextAncestorsScratch[i]]?.onEnter?.call(prev);
    }

    onStateChanged?.call(prev, nextState);
    return true;
  }

  /// Pushes [currentState] onto the history stack and transitions to
  /// [overlayState].
  void pushState(S overlayState) {
    if (!_started) {
      start();
    }
    _historyStack.add(_current);
    transitionTo(overlayState, allowSelfTransition: true);
  }

  /// Pops and transitions back to the most recently pushed state, returning
  /// `true` if the stack was non-empty.
  bool popState() {
    if (_historyStack.isEmpty) {
      return false;
    }
    final restored = _historyStack.removeLast();
    transitionTo(restored, allowSelfTransition: true);
    return true;
  }

  /// Dispatches [event] against matching transition rules (preferring exact
  /// state/ancestor rules before `from == null` wildcard rules).
  bool dispatch(E event) {
    if (!_started) {
      start();
    }
    // 1. Specific state or active ancestor match.
    for (var i = 0; i < _rules.length; i++) {
      final rule = _rules[i];
      final fromState = rule.from;
      if (fromState != null &&
          rule.event == event &&
          isInState(fromState) &&
          (rule.guard?.call() ?? true)) {
        return transitionTo(rule.to);
      }
    }
    // 2. Wildcard (any-state) match.
    for (var i = 0; i < _rules.length; i++) {
      final rule = _rules[i];
      if (rule.from == null &&
          rule.event == event &&
          (rule.guard?.call() ?? true)) {
        return transitionTo(rule.to);
      }
    }
    return false;
  }

  /// Advances `stateElapsed` and invokes `onUpdate` from active root ancestor
  /// down to [currentState] (re-entrancy safe if an `onUpdate` hook calls
  /// [transitionTo], [dispatch], [pushState], or [popState]).
  void update(double dt) {
    if (!_started) {
      start();
    }
    _stateElapsed += dt;
    final stateAtTickStart = _current;
    final elapsedSnap = _stateElapsed;
    _collectAncestors(stateAtTickStart, _updateAncestorsScratch);
    for (var i = _updateAncestorsScratch.length - 1; i >= 0; i--) {
      if (_current != stateAtTickStart) {
        break;
      }
      _states[_updateAncestorsScratch[i]]?.onUpdate?.call(dt, elapsedSnap);
    }
  }

  /// Deepest parent chain that is followed, which also bounds the walk over
  /// a parent chain that (by mistake) forms a cycle.
  static const int _maxDepth = 32;

  void _collectAncestors(S leaf, List<S> out) {
    out.clear();
    S? cursor = leaf;
    var guard = 0;
    while (cursor != null && guard < _maxDepth) {
      out.add(cursor);
      cursor = _states[cursor]?.parent;
      guard++;
    }
  }
}

/// Component wrapper ticking a [StateMachine] automatically during the Flame
/// component update loop.
class StateMachineComponent<S, E>({
  required final StateMachine<S, E> machine,
  super.priority,
  super.key,
}) extends Component {
  @override
  void onMount() {
    super.onMount();
    machine.start();
  }

  @override
  void update(double dt) {
    machine.update(dt);
  }
}
