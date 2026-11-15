import 'dart:math' as math;

import 'package:flame/src/rpg/world_state_blackboard.dart';
import 'package:meta/meta.dart';

/// RPG Maker-style activation trigger for an `EventPage`.
enum EventTriggerMode() {
  /// Triggered when the player presses Confirm facing this entity (including
  /// `1` tile further across a `counter` desk tile).
  actionButton,

  /// Triggered when the player steps into or bumps against this entity.
  playerTouch,

  /// Triggered when either the player OR this entity's move route touches the
  /// other.
  eventTouch,

  /// Starts automatically as soon as its `EventPage` becomes active and holds
  /// an exclusive modal cutscene lock until its script finishes or switches
  /// pages.
  autorun,

  /// Runs continuously in the background every frame while its `EventPage` is
  /// active without locking player input.
  parallel,
}

/// Comparison operator for [EventVariableCondition] and script predicates.
enum EventComparisonOp() {
  equals,
  notEquals,
  greaterOrEqual,
  greaterThan,
  lessOrEqual,
  lessThan;

  bool evaluate(num lhs, num rhs) => switch (this) {
    EventComparisonOp.equals => lhs == rhs,
    EventComparisonOp.notEquals => lhs != rhs,
    EventComparisonOp.greaterOrEqual => lhs >= rhs,
    EventComparisonOp.greaterThan => lhs > rhs,
    EventComparisonOp.lessOrEqual => lhs <= rhs,
    EventComparisonOp.lessThan => lhs < rhs,
  };
}

/// Variable threshold clause inside an [EventPageCondition] or branch guard.
class const EventVariableCondition(
  this.variableId,
  this.op,
  this.threshold,
) {
  final int variableId;
  final EventComparisonOp op;
  final num threshold;

  bool matches(WorldStateBlackboard blackboard) =>
      op.evaluate(blackboard.getDouble(variableId), threshold);
}

/// Declarative activation guard for an `EventPage` or `branchIf` instruction.
class EventPageCondition({
  this.requiredSwitches = const <int, bool>{},
  this.variableConditions = const <EventVariableCondition>[],
  this.requiredSelfSwitches = const <String, bool>{},
  this.customPredicate,
}) {
  /// Switch ID -> expected boolean state (`true` or `false`).
  final Map<int, bool> requiredSwitches;

  /// Numeric variable comparisons (`all` must hold).
  final List<EventVariableCondition> variableConditions;

  /// Self-switch channel (`'A'..'D'`) -> expected boolean state for the owning
  /// `(mapId, eventId)`.
  final Map<String, bool> requiredSelfSwitches;

  /// Optional host callback (e.g. checking party leader or key item).
  final bool Function(WorldStateBlackboard blackboard)? customPredicate;

  bool isSatisfied(
    WorldStateBlackboard blackboard, {
    required String mapId,
    required String eventId,
  }) {
    for (final entry in requiredSwitches.entries) {
      if (blackboard.getSwitch(entry.key) != entry.value) {
        return false;
      }
    }
    for (var i = 0; i < variableConditions.length; i++) {
      if (!variableConditions[i].matches(blackboard)) {
        return false;
      }
    }
    for (final entry in requiredSelfSwitches.entries) {
      if (blackboard.getSelfSwitch(mapId, eventId, entry.key) != entry.value) {
        return false;
      }
    }
    if (customPredicate != null && !customPredicate!(blackboard)) {
      return false;
    }
    return true;
  }
}

@internal
enum EventOpKind() {
  setSwitch,
  setVar,
  addVar,
  setSelfSwitch,
  waitSeconds,
  yieldTick,
  showDialogue,
  promptChoice,
  awaitSignal,
  jumpIfFalse,
  jump,
  callCommon,
  emitAction,
}

