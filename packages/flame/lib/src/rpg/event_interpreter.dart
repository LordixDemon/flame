import 'dart:math' as math;

import 'package:flame/components.dart';
import 'package:flame/src/rpg/world_state_blackboard.dart';

/// RPG Maker-style activation trigger for an [EventPage].
enum EventTriggerMode() {
  /// Triggered when the player presses Confirm facing this entity (including
  /// `1` tile further across a `counter` desk tile).
  actionButton,

  /// Triggered when the player steps into or bumps against this entity.
  playerTouch,

  /// Triggered when either the player OR this entity's move route touches the
  /// other.
  eventTouch,

  /// Starts automatically as soon as its [EventPage] becomes active and holds
  /// an exclusive modal cutscene lock until its script finishes or switches
  /// pages.
  autorun,

  /// Runs continuously in the background every frame while its [EventPage] is
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

/// Declarative activation guard for an [EventPage] or `branchIf` instruction.
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

enum _OpKind() {
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

class _EventInstruction({
  required this.kind,
  this.intArg = 0,
  this.boolArg = false,
  this.numArg = 0.0,
  this.strArg = '',
  this.choices = const <String>[],
  this.condition,
  this.payload = const <String, Object?>{},
}) {
  final _OpKind kind;
  int intArg;
  final bool boolArg;
  final double numArg;
  final String strArg;
  final List<String> choices;
  final EventPageCondition? condition;
  final Map<String, Object?> payload;
}

/// Immutable compiled command script executed by [EventFiber].
class EventScript._(this.id, this._ops) {
  final String id;
  final List<_EventInstruction> _ops;

  int get instructionCount => _ops.length;
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
  final List<_EventInstruction> _ops = <_EventInstruction>[];
  final List<_IfPatch> _ifStack = <_IfPatch>[];
  final List<_LoopPatch> _loopStack = <_LoopPatch>[];

  void setSwitch(int switchId, {required bool value}) {
    _ops.add(
      _EventInstruction(
        kind: _OpKind.setSwitch,
        intArg: switchId,
        boolArg: value,
      ),
    );
  }

  void setVariable(int varId, Object value) {
    if (value is num) {
      _ops.add(
        _EventInstruction(
          kind: _OpKind.setVar,
          intArg: varId,
          numArg: value.toDouble(),
          boolArg: value is int,
        ),
      );
    } else {
      _ops.add(
        _EventInstruction(
          kind: _OpKind.setVar,
          intArg: varId,
          strArg: value.toString(),
          payload: const <String, Object?>{'isString': true},
        ),
      );
    }
  }

  void addVariable(int varId, int delta) {
    _ops.add(
      _EventInstruction(
        kind: _OpKind.addVar,
        intArg: varId,
        numArg: delta.toDouble(),
      ),
    );
  }

  void setSelfSwitch(String channel, {required bool value}) {
    _ops.add(
      _EventInstruction(
        kind: _OpKind.setSelfSwitch,
        strArg: channel,
        boolArg: value,
      ),
    );
  }

  void waitSeconds(double seconds) {
    _ops.add(
      _EventInstruction(
        kind: _OpKind.waitSeconds,
        numArg: math.max(0.0, seconds),
      ),
    );
  }

  /// Yields execution until the next tick without imposing a wall-clock delay.
  void yieldTick() {
    _ops.add(_EventInstruction(kind: _OpKind.yieldTick));
  }

  /// Suspends the fiber until the host UI completes displaying [text] (via
  /// [EventFiber.completeDialogue]).
  void showDialogue(
    String text, {
    String speaker = '',
    String portraitId = '',
  }) {
    _ops.add(
      _EventInstruction(
        kind: _OpKind.showDialogue,
        strArg: text,
        payload: <String, Object?>{
          'speaker': speaker,
          'portraitId': portraitId,
        },
      ),
    );
  }

  /// Suspends the fiber until the player selects one of [choices] (via
  /// [EventFiber.submitChoice]), optionally storing the 0-based selected index
  /// into [storeInVariableId].
  void promptChoice(
    List<String> choices, {
    int storeInVariableId = -1,
  }) {
    if (choices.isEmpty) {
      throw ArgumentError.value(choices, 'choices', 'Must not be empty');
    }
    _ops.add(
      _EventInstruction(
        kind: _OpKind.promptChoice,
        intArg: storeInVariableId,
        choices: List<String>.unmodifiable(choices),
      ),
    );
  }

