import 'package:flame_3d/core.dart';
import 'package:flame_3d/src/model/animation_state.dart';
import 'package:flame_3d/src/model/blend_space_3d.dart';
import 'package:flame_3d/src/model/model_animation.dart';

part 'animation_state_machine_eval_3d.dart';

/// Comparison / predicate operator for an [AnimCondition3D] on an
/// [AnimationStateMachine3D] parameter blackboard.
enum AnimConditionOperator3D() {
  /// Numeric parameter strictly greater than threshold (`param > threshold`).
  greater,

  /// Numeric parameter strictly less than threshold (`param < threshold`).
  less,

  /// Numeric parameter equal to target value (`|param - value| <= 1e-6`).
  equals,

  /// Numeric parameter not equal to target value (`|param - value| > 1e-6`).
  notEquals,

  /// Boolean parameter is `true`.
  ifTrue,

  /// Boolean parameter is `false`.
  ifFalse,

  /// One-shot trigger parameter is set (auto-consumed when transition fires).
  onTrigger,
}

/// A single predicate guarding an [AnimTransition3D].
class const AnimCondition3D({
  required final String parameter,
  required final AnimConditionOperator3D operator,
  final num threshold = 0,
}) {
  /// Fires when float/int [parameter] is strictly greater than [value].
  const AnimCondition3D.greater(String parameter, num value)
    : this(
        parameter: parameter,
        operator: AnimConditionOperator3D.greater,
        threshold: value,
      );

  /// Fires when float/int [parameter] is strictly less than [value].
  const AnimCondition3D.less(String parameter, num value)
    : this(
        parameter: parameter,
        operator: AnimConditionOperator3D.less,
        threshold: value,
      );

  /// Fires when float/int [parameter] equals [value].
  const AnimCondition3D.equals(String parameter, num value)
    : this(
        parameter: parameter,
        operator: AnimConditionOperator3D.equals,
        threshold: value,
      );

  /// Fires when float/int [parameter] does not equal [value].
  const AnimCondition3D.notEquals(String parameter, num value)
    : this(
        parameter: parameter,
        operator: AnimConditionOperator3D.notEquals,
        threshold: value,
      );

  /// Fires when boolean [parameter] is `true`.
  const AnimCondition3D.ifTrue(String parameter)
    : this(
        parameter: parameter,
        operator: AnimConditionOperator3D.ifTrue,
      );

  /// Fires when boolean [parameter] is `false`.
  const AnimCondition3D.ifFalse(String parameter)
    : this(
        parameter: parameter,
        operator: AnimConditionOperator3D.ifFalse,
      );

  /// Fires when trigger [parameter] is active, consuming it on transition.
  const AnimCondition3D.onTrigger(String parameter)
    : this(
        parameter: parameter,
        operator: AnimConditionOperator3D.onTrigger,
      );
}

/// Base node inside an [AnimationStateMachine3D] or [SubStateMachine3D].
sealed class AnimGraphState3D({
  required final String name,
  final String? syncGroup,
});

/// Single-clip state inside an [AnimationStateMachine3D].
class ClipAnimState3D({
  required super.name,
  required final ModelAnimation animation,
  var double speed = 1.0,
  var AnimationPlayMode playMode = AnimationPlayMode.loop,
  super.syncGroup,
}) extends AnimGraphState3D;

/// 1D locomotion/pose [BlendSpace1D] state driven by float [parameter].
class Blend1DAnimState3D({
  required super.name,
  required final BlendSpace1D space,
  required final String parameter,
  var double speed = 1.0,
  super.syncGroup,
}) extends AnimGraphState3D;

/// 2D directional [BlendSpace2D] state driven by float parameters
/// `([paramX], [paramY])`.
class Blend2DAnimState3D({
  required super.name,
  required final BlendSpace2D space,
  required final String paramX,
  required final String paramY,
  var double speed = 1.0,
  super.syncGroup,
}) extends AnimGraphState3D;

/// Nested hierarchical state machine state with its own child `states`,
/// [initialState], and internal [transitions].
class SubStateMachine3D({
  required super.name,
  required List<AnimGraphState3D> states,
  required final String initialState,
  List<AnimTransition3D> transitions = const [],
}) extends AnimGraphState3D {
  /// Child states indexed by [AnimGraphState3D.name].
  final Map<String, AnimGraphState3D> statesByName = _indexStates(states);

  /// Ordered transitions local to this sub-state machine.
  final List<AnimTransition3D> transitions =
      List<AnimTransition3D>.unmodifiable(
        transitions,
      );

  static Map<String, AnimGraphState3D> _indexStates(
    List<AnimGraphState3D> raw,
  ) {
    if (raw.isEmpty) {
      throw ArgumentError.value(raw, 'states', 'Must contain >= 1 state');
    }
    final map = <String, AnimGraphState3D>{};
    for (final s in raw) {
      map[s.name] = s;
    }
    return Map<String, AnimGraphState3D>.unmodifiable(map);
  }
}

