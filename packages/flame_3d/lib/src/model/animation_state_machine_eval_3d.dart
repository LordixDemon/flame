part of 'animation_state_machine_3d.dart';

extension _AnimationStateMachineEval on AnimationStateMachine3D {
  double _currentMonotonicNormalizedTime(AnimationState target) {
    final leaf = _activeLeaf;
    if (leaf is ClipAnimState3D &&
        leaf.playMode == AnimationPlayMode.once &&
        target.isCompleted) {
      return 1.0;
    }
    final dur = switch (leaf) {
      ClipAnimState3D(:final animation) => animation.lastTime,
      _ => 1.0,
    };
    if (dur <= 1e-9 && leaf is ClipAnimState3D) {
      return _stateElapsed > 0.0 ? 1.0 : 0.0;
    }
    return _leafLoopCount + target.currentNormalizedPhase;
  }

  ({AnimTransition3D transition, SubStateMachine3D? scope})?
  _findFiringTransition(AnimationState target) {
    final normProgress = _currentMonotonicNormalizedTime(target);

    // 1. Check `'any'` transitions from root down through active sub-SMs.
    for (var i = 0; i < _rootTransitions.length; i++) {
      final t = _rootTransitions[i];
      if (t.fromState == AnimTransition3D.anyState &&
          _canFire(t, null, normProgress)) {
        return (transition: t, scope: null);
      }
    }
    for (var s = 0; s < _activeSubStack.length; s++) {
      final sub = _activeSubStack[s];
      for (var i = 0; i < sub.transitions.length; i++) {
        final t = sub.transitions[i];
        if (t.fromState == AnimTransition3D.anyState &&
            _canFire(t, sub, normProgress)) {
          return (transition: t, scope: sub);
        }
      }
    }

    // 2. Check specific transitions from innermost sub-state machine outward
    // so child transitions work while parent sub-machine exits also fire.
    for (var s = _activeSubStack.length - 1; s >= 0; s--) {
      final sub = _activeSubStack[s];
      final activeAtDepth = _activePath[s + 1];
      for (var i = 0; i < sub.transitions.length; i++) {
        final t = sub.transitions[i];
        if (t.fromState == activeAtDepth && _canFire(t, sub, normProgress)) {
          return (transition: t, scope: sub);
        }
      }
    }

    if (_activePath.isNotEmpty) {
      final rootActive = _activePath.first;
      final leafName = _activePath.last;
      for (var i = 0; i < _rootTransitions.length; i++) {
        final t = _rootTransitions[i];
        if ((t.fromState == rootActive || t.fromState == leafName) &&
            _canFire(t, null, normProgress)) {
          return (transition: t, scope: null);
        }
      }
    }
    return null;
  }

  bool _canFire(
    AnimTransition3D t,
    SubStateMachine3D? scope,
    double normProgress,
  ) {
    final resolvedLeaf = _peekLeaf(t.toState, scope);
    if (resolvedLeaf == null) {
      return false;
    }
    if (!t.canTransitionToSelf && identical(resolvedLeaf, _activeLeaf)) {
      return false;
    }
    final reqExit = t.exitTime;
    if (reqExit != null && normProgress + 1e-7 < reqExit) {
      return false;
    }
    if (t.conditions.isEmpty && reqExit == null) {
      // Unconditional transition with no exitTime shouldn't fire automatically
      // unless explicitly configured with exitTime (e.g. `exitTime: 1.0`).
      return false;
    }
    for (var i = 0; i < t.conditions.length; i++) {
      if (!_evaluateCondition(t.conditions[i])) {
        return false;
      }
    }
    return true;
  }

  bool _evaluateCondition(AnimCondition3D cond) {
    final name = cond.parameter;
    switch (cond.operator) {
      case AnimConditionOperator3D.greater:
        return _readNumeric(name) > cond.threshold.toDouble();
      case AnimConditionOperator3D.less:
        return _readNumeric(name) < cond.threshold.toDouble();
      case AnimConditionOperator3D.equals:
        if (_ints.containsKey(name) && cond.threshold is int) {
          return _ints[name] == cond.threshold;
        }
        return (_readNumeric(name) - cond.threshold.toDouble()).abs() <= 1e-6;
      case AnimConditionOperator3D.notEquals:
        if (_ints.containsKey(name) && cond.threshold is int) {
          return _ints[name] != cond.threshold;
        }
        return (_readNumeric(name) - cond.threshold.toDouble()).abs() > 1e-6;
      case AnimConditionOperator3D.ifTrue:
        return _bools[name] ?? false;
      case AnimConditionOperator3D.ifFalse:
        return !(_bools[name] ?? false);
      case AnimConditionOperator3D.onTrigger:
        return _triggers.contains(name);
    }
  }

  double _readNumeric(String name) {
    final f = _floats[name];
    if (f != null) {
      return f;
    }
    final i = _ints[name];
    if (i != null) {
      return i.toDouble();
    }
    return 0.0;
  }

  AnimGraphState3D? _peekLeaf(String targetName, SubStateMachine3D? scope) {
    var node = scope?.statesByName[targetName] ?? _rootStates[targetName];
    if (node == null && targetName.contains('/')) {
      final parts = targetName.split('/');
      Map<String, AnimGraphState3D>? currentMap = _rootStates;
      for (var i = 0; i < parts.length; i++) {
        node = currentMap?[parts[i]];
        if (node is SubStateMachine3D && i + 1 < parts.length) {
          currentMap = node.statesByName;
        } else {
          currentMap = null;
        }
      }
    }
    var guard = 0;
    while (node is SubStateMachine3D && guard++ < 16) {
      node = node.statesByName[node.initialState];
    }
    return node;
  }