@internal
class EventInstruction({
  required this.kind,
  this.intArg = 0,
  this.boolArg = false,
  this.numArg = 0.0,
  this.strArg = '',
  this.choices = const <String>[],
  this.condition,
  this.payload = const <String, Object?>{},
}) {
  final EventOpKind kind;
  int intArg;
  final bool boolArg;
  final double numArg;
  final String strArg;
  final List<String> choices;
  final EventPageCondition? condition;
  final Map<String, Object?> payload;
}

/// Immutable compiled command script executed by `EventFiber`.
class EventScript._(this.id, this._ops) {
  final String id;
  final List<EventInstruction> _ops;

  int get instructionCount => _ops.length;

  @internal
  List<EventInstruction> get ops => _ops;
}

class _IfPatch(this.jumpIfFalseIdx) {
  final int jumpIfFalseIdx;
  int? jumpOverElseIdx;
}

class _LoopPatch(this.loopStartIdx) {
  final int loopStartIdx;
  final List<int> breakJumpIndices = <int>[];
}

/// Fluent builder that compiles structured RPG Maker commands (`branchIf` /
/// `elseBranch` / `endBranch`, `beginLoop` / `breakLoop` / `endLoop`,
/// `showDialogue`, `promptChoice`, `waitSeconds`, `callCommonEvent`, etc.) into
/// a flat jump-resolved [EventScript], rejecting malformed control-flow blocks
/// at build time.
class EventScriptBuilder(this.id) {
  final String id;
  final List<EventInstruction> _ops = <EventInstruction>[];
  final List<_IfPatch> _ifStack = <_IfPatch>[];
  final List<_LoopPatch> _loopStack = <_LoopPatch>[];

  void setSwitch(int switchId, {required bool value}) {
    _ops.add(
      EventInstruction(
        kind: EventOpKind.setSwitch,
        intArg: switchId,
        boolArg: value,
      ),
    );
  }

  void setVariable(int varId, Object value) {
    if (value is num) {
      _ops.add(
        EventInstruction(
          kind: EventOpKind.setVar,
          intArg: varId,
          numArg: value.toDouble(),
          boolArg: value is int,
        ),
      );
    } else {
      _ops.add(
        EventInstruction(
          kind: EventOpKind.setVar,
          intArg: varId,
          strArg: value.toString(),
          payload: const <String, Object?>{'isString': true},
        ),
      );
    }
  }

  void addVariable(int varId, int delta) {
    _ops.add(
      EventInstruction(
        kind: EventOpKind.addVar,
        intArg: varId,
        numArg: delta.toDouble(),
      ),
    );
  }

  void setSelfSwitch(String channel, {required bool value}) {
    _ops.add(
      EventInstruction(
        kind: EventOpKind.setSelfSwitch,
        strArg: channel,
        boolArg: value,
      ),
    );
  }

  void waitSeconds(double seconds) {
    _ops.add(
      EventInstruction(
        kind: EventOpKind.waitSeconds,
        numArg: math.max(0.0, seconds),
      ),
    );
  }

  /// Yields execution until the next tick without imposing a wall-clock delay.
  void yieldTick() {
    _ops.add(EventInstruction(kind: EventOpKind.yieldTick));
  }

  /// Suspends the fiber until the host UI completes displaying [text] (via
  /// `EventFiber.completeDialogue`).
  void showDialogue(
    String text, {
    String speaker = '',
    String portraitId = '',
  }) {
    _ops.add(
      EventInstruction(
        kind: EventOpKind.showDialogue,
        strArg: text,
        payload: <String, Object?>{
          'speaker': speaker,
          'portraitId': portraitId,
        },
      ),
    );
  }

  /// Suspends the fiber until the player selects one of [choices] (via
  /// `EventFiber.submitChoice`), optionally storing the 0-based selected index
  /// into [storeInVariableId].
  void promptChoice(
    List<String> choices, {
    int storeInVariableId = -1,
  }) {
    if (choices.isEmpty) {
      throw ArgumentError.value(choices, 'choices', 'Must not be empty');
    }
    _ops.add(
      EventInstruction(
        kind: EventOpKind.promptChoice,
        intArg: storeInVariableId,
        choices: List<String>.unmodifiable(choices),
      ),
    );
  }