/// Directed transition edge inside an [AnimationStateMachine3D] or
/// [SubStateMachine3D].
///
/// Set [fromState] to [anyState] (`'any'`) for global interrupt transitions
/// (such as hit-reactions, dodge, or death).
class AnimTransition3D({
  required final String fromState,
  required final String toState,
  List<AnimCondition3D> conditions = const [],
  final double? exitTime,
  final double crossFadeDuration = 0.2,
  final bool canTransitionToSelf = false,
  final bool syncNormalizedPhase = false,
}) {
  /// Wildcard source state name matching any active state.
  static const String anyState = 'any';

  /// Guard predicates that must all hold for this transition to fire.
  final List<AnimCondition3D> conditions = List<AnimCondition3D>.unmodifiable(
    conditions,
  );
}

/// Declarative Hierarchical Finite State Machine (AnimGraph) driving an
/// [AnimationState] or `ModelComponent` via a typed parameter blackboard,
/// 1D/2D blend spaces, nested [SubStateMachine3D]s, `exitTime` guards,
/// auto-consumed triggers, and gait phase transfer.
class AnimationStateMachine3D({
  required List<AnimGraphState3D> states,
  required final String initialState,
  List<AnimTransition3D> transitions = const [],
  AnimationState? animationState,
}) {
  this {
    if (animationState != null) {
      bind(animationState);
    }
  }

  final Map<String, AnimGraphState3D> _rootStates =
      SubStateMachine3D._indexStates(states);
  final List<AnimTransition3D> _rootTransitions =
      List<AnimTransition3D>.unmodifiable(transitions);

  final Map<String, double> _floats = {};
  final Map<String, int> _ints = {};
  final Map<String, bool> _bools = {};
  final Set<String> _triggers = {};

  AnimationState? _boundState;
  final List<String> _activePath = [];
  final List<SubStateMachine3D> _activeSubStack = [];
  AnimGraphState3D? _activeLeaf;

  double _stateElapsed = 0.0;
  int _leafLoopCount = 0;
  int _transitionCount = 0;
  bool _dirtyParams = false;
  final Vector2 _scratch2D = Vector2.zero();

  /// Currently bound [AnimationState], if any.
  AnimationState? get boundAnimationState => _boundState;

  /// Name of the currently active leaf state (`ClipAnimState3D`,
  /// `Blend1DAnimState3D`, or `Blend2DAnimState3D`).
  String get currentStateName => _activeLeaf?.name ?? initialState;

  /// Full hierarchical path from the root state down to [currentStateName]
  /// (for example `['combat', 'combo_1']`).
  List<String> get activeStatePath => List<String>.unmodifiable(_activePath);

  /// Elapsed time in seconds spent in the current leaf state.
  double get stateElapsed => _stateElapsed;

  /// Total number of state transitions executed since creation.
  int get transitionCount => _transitionCount;

  // ---------------------------------------------------------------------------
  // Typed Blackboard Parameters
  // ---------------------------------------------------------------------------

  /// Sets floating-point parameter [name] to [value].
  void setFloat(String name, double value) {
    if (_floats[name] != value) {
      _floats[name] = value;
      _dirtyParams = true;
    }
  }

  /// Reads floating-point parameter [name] (or [defaultValue] if unset).
  double getFloat(String name, {double defaultValue = 0.0}) =>
      _floats[name] ?? defaultValue;

  /// Sets integer parameter [name] to [value].
  void setInt(String name, int value) {
    if (_ints[name] != value) {
      _ints[name] = value;
      _dirtyParams = true;
    }
  }

  /// Reads integer parameter [name] (or [defaultValue] if unset).
  int getInt(String name, {int defaultValue = 0}) =>
      _ints[name] ?? defaultValue;

  /// Sets boolean parameter [name] to [value].
  // ignore: avoid_positional_boolean_parameters
  void setBool(String name, bool value) {
    if (_bools[name] != value) {
      _bools[name] = value;
      _dirtyParams = true;
    }
  }

  /// Reads boolean parameter [name] (or [defaultValue] if unset).
  bool getBool(String name, {bool defaultValue = false}) =>
      _bools[name] ?? defaultValue;

  /// Arms one-shot trigger [name]; automatically consumed when a transition
  /// guarded by `AnimCondition3D.onTrigger(name)` fires.
  void setTrigger(String name) {
    if (_triggers.add(name)) {
      _dirtyParams = true;
    }
  }

  /// Clears one-shot trigger [name] without firing a transition.
  void resetTrigger(String name) {
    _triggers.remove(name);
  }

  /// Whether one-shot trigger [name] is currently armed.
  bool isTriggerSet(String name) => _triggers.contains(name);

  // ---------------------------------------------------------------------------
  // Lifecycle & Evaluation
  // ---------------------------------------------------------------------------

  /// Binds this state machine to [target] and enters [initialState]
  /// immediately if not yet initialized.
  void bind(AnimationState target) {
    _boundState = target;
    if (_activeLeaf == null) {
      _enterTargetState(
        initialState,
        target: target,
        crossFadeDuration: 0.0,
        syncPhase: false,
        allowSelfTransition: false,
      );
    } else {
      _applyLeafStateToTarget(
        _activeLeaf!,
        target,
        crossFadeDuration: 0.0,
        outgoingPhase: null,
        allowSelfTransition: false,
      );
    }
  }

  /// Imperatively transitions to [stateName] over [crossFadeDuration] seconds.
  void forceState(
    String stateName, {
    double crossFadeDuration = 0.0,
    bool syncNormalizedPhase = false,
  }) {
    final target = _boundState;
    if (target == null) {
      return;
    }
    _enterTargetState(
      stateName,
      target: target,
      crossFadeDuration: crossFadeDuration,
      syncPhase: syncNormalizedPhase,
      allowSelfTransition: true,
    );
    _transitionCount++;
  }

  /// Advances the active state, evaluates hierarchical transitions, and drives
  /// [targetState] (defaults to [boundAnimationState]), returning `true` when
  /// the resulting animation pose changed.
  bool update(double dt, {AnimationState? targetState}) {
    final target = targetState ?? _boundState;
    if (target == null) {
      throw StateError(
        'AnimationStateMachine3D.update requires a bound AnimationState',
      );
    }
    _boundState ??= target;
    if (_activeLeaf == null) {
      _enterTargetState(
        initialState,
        target: target,
        crossFadeDuration: 0.0,
        syncPhase: false,
        allowSelfTransition: false,
      );
      _dirtyParams = false;
    }

    var changed = _dirtyParams;
    _dirtyParams = false;

    // 1. Sync continuous parameters (speed, 1D/2D blend coordinates) before
    // advancing clocks.
    _syncContinuousLeafParams(_activeLeaf!, target);

    // 2. Advance underlying AnimationState clock by `dt`.
    if (dt > 0.0) {
      _stateElapsed += dt;
      if (target.update(dt)) {
        changed = true;
      }
      if (target.lastLoopWrapCount > 0) {
        _leafLoopCount += target.lastLoopWrapCount;
      }
    } else if (target.consumeParameterChanges()) {
      changed = true;
    }

    // 3. Evaluate transitions (up to a small chain cap to avoid infinite loops
    // while supporting immediate 0-exitTime cascades).
    var guard = 0;
    while (guard++ < 8) {
      final match = _findFiringTransition(target);
      if (match == null) {
        break;
      }
      final (:transition, :scope) = match;
      for (var i = 0; i < transition.conditions.length; i++) {
        final cond = transition.conditions[i];
        if (cond.operator == AnimConditionOperator3D.onTrigger) {
          _triggers.remove(cond.parameter);
        }
      }
      _enterTargetState(
        transition.toState,
        scope: scope,
        target: target,
        crossFadeDuration: transition.crossFadeDuration,
        syncPhase: transition.syncNormalizedPhase,
        allowSelfTransition: transition.canTransitionToSelf,
      );
      _transitionCount++;
      changed = true;
      // Only chain multiple transitions in the same tick if the newly entered
      // state has no exitTime requirement and another condition is already met;
      // break if the transition consumed a trigger or used exitTime to avoid
      // runaway self-loops.
      if (transition.canTransitionToSelf || transition.exitTime != null) {
        break;
      }
    }

    _syncContinuousLeafParams(_activeLeaf!, target);
    if (target.consumeParameterChanges()) {
      changed = true;
    }
    return changed;
  }
}