  void _enterTargetState(
    String targetName, {
    required AnimationState target,
    required double crossFadeDuration,
    required bool syncPhase,
    required bool allowSelfTransition,
    SubStateMachine3D? scope,
  }) {
    final prevLeaf = _activeLeaf;
    final outgoingPhase = prevLeaf != null
        ? target.currentNormalizedPhase
        : 0.0;

    final nextPath = <String>[];
    final nextSubStack = <SubStateMachine3D>[];

    AnimGraphState3D? current;
    if (scope != null && scope.statesByName.containsKey(targetName)) {
      // Preserve path up to and including `scope`.
      for (var i = 0; i < _activeSubStack.length; i++) {
        final s = _activeSubStack[i];
        nextPath.add(s.name);
        nextSubStack.add(s);
        if (identical(s, scope)) {
          break;
        }
      }
      current = scope.statesByName[targetName];
    } else if (targetName.contains('/')) {
      final parts = targetName.split('/');
      Map<String, AnimGraphState3D>? map = _rootStates;
      for (var i = 0; i < parts.length; i++) {
        final found = map?[parts[i]];
        if (found == null) {
          throw ArgumentError('Unknown AnimGraph state path "$targetName"');
        }
        current = found;
        if (found is SubStateMachine3D && i + 1 < parts.length) {
          nextPath.add(found.name);
          nextSubStack.add(found);
          map = found.statesByName;
        } else {
          map = null;
        }
      }
    } else {
      current = _rootStates[targetName];
    }

    if (current == null) {
      throw ArgumentError('Unknown AnimGraph state "$targetName"');
    }

    var resolved = current;
    var guard = 0;
    while (resolved is SubStateMachine3D && guard++ < 16) {
      nextPath.add(resolved.name);
      nextSubStack.add(resolved);
      final entry = resolved.statesByName[resolved.initialState];
      if (entry == null) {
        throw StateError(
          'SubStateMachine3D "${resolved.name}" missing initialState '
          '"${resolved.initialState}"',
        );
      }
      resolved = entry;
    }
    if (resolved is SubStateMachine3D) {
      throw StateError('Cyclic SubStateMachine3D hierarchy at "$targetName"');
    }

    nextPath.add(resolved.name);
    _activePath
      ..clear()
      ..addAll(nextPath);
    _activeSubStack
      ..clear()
      ..addAll(nextSubStack);
    _activeLeaf = resolved;
    _stateElapsed = 0.0;
    _leafLoopCount = 0;

    final matchingSyncGroup =
        prevLeaf != null &&
        prevLeaf.syncGroup != null &&
        prevLeaf.syncGroup == resolved.syncGroup;
    final transferPhase = (syncPhase || matchingSyncGroup) && prevLeaf != null
        ? outgoingPhase
        : null;

    _applyLeafStateToTarget(
      resolved,
      target,
      crossFadeDuration: crossFadeDuration,
      outgoingPhase: transferPhase,
      allowSelfTransition: allowSelfTransition,
    );
  }

  void _applyLeafStateToTarget(
    AnimGraphState3D leaf,
    AnimationState target, {
    required double crossFadeDuration,
    required double? outgoingPhase,
    required bool allowSelfTransition,
  }) {
    switch (leaf) {
      case ClipAnimState3D():
        target.speed = leaf.speed;
        if (crossFadeDuration > 0.0) {
          target.crossFadeTo(
            leaf.animation,
            duration: crossFadeDuration,
            mode: leaf.playMode,
            allowSelfTransition: allowSelfTransition,
          );
        } else {
          target.startAnimation(
            leaf.animation,
            mode: leaf.playMode,
          );
        }
      case Blend1DAnimState3D():
        target.speed = leaf.speed;
        final paramVal = getFloat(leaf.parameter);
        if (crossFadeDuration > 0.0) {
          target.crossFadeToBlendSpace1D(
            leaf.space,
            duration: crossFadeDuration,
            initialValue: paramVal,
            allowSelfTransition: allowSelfTransition,
          );
        } else {
          target.playBlendSpace1D(
            leaf.space,
            initialValue: paramVal,
          );
        }
      case Blend2DAnimState3D():
        target.speed = leaf.speed;
        _scratch2D.setValues(getFloat(leaf.paramX), getFloat(leaf.paramY));
        if (crossFadeDuration > 0.0) {
          target.crossFadeToBlendSpace2D(
            leaf.space,
            duration: crossFadeDuration,
            initialValue: _scratch2D,
            allowSelfTransition: allowSelfTransition,
          );
        } else {
          target.playBlendSpace2D(
            leaf.space,
            initialValue: _scratch2D,
          );
        }
      case SubStateMachine3D():
        throw StateError('SubStateMachine3D cannot be an active leaf');
    }

    if (outgoingPhase != null) {
      target.setNormalizedPhase(outgoingPhase);
    }
  }

  void _syncContinuousLeafParams(AnimGraphState3D leaf, AnimationState target) {
    switch (leaf) {
      case ClipAnimState3D():
        target.speed = leaf.speed;
      case Blend1DAnimState3D():
        target
          ..speed = leaf.speed
          ..blendParameter1D = getFloat(leaf.parameter);
      case Blend2DAnimState3D():
        target.speed = leaf.speed;
        target.blendParameter2D.setValues(
          getFloat(leaf.paramX),
          getFloat(leaf.paramY),
        );
      case SubStateMachine3D():
        break;
    }
  }
}