  /// Suspends the fiber until `EventFiber.resolveSignal` is called with
  /// [signalId] (e.g. waiting for an NPC `MoveRoute` or chest animation to
  /// finish!).
  void awaitSignal(String signalId) {
    _ops.add(EventInstruction(kind: EventOpKind.awaitSignal, strArg: signalId));
  }

  /// Invokes registered Common Event [commonEventId], pushing a return frame on
  /// the fiber's call stack.
  void callCommonEvent(String commonEventId) {
    _ops.add(
      EventInstruction(kind: EventOpKind.callCommon, strArg: commonEventId),
    );
  }

  /// Emits custom host command [actionName] with [params] synchronously.
  void emitAction(
    String actionName, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    _ops.add(
      EventInstruction(
        kind: EventOpKind.emitAction,
        strArg: actionName,
        payload: Map<String, Object?>.unmodifiable(params),
      ),
    );
  }

  void branchIf(EventPageCondition condition) {
    final idx = _ops.length;
    _ops.add(
      EventInstruction(
        kind: EventOpKind.jumpIfFalse,
        condition: condition,
        intArg: -1,
      ),
    );
    _ifStack.add(_IfPatch(idx));
  }

  /// Convenience branch testing whether `lastChoiceIndex == choiceIndex`.
  void branchIfChoiceEquals(int choiceIndex, {required int choiceVariableId}) {
    branchIf(
      EventPageCondition(
        variableConditions: <EventVariableCondition>[
          EventVariableCondition(
            choiceVariableId,
            EventComparisonOp.equals,
            choiceIndex,
          ),
        ],
      ),
    );
  }

  void elseBranch() {
    if (_ifStack.isEmpty) {
      throw StateError('elseBranch() without matching branchIf()');
    }
    final top = _ifStack.last;
    if (top.jumpOverElseIdx != null) {
      throw StateError('Duplicate elseBranch() in the same branchIf() block');
    }
    final jumpOverIdx = _ops.length;
    _ops.add(EventInstruction(kind: EventOpKind.jump, intArg: -1));
    top.jumpOverElseIdx = jumpOverIdx;
    _ops[top.jumpIfFalseIdx].intArg = _ops.length;
  }

  void endBranch() {
    if (_ifStack.isEmpty) {
      throw StateError('endBranch() without matching branchIf()');
    }
    final top = _ifStack.removeLast();
    if (top.jumpOverElseIdx != null) {
      _ops[top.jumpOverElseIdx!].intArg = _ops.length;
    } else {
      _ops[top.jumpIfFalseIdx].intArg = _ops.length;
    }
  }

  void beginLoop() {
    _loopStack.add(_LoopPatch(_ops.length));
  }

  void breakLoop() {
    if (_loopStack.isEmpty) {
      throw StateError('breakLoop() outside beginLoop()');
    }
    final idx = _ops.length;
    _ops.add(EventInstruction(kind: EventOpKind.jump, intArg: -1));
    _loopStack.last.breakJumpIndices.add(idx);
  }

  void endLoop() {
    if (_loopStack.isEmpty) {
      throw StateError('endLoop() without matching beginLoop()');
    }
    final loop = _loopStack.removeLast();
    _ops.add(
      EventInstruction(kind: EventOpKind.jump, intArg: loop.loopStartIdx),
    );
    final exitIdx = _ops.length;
    for (final brk in loop.breakJumpIndices) {
      _ops[brk].intArg = exitIdx;
    }
  }

  EventScript build() {
    if (_ifStack.isNotEmpty) {
      throw StateError(
        'Unclosed branchIf() block in EventScript "$id" '
        '(${_ifStack.length} open)',
      );
    }
    if (_loopStack.isNotEmpty) {
      throw StateError(
        'Unclosed beginLoop() block in EventScript "$id" '
        '(${_loopStack.length} open)',
      );
    }
    return EventScript._(id, List<EventInstruction>.unmodifiable(_ops));
  }
}
