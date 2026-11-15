import 'dart:math' as math;

import 'package:flame/src/rpg/event_script.dart';
import 'package:flame/src/rpg/world_state_blackboard.dart';

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
        _stack.last.ip >= _stack.last.script.ops.length) {
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
      return;
    }

    var executed = 0;
    while (_stack.isNotEmpty && _waitKind == EventFiberWaitKind.none) {
      final frame = _stack.last;
      if (frame.ip >= frame.script.ops.length) {
        _stack.removeLast();
        continue;
      }

      if (executed >= maxInstructionsPerTick) {
        _hitBudgetThisTick = true;
        return;
      }
      executed++;

      final op = frame.script.ops[frame.ip++];
      switch (op.kind) {
        case EventOpKind.setSwitch:
          blackboard.setSwitch(op.intArg, value: op.boolArg);
        case EventOpKind.setVar:
          if (op.payload['isString'] == true) {
            blackboard.setVariable(op.intArg, op.strArg);
          } else if (op.boolArg) {
            blackboard.setVariable(op.intArg, op.numArg.round());
          } else {
            blackboard.setVariable(op.intArg, op.numArg);
          }
        case EventOpKind.addVar:
          blackboard.addInt(op.intArg, op.numArg.round());
        case EventOpKind.setSelfSwitch:
          blackboard.setSelfSwitch(
            mapId,
            eventId,
            op.strArg,
            value: op.boolArg,
          );
        case EventOpKind.waitSeconds:
          if (op.numArg > 1e-7) {
            _waitRemaining = op.numArg;
            _waitKind = EventFiberWaitKind.timer;
            return;
          }
        case EventOpKind.yieldTick:
          _unwindCompletedFrames();
          return;
        case EventOpKind.showDialogue:
          _pendingDialogue = PendingEventDialogue(
            text: op.strArg,
            speaker: op.payload['speaker'] as String? ?? '',
            portraitId: op.payload['portraitId'] as String? ?? '',
          );
          _waitKind = EventFiberWaitKind.dialogue;
          return;
        case EventOpKind.promptChoice:
          _pendingChoices = op.choices;
          _choiceTargetVarId = op.intArg;
          _waitKind = EventFiberWaitKind.choice;
          return;
        case EventOpKind.awaitSignal:
          _awaitedSignalId = op.strArg;
          _waitKind = EventFiberWaitKind.signal;
          return;
        case EventOpKind.jumpIfFalse:
          final ok = op.condition!.isSatisfied(
            blackboard,
            mapId: mapId,
            eventId: eventId,
          );
          if (!ok) {
            frame.ip = op.intArg;
          }
        case EventOpKind.jump:
          frame.ip = op.intArg;
        case EventOpKind.callCommon:
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
        case EventOpKind.emitAction:
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
      final ip = (m['ip']! as num).toInt().clamp(0, s.ops.length);
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