  /// Suspends the fiber until [EventFiber.resolveSignal] is called with
  /// [signalId] (e.g. waiting for an NPC `MoveRoute` or chest animation to
  /// finish!).
  void awaitSignal(String signalId) {
    _ops.add(_EventInstruction(kind: _OpKind.awaitSignal, strArg: signalId));
  }

  /// Invokes registered Common Event [commonEventId], pushing a return frame on
  /// the fiber's call stack.
  void callCommonEvent(String commonEventId) {
    _ops.add(
      _EventInstruction(kind: _OpKind.callCommon, strArg: commonEventId),
    );
  }

  /// Emits custom host command [actionName] with [params] synchronously.
  void emitAction(
    String actionName, [
    Map<String, Object?> params = const <String, Object?>{},
  ]) {
    _ops.add(
      _EventInstruction(
        kind: _OpKind.emitAction,
        strArg: actionName,
        payload: Map<String, Object?>.unmodifiable(params),
      ),
    );
  }

  // --- Structured Branching ---

  void branchIf(EventPageCondition condition) {
    final idx = _ops.length;
    _ops.add(
      _EventInstruction(
        kind: _OpKind.jumpIfFalse,
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
    _ops.add(_EventInstruction(kind: _OpKind.jump, intArg: -1));
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

  // --- Structured Loops ---

  void beginLoop() {
    _loopStack.add(_LoopPatch(_ops.length));
  }

  void breakLoop() {
    if (_loopStack.isEmpty) {
      throw StateError('breakLoop() outside beginLoop()');
    }
    final idx = _ops.length;
    _ops.add(_EventInstruction(kind: _OpKind.jump, intArg: -1));
    _loopStack.last.breakJumpIndices.add(idx);
  }

  void endLoop() {
    if (_loopStack.isEmpty) {
      throw StateError('endLoop() without matching beginLoop()');
    }
    final loop = _loopStack.removeLast();
    _ops.add(_EventInstruction(kind: _OpKind.jump, intArg: loop.loopStartIdx));
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
    return EventScript._(id, List<_EventInstruction>.unmodifiable(_ops));
  }
}

/// Suspension reason of an active [EventFiber].
enum EventFiberWaitKind() {
  none,
  timer,
  dialogue,
  choice,
  signal,
  finished,
}

class _CallFrame(this.script, this.ip) {
  final EventScript script;
  int ip;
}

/// Pending dialogue request surfaced by [EventFiber].
class const PendingEventDialogue({
  required this.text,
  required this.speaker,
  required this.portraitId,
}) {
  final String text;
  final String speaker;
  final String portraitId;
}

/// Resumable, snapshot-serializable RPG event coroutine fiber with nested
/// `CommonEvent` call stack, indeterminate async suspension (`dialogue`,
/// `choice`, `signal`, `timer`), and per-tick instruction budget protection
/// against accidental infinite loops.
class EventFiber({
  required this.blackboard,
  required EventScript rootScript,
  this.mapId = 'default_map',
  this.eventId = 'event_0',
  this.commonEvents = const <String, EventScript>{},
  this.onEmitAction,
  this.maxInstructionsPerTick = 4096,
  this.maxCallStackDepth = 32,
}) {
  this {
    _stack.add(_CallFrame(rootScript, 0));
  }

  final WorldStateBlackboard blackboard;
  final String mapId;
  final String eventId;
  final Map<String, EventScript> commonEvents;
  final void Function(String actionName, Map<String, Object?> params)?
  onEmitAction;
  final int maxInstructionsPerTick;
  final int maxCallStackDepth;

  final List<_CallFrame> _stack = <_CallFrame>[];

  EventFiberWaitKind _waitKind = EventFiberWaitKind.none;
  double _waitRemaining = 0.0;
  PendingEventDialogue? _pendingDialogue;
  List<String>? _pendingChoices;
  int _choiceTargetVarId = -1;
  int _lastChoiceIndex = 0;
  String? _awaitedSignalId;
  bool _hitBudgetThisTick = false;

  EventFiberWaitKind get waitKind => _waitKind;
  bool get isFinished => _waitKind == EventFiberWaitKind.finished;
  PendingEventDialogue? get pendingDialogue => _pendingDialogue;
  List<String>? get pendingChoices => _pendingChoices;
  String? get awaitedSignalId => _awaitedSignalId;
  int get lastChoiceIndex => _lastChoiceIndex;
  int get callStackDepth => _stack.length;

  /// `true` if the most recent [tick] halted early because a script loop ran
  /// [maxInstructionsPerTick] steps without yielding or waiting.
  bool get hitInstructionBudgetThisTick => _hitBudgetThisTick;

  /// Resumes a fiber suspended on `showDialogue`.
  void completeDialogue() {
    if (_waitKind == EventFiberWaitKind.dialogue) {
      _pendingDialogue = null;
      _waitKind = EventFiberWaitKind.none;
    }
  }

  /// Submits 0-based [choiceIndex] to a fiber suspended on `promptChoice`.
  void submitChoice(int choiceIndex) {
    if (_waitKind != EventFiberWaitKind.choice) {
      return;
    }
    final opts = _pendingChoices;
    final clamped = (opts == null || opts.isEmpty)
        ? 0
        : choiceIndex.clamp(0, opts.length - 1);
    _lastChoiceIndex = clamped;
    if (_choiceTargetVarId >= 0) {
      blackboard.setVariable(_choiceTargetVarId, clamped);
    }
    _pendingChoices = null;
    _choiceTargetVarId = -1;
    _waitKind = EventFiberWaitKind.none;
  }

  /// Wakes a fiber waiting on `awaitSignal(signalId)`.
  void resolveSignal(String signalId) {
    if (_waitKind == EventFiberWaitKind.signal &&
        _awaitedSignalId == signalId) {
      _awaitedSignalId = null;
      _waitKind = EventFiberWaitKind.none;
    }
  }

  void _unwindCompletedFrames() {
    while (_stack.isNotEmpty &&
        _stack.last.ip >= _stack.last.script._ops.length) {
      _stack.removeLast();
    }
    if (_stack.isEmpty) {
      _waitKind = EventFiberWaitKind.finished;
    }
  }

  /// Advances the fiber by [dt] seconds.
  void tick(double dt) {
    _hitBudgetThisTick = false;
    if (_waitKind == EventFiberWaitKind.finished) {
      return;
    }

    if (_waitKind == EventFiberWaitKind.timer) {
      _waitRemaining -= math.max(0.0, dt);
      if (_waitRemaining > 1e-7) {
        return;
      }
      _waitRemaining = 0.0;
      _waitKind = EventFiberWaitKind.none;
    } else if (_waitKind != EventFiberWaitKind.none) {
      // Suspended on indeterminate player/world interaction:
      return;
    }

    var executed = 0;
    while (_stack.isNotEmpty && _waitKind == EventFiberWaitKind.none) {
      final frame = _stack.last;
      if (frame.ip >= frame.script._ops.length) {
        _stack.removeLast();
        continue;
      }

      if (executed >= maxInstructionsPerTick) {
        _hitBudgetThisTick = true;
        return;
      }
      executed++;

      final op = frame.script._ops[frame.ip++];
      switch (op.kind) {
        case _OpKind.setSwitch:
          blackboard.setSwitch(op.intArg, value: op.boolArg);
        case _OpKind.setVar:
          if (op.payload['isString'] == true) {
            blackboard.setVariable(op.intArg, op.strArg);
          } else if (op.boolArg) {
            blackboard.setVariable(op.intArg, op.numArg.round());
          } else {
            blackboard.setVariable(op.intArg, op.numArg);
          }
        case _OpKind.addVar:
          blackboard.addInt(op.intArg, op.numArg.round());
        case _OpKind.setSelfSwitch:
          blackboard.setSelfSwitch(
            mapId,
            eventId,
            op.strArg,
            value: op.boolArg,
          );
        case _OpKind.waitSeconds:
          if (op.numArg > 1e-7) {
            _waitRemaining = op.numArg;
            _waitKind = EventFiberWaitKind.timer;
            return;
          }
        case _OpKind.yieldTick:
          _unwindCompletedFrames();
          return;
        case _OpKind.showDialogue:
          _pendingDialogue = PendingEventDialogue(
            text: op.strArg,
            speaker: op.payload['speaker'] as String? ?? '',
            portraitId: op.payload['portraitId'] as String? ?? '',
          );
          _waitKind = EventFiberWaitKind.dialogue;
          return;
        case _OpKind.promptChoice:
          _pendingChoices = op.choices;
          _choiceTargetVarId = op.intArg;
          _waitKind = EventFiberWaitKind.choice;
          return;
        case _OpKind.awaitSignal:
          _awaitedSignalId = op.strArg;
          _waitKind = EventFiberWaitKind.signal;
          return;
        case _OpKind.jumpIfFalse:
          final ok = op.condition!.isSatisfied(
            blackboard,
            mapId: mapId,
            eventId: eventId,
          );
          if (!ok) {
            frame.ip = op.intArg;
          }
        case _OpKind.jump:
          frame.ip = op.intArg;
        case _OpKind.callCommon:
          final sub = commonEvents[op.strArg];
          if (sub == null) {
            throw StateError('Unknown CommonEvent "${op.strArg}"');
          }
          if (_stack.length >= maxCallStackDepth) {
            throw StateError(
              'EventFiber call stack overflow (depth >= $maxCallStackDepth)',
            );
          }
          _stack.add(_CallFrame(sub, 0));
        case _OpKind.emitAction:
          onEmitAction?.call(op.strArg, op.payload);
      }
    }

    if (_stack.isEmpty) {
      _waitKind = EventFiberWaitKind.finished;
    }
  }

  /// Captures the exact mid-execution instruction pointer stack and wait state
  /// for mid-cutscene save games (`StateSnapshotStore`).
  Map<String, Object?> saveState() {
    return <String, Object?>{
      'waitKind': _waitKind.name,
      'waitRemaining': _waitRemaining,
      'lastChoiceIndex': _lastChoiceIndex,
      'choiceTargetVarId': _choiceTargetVarId,
      if (_awaitedSignalId != null) 'awaitedSignalId': _awaitedSignalId,
      if (_pendingChoices != null) 'pendingChoices': _pendingChoices,
      if (_pendingDialogue != null)
        'pendingDialogue': <String, Object?>{
          'text': _pendingDialogue!.text,
          'speaker': _pendingDialogue!.speaker,
          'portraitId': _pendingDialogue!.portraitId,
        },
      'frames': <Map<String, Object?>>[
        for (final f in _stack)
          <String, Object?>{
            'scriptId': f.script.id,
            'ip': f.ip,
          },
      ],
    };
  }

  /// Restores call stack and suspension state from [saveState], resolving
  /// scripts from `rootScript` + [commonEvents].
  void restoreState(
    Map<String, Object?> snapshot, {
    required EventScript rootScript,
  }) {
    EventScript resolveScript(String id) {
      if (id == rootScript.id) {
        return rootScript;
      }
      final sub = commonEvents[id];
      if (sub != null) {
        return sub;
      }
      throw StateError('Cannot restore unknown EventScript "$id"');
    }

    _stack.clear();
    final rawFrames = snapshot['frames'] as List<Object?>? ?? const <Object?>[];
    for (final rf in rawFrames) {
      final m = rf! as Map<String, Object?>;
      final s = resolveScript(m['scriptId']! as String);
      final ip = (m['ip']! as num).toInt().clamp(0, s._ops.length);
      _stack.add(_CallFrame(s, ip));
    }

    final wkName = snapshot['waitKind'] as String? ?? 'none';
    _waitKind = EventFiberWaitKind.values.firstWhere(
      (e) => e.name == wkName,
      orElse: () => EventFiberWaitKind.none,
    );
    _waitRemaining = (snapshot['waitRemaining'] as num?)?.toDouble() ?? 0.0;
    _lastChoiceIndex = (snapshot['lastChoiceIndex'] as num?)?.toInt() ?? 0;
    _choiceTargetVarId = (snapshot['choiceTargetVarId'] as num?)?.toInt() ?? -1;
    _awaitedSignalId = snapshot['awaitedSignalId'] as String?;

    final rawChoices = snapshot['pendingChoices'];
    _pendingChoices = rawChoices is List
        ? rawChoices.map((e) => e.toString()).toList(growable: false)
        : null;

    final rawDlg = snapshot['pendingDialogue'];
    if (rawDlg is Map<String, Object?>) {
      _pendingDialogue = PendingEventDialogue(
        text: rawDlg['text'] as String? ?? '',
        speaker: rawDlg['speaker'] as String? ?? '',
        portraitId: rawDlg['portraitId'] as String? ?? '',
      );
    } else {
      _pendingDialogue = null;
    }
  }
}

/// Single conditional behavior page (`1..N`) inside an [EventPageComponent].
class EventPage({
  required this.condition,
  required this.trigger,
  required this.script,
  this.graphicId = '',
  this.solid = true,
  this.through = false,
}) {
  final EventPageCondition condition;
  final EventTriggerMode trigger;
  final EventScript script;
  final String graphicId;
  final bool solid;
  final bool through;
}

/// RPG Maker-style world entity component managing ordered [EventPage]s
/// (`Page 0 .. Page N-1`), reactively activating the **highest-index** page
/// whose [EventPageCondition] holds in [blackboard] **without per-frame
/// polling**, and driving `autorun`, `parallel`, and interactive `EventFiber`
/// execution.
class EventPageComponent({
  required this.mapId,
  required this.eventId,
  required this.blackboard,
  required this.pages,
  this.commonEvents = const <String, EventScript>{},
  this.onEmitAction,
  this.onAutorunLockChanged,
  this.onActivePageChanged,
  super.position,
  super.size,
  super.anchor,
  super.priority,
  super.key,
}) extends PositionComponent {
  final String mapId;
  final String eventId;
  final WorldStateBlackboard blackboard;
  final List<EventPage> pages;
  final Map<String, EventScript> commonEvents;
  final void Function(String actionName, Map<String, Object?> params)?
  onEmitAction;

  /// Invoked with `locked: true` when an `autorun` fiber starts locking player
  /// input, and `locked: false` when it finishes or switches away.
  final void Function({required bool locked})? onAutorunLockChanged;

  final void Function(int? pageIndex, EventPage? page)? onActivePageChanged;

  final Set<int> _watchedSwitches = <int>{};
  final Set<int> _watchedVars = <int>{};
  final Set<String> _watchedSelfChannels = <String>{};
  bool _hasCustomPredicates = false;

  int? _activePageIndex;
  EventFiber? _foregroundFiber;
  EventFiber? _parallelFiber;
  bool _autorunHoldingLock = false;
  int _pageEvaluationCount = 0;

  /// Currently active 0-based page index, or `null` if no page matches.
  int? get activePageIndex => _activePageIndex;

  /// Currently active [EventPage], or `null` if no page matches.
  EventPage? get activePage =>
      _activePageIndex == null ? null : pages[_activePageIndex!];

  /// Active foreground (`actionButton` / `playerTouch` / `eventTouch` /
  /// `autorun`) fiber, if running.
  EventFiber? get foregroundFiber => _foregroundFiber;

  /// Active background `parallel` fiber, if running.
  EventFiber? get parallelFiber => _parallelFiber;

  /// Whether an active `autorun` fiber currently holds a cutscene input lock.
  bool get isAutorunLockingInput => _autorunHoldingLock;

  /// Number of times page conditions were evaluated (diagnostic proving `0`
  /// per-frame polling when unrelated blackboard keys mutate).
  int get pageEvaluationCount => _pageEvaluationCount;

  @override
  void onMount() {
    super.onMount();
    _bindDependencies();
    _reevaluatePages();
  }

  @override
  void onRemove() {
    _unbindDependencies();
    _setAutorunLock(locked: false);
    super.onRemove();
  }

  /// Triggers the active page if its mode matches [trigger] (`actionButton`,
  /// `playerTouch`, or `eventTouch`) and no foreground fiber is already busy.
  bool triggerInteraction(EventTriggerMode trigger) {
    final page = activePage;
    if (page == null || _foregroundFiber != null) {
      return false;
    }
    final matches =
        page.trigger == trigger ||
        (page.trigger == EventTriggerMode.eventTouch &&
            trigger == EventTriggerMode.playerTouch);
    if (!matches) {
      return false;
    }
    _foregroundFiber = _spawnFiber(page.script);
    return true;
  }

  @override
  void update(double dt) {
    super.update(dt);
    final page = activePage;

    // 1. Autorun auto-start while active:
    if (page != null &&
        page.trigger == EventTriggerMode.autorun &&
        _foregroundFiber == null) {
      _foregroundFiber = _spawnFiber(page.script);
      _setAutorunLock(locked: true);
    }

    // 2. Step foreground fiber:
    final fg = _foregroundFiber;
    if (fg != null) {
      fg.tick(dt);
      if (fg.isFinished) {
        _foregroundFiber = null;
        _setAutorunLock(locked: false);
      }
    }

    // 3. Step parallel background fiber (restarts automatically on completion
    // just like RPG Maker Parallel Process!):
    if (page != null && page.trigger == EventTriggerMode.parallel) {
      _parallelFiber ??= _spawnFiber(page.script);
      _parallelFiber!.tick(dt);
      if (_parallelFiber != null && _parallelFiber!.isFinished) {
        _parallelFiber = null;
      }
    }
  }

  EventFiber _spawnFiber(EventScript script) {
    return EventFiber(
      blackboard: blackboard,
      rootScript: script,
      mapId: mapId,
      eventId: eventId,
      commonEvents: commonEvents,
      onEmitAction: onEmitAction,
    );
  }

  void _setAutorunLock({required bool locked}) {
    if (_autorunHoldingLock != locked) {
      _autorunHoldingLock = locked;
      onAutorunLockChanged?.call(locked: locked);
    }
  }

  void _bindDependencies() {
    for (final p in pages) {
      final c = p.condition;
      _watchedSwitches.addAll(c.requiredSwitches.keys);
      for (final vc in c.variableConditions) {
        _watchedVars.add(vc.variableId);
      }
      _watchedSelfChannels.addAll(c.requiredSelfSwitches.keys);
      if (c.customPredicate != null) {
        _hasCustomPredicates = true;
      }
    }
    for (final sw in _watchedSwitches) {
      blackboard.watchSwitch(sw, _reevaluatePages);
    }
    for (final v in _watchedVars) {
      blackboard.watchVariable(v, _reevaluatePages);
    }
    for (final ch in _watchedSelfChannels) {
      blackboard.watchSelfSwitch(mapId, eventId, ch, _reevaluatePages);
    }
    if (_hasCustomPredicates) {
      blackboard.addGlobalListener(_reevaluatePages);
    }
  }

  void _unbindDependencies() {
    for (final sw in _watchedSwitches) {
      blackboard.unwatchSwitch(sw, _reevaluatePages);
    }
    for (final v in _watchedVars) {
      blackboard.unwatchVariable(v, _reevaluatePages);
    }
    for (final ch in _watchedSelfChannels) {
      blackboard.unwatchSelfSwitch(mapId, eventId, ch, _reevaluatePages);
    }
    if (_hasCustomPredicates) {
      blackboard.removeGlobalListener(_reevaluatePages);
    }
    _watchedSwitches.clear();
    _watchedVars.clear();
    _watchedSelfChannels.clear();
    _hasCustomPredicates = false;
  }

  void _reevaluatePages() {
    _pageEvaluationCount++;
    int? matched;
    for (var i = pages.length - 1; i >= 0; i--) {
      if (pages[i].condition.isSatisfied(
        blackboard,
        mapId: mapId,
        eventId: eventId,
      )) {
        matched = i;
        break;
      }
    }
    if (matched == _activePageIndex) {
      return;
    }
    _activePageIndex = matched;
    _parallelFiber = null;

    // If an autorun fiber was active for the old page and the new page is no
    // longer autorun, release the autorun lock cleanly when foreground finishes
    // (or immediately if it was an autorun page replaced by a passive page!):
    if (_autorunHoldingLock &&
        (matched == null ||
            pages[matched].trigger != EventTriggerMode.autorun)) {
      _foregroundFiber = null;
      _setAutorunLock(locked: false);
    }

    onActivePageChanged?.call(matched, activePage);
  }
}
